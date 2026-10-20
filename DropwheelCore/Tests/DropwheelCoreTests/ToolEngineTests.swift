import AppKit
import ImageIO
import PDFKit
import XCTest
@testable import DropwheelCore

final class ToolEngineTests: XCTestCase {
    var dir: URL!
    let tools = ExternalTools.discover()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DropwheelTools-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func requireFfmpeg() throws { try XCTSkipIf(tools.ffmpeg == nil, "ffmpeg не установлен") }

    func photo(_ w: Int = 400, _ h: Int = 300, gps: Bool = false, name: String = "photo.jpg") throws -> URL {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        // Шум, чтобы JPEG не сжимался в ноль и поиск качества был осмысленным.
        for y in stride(from: 0, to: h, by: 4) { for x in stride(from: 0, to: w, by: 4) {
            ctx.setFillColor(CGColor(srgbRed: CGFloat((x * 7 + y * 3) % 255) / 255, green: CGFloat((x * y) % 255) / 255, blue: CGFloat(y % 255) / 255, alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
        } }
        let url = dir.appendingPathComponent(name)
        var meta: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "TestCam"]]
        if gps { meta[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 55.75, kCGImagePropertyGPSLatitudeRef: "N",
                                                       kCGImagePropertyGPSLongitude: 37.61, kCGImagePropertyGPSLongitudeRef: "E"] }
        try ImageEngine.writeImageIO(ctx.makeImage()!, to: url, type: .jpeg, quality: 0.95, metadata: meta)
        return url
    }

    func media(_ name: String, video: Bool, seconds: Int = 4) async throws -> URL {
        let url = dir.appendingPathComponent(name)
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)"]
        if video { args += ["-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=\(seconds)", "-c:v", "libx264", "-pix_fmt", "yuv420p"] }
        args += ["-ac", "2", "-shortest", url.path]
        try await ProcessRunner.run(tools.ffmpeg!, args)
        return url
    }

    func run(_ input: URL, ext: String, args: [String], pre: [String] = []) async throws -> MediaEngine.Info {
        let out = dir.appendingPathComponent("out-\(UUID().uuidString).\(ext)")
        try await MediaEngine(tools: tools).process(input, output: out, args: args, preInput: pre) { _ in }
        return try await MediaEngine(tools: tools).probe(out)
    }

    // MARK: Фото

    func testAdjustmentsChangePixels() throws {
        let cg = try ImageEngine.loadCGImage(try photo())
        var a = ImageOps.Adjustments(); a.exposure = 1; a.grain = 30; a.dehaze = 40
        let out = ImageOps.render(ImageOps.adjust(CIImage(cgImage: cg), a))!
        XCTAssertEqual(out.width, cg.width)
        XCTAssertEqual(out.height, cg.height)
        XCTAssertTrue(ImageOps.Adjustments().isIdentity)
    }

    func testCropFrameRedactAnnotateCollage() throws {
        let cg = try ImageEngine.loadCGImage(try photo())
        XCTAssertEqual(ImageOps.crop(cg, to: CGRect(x: 10, y: 10, width: 100, height: 50)).map { [$0.width, $0.height] }, [100, 50])
        var f = ImageOps.Frame(); f.aspect = 1; f.padding = 0.1
        let framed = try ImageOps.frame(cg, f)
        XCTAssertEqual(framed.width, framed.height, "квадратный холст")
        XCTAssertGreaterThan(framed.width, cg.width)
        let redacted = ImageOps.redact(cg, regions: [CGRect(x: 0, y: 0, width: 0.5, height: 0.5)], style: .solid)!
        XCTAssertEqual(redacted.width, cg.width)
        var arrow = ImageOps.Annotation(kind: .arrow, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.8, y: 0.8)])
        arrow.width = 0.01
        XCTAssertNotNil(ImageOps.annotate(cg, [arrow, ImageOps.Annotation(kind: .number, points: [CGPoint(x: 0.5, y: 0.5)])]))
        var c = ImageOps.Collage(); c.layout = .featured; c.width = 1200; c.height = 800
        XCTAssertEqual(ImageOps.cells(count: 4, c).count, 4)
        XCTAssertEqual(ImageOps.collage([cg, cg, cg, cg], c)?.width, 1200)
    }

    func testCompressImageHitsTarget() async throws {
        let url = try photo(1200, 900)
        let original = CompressEngine.size(url)
        let target = original / 3
        let out = try await CompressEngine(tools: tools).compress(url, goal: .targetBytes(target), maxSide: nil) { _ in }
        XCTAssertLessThanOrEqual(CompressEngine.size(out), target)
        XCTAssertEqual(out.lastPathComponent, "photo сжатый.jpg")
        let resized = try await CompressEngine(tools: tools).compress(url, goal: .preset(.balanced), maxSide: 600) { _ in }
        XCTAssertEqual(ImageEngine.pixelSize(resized), CGSize(width: 600, height: 450))
    }

    func testCompressPNGWithoutAlphaBecomesJPEG() {
        XCTAssertEqual(CompressEngine.outputExt(for: URL(fileURLWithPath: "/a.png"), hasAlpha: false), "jpg")
        XCTAssertEqual(CompressEngine.outputExt(for: URL(fileURLWithPath: "/a.png"), hasAlpha: true), "heic")
        XCTAssertEqual(CompressEngine.outputExt(for: URL(fileURLWithPath: "/a.webp"), hasAlpha: true), "webp")
    }

    // MARK: Метаданные

    func testStripRemovesLocation() async throws {
        let url = try photo(gps: true)
        let fields = try await MetadataEngine(tools: tools).read(url)
        XCTAssertEqual(fields.first { $0.key == "Широта" }?.value, "55.75")
        XCTAssertEqual(fields.first { $0.key == "Модель" }?.value, "TestCam")
        let clean = try MetadataEngine(tools: tools).writeImage(url, changes: [:], stripAll: true)
        let after = try await MetadataEngine(tools: tools).read(clean)
        XCTAssertEqual(after.first { $0.key == "Широта" }?.value, "")
        XCTAssertEqual(after.first { $0.key == "Модель" }?.value, "")
    }

    func testEditImageFields() async throws {
        let url = try photo()
        let edited = try MetadataEngine(tools: tools).writeImage(url, changes: ["Автор": "Аня", "Долгота": "-12.5"], stripAll: false)
        let f = try await MetadataEngine(tools: tools).read(edited)
        XCTAssertEqual(f.first { $0.key == "Автор" }?.value, "Аня")
        XCTAssertEqual(f.first { $0.key == "Долгота" }?.value, "-12.5")
        XCTAssertEqual(f.first { $0.key == "Модель" }?.value, "TestCam", "прочие поля сохраняются")
    }

    func testPDFMetadata() throws {
        let doc = PDFDocument()
        let img = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in NSColor.white.setFill(); r.fill(); return true }
        doc.insert(PDFPage(image: img)!, at: 0)
        doc.documentAttributes = [PDFDocumentAttribute.authorAttribute: "Боб"]
        let url = dir.appendingPathComponent("m.pdf")
        doc.write(to: url)
        let out = try MetadataEngine(tools: tools).writePDF(url, changes: ["Автор": "", "Название": "Отчёт"], stripAll: false)
        let f = try MetadataEngine.readPDF(out)
        XCTAssertEqual(f.first { $0.key == "Название" }?.value, "Отчёт")
        XCTAssertEqual(f.first { $0.key == "Автор" }?.value, "")
    }

    // MARK: Видео и аудио

    func testVideoToolsProduceExpectedMedia() async throws {
        try requireFfmpeg()
        let clip = try await media("clip.mp4", video: true)
        var info = try await run(clip, ext: "mp4", args: MediaTools.trim(start: 1, end: 2.5, ext: "mp4", hasVideo: true))
        XCTAssertEqual(info.duration, 1.5, accuracy: 0.15, "trim")
        info = try await run(clip, ext: "mp4", args: MediaTools.crop(x: 10, y: 10, width: 161, height: 101, ext: "mp4"))
        XCTAssertEqual(info.width, 160); XCTAssertEqual(info.height, 100)
        XCTAssertTrue(info.hasAudio, "кроп сохраняет звук")
        info = try await run(clip, ext: "mp4", args: MediaTools.speed(2, keepPitch: true, hasAudio: true, ext: "mp4"))
        XCTAssertEqual(info.duration, 2, accuracy: 0.2, "speed ×2")
        let snap = MediaTools.snapshot(at: 1)
        let png = dir.appendingPathComponent("frame.png")
        try await MediaEngine(tools: tools).process(clip, output: png, args: snap.args, preInput: snap.pre) { _ in }
        XCTAssertEqual(ImageEngine.pixelSize(png), CGSize(width: 320, height: 240))
        let red = [MediaTools.VideoRedaction(rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3), start: 0, end: 2, blur: true),
                   MediaTools.VideoRedaction(rect: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), start: 1, end: 3, blur: false)]
        info = try await run(clip, ext: "mp4", args: MediaTools.redact(red, width: 320, height: 240, ext: "mp4"))
        XCTAssertEqual(info.duration, 4, accuracy: 0.2, "redact")
        info = try await run(clip, ext: "mp4", args: ["-an", "-c:v", "copy"])
        XCTAssertFalse(info.hasAudio, "mute")
    }

    func testSplitSegments() {
        let s = MediaTools.segments(duration: 10, cuts: [7, 3, 0, 10])
        XCTAssertEqual(s.map { $0.0 }, [0, 3, 7])
        XCTAssertEqual(s.map { $0.1 }, [3, 7, 10])
        XCTAssertEqual(MediaTools.equalCuts(duration: 9, parts: 3), [3, 6])
        XCTAssertEqual(MediaTools.atempoChain(3), "atempo=2.0,atempo=1.5000")
        XCTAssertEqual(MediaTools.atempoChain(0.25), "atempo=0.5,atempo=0.5000")
    }

    func testJoinMixedClips() async throws {
        try requireFfmpeg()
        let a = try await media("a.mp4", video: true, seconds: 2)
        let silent = dir.appendingPathComponent("b.mov")
        try await ProcessRunner.run(tools.ffmpeg!, ["-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=30:duration=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", silent.path])
        let out = dir.appendingPathComponent("joined.mp4")
        let args = MediaTools.join(count: 2, width: 320, height: 240, fps: 25, hasAudio: [true, false], durations: [2, 1])
        let pre = ["-i", a.path, "-i", silent.path]
        try await MediaEngine(tools: tools).run(pre + args + [out.path], duration: 3) { _ in }
        let info = try await MediaEngine(tools: tools).probe(out)
        XCTAssertEqual(info.duration, 3, accuracy: 0.3)
        XCTAssertEqual(info.width, 320, "холст по первому клипу")
        XCTAssertTrue(info.hasAudio)
    }

    func testAudioTools() async throws {
        try requireFfmpeg()
        let tone = try await media("tone.wav", video: false)
        var info = try await run(tone, ext: "wav", args: MediaTools.normalize(lufs: -16, lra: 11, truePeak: -1.5, ext: "wav"))
        XCTAssertEqual(info.duration, 4, accuracy: 0.2, "normalize")
        info = try await run(tone, ext: "wav", args: MediaTools.channels(mono: true, left: 1, right: 1, ext: "wav"))
        XCTAssertEqual(info.audioChannels, 1)
        info = try await run(tone, ext: "wav", args: MediaTools.bleep([(1, 2)], duration: 4, ext: "wav"))
        XCTAssertEqual(info.duration, 4, accuracy: 0.2, "bleep")
        info = try await run(tone, ext: "m4a", args: MediaTools.compressAudio(kbps: 64, ext: "m4a"))
        XCTAssertTrue(info.hasAudio)
        let viz = MediaTools.visualizer(style: .wave, shape: .square, color: "white", image: nil)
        info = try await run(tone, ext: "mp4", args: viz.args)
        XCTAssertEqual(info.width, 1080); XCTAssertEqual(info.height, 1080)
        XCTAssertEqual(info.duration, 4, accuracy: 0.3)
    }
}
