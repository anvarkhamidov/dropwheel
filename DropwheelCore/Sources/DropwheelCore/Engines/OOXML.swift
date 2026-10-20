import Foundation

/// Минимальные писатели и читатели Office Open XML (XLSX, PPTX), написанные с нуля по спецификации ECMA-376.
public enum OOXML {
    static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    // MARK: XLSX

    /// Колонка по индексу: 0 → A, 26 → AA.
    public static func columnName(_ index: Int) -> String {
        var n = index + 1, s = ""
        while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
        return s
    }

    public static func columnIndex(_ ref: String) -> Int {
        var n = 0
        for c in ref.uppercased() where c.isLetter { n = n * 26 + Int(c.asciiValue! - 64) }
        return n - 1
    }

    public static func writeXlsx(sheets: [(String, [[String]])], to output: URL, scratch: URL) async throws {
        let dir = scratch.appendingPathComponent("xlsx-\(UUID().uuidString)", isDirectory: true)
        var files: [String: Data] = [:]
        var overrides = "", sheetEntries = "", rels = ""
        var usedNames = Set<String>()
        for (i, (rawName, rows)) in sheets.enumerated() {
            // Имя листа: до 31 символа, без []:*?/\ и уникальное.
            var name = String(rawName.replacingOccurrences(of: "[\\[\\]:*?/\\\\]", with: " ", options: .regularExpression).prefix(31))
            if name.isEmpty || usedNames.contains(name) { name = "Лист \(i + 1)" }
            usedNames.insert(name)
            var xml = header + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
            for (r, row) in rows.enumerated() {
                xml += "<row r=\"\(r + 1)\">"
                for (c, value) in row.enumerated() where !value.isEmpty {
                    let ref = columnName(c) + String(r + 1)
                    if let num = CellValue.number(value) {
                        xml += "<c r=\"\(ref)\"><v>\(CellValue.format(num))</v></c>"
                    } else {
                        xml += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(value.xmlEscaped)</t></is></c>"
                    }
                }
                xml += "</row>"
            }
            xml += "</sheetData></worksheet>"
            files["xl/worksheets/sheet\(i + 1).xml"] = xml.data
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            sheetEntries += "<sheet name=\"\(name.xmlEscaped)\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
            rels += "<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
        }
        files["[Content_Types].xml"] = (header + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        \(overrides)
        </Types>
        """).data
        files["_rels/.rels"] = (header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """).data
        files["xl/workbook.xml"] = (header + """
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets>\(sheetEntries)</sheets></workbook>
        """).data
        files["xl/_rels/workbook.xml.rels"] = (header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(rels)</Relationships>").data
        try Zip.write(files, into: dir)
        try await Zip.pack(dir, to: output)
    }

    /// Читает все листы XLSX: значения как строки (общие строки, inline, числа, булевы).
    public static func readXlsx(_ input: URL, scratch: URL) async throws -> [(String, [[String]])] {
        let dir = scratch.appendingPathComponent("xlsx-in", isDirectory: true)
        try await Zip.unpack(input, into: dir)
        var shared: [String] = []
        if let data = try? Data(contentsOf: dir.appendingPathComponent("xl/sharedStrings.xml")) {
            shared = SharedStringsParser.parse(data)
        }
        let workbook = (try? String(contentsOf: dir.appendingPathComponent("xl/workbook.xml"), encoding: .utf8)) ?? ""
        let relsXML = (try? String(contentsOf: dir.appendingPathComponent("xl/_rels/workbook.xml.rels"), encoding: .utf8)) ?? ""
        var targets: [String: String] = [:]
        for m in relsXML.matches(of: /<Relationship\b[^>]*>/) {
            let tag = String(m.0)
            if let id = tag.firstMatch(of: /Id="([^"]+)"/)?.1, let t = tag.firstMatch(of: /Target="([^"]+)"/)?.1 { targets[String(id)] = String(t) }
        }
        var result: [(String, [[String]])] = []
        for m in workbook.matches(of: /<sheet\b[^>]*>/) {
            let tag = String(m.0)
            guard let name = tag.firstMatch(of: /name="([^"]*)"/)?.1, let rid = tag.firstMatch(of: /r:id="([^"]+)"/)?.1,
                  var target = targets[String(rid)] else { continue }
            if target.hasPrefix("/") { target.removeFirst() } else { target = "xl/" + target }
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(target)) else { continue }
            result.append((String(name).xmlUnescaped, SheetParser.parse(data, shared: shared)))
        }
        guard !result.isEmpty else { throw DropwheelError("В книге не найдено листов") }
        return result
    }

    // MARK: PPTX

    /// Презентация из картинок: по слайду на картинку, слайд — размера первой страницы.
    public static func writePptx(slides: [(URL, CGSize)], to output: URL, scratch: URL) async throws {
        guard let first = slides.first else { throw DropwheelError("Нет слайдов") }
        let dir = scratch.appendingPathComponent("pptx-\(UUID().uuidString)", isDirectory: true)
        let emu = 12700.0 // EMU на пункт
        let cx = Int(first.1.width * emu), cy = Int(first.1.height * emu)
        var files: [String: Data] = [:]
        var overrides = "", sldIds = "", presRels = ""
        for (i, (png, size)) in slides.enumerated() {
            let n = i + 1
            files["ppt/media/image\(n).png"] = try Data(contentsOf: png)
            // Вписываем картинку в слайд с сохранением пропорций.
            let scale = min(Double(cx) / (size.width * emu), Double(cy) / (size.height * emu))
            let w = Int(size.width * emu * scale), h = Int(size.height * emu * scale)
            let x = (cx - w) / 2, y = (cy - h) / 2
            files["ppt/slides/slide\(n).xml"] = (header + """
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
            <p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>
            <p:pic><p:nvPicPr><p:cNvPr id="2" name="Page \(n)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>
            <p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>
            <p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(w)" cy="\(h)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>
            </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
            """).data
            files["ppt/slides/_rels/slide\(n).xml.rels"] = (header + """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image\(n).png"/>
            </Relationships>
            """).data
            overrides += "<Override PartName=\"/ppt/slides/slide\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
            sldIds += "<p:sldId id=\"\(255 + n)\" r:id=\"rId\(n + 2)\"/>"
            presRels += "<Relationship Id=\"rId\(n + 2)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(n).xml\"/>"
        }
        files["[Content_Types].xml"] = (header + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="png" ContentType="image/png"/>
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
        \(overrides)
        </Types>
        """).data
        files["_rels/.rels"] = (header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
        </Relationships>
        """).data
        files["ppt/presentation.xml"] = (header + """
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
        <p:sldIdLst>\(sldIds)</p:sldIdLst>
        <p:sldSz cx="\(cx)" cy="\(cy)"/><p:notesSz cx="\(cy)" cy="\(cx)"/>
        </p:presentation>
        """).data
        files["ppt/_rels/presentation.xml.rels"] = (header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>
        \(presRels)
        </Relationships>
        """).data
        let emptyTree = "<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>"
        files["ppt/slideMasters/slideMaster1.xml"] = (header + """
        <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        \(emptyTree)
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
        </p:sldMaster>
        """).data
        files["ppt/slideMasters/_rels/slideMaster1.xml.rels"] = (header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>
        </Relationships>
        """).data
        files["ppt/slideLayouts/slideLayout1.xml"] = (header + """
        <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank">
        \(emptyTree)<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
        """).data
        files["ppt/slideLayouts/_rels/slideLayout1.xml.rels"] = (header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
        </Relationships>
        """).data
        files["ppt/theme/theme1.xml"] = (header + themeXML).data
        try Zip.write(files, into: dir)
        try await Zip.pack(dir, to: output)
    }

    static let themeXML = """
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Dropwheel">
    <a:themeElements>
    <a:clrScheme name="Dropwheel"><a:dk1><a:srgbClr val="000000"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1D1D1F"/></a:dk2><a:lt2><a:srgbClr val="F5F5F7"/></a:lt2>
    <a:accent1><a:srgbClr val="0E7C86"/></a:accent1><a:accent2><a:srgbClr val="1F7A4D"/></a:accent2><a:accent3><a:srgbClr val="9A5300"/></a:accent3>
    <a:accent4><a:srgbClr val="C62F2F"/></a:accent4><a:accent5><a:srgbClr val="636366"/></a:accent5><a:accent6><a:srgbClr val="86868B"/></a:accent6>
    <a:hlink><a:srgbClr val="0E7C86"/></a:hlink><a:folHlink><a:srgbClr val="636366"/></a:folHlink></a:clrScheme>
    <a:fontScheme name="Dropwheel"><a:majorFont><a:latin typeface="Helvetica"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Helvetica"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>
    <a:fmtScheme name="Dropwheel">
    <a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>
    <a:lnStyleLst><a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="25400"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="38100"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>
    <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>
    <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst>
    </a:fmtScheme></a:themeElements></a:theme>
    """
}

extension String {
    var xmlUnescaped: String {
        var s = self
        for (a, b) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] { s = s.replacingOccurrences(of: a, with: b) }
        return s
    }
}

/// xl/sharedStrings.xml → массив строк (с учётом rich text из нескольких <t>).
final class SharedStringsParser: NSObject, XMLParserDelegate {
    var items: [String] = []
    var current = ""
    var inText = false
    var inSI = false

    static func parse(_ data: Data) -> [String] {
        let p = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.items
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "si" { inSI = true; current = "" }
        if name == "t" && inSI { inText = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { current += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "t" { inText = false }
        if name == "si" { items.append(current); inSI = false }
    }
}

/// Лист XLSX → матрица строк.
final class SheetParser: NSObject, XMLParserDelegate {
    var rows: [[String]] = []
    var shared: [String] = []
    var cellRef = "", cellType = "", value = ""
    var collecting = false
    var row: [String] = []
    var rowIndex = 0

    static func parse(_ data: Data, shared: [String]) -> [[String]] {
        let p = SheetParser()
        p.shared = shared
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        // Убираем хвостовые пустые строки.
        while let last = p.rows.last, last.allSatisfy(\.isEmpty) { p.rows.removeLast() }
        return p.rows
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch name {
        case "row":
            let r = Int(a["r"] ?? "") ?? rowIndex + 1
            while rows.count < r - 1 { rows.append([]) }
            row = []; rowIndex = r
        case "c": cellRef = a["r"] ?? ""; cellType = a["t"] ?? ""; value = ""
        case "v", "t": collecting = true
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { if collecting { value += s } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v", "t": collecting = false
        case "c":
            var text = value
            if cellType == "s", let i = Int(value), i < shared.count { text = shared[i] }
            if cellType == "b" { text = value == "1" ? "TRUE" : "FALSE" }
            if text.hasSuffix(".0"), Double(text) != nil { text.removeLast(2) }
            let col = cellRef.isEmpty ? row.count : OOXML.columnIndex(cellRef)
            while row.count < col { row.append("") }
            if row.count == col { row.append(text) } else if col < row.count { row[col] = text }
        case "row": rows.append(row)
        default: break
        }
    }
}
