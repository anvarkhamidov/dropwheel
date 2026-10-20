import AppKit
import PDFKit
import XCTest
@testable import DropwheelCore

/// Прогон движков на настоящих файлах. Медиатесты пропускаются, если нет ffmpeg.
final class EngineTests: XCTestCase {
    var dir: URL!
    let tools = ExternalTools.discover()
    var converter: Converter { Converter(tools: tools) }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DropwheelTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Фикстуры

    func makePNG(_ name: String = "pic.png", size: Int = 64, alpha: Bool = true) throws -> URL {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: alpha ? 0.8 : 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size / 2))
        let url = dir.appendingPathComponent(name)
        try ImageEngine.writeImageIO(ctx.makeImage()!, to: url, type: .png, quality: 1, metadata: nil)
        return url
    }

    /// PDF с явными страницами: заголовок и таблица из двух колонок, разнесённых по x.
    func makePDF(pages: Int, name: String = "doc.pdf") throws -> URL {
        let url = dir.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        let font = NSFont.systemFont(ofSize: 14)
        func draw(_ s: String, _ x: CGFloat, _ y: CGFloat) {
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]) as CFAttributedString), ctx)
        }
        for i in 1...pages {
            ctx.beginPDFPage(nil)
            draw("Страница \(i)", 56, 780)
            draw("Имя", 56, 740); draw("Сумма", 220, 740)
            draw("Аня", 56, 720); draw("10", 220, 720)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    func requireFfmpeg() throws {
        try XCTSkipIf(tools.ffmpeg == nil, "ffmpeg не установлен")
    }

    func makeMedia(_ name: String, video: Bool) async throws -> URL {
        let url = dir.appendingPathComponent(name)
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1"]
        if video { args += ["-f", "lavfi", "-i", "testsrc=size=160x120:rate=10:duration=1", "-c:v", "libx264", "-pix_fmt", "yuv420p"] }
        args += ["-shortest", url.path]
        try await ProcessRunner.run(tools.ffmpeg!, args)
        return url
    }

    // MARK: Изображения

    func testImageToEveryTarget() async throws {
        let png = try makePNG()
        for ext in Registry.outputs[.image]! where ext != "png" {
            if ext == "webp", tools.cwebp == nil { continue }
            let out = try await converter.convert(png, to: ext) { _ in }
            XCTAssertEqual(out.count, 1)
            XCTAssertEqual(out[0].pathExtension, ext)
            let size = try FileManager.default.attributesOfItem(atPath: out[0].path)[.size] as! Int
            XCTAssertGreaterThan(size, 0, ext)
            if ext != "pdf" { XCTAssertEqual(ImageEngine.pixelSize(out[0]), CGSize(width: 64, height: 64), ext) }
        }
    }

    func testRepeatedConversionCreatesNumberedCopy() async throws {
        let png = try makePNG()
        let a = try await converter.convert(png, to: "jpg") { _ in }
        let b = try await converter.convert(png, to: "jpg") { _ in }
        XCTAssertEqual(a[0].lastPathComponent, "pic.jpg")
        XCTAssertEqual(b[0].lastPathComponent, "pic 2.jpg")
    }

    func testMakePDFFromImages() throws {
        let a = try makePNG("a.png"), b = try makePNG("b.png")
        let out = dir.appendingPathComponent("both.pdf")
        try ImageEngine(tools: tools).makePDF([a, b], output: out) { _ in }
        XCTAssertEqual(PDFDocument(url: out)?.pageCount, 2)
    }

    // MARK: Медиа

    func testAudioToEveryTarget() async throws {
        try requireFfmpeg()
        let wav = try await makeMedia("tone.wav", video: false)
        for ext in Registry.outputs[.audio]! where ext != "wav" {
            let out = try await converter.convert(wav, to: ext) { _ in }
            let info = try await MediaEngine(tools: tools).probe(out[0])
            XCTAssertTrue(info.hasAudio, ext)
            XCTAssertEqual(info.duration, 1, accuracy: 0.2, ext)
        }
    }

    func testVideoToEveryTarget() async throws {
        try requireFfmpeg()
        let mp4 = try await makeMedia("clip.mp4", video: true)
        let progress = Box<[Double]>([])
        for ext in Registry.outputs[.video]! where ext != "mp4" {
            let out = try await converter.convert(mp4, to: ext) { p in if let p { progress.mutate { $0.append(p) } } }
            let info = try await MediaEngine(tools: tools).probe(out[0])
            if ext == "mp3" { XCTAssertTrue(info.hasAudio && !info.hasVideo, ext) } else { XCTAssertTrue(info.hasVideo, ext) }
        }
        XCTAssertFalse(progress.value.isEmpty, "ffmpeg должен сообщать прогресс")
    }

    // MARK: PDF

    func testPDFToImagesAndText() async throws {
        let pdf = try makePDF(pages: 2)
        let png = try await converter.convert(pdf, to: "png") { _ in }
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: png[0].path, isDirectory: &isDir) && isDir.boolValue, "многостраничный PDF → папка")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: png[0].path).count, 2)
        let txt = try await converter.convert(pdf, to: "txt") { _ in }
        XCTAssertTrue(try String(contentsOf: txt[0], encoding: .utf8).contains("Страница 2"))
        let md = try await converter.convert(pdf, to: "md") { _ in }
        XCTAssertTrue(try String(contentsOf: md[0], encoding: .utf8).contains("Страница 1"))
    }

    func testPDFToOfficeAndEpub() async throws {
        let pdf = try makePDF(pages: 2)
        for ext in ["docx", "xlsx", "pptx", "epub"] {
            let out = try await converter.convert(pdf, to: ext) { _ in }
            XCTAssertEqual(out[0].pathExtension, ext)
            // Любой OOXML/EPUB — это zip с правильной сигнатурой.
            let head = try FileHandle(forReadingFrom: out[0]).read(upToCount: 2)
            XCTAssertEqual(head, Data([0x50, 0x4B]), ext)
        }
        let xlsx = dir.appendingPathComponent("doc.xlsx")
        let sheets = try await OOXML.readXlsx(xlsx, scratch: try Scratch.dir())
        XCTAssertEqual(sheets.count, 2)
        XCTAssertTrue(sheets[0].1.contains(["Аня", "10"]), "\(sheets[0].1)")
    }

    func testPDFTools() throws {
        let a = try makePDF(pages: 3, name: "a.pdf"), b = try makePDF(pages: 1, name: "b.pdf")
        let engine = PDFEngine(tools: tools)
        let merged = try engine.merge([a, b]) { _ in }
        XCTAssertEqual(PDFDocument(url: merged)?.pageCount, 4)
        let parts = try engine.split(a, ranges: PDFEngine.evenRanges(pageCount: 3, every: 2))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parts.path).count, 2)
        let organized = try engine.organize(a, pages: [(2, 90), (0, 0)])
        let doc = PDFDocument(url: organized)!
        XCTAssertEqual(doc.pageCount, 2)
        XCTAssertEqual(doc.page(at: 0)?.rotation, 90)
        let compressed = try engine.compress(a, dpi: 72, quality: 0.5) { _ in }
        XCTAssertEqual(PDFDocument(url: compressed)?.pageCount, 3)
    }

    // MARK: Документы

    func testMarkdownToDocumentsAndBack() async throws {
        let md = dir.appendingPathComponent("note.md")
        try "# Заголовок\n\nАбзац с **жирным** словом.\n\n- пункт\n".write(to: md, atomically: true, encoding: .utf8)
        for ext in ["docx", "pdf", "txt", "html", "epub"] {
            let out = try await converter.convert(md, to: ext) { _ in }
            XCTAssertTrue(FileManager.default.fileExists(atPath: out[0].path), ext)
        }
        // DOCX обратно в Markdown сохраняет заголовок и жирный.
        let back = try await converter.convert(dir.appendingPathComponent("note.docx"), to: "md") { _ in }
        let text = try String(contentsOf: back[0], encoding: .utf8)
        XCTAssertTrue(text.contains("# Заголовок"), text)
        XCTAssertTrue(text.contains("**жирным**"), text)
        // EPUB читается обратно.
        let txt = try await converter.convert(dir.appendingPathComponent("note.epub"), to: "txt") { _ in }
        XCTAssertTrue(try String(contentsOf: txt[0], encoding: .utf8).contains("Абзац"))
        // Документ в картинки.
        let png = try await converter.convert(md, to: "png") { _ in }
        XCTAssertEqual(png[0].pathExtension, "png")
    }

    // MARK: Таблицы

    func testSpreadsheetRoundTrips() async throws {
        let csv = dir.appendingPathComponent("data.csv")
        try "Имя,Сумма\nАня,10\n\"Боб, мл.\",2.5\n".write(to: csv, atomically: true, encoding: .utf8)
        let expected = [["Имя", "Сумма"], ["Аня", "10"], ["Боб, мл.", "2.5"]]
        for ext in ["xlsx", "ods", "tsv"] {
            let out = try await converter.convert(csv, to: ext) { _ in }
            let back = try await SheetEngine(tools: tools).read(out[0], scratch: try Scratch.dir())
            XCTAssertEqual(back.first?.1, expected, ext)
        }
        let pdf = try await converter.convert(csv, to: "pdf") { _ in }
        XCTAssertEqual(PDFDocument(url: pdf[0])?.pageCount, 1)
    }

    // MARK: Архивы

    func testArchiveConversions() async throws {
        let src = dir.appendingPathComponent("box", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "hello".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let zip = dir.appendingPathComponent("box.zip")
        try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "cd \"$0\" && /usr/bin/zip -qr \"$1\" box", dir.path, zip.path])
        let tar = try await converter.convert(zip, to: "tar") { _ in }
        XCTAssertEqual(tar[0].lastPathComponent, "box.tar")
        let gz = try await converter.convert(tar[0], to: "gz") { _ in }
        XCTAssertEqual(gz[0].lastPathComponent, "box.tar.gz")
        let extracted = try await ArchiveEngine.extractBeside(gz[0])
        XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("box/a.txt"), encoding: .utf8), "hello")
    }

    // MARK: Отмена и мусор

    func testCancellationStopsConversionAndLeavesNothing() async throws {
        try requireFfmpeg()
        // Фикстура готовится до запуска задачи, отменяем именно конвертацию.
        let long = dir.appendingPathComponent("long.wav")
        try await ProcessRunner.run(tools.ffmpeg!, ["-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=duration=900", "-ar", "48000", long.path])
        let started = Box(false)
        let task = Task { try await self.converter.convert(long, to: "mp3") { _ in started.mutate { $0 = true } } }
        for _ in 0..<200 where !started.value { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(started.value, "конвертация должна была начаться")
        task.cancel()
        do { _ = try await task.value; XCTFail("ожидалась отмена") } catch is CancellationError {} catch { XCTFail("ожидалась CancellationError, получено \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("long.mp3").path), "после отмены рядом не должно остаться файла")
    }

    func testCancelledBeforeStartNeverLaunchesProcess() async throws {
        let task = Task { () -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["5"])
        }
        let start = Date()
        do { _ = try await task.value; XCTFail("ожидалась отмена") } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "процесс не должен был стартовать")
    }

    // MARK: Негативные случаи

    func testCorruptInputsFailWithMessageAndLeaveNothing() async throws {
        let fakePNG = dir.appendingPathComponent("fake.png")
        try "это не картинка".write(to: fakePNG, atomically: true, encoding: .utf8)
        let brokenPDF = dir.appendingPathComponent("broken.pdf")
        try "%PDF-1.4 мусор".write(to: brokenPDF, atomically: true, encoding: .utf8)
        let emptyZip = dir.appendingPathComponent("empty.zip")
        try Data([0x50, 0x4B, 0x05, 0x06] + Array(repeating: UInt8(0), count: 18)).write(to: emptyZip)
        for (input, ext) in [(fakePNG, "jpg"), (brokenPDF, "png"), (brokenPDF, "txt"), (emptyZip, "tar")] {
            do {
                _ = try await converter.convert(input, to: ext) { _ in }
                XCTFail("\(input.lastPathComponent) → \(ext) должен был упасть")
            } catch {
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(left, ["broken.pdf", "empty.zip", "fake.png"], "неудачные конвертации не должны оставлять файлов")
    }

    func testScannedPDFExplainsMissingText() async throws {
        let png = try makePNG(size: 200, alpha: false)
        let pdf = dir.appendingPathComponent("scan.pdf")
        try ImageEngine(tools: tools).makePDF([png, png], output: pdf) { _ in }
        do { _ = try await converter.convert(pdf, to: "txt") { _ in }; XCTFail() } catch {
            XCTAssertTrue(error.localizedDescription.contains("скан"), error.localizedDescription)
        }
    }

    func testLeadingZerosSurviveSpreadsheetConversion() async throws {
        let csv = dir.appendingPathComponent("ids.csv")
        try "Индекс,Кол-во,Цена\n007,3,0.5\n123456,10,12\n".write(to: csv, atomically: true, encoding: .utf8)
        for ext in ["xlsx", "ods"] {
            let out = try await converter.convert(csv, to: ext) { _ in }
            let back = try await SheetEngine(tools: tools).read(out[0], scratch: try Scratch.dir())
            XCTAssertEqual(back.first?.1, [["Индекс", "Кол-во", "Цена"], ["007", "3", "0.5"], ["123456", "10", "12"]], ext)
        }
    }

    func testEpubWithRemoteImageConvertsOffline() async throws {
        let md = dir.appendingPathComponent("remote.md")
        try "# Книга\n\nТекст.\n".write(to: md, atomically: true, encoding: .utf8)
        let epub = try await converter.convert(md, to: "epub") { _ in }
        // Подкладываем удалённую картинку внутрь главы и читаем книгу обратно.
        let unpacked = dir.appendingPathComponent("unpacked", isDirectory: true)
        try await Zip.unpack(epub[0], into: unpacked)
        let ch = unpacked.appendingPathComponent("OEBPS/ch1.xhtml")
        let body = try String(contentsOf: ch, encoding: .utf8).replacingOccurrences(of: "</body>", with: "<img src=\"https://example.invalid/track.png\"/></body>")
        try body.write(to: ch, atomically: true, encoding: .utf8)
        let repacked = dir.appendingPathComponent("tracked.epub")
        try await Zip.pack(unpacked, to: repacked, storedFirst: "mimetype")
        let txt = try await converter.convert(repacked, to: "txt") { _ in }
        XCTAssertTrue(try String(contentsOf: txt[0], encoding: .utf8).contains("Текст"))
    }
}

final class Box<T>: @unchecked Sendable {
    private var v: T
    private let lock = NSLock()
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}
