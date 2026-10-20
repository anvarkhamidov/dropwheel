import AppKit
import CoreText

/// Таблицы: XLSX, ODS, CSV, TSV ⇄ друг в друга и в PDF; XLS и Numbers — через Numbers.app.
public struct SheetEngine: Sendable {
    public typealias Sheet = (String, [[String]])
    public let tools: ExternalTools
    public init(tools: ExternalTools) { self.tools = tools }

    public func convert(_ input: URL, to ext: String, output: URL, scratch: URL) async throws {
        let sheets = try await read(input, scratch: scratch)
        try await write(sheets, to: output, ext: ext, scratch: scratch)
    }

    public func read(_ input: URL, scratch: URL) async throws -> [Sheet] {
        switch input.pathExtension.lowercased() {
        case "xlsx": return try await OOXML.readXlsx(input, scratch: scratch)
        case "ods": return try await ODS.read(input, scratch: scratch)
        case "csv": return [(Self.sheetName(input), CSV.parse(try Self.text(input), separator: CSV.detectSeparator(try Self.text(input))))]
        case "tsv": return [(Self.sheetName(input), CSV.parse(try Self.text(input), separator: "\t"))]
        case "xls", "numbers":
            let xlsx = scratch.appendingPathComponent("from-numbers.xlsx")
            try await OfficeScripting.numbersExport(input, to: xlsx)
            return try await OOXML.readXlsx(xlsx, scratch: scratch)
        default: throw DropwheelError("Формат таблицы не поддерживается")
        }
    }

    public func write(_ sheets: [Sheet], to output: URL, ext: String, scratch: URL) async throws {
        switch ext {
        case "xlsx": try await OOXML.writeXlsx(sheets: sheets, to: output, scratch: scratch)
        case "ods": try await ODS.write(sheets, to: output, scratch: scratch)
        case "csv": try CSV.write(sheets.first?.1 ?? [], separator: ",").write(to: output, atomically: true, encoding: .utf8)
        case "tsv": try CSV.write(sheets.first?.1 ?? [], separator: "\t").write(to: output, atomically: true, encoding: .utf8)
        case "pdf": try TablePDF.write(sheets, to: output)
        default: throw DropwheelError("Формат \(ext.uppercased()) не поддерживается для таблиц")
        }
    }

    static func sheetName(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    static func text(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8) { return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s }
        return String(data: data, encoding: .windowsCP1251) ?? String(decoding: data, as: UTF8.self)
    }
}

/// CSV по RFC 4180: кавычки, переводы строк внутри полей, удвоенные кавычки.
public enum CSV {
    public static func detectSeparator(_ text: String) -> Character {
        let head = text.prefix(4000)
        let counts: [(Character, Int)] = [",", ";", "\t"].map { c in (c, head.filter { $0 == c }.count) }
        return counts.max { $0.1 < $1.1 }?.0 ?? ","
    }

    public static func parse(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false
        var it = Array(text).makeIterator()
        var pending: Character? = nil
        func next() -> Character? { if let p = pending { pending = nil; return p }; return it.next() }
        while let c = next() {
            if quoted {
                if c == "\"" {
                    if let n = next() { if n == "\"" { field.append("\"") } else { quoted = false; pending = n } } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == separator {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); rows.append(row); row = []; field = ""
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    public static func write(_ rows: [[String]], separator: Character) -> String {
        rows.map { row in
            row.map { v in
                let needs = v.contains(separator) || v.contains("\"") || v.contains("\n") || v.contains("\r")
                return needs ? "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : v
            }.joined(separator: String(separator))
        }.joined(separator: "\n") + "\n"
    }
}

/// OpenDocument Spreadsheet: content.xml с table:table.
public enum ODS {
    public static func read(_ input: URL, scratch: URL) async throws -> [SheetEngine.Sheet] {
        let dir = scratch.appendingPathComponent("ods-in", isDirectory: true)
        try await Zip.unpack(input, into: dir)
        let data = try Data(contentsOf: dir.appendingPathComponent("content.xml"))
        let p = ODSParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        guard !p.sheets.isEmpty else { throw DropwheelError("В файле нет листов") }
        return p.sheets
    }

    public static func write(_ sheets: [SheetEngine.Sheet], to output: URL, scratch: URL) async throws {
        let dir = scratch.appendingPathComponent("ods-\(UUID().uuidString)", isDirectory: true)
        var tables = ""
        for (name, rows) in sheets {
            tables += "<table:table table:name=\"\(name.xmlEscaped)\">"
            let cols = rows.map(\.count).max() ?? 1
            tables += "<table:table-column table:number-columns-repeated=\"\(max(cols, 1))\"/>"
            for row in rows {
                tables += "<table:table-row>"
                for v in row {
                    if let n = CellValue.number(v) {
                        tables += "<table:table-cell office:value-type=\"float\" office:value=\"\(CellValue.format(n))\"><text:p>\(v.xmlEscaped)</text:p></table:table-cell>"
                    } else {
                        tables += "<table:table-cell office:value-type=\"string\"><text:p>\(v.xmlEscaped)</text:p></table:table-cell>"
                    }
                }
                tables += "</table:table-row>"
            }
            tables += "</table:table>"
        }
        let ns = "xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\""
        let files: [String: Data] = [
            "mimetype": "application/vnd.oasis.opendocument.spreadsheet".data,
            "content.xml": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><office:document-content \(ns) office:version=\"1.3\"><office:body><office:spreadsheet>\(tables)</office:spreadsheet></office:body></office:document-content>".data,
            "META-INF/manifest.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3">
            <manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/>
            <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
            </manifest:manifest>
            """.data,
        ]
        try Zip.write(files, into: dir)
        try await Zip.pack(dir, to: output, storedFirst: "mimetype")
    }
}

final class ODSParser: NSObject, XMLParserDelegate {
    var sheets: [SheetEngine.Sheet] = []
    var name = "", rows: [[String]] = [], row: [String] = []
    var cell = "", inCell = false, inP = false, hasValue = false
    var repeatCols = 1, repeatRows = 1

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String] = [:]) {
        switch q ?? el {
        case "table:table": name = a["table:name"] ?? "Лист"; rows = []
        case "table:table-row": row = []; repeatRows = min(Int(a["table:number-rows-repeated"] ?? "1") ?? 1, 1000)
        case "table:table-cell", "table:covered-table-cell":
            inCell = true; cell = ""; hasValue = false
            repeatCols = min(Int(a["table:number-columns-repeated"] ?? "1") ?? 1, 1000)
            // Для чисел точное значение лежит в атрибуте; текст ячейки — лишь его отображение.
            if let v = a["office:value"], (a["office:value-type"] ?? "") != "string" {
                cell = v.hasSuffix(".0") ? String(v.dropLast(2)) : v
                hasValue = true
            }
        case "text:p":
            if inCell && !hasValue && !cell.isEmpty { cell += "\n" }
            inP = true
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) {
        if inCell && inP && !hasValue { cell += s }
    }
    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName q: String?) {
        switch q ?? el {
        case "text:p": inP = false
        case "table:table-cell", "table:covered-table-cell":
            row += Array(repeating: cell, count: repeatCols); inCell = false
        case "table:table-row":
            while row.last == "" { row.removeLast() }
            for _ in 0..<repeatRows { rows.append(row) }
        case "table:table":
            while let last = rows.last, last.isEmpty { rows.removeLast() }
            sheets.append((name, rows))
        default: break
        }
    }
}

/// Вёрстка таблицы в PDF: сетка, ширина колонок по содержимому, перенос на новые страницы.
enum TablePDF {
    static func write(_ sheets: [SheetEngine.Sheet], to url: URL) throws {
        let page = CGSize(width: 842, height: 595) // A4 альбомная
        let margin: CGFloat = 36, rowH: CGFloat = 18, pad: CGFloat = 4
        var box = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(url: url as CFURL), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw DropwheelError("Не удалось создать PDF")
        }
        let font = NSFont.systemFont(ofSize: 9)
        let bold = NSFont.boldSystemFont(ofSize: 11)
        func draw(_ s: String, at p: CGPoint, width: CGFloat, font: NSFont) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]) as CFAttributedString)
            let truncated = CTLineCreateTruncatedLine(line, Double(width), .end,
                                                      CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [.font: font]) as CFAttributedString)) ?? line
            ctx.textPosition = p
            CTLineDraw(truncated, ctx)
        }
        for (name, rows) in sheets {
            let cols = rows.map(\.count).max() ?? 0
            var widths = (0..<cols).map { c in
                rows.prefix(200).map { $0.count > c ? ($0[c] as NSString).size(withAttributes: [.font: font]).width : 0 }.max() ?? 0
            }.map { min(max($0 + 2 * pad, 30), 220) }
            let total = widths.reduce(0, +), avail = page.width - 2 * margin
            if total > avail { widths = widths.map { $0 * avail / total } }
            var y = page.height - margin
            func newPage(first: Bool) {
                ctx.beginPDFPage(nil)
                y = page.height - margin
                draw(first ? name : name + " (продолжение)", at: CGPoint(x: margin, y: y - 12), width: avail, font: bold)
                y -= 24
            }
            newPage(first: true)
            for row in rows {
                if y - rowH < margin { ctx.endPDFPage(); newPage(first: false) }
                var x = margin
                ctx.setStrokeColor(CGColor(gray: 0.8, alpha: 1))
                ctx.setLineWidth(0.5)
                for c in 0..<cols {
                    let rect = CGRect(x: x, y: y - rowH, width: widths[c], height: rowH)
                    ctx.stroke(rect)
                    if c < row.count { draw(row[c], at: CGPoint(x: x + pad, y: y - rowH + 5), width: widths[c] - 2 * pad, font: font) }
                    x += widths[c]
                }
                y -= rowH
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}
