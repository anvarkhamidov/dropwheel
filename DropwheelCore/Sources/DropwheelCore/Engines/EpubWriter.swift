import Foundation

/// Минимальный валидный EPUB 3: OPF, nav, главы XHTML.
public enum EpubWriter {
    public static func escape(_ s: String) -> String { s.xmlEscaped }

    public static func write(title: String, chapters: [String], to output: URL, scratch: URL) async throws {
        let dir = scratch.appendingPathComponent("epub-\(UUID().uuidString)", isDirectory: true)
        let id = UUID().uuidString
        var files: [String: Data] = [
            "mimetype": "application/epub+zip".data,
            "META-INF/container.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.data,
            "OEBPS/style.css": "body{font-family:serif;line-height:1.5;margin:0 5%}h1,h2{font-family:sans-serif}img{max-width:100%}".data,
        ]
        var manifest = "", spine = "", nav = ""
        for (i, body) in chapters.enumerated() {
            let name = "ch\(i + 1).xhtml"
            files["OEBPS/" + name] = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><meta charset="utf-8"/><title>\(escape(title))</title><link rel="stylesheet" href="style.css"/></head>
            <body>
            \(body)
            </body></html>
            """.data
            manifest += "<item id=\"c\(i + 1)\" href=\"\(name)\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "<itemref idref=\"c\(i + 1)\"/>\n"
            nav += "<li><a href=\"\(name)\">Часть \(i + 1)</a></li>\n"
        }
        files["OEBPS/nav.xhtml"] = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><meta charset="utf-8"/><title>Содержание</title></head>
        <body><nav epub:type="toc"><ol>\(nav)</ol></nav></body></html>
        """.data
        let modified = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)
        files["OEBPS/content.opf"] = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:\(id)</dc:identifier>
            <dc:title>\(escape(title))</dc:title>
            <dc:language>ru</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="css" href="style.css" media-type="text/css"/>
            \(manifest)
          </manifest>
          <spine>\(spine)</spine>
        </package>
        """.data
        try Zip.write(files, into: dir)
        try await Zip.pack(dir, to: output, storedFirst: "mimetype")
    }

    /// Читает EPUB и склеивает главы по порядку spine в один HTML.
    public static func readHTML(_ epub: URL, scratch: URL) async throws -> (title: String, html: String, base: URL) {
        let dir = scratch.appendingPathComponent("epub-in", isDirectory: true)
        try await Zip.unpack(epub, into: dir)
        let container = try String(contentsOf: dir.appendingPathComponent("META-INF/container.xml"), encoding: .utf8)
        guard let opfPath = container.firstMatch(of: /full-path="([^"]+)"/)?.1 else { throw DropwheelError("EPUB повреждён: нет OPF") }
        let opfURL = dir.appendingPathComponent(String(opfPath))
        let opf = try String(contentsOf: opfURL, encoding: .utf8)
        let base = opfURL.deletingLastPathComponent()
        var hrefs: [String: String] = [:]
        for m in opf.matches(of: /<item\b[^>]*>/) {
            let tag = String(m.0)
            if let id = tag.firstMatch(of: /\bid="([^"]+)"/)?.1, let href = tag.firstMatch(of: /\bhref="([^"]+)"/)?.1 {
                hrefs[String(id)] = String(href).removingPercentEncoding ?? String(href)
            }
        }
        let order = opf.matches(of: /<itemref\b[^>]*idref="([^"]+)"/).map { String($0.1) }
        let title = opf.firstMatch(of: /<dc:title[^>]*>([^<]*)</).map { String($0.1).xmlUnescaped } ?? epub.deletingPathExtension().lastPathComponent
        var body = ""
        for id in order {
            guard let href = hrefs[id] else { continue }
            let file = base.appendingPathComponent(href)
            guard let xhtml = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let inner = xhtml.firstMatch(of: /(?s)<body[^>]*>(.*)<\/body>/).map { String($0.1) } ?? xhtml
            // Пути картинок делаем абсолютными, чтобы NSAttributedString их нашёл.
            let fixed = inner.replacing(/src="(?!https?:|data:|\/)([^"]+)"/) { m in
                "src=\"\(file.deletingLastPathComponent().appendingPathComponent(String(m.1)).absoluteString)\""
            }
            body += fixed + "\n<hr/>\n"
        }
        return (title, "<html><head><meta charset=\"utf-8\"><title>\(escape(title))</title></head><body>\(body)</body></html>", base)
    }
}
