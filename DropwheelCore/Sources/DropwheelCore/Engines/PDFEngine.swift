import AppKit
import PDFKit

/// PDF: рендер страниц, извлечение текста, сборка Office/EPUB, merge/split/organize, сжатие.
public struct PDFEngine: Sendable {
    public let tools: ExternalTools
    public init(tools: ExternalTools) { self.tools = tools }

    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw DropwheelError("Не удалось открыть PDF \(url.lastPathComponent)") }
        if doc.isLocked { throw DropwheelError("PDF защищён паролем") }
        return doc
    }

    public func convert(_ input: URL, to ext: String, scratch: URL, progress: @escaping ProgressHandler) async throws -> [URL] {
        let doc = try Self.open(input)
        switch ext {
        case "jpg", "png":
            return try rasterize(input, original: input, ext: ext, progress: progress)
        case "txt":
            return [try writeText(Self.plainText(doc), beside: input, ext: "txt")]
        case "md":
            return [try writeText(Self.markdown(doc), beside: input, ext: "md")]
        case "docx", "pages":
            let attr = Self.attributedText(doc)
            let docx = scratch.appendingPathComponent("out.docx")
            try DocumentEngine.writeAttributed(attr, to: docx, ext: "docx")
            if ext == "pages" {
                let pages = scratch.appendingPathComponent("out.pages")
                try await OfficeScripting.pagesSave(docx, as: pages)
                return [try Scratch.commit(pages, to: OutputNamer.sibling(of: input, ext: "pages"))]
            }
            return [try Scratch.commit(docx, to: OutputNamer.sibling(of: input, ext: "docx"))]
        case "epub":
            let html = Self.pagesAsHTML(doc)
            let out = scratch.appendingPathComponent("out.epub")
            try await EpubWriter.write(title: input.deletingPathExtension().lastPathComponent, chapters: html, to: out, scratch: scratch)
            return [try Scratch.commit(out, to: OutputNamer.sibling(of: input, ext: "epub"))]
        case "pptx":
            let dir = scratch.appendingPathComponent("slides", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var images: [(URL, CGSize)] = []
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let png = dir.appendingPathComponent("p\(i + 1).png")
                let cg = Self.render(page, dpi: 200)
                try ImageEngine.writeImageIO(cg, to: png, type: .png, quality: 1, metadata: nil)
                images.append((png, page.bounds(for: .mediaBox).size))
                progress(Double(i + 1) / Double(doc.pageCount) * 0.8)
            }
            let out = scratch.appendingPathComponent("out.pptx")
            try await OOXML.writePptx(slides: images, to: out, scratch: scratch)
            return [try Scratch.commit(out, to: OutputNamer.sibling(of: input, ext: "pptx"))]
        case "xlsx":
            let sheets = (0..<doc.pageCount).compactMap { i -> (String, [[String]])? in
                guard let page = doc.page(at: i) else { return nil }
                let rows = Self.tableRows(page: page)
                return rows.isEmpty ? nil : ("Стр. \(i + 1)", rows)
            }
            guard !sheets.isEmpty else { throw DropwheelError("В PDF нет текста — это скан. Распознавание текста не поддерживается") }
            let out = scratch.appendingPathComponent("out.xlsx")
            try await OOXML.writeXlsx(sheets: sheets, to: out, scratch: scratch)
            return [try Scratch.commit(out, to: OutputNamer.sibling(of: input, ext: "xlsx"))]
        default:
            throw DropwheelError("Формат \(ext.uppercased()) не поддерживается для PDF")
        }
    }

    func writeText(_ text: String, beside input: URL, ext: String) throws -> URL {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DropwheelError("В PDF нет текста — это скан. Распознавание текста не поддерживается")
        }
        return try Staged.file(beside: OutputNamer.sibling(of: input, ext: ext)) { try text.write(to: $0, atomically: true, encoding: .utf8) }
    }

    // MARK: Текст

    public static func plainText(_ doc: PDFDocument) -> String {
        (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n\n")
    }

    static func attributedText(_ doc: PDFDocument) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let a = page.attributedString else { continue }
            if out.length > 0 { out.append(NSAttributedString(string: "\u{000C}")) } // разрыв страницы
            out.append(a)
        }
        return out
    }

    /// Абзацы по пустым строкам; короткие строки в верхнем регистре или крупным шрифтом считаем заголовками.
    static func markdown(_ doc: PDFDocument) -> String {
        var md: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let attr = page.attributedString else { continue }
            let sizes = Self.fontSizes(attr)
            let body = sizes.median
            attr.string.components(separatedBy: "\n").enumerated().forEach { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { md.append(""); return }
                let range = (attr.string as NSString).range(of: line)
                var size = body
                if range.location != NSNotFound, range.length > 0,
                   let f = attr.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont { size = f.pointSize }
                if size >= body * 1.5, trimmed.count < 80 { md.append("# " + trimmed) }
                else if size >= body * 1.2, trimmed.count < 100 { md.append("## " + trimmed) }
                else { md.append(trimmed) }
            }
            md.append("")
        }
        return md.joined(separator: "\n").replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    }

    static func fontSizes(_ a: NSAttributedString) -> [CGFloat] {
        var sizes: [CGFloat] = []
        a.enumerateAttribute(.font, in: NSRange(location: 0, length: a.length)) { v, r, _ in
            if let f = v as? NSFont { sizes += Array(repeating: f.pointSize, count: max(1, r.length / 10)) }
        }
        return sizes
    }

    static func pagesAsHTML(_ doc: PDFDocument) -> [String] {
        // Главы по 10 страниц: текст перетекает, как в обычной книге.
        var chapters: [String] = []
        var current = ""
        for i in 0..<doc.pageCount {
            let text = doc.page(at: i)?.string ?? ""
            let paras = text.components(separatedBy: "\n\n").map {
                "<p>" + EpubWriter.escape($0.replacingOccurrences(of: "\n", with: " ")) + "</p>"
            }
            current += paras.joined(separator: "\n")
            if (i + 1) % 10 == 0 { chapters.append(current); current = "" }
        }
        if !current.isEmpty || chapters.isEmpty { chapters.append(current) }
        return chapters
    }

    /// Строки таблицы по геометрии. PDFKit вставляет в `page.string` пробел на месте любого
    /// горизонтального разрыва, и выделение этого пробела занимает весь разрыв: обычный пробел
    /// уже половины высоты строки, межколоночный — намного шире. По этому признаку и режем ячейки.
    /// (`characterBounds(at:)` не годится: его индексы расходятся со `string` на переводах строк.)
    static func tableRows(page: PDFPage) -> [[String]] {
        guard let raw = page.string else { return [] }
        let text = raw as NSString
        var rows: [[String]] = []
        var row: [String] = [], cell = ""
        func endCell() {
            let t = cell.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { row.append(t) }
            cell = ""
        }
        func endRow() {
            endCell()
            if !row.isEmpty { rows.append(row) }
            row = []
        }
        for i in 0..<text.length {
            guard let scalar = UnicodeScalar(text.character(at: i)) else { continue }
            if CharacterSet.newlines.contains(scalar) { endRow(); continue }
            if CharacterSet.whitespaces.contains(scalar) {
                let b = page.selection(for: NSRange(location: i, length: 1))?.bounds(for: page) ?? .zero
                if scalar == "\t" || (b.height > 0 && b.width > b.height * 0.5) { endCell() } else { cell += " " }
                continue
            }
            cell.unicodeScalars.append(scalar)
        }
        endRow()
        return rows
    }

    // MARK: Рендер

    public static func render(_ page: PDFPage, dpi: CGFloat) -> CGImage {
        let box = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let scale = dpi / 72
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()!
    }

    /// Все страницы в картинки 300 DPI. Одна страница — один файл, несколько — папка рядом.
    public func rasterize(_ pdf: URL, original: URL, ext: String, progress: @escaping ProgressHandler) throws -> [URL] {
        let doc = try Self.open(pdf)
        let type = ImageEngine.utType(for: ext)!
        if doc.pageCount == 1, let page = doc.page(at: 0) {
            return [try Staged.file(beside: OutputNamer.sibling(of: original, ext: ext)) {
                try ImageEngine.writeImageIO(Self.render(page, dpi: 300), to: $0, type: type, quality: 0.92, metadata: nil)
            }]
        }
        return [try Staged.folder(beside: original, suffix: ext.uppercased()) { folder in
        let base = original.deletingPathExtension().lastPathComponent
        let digits = max(2, String(doc.pageCount).count)
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else { continue }
            let name = String(format: "%@ %0\(digits)d.%@", base, i + 1, ext)
            try ImageEngine.writeImageIO(Self.render(page, dpi: 300), to: folder.appendingPathComponent(name), type: type, quality: 0.92, metadata: nil)
            progress(Double(i + 1) / Double(doc.pageCount))
        }
        }]
    }

    // MARK: Инструменты

    public func merge(_ inputs: [URL], progress: @escaping ProgressHandler) throws -> URL {
        let out = PDFDocument()
        for (n, url) in inputs.enumerated() {
            let doc = try Self.open(url)
            for i in 0..<doc.pageCount { if let p = doc.page(at: i) { out.insert(p, at: out.pageCount) } }
            progress(Double(n + 1) / Double(inputs.count))
        }
        return try Staged.file(beside: OutputNamer.sibling(of: inputs[0], ext: "pdf", suffix: "объединённый")) {
            guard out.write(to: $0) else { throw DropwheelError("Не удалось записать PDF") }
        }
    }

    /// Разбивка: каждые `every` страниц или по диапазонам вида [1...3, 4...4].
    public func split(_ input: URL, ranges: [ClosedRange<Int>]) throws -> URL {
        let doc = try Self.open(input)
        return try Staged.folder(beside: input, suffix: "части") { folder in
        let base = input.deletingPathExtension().lastPathComponent
        for r in ranges {
            let part = PDFDocument()
            for i in r where i >= 1 && i <= doc.pageCount {
                if let p = doc.page(at: i - 1) { part.insert(p, at: part.pageCount) }
            }
            guard part.pageCount > 0 else { continue }
            let label = r.count == 1 ? "\(r.lowerBound)" : "\(r.lowerBound)-\(r.upperBound)"
            guard part.write(to: folder.appendingPathComponent("\(base) стр. \(label).pdf")) else { throw DropwheelError("Не удалось записать часть PDF") }
        }
        }
    }

    public static func evenRanges(pageCount: Int, every: Int) -> [ClosedRange<Int>] {
        guard pageCount > 0, every > 0 else { return [] }
        return stride(from: 1, through: pageCount, by: every).map { $0...min(pageCount, $0 + every - 1) }
    }

    /// Новый PDF из описания страниц: индекс исходной страницы (0-based) и поворот.
    public func organize(_ input: URL, pages: [(index: Int, rotation: Int)]) throws -> URL {
        let doc = try Self.open(input)
        let out = PDFDocument()
        for spec in pages {
            guard let original = doc.page(at: spec.index), let copy = original.copy() as? PDFPage else { continue }
            copy.rotation = ((original.rotation + spec.rotation) % 360 + 360) % 360
            out.insert(copy, at: out.pageCount)
        }
        guard out.pageCount > 0 else { throw DropwheelError("В документе не осталось страниц") }
        return try Staged.file(beside: OutputNamer.sibling(of: input, ext: "pdf", suffix: "упорядоченный")) {
            guard out.write(to: $0) else { throw DropwheelError("Не удалось записать PDF") }
        }
    }

    /// Сжатие: страницы перерисовываются с JPEG-картинками в заданном DPI и качестве.
    public func compress(_ input: URL, dpi: CGFloat, quality: Double, progress: @escaping ProgressHandler) throws -> URL {
        let doc = try Self.open(input)
        return try Staged.file(beside: OutputNamer.sibling(of: input, ext: "pdf", suffix: "сжатый")) { dest in
        guard let consumer = CGDataConsumer(url: dest as CFURL) else { throw DropwheelError("Не удалось создать файл") }
        var mediaBox = CGRect.zero
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw DropwheelError("Не удалось создать PDF") }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            let size = page.rotation % 180 != 0 ? CGSize(width: box.height, height: box.width) : box.size
            var rect = CGRect(origin: .zero, size: size)
            let raster = Self.render(page, dpi: dpi)
            let data = NSMutableData()
            if let dst = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(dst, raster, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                CGImageDestinationFinalize(dst)
            }
            let jpeg = CGImage(jpegDataProviderSource: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent) ?? raster
            ctx.beginPage(mediaBox: &rect)
            ctx.draw(jpeg, in: rect)
            ctx.endPage()
            progress(Double(i + 1) / Double(doc.pageCount))
        }
        ctx.closePDF()
        }
    }
}

extension Array where Element == CGFloat {
    var median: CGFloat {
        guard !isEmpty else { return 12 }
        return sorted()[count / 2]
    }
}
