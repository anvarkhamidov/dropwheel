import Foundation
import ImageIO

/// COMPRESS для любых поддерживаемых файлов. Оригинал не трогается, результат — «<имя> сжатый».
public struct CompressEngine: Sendable {
    public enum Goal: Equatable, Sendable {
        case preset(Preset)
        case percent(Double)      // на сколько уменьшить, 0.1…0.9
        case targetBytes(Int64)
    }

    public enum Preset: String, CaseIterable, Sendable {
        case light, balanced, strong
        public var title: String {
            switch self { case .light: return "Слабое"; case .balanced: return "Среднее"; case .strong: return "Сильное" }
        }
        var imageQuality: Double { switch self { case .light: return 0.85; case .balanced: return 0.7; case .strong: return 0.5 } }
        var crf: Int { switch self { case .light: return 23; case .balanced: return 27; case .strong: return 31 } }
        var audioKbps: Int { switch self { case .light: return 192; case .balanced: return 128; case .strong: return 80 } }
        var pdfDPI: CGFloat { switch self { case .light: return 200; case .balanced: return 150; case .strong: return 100 } }
    }

    public let tools: ExternalTools
    public init(tools: ExternalTools) { self.tools = tools }

    static func size(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    func target(for url: URL, goal: Goal) -> Int64? {
        switch goal {
        case .preset: return nil
        case .percent(let p): return Int64(Double(Self.size(url)) * (1 - min(max(p, 0.05), 0.95)))
        case .targetBytes(let b): return b
        }
    }

    public func compress(_ url: URL, goal: Goal, maxSide: Int?, progress: @escaping ProgressHandler) async throws -> URL {
        switch FileCategory.of(url) {
        case .image: return try await compressImage(url, goal: goal, maxSide: maxSide)
        case .video: return try await compressVideo(url, goal: goal, maxSide: maxSide, progress: progress)
        case .audio: return try await compressAudio(url, goal: goal, progress: progress)
        case .pdf: return try compressPDF(url, goal: goal, progress: progress)
        default: throw DropwheelError("Этот тип файла не сжимается")
        }
    }

    // MARK: Изображения

    /// Формат результата: lossy-форматы сохраняются, PNG/TIFF/BMP превращаются в JPEG (без прозрачности) или HEIC (с ней).
    static func outputExt(for url: URL, hasAlpha: Bool) -> String {
        let ext = FileCategory.canonical(ext: url.pathExtension)
        if ["jpg", "heic", "webp", "avif"].contains(ext) { return ext }
        return hasAlpha ? "heic" : "jpg"
    }

    func compressImage(_ url: URL, goal: Goal, maxSide: Int?) async throws -> URL {
        var image = try ImageEngine.loadCGImage(url)
        if let maxSide { image = ImageEngine.resized(image, maxSide: maxSide) }
        let alpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let ext = Self.outputExt(for: url, hasAlpha: alpha)
        let engine = ImageEngine(tools: tools)
        let meta = ImageEngine.carriedMetadata(url)
        let dest = OutputNamer.sibling(of: url, ext: ext, suffix: "сжатый")
        let scratch = try Scratch.dir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        func encode(_ q: Double) async throws -> URL {
            let out = scratch.appendingPathComponent("q\(Int(q * 1000))").appendingPathExtension(ext)
            try await engine.write(image, to: out, ext: ext, quality: q, metadata: meta)
            return out
        }

        guard let target = target(for: url, goal: goal) else {
            if case .preset(let p) = goal { return try Scratch.commit(try await encode(p.imageQuality), to: dest) }
            throw DropwheelError("Не задана цель сжатия")
        }
        // Бинарный поиск качества: самый качественный вариант, который укладывается в цель.
        var lo = 0.05, hi = 0.95
        var best: URL?
        for _ in 0..<7 {
            try Task.checkCancellation()
            let mid = (lo + hi) / 2
            let out = try await encode(mid)
            if Self.size(out) <= target { best = out; lo = mid } else { hi = mid }
        }
        if best == nil {
            let smallest = try await encode(0.05)
            guard Self.size(smallest) <= target else {
                throw DropwheelError("Не получается уложиться в \(ByteCountFormatter.string(fromByteCount: target, countStyle: .file)) — уменьшите размер изображения")
            }
            best = smallest
        }
        return try Scratch.commit(best!, to: dest)
    }

    // MARK: Видео

    func compressVideo(_ url: URL, goal: Goal, maxSide: Int?, progress: @escaping ProgressHandler) async throws -> URL {
        let media = MediaEngine(tools: tools)
        let info = try await media.probe(url)
        let crf: Int = { if case .preset(let p) = goal { return p.crf }; return 26 }()
        let args = MediaTools.compressVideo(targetBytes: target(for: url, goal: goal), duration: info.duration, crf: crf, maxHeight: maxSide)
        return try await staged(url, ext: "mp4", suffix: "сжатый") { out in
            try await media.process(url, output: out, args: args, progress: progress)
        }
    }

    // MARK: Аудио

    func compressAudio(_ url: URL, goal: Goal, progress: @escaping ProgressHandler) async throws -> URL {
        let media = MediaEngine(tools: tools)
        let info = try await media.probe(url)
        var kbps: Int
        switch goal {
        case .preset(let p): kbps = p.audioKbps
        default:
            let t = target(for: url, goal: goal) ?? Self.size(url) / 2
            kbps = info.duration > 0 ? Int(Double(t) * 8 / 1000 / info.duration * 0.97) : 128
        }
        kbps = min(max(kbps, 32), 320)
        let ext = MediaTools.compressedAudioExt(url.pathExtension)
        return try await staged(url, ext: ext, suffix: "сжатый") { out in
            try await media.process(url, output: out, args: MediaTools.compressAudio(kbps: kbps, ext: ext), progress: progress)
        }
    }

    // MARK: PDF

    func compressPDF(_ url: URL, goal: Goal, progress: @escaping ProgressHandler) throws -> URL {
        let pdf = PDFEngine(tools: tools)
        if case .preset(let p) = goal { return try pdf.compress(url, dpi: p.pdfDPI, quality: p.imageQuality, progress: progress) }
        // Для цели по размеру пробуем ступени от мягкой к жёсткой и оставляем первую подходящую.
        guard let target = target(for: url, goal: goal) else { throw DropwheelError("Не задана цель сжатия") }
        var last: URL?
        for (dpi, q) in [(200.0, 0.8), (150.0, 0.7), (120.0, 0.6), (96.0, 0.5), (72.0, 0.4)] {
            try Task.checkCancellation()
            if let l = last { try? FileManager.default.removeItem(at: l) }
            let out = try pdf.compress(url, dpi: CGFloat(dpi), quality: q, progress: progress)
            last = out
            if Self.size(out) <= target { return out }
        }
        if let l = last { try? FileManager.default.removeItem(at: l) }
        throw DropwheelError("Не получается уложиться в \(ByteCountFormatter.string(fromByteCount: target, countStyle: .file))")
    }

    func staged(_ url: URL, ext: String, suffix: String, _ work: (URL) async throws -> Void) async throws -> URL {
        let scratch = try Scratch.dir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let temp = scratch.appendingPathComponent("out").appendingPathExtension(ext)
        try await work(temp)
        return try Scratch.commit(temp, to: OutputNamer.sibling(of: url, ext: ext, suffix: suffix))
    }
}
