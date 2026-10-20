import AppKit
import CoreText

/// Текстовые документы: DOCX, ODT, RTF(D), HTML, TXT, Markdown, EPUB, Pages.
public struct DocumentEngine: Sendable {
    public let tools: ExternalTools
    public init(tools: ExternalTools) { self.tools = tools }

    public func convert(_ input: URL, to ext: String, output: URL, scratch: URL, progress: @escaping ProgressHandler) async throws {
        progress(nil)
        let attr = try await Self.read(input, scratch: scratch)
        progress(0.5)
        switch ext {
        case "pages":
            let docx = scratch.appendingPathComponent("tmp.docx")
            try Self.writeAttributed(attr, to: docx, ext: "docx")
            try await OfficeScripting.pagesSave(docx, as: output)
        case "epub":
            let html = try await Self.htmlBody(attr)
            try await EpubWriter.write(title: input.deletingPathExtension().lastPathComponent, chapters: [html], to: output, scratch: scratch)
        default:
            try Self.writeAttributed(attr, to: output, ext: ext)
        }
        progress(1)
    }

    // MARK: Чтение

    public static func read(_ input: URL, scratch: URL) async throws -> NSAttributedString {
        let ext = FileCategory.canonical(ext: input.pathExtension)
        switch ext {
        case "txt":
            let text = try String(contentsOf: input, encoding: .utf8)
            return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        case "md":
            let md = try String(contentsOf: input, encoding: .utf8)
            return try await html(Markdown.toHTML(md))
        case "epub":
            let book = try await EpubWriter.readHTML(input, scratch: scratch)
            return try await html(book.html)
        case "pages":
            let docx = scratch.appendingPathComponent("from-pages.docx")
            try await OfficeScripting.pagesExport(input, to: docx, format: "Microsoft Word")
            return try NSAttributedString(url: docx, options: [:], documentAttributes: nil)
        case "html", "htm":
            return try await html(String(contentsOf: input, encoding: .utf8))
        default:
            // DOCX, ODT, RTF, RTFD — системные импортёры, без WebKit.
            do {
                return try NSAttributedString(url: input, options: [:], documentAttributes: nil)
            } catch {
                throw DropwheelError("Не удалось прочитать \(input.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// HTML-импорт требует главного потока. Перед импортом вырезаем всё, что может сходить в сеть:
    /// системный импортёр сам загружает удалённые картинки и стили, а приложение обещает работать офлайн.
    @MainActor
    static func html(_ string: String) throws -> NSAttributedString {
        let safe = OfflineHTML.sanitize(string)
        guard let a = NSAttributedString(html: Data(safe.utf8), options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) else {
            throw DropwheelError("Не удалось разобрать HTML")
        }
        return a
    }

    // MARK: Запись

    public static func writeAttributed(_ attr: NSAttributedString, to url: URL, ext: String) throws {
        let range = NSRange(location: 0, length: attr.length)
        switch ext {
        case "docx":
            try attr.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: url)
        case "odt":
            try attr.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.openDocument]).write(to: url)
        case "rtf":
            try attr.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: url)
        case "html":
            try attr.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html,
                                                            .characterEncoding: String.Encoding.utf8.rawValue]).write(to: url)
        case "txt":
            try attr.string.replacingOccurrences(of: "\u{000C}", with: "\n\n").write(to: url, atomically: true, encoding: .utf8)
        case "md":
            try Markdown.fromAttributed(attr).write(to: url, atomically: true, encoding: .utf8)
        case "pdf":
            try PDFTypesetter.write(attr, to: url)
        default:
            throw DropwheelError("Формат \(ext.uppercased()) не поддерживается для документов")
        }
    }

    /// Тело HTML без <head> — для глав EPUB.
    static func htmlBody(_ attr: NSAttributedString) async throws -> String {
        let data = try attr.data(from: NSRange(location: 0, length: attr.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.html,
                                                      .characterEncoding: String.Encoding.utf8.rawValue,
                                                      .excludedElements: ["doctype", "html", "head", "body", "xml", "font", "span"]])
        var html = String(decoding: data, as: UTF8.self)
        // XHTML требует закрытых пустых тегов.
        html = html.replacingOccurrences(of: "<br>", with: "<br/>").replacingOccurrences(of: "<hr>", with: "<hr/>")
        html = html.replacingOccurrences(of: "<img([^>]*?)(?<!/)>", with: "<img$1/>", options: .regularExpression)
        html = html.replacing(/<meta[^>]*>/) { _ in "" }
        return html
    }
}

/// Постраничная вёрстка NSAttributedString в PDF формата A4.
public enum PDFTypesetter {
    public static func write(_ attr: NSAttributedString, to url: URL, pageSize: CGSize = CGSize(width: 595, height: 842), margin: CGFloat = 56) throws {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(url: url as CFURL), let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw DropwheelError("Не удалось создать PDF")
        }
        let text = attr.length > 0 ? attr : NSAttributedString(string: " ")
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        var location = 0
        repeat {
            ctx.beginPDFPage(nil)
            let path = CGPath(rect: CGRect(x: margin, y: margin, width: pageSize.width - 2 * margin, height: pageSize.height - 2 * margin), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            ctx.endPDFPage()
            if visible.length == 0 { break }
            location += visible.length
        } while location < text.length
        ctx.closePDF()
    }
}

/// Небольшой конвертер Markdown ⇄ HTML/NSAttributedString: заголовки, абзацы, списки, жирный, курсив, код, ссылки.
public enum Markdown {
    public static func toHTML(_ md: String) -> String {
        var html: [String] = []
        var inList: String?
        var inCode = false
        var para: [String] = []
        func flush() {
            if !para.isEmpty { html.append("<p>" + inline(para.joined(separator: " ")) + "</p>"); para = [] }
        }
        func closeList() { if let l = inList { html.append("</\(l)>"); inList = nil } }
        for raw in md.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flush(); closeList()
                html.append(inCode ? "</code></pre>" : "<pre><code>")
                inCode.toggle(); continue
            }
            if inCode { html.append(raw.xmlEscaped); continue }
            if line.isEmpty { flush(); closeList(); continue }
            if let m = line.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                flush(); closeList()
                html.append("<h\(m.1.count)>\(inline(String(m.2)))</h\(m.1.count)>"); continue
            }
            if let m = line.firstMatch(of: /^([-*+]|\d+[.)])\s+(.*)$/) {
                flush()
                let tag = m.1.first?.isNumber == true ? "ol" : "ul"
                if inList != tag { closeList(); html.append("<\(tag)>"); inList = tag }
                html.append("<li>\(inline(String(m.2)))</li>"); continue
            }
            if line.hasPrefix(">") { flush(); closeList(); html.append("<blockquote>\(inline(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))</blockquote>"); continue }
            if line.allSatisfy({ $0 == "-" || $0 == "*" }) && line.count >= 3 { flush(); closeList(); html.append("<hr/>"); continue }
            para.append(line)
        }
        flush(); closeList()
        if inCode { html.append("</code></pre>") }
        return "<html><head><meta charset=\"utf-8\"></head><body>" + html.joined(separator: "\n") + "</body></html>"
    }

    static func inline(_ s: String) -> String {
        var t = s.xmlEscaped
        t = t.replacing(/`([^`]+)`/) { "<code>\($0.1)</code>" }
        t = t.replacing(/\*\*([^*]+)\*\*/) { "<b>\($0.1)</b>" }
        t = t.replacing(/__([^_]+)__/) { "<b>\($0.1)</b>" }
        // Lookbehind есть только в ICU-регулярках, поэтому здесь NSString-API.
        t = t.replacingOccurrences(of: "(?<![*\\w])\\*([^*]+)\\*(?![*\\w])", with: "<i>$1</i>", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?<![_\\w])_([^_]+)_(?![_\\w])", with: "<i>$1</i>", options: .regularExpression)
        t = t.replacing(/\[([^\]]+)\]\(([^)\s]+)\)/) { "<a href=\"\($0.2)\">\($0.1)</a>" }
        return t
    }

    /// Обратное направление: размер шрифта → заголовок, жирный/курсив → ** и *.
    public static func fromAttributed(_ attr: NSAttributedString) -> String {
        let ns = attr.string as NSString
        var sizes: [CGFloat] = []
        attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { v, r, _ in
            if let f = v as? NSFont { sizes += Array(repeating: f.pointSize, count: max(1, r.length / 20)) }
        }
        let body = sizes.median
        var out: [String] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { _, range, _, _ in
            guard range.length > 0 else { out.append(""); return }
            var line = ""
            var maxSize: CGFloat = 0
            var allBold = true
            attr.enumerateAttributes(in: range) { attrs, r, _ in
                var piece = ns.substring(with: r).replacingOccurrences(of: "\u{000C}", with: "")
                let font = attrs[.font] as? NSFont
                let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
                maxSize = max(maxSize, font?.pointSize ?? body)
                let bold = traits.contains(.boldFontMask), italic = traits.contains(.italicFontMask)
                if !bold { allBold = false }
                let trimmed = piece.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    if italic { piece = piece.replacingOccurrences(of: trimmed, with: "*\(trimmed)*") }
                    if bold { piece = piece.replacingOccurrences(of: trimmed, with: "**\(trimmed)**") }
                }
                if let link = attrs[.link] { piece = "[\(piece)](\(link))" }
                line += piece
            }
            let plain = ns.substring(with: range).trimmingCharacters(in: .whitespaces)
            if maxSize >= body * 1.5, plain.count < 120 { line = "# " + plain }
            else if maxSize >= body * 1.2 || (allBold && plain.count < 80), plain.count < 120 { line = "## " + plain }
            // Маркеры списков из NSTextList уже вписаны в текст как «•» или «1.».
            line = line.replacingOccurrences(of: "^\\s*[•◦▪]\\s*", with: "- ", options: .regularExpression)
            out.append(line)
            out.append("")
        }
        return out.joined(separator: "\n").replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
