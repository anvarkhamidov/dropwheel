import XCTest
@testable import DropwheelCore

final class LogicTests: XCTestCase {
    let all: Set<Requirement> = [.ffmpeg, .cwebp, .pages, .keynote, .numbers]

    func testCategoryDetection() {
        XCTAssertEqual(FileCategory.of(URL(fileURLWithPath: "/a/b.JPEG")), .image)
        XCTAssertEqual(FileCategory.of(URL(fileURLWithPath: "/a/b.mkv")), .video)
        XCTAssertEqual(FileCategory.of(URL(fileURLWithPath: "/a/b.srt")), .subtitle)
        XCTAssertEqual(FileCategory.of(URL(fileURLWithPath: "/a/b.unknown")), .other)
    }

    func testConvertWheelExcludesOwnFormat() {
        let r = Registry(available: all)
        let items = r.formats(for: [URL(fileURLWithPath: "/x/photo.jpeg")]).map(\.ext)
        XCTAssertFalse(items.contains("jpg"))
        XCTAssertEqual(items, ["png", "webp", "heic", "tiff", "avif", "bmp", "pdf"])
    }

    func testKeynoteAndPptGetPptxButPptxDoesNot() {
        let r = Registry(available: all)
        XCTAssertTrue(r.formats(for: [URL(fileURLWithPath: "/talk.key")]).map(\.ext).contains("pptx"))
        XCTAssertTrue(r.formats(for: [URL(fileURLWithPath: "/old.ppt")]).map(\.ext).contains("pptx"))
        XCTAssertFalse(r.formats(for: [URL(fileURLWithPath: "/deck.pptx")]).map(\.ext).contains("pptx"))
        XCTAssertTrue(Registry(available: []).formats(for: [URL(fileURLWithPath: "/talk.key")]).isEmpty, "без Keynote — ничего")
    }

    func testMixedSelectionHasNoFormats() {
        let r = Registry(available: all)
        XCTAssertTrue(r.formats(for: [URL(fileURLWithPath: "/a.png"), URL(fileURLWithPath: "/b.mp3")]).isEmpty)
    }

    func testMissingFfmpegHidesMediaOptions() {
        let r = Registry(available: [])
        XCTAssertTrue(r.formats(for: [URL(fileURLWithPath: "/a.mp3")]).isEmpty)
        XCTAssertFalse(r.formats(for: [URL(fileURLWithPath: "/a.png")]).map(\.ext).contains("webp"))
        XCTAssertFalse(r.tools(for: [URL(fileURLWithPath: "/a.mp4")]).contains(Tools.trimVideo))
    }

    func testMultiFileToolsAppearOnlyForSelections() {
        let r = Registry(available: all)
        let one = r.tools(for: [URL(fileURLWithPath: "/a.png")])
        XCTAssertFalse(one.contains(Tools.createPDF))
        XCTAssertTrue(one.contains(Tools.editImage))
        let two = r.tools(for: [URL(fileURLWithPath: "/a.png"), URL(fileURLWithPath: "/b.jpg")])
        XCTAssertTrue(two.contains(Tools.createPDF))
        XCTAssertTrue(two.contains(Tools.collage))
        XCTAssertFalse(two.contains(Tools.editImage), "редактор фото работает с одним файлом")
        XCTAssertTrue(two.contains(Tools.cropImage), "кроп работает с выборкой")
    }

    func testWheelNeverExceedsTenSegments() {
        let r = Registry(available: all)
        for category in FileCategory.allCases {
            guard let ext = FileCategory.extensions[category]?.sorted().first else { continue }
            let one = [URL(fileURLWithPath: "/a.\(ext)")]
            let many = [URL(fileURLWithPath: "/a.\(ext)"), URL(fileURLWithPath: "/b.\(ext)")]
            for urls in [one, many] {
                XCTAssertLessThanOrEqual(r.items(for: urls, kind: .convert).count, 10, "\(category)")
                XCTAssertLessThanOrEqual(r.items(for: urls, kind: .tools).count, 10, "\(category)")
            }
        }
        XCTAssertEqual(r.items(for: [URL(fileURLWithPath: "/folder")], kind: .actions).count, 6)
    }

    func testOutputNamerNeverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let input = dir.appendingPathComponent("photo.png")
        XCTAssertEqual(OutputNamer.sibling(of: input, ext: "jpg").lastPathComponent, "photo.jpg")
        try Data().write(to: dir.appendingPathComponent("photo.jpg"))
        XCTAssertEqual(OutputNamer.sibling(of: input, ext: "jpg").lastPathComponent, "photo 2.jpg")
        try Data().write(to: dir.appendingPathComponent("photo 2.jpg"))
        XCTAssertEqual(OutputNamer.sibling(of: input, ext: "jpg").lastPathComponent, "photo 3.jpg")
        XCTAssertEqual(OutputNamer.sibling(of: input, ext: "png", suffix: "сжатый").lastPathComponent, "photo сжатый.png")
    }

    func testSubtitlesRoundTrip() {
        let srt = "1\n00:00:01,500 --> 00:00:03,000\n<i>Привет</i>\n\n2\n00:01:02,250 --> 00:01:04,000\nДве\nстроки\n"
        let cues = SubtitleEngine.parse(srt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[1].start, 62.25, accuracy: 0.001)
        let vtt = SubtitleEngine.vtt(cues)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT"))
        XCTAssertTrue(vtt.contains("00:01:02.250 --> 00:01:04.000"))
        XCTAssertEqual(SubtitleEngine.parse(vtt), cues)
        XCTAssertEqual(SubtitleEngine.plain(cues), "Привет\nДве\nстроки\n")
        XCTAssertEqual(SubtitleEngine.parse(SubtitleEngine.srt(cues)), cues)
    }

    func testCSVQuotingRoundTrip() {
        let rows = [["имя", "заметка"], ["Аня", "с запятой, и \"кавычками\""], ["Боб", "две\nстроки"]]
        let text = CSV.write(rows, separator: ",")
        XCTAssertEqual(CSV.parse(text, separator: ","), rows)
        XCTAssertEqual(CSV.detectSeparator("a;b;c\n1;2;3"), ";")
    }

    func testColumnNames() {
        XCTAssertEqual(OOXML.columnName(0), "A")
        XCTAssertEqual(OOXML.columnName(25), "Z")
        XCTAssertEqual(OOXML.columnName(26), "AA")
        XCTAssertEqual(OOXML.columnIndex("AB12"), 27)
    }

    func testMarkdownToHTML() {
        let html = Markdown.toHTML("# Заголовок\n\nТекст **жирный** и *курсив*.\n\n- раз\n- два\n")
        XCTAssertTrue(html.contains("<h1>Заголовок</h1>"))
        XCTAssertTrue(html.contains("<b>жирный</b>"))
        XCTAssertTrue(html.contains("<i>курсив</i>"))
        XCTAssertTrue(html.contains("<ul>\n<li>раз</li>\n<li>два</li>\n</ul>"))
    }

    func testArchiveBaseName() {
        XCTAssertEqual(ArchiveEngine.baseName(URL(fileURLWithPath: "/a/photos.tar.gz")), "photos")
        XCTAssertEqual(ArchiveEngine.baseName(URL(fileURLWithPath: "/a/x.zip")), "x")
        XCTAssertTrue(ArchiveEngine.isPlainGzip(URL(fileURLWithPath: "/a/log.txt.gz")))
        XCTAssertFalse(ArchiveEngine.isPlainGzip(URL(fileURLWithPath: "/a/b.tar.gz")))
    }

    func testPdfEvenRanges() {
        XCTAssertEqual(PDFEngine.evenRanges(pageCount: 5, every: 2), [1...2, 3...4, 5...5])
    }

    func testOfflineHTMLStripsRemoteResources() {
        let html = """
        <html><head><link rel="stylesheet" href="https://t.example/a.css"><style>@import url(http://t.example/b.css); body{background:url('https://t.example/c.png')}</style>
        <script>fetch('https://t.example')</script></head>
        <body><p>Текст</p><img src="https://t.example/p.png"><img src="//t.example/q.png"><img src="file:///tmp/local.png" srcset="https://t.example/r.png 2x">
        <iframe src="https://t.example"></iframe><video src="https://t.example/v.mp4" poster="https://t.example/p.jpg"></video></body></html>
        """
        let clean = OfflineHTML.sanitize(html)
        XCTAssertFalse(clean.contains("t.example"), clean)
        XCTAssertTrue(clean.contains("<p>Текст</p>"))
        XCTAssertTrue(clean.contains("file:///tmp/local.png"), "локальные картинки остаются")
    }

    func testCellValueKeepsLeadingZerosAsText() {
        XCTAssertNil(CellValue.number("007"))
        XCTAssertNil(CellValue.number("1234567890123456789"), "длинные номера не превращаем в float")
        XCTAssertEqual(CellValue.number("0.5"), 0.5)
        XCTAssertEqual(CellValue.number("-12,25"), -12.25)
        XCTAssertEqual(CellValue.format(10), "10")
        XCTAssertEqual(CellValue.format(2.5), "2.5")
    }
}
