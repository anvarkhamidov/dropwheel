import Foundation

/// Внешние зависимости, без которых часть опций недоступна.
public enum Requirement: String, Sendable, Hashable {
    case ffmpeg, cwebp, pages, keynote, numbers
}

/// Сегмент колеса конвертации: целевой формат.
public struct FormatOption: Identifiable, Hashable, Sendable {
    public let ext: String
    public var id: String { "fmt." + ext }
    public var label: String { ext == "gz" ? "GZIP" : ext.uppercased() }
    public let requires: Set<Requirement>
}

public enum ToolKind: Sendable { case instant, window }

/// Сегмент колеса инструментов.
public struct ToolDef: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let symbol: String
    public let kind: ToolKind
    public let minFiles: Int
    public let maxFiles: Int?
    public let requires: Set<Requirement>

    public static func == (a: ToolDef, b: ToolDef) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

/// Сегмент колеса действий.
public enum ActionKind: String, CaseIterable, Identifiable, Sendable {
    case airdrop, float, copy, move, copyPath, terminal
    public var id: String { "act." + rawValue }
    public var label: String {
        switch self {
        case .airdrop: return "AIRDROP"
        case .float: return "FLOAT"
        case .copy: return "COPY"
        case .move: return "MOVE"
        case .copyPath: return "COPY PATH"
        case .terminal: return "TERMINAL"
        }
    }
    public var symbol: String {
        switch self {
        case .airdrop: return "dot.radiowaves.left.and.right"
        case .float: return "tray.and.arrow.down"
        case .copy: return "doc.on.doc"
        case .move: return "folder"
        case .copyPath: return "link"
        case .terminal: return "apple.terminal"
        }
    }
}

public enum WheelKind: String, CaseIterable, Sendable { case convert, tools, actions }

public enum WheelPayload: Hashable, Sendable {
    case format(FormatOption)
    case tool(ToolDef)
    case action(ActionKind)
}

public struct WheelItem: Identifiable, Hashable, Sendable {
    public let payload: WheelPayload
    public var id: String {
        switch payload {
        case .format(let f): return f.id
        case .tool(let t): return t.id
        case .action(let a): return a.id
        }
    }
    public var label: String {
        switch payload {
        case .format(let f): return f.label
        case .tool(let t): return t.label
        case .action(let a): return a.label
        }
    }
    public var symbol: String? {
        switch payload {
        case .format: return nil
        case .tool(let t): return t.symbol
        case .action(let a): return a.symbol
        }
    }
}

/// Каталог инструментов.
public enum Tools {
    static func t(_ id: String, _ label: String, _ symbol: String, _ kind: ToolKind = .window,
                  min: Int = 1, max: Int? = nil, requires: Set<Requirement> = []) -> ToolDef {
        ToolDef(id: "tool." + id, label: label, symbol: symbol, kind: kind, minFiles: min, maxFiles: max, requires: requires)
    }

    public static let compress = t("compress", "COMPRESS", "arrow.down.right.and.arrow.up.left")
    public static let metadata = t("metadata", "METADATA", "tag", max: 1)
    // Изображения
    public static let editImage = t("editImage", "EDIT", "slider.horizontal.3", max: 1)
    public static let annotate = t("annotate", "ANNOTATE", "pencil.tip.crop.circle", max: 1)
    public static let addBackground = t("addBackground", "ADD BG", "photo.on.rectangle", max: 1)
    public static let cropImage = t("cropImage", "CROP", "crop")
    public static let redactImage = t("redactImage", "REDACT", "eye.slash", max: 1)
    public static let readQR = t("readQR", "QR", "qrcode.viewfinder", .instant)
    public static let createPDF = t("createPDF", "MAKE PDF", "doc.richtext", .instant, min: 2)
    public static let collage = t("collage", "COLLAGE", "square.grid.2x2", min: 2, max: 12)
    // Видео
    public static let mute = t("mute", "MUTE", "speaker.slash", .instant, requires: [.ffmpeg])
    public static let trimVideo = t("trimVideo", "TRIM", "timeline.selection", max: 1, requires: [.ffmpeg])
    public static let cropVideo = t("cropVideo", "CROP", "crop", max: 1, requires: [.ffmpeg])
    public static let speed = t("speed", "SPEED", "gauge.with.dots.needle.67percent", max: 1, requires: [.ffmpeg])
    public static let snapshot = t("snapshot", "SNAPSHOT", "camera.viewfinder", max: 1, requires: [.ffmpeg])
    public static let splitVideo = t("splitVideo", "SPLIT", "scissors", max: 1, requires: [.ffmpeg])
    public static let redactVideo = t("redactVideo", "REDACT", "eye.slash", max: 1, requires: [.ffmpeg])
    public static let joinVideos = t("joinVideos", "JOIN", "rectangle.stack.badge.plus", min: 2, requires: [.ffmpeg])
    // Аудио
    public static let normalize = t("normalize", "NORMALIZE", "waveform.badge.magnifyingglass", max: 1, requires: [.ffmpeg])
    public static let visualize = t("visualize", "VISUALIZE", "waveform.path", max: 1, requires: [.ffmpeg])
    public static let trimAudio = t("trimAudio", "TRIM", "timeline.selection", max: 1, requires: [.ffmpeg])
    public static let channels = t("channels", "CHANNELS", "speaker.wave.2", max: 1, requires: [.ffmpeg])
    public static let bleep = t("bleep", "BLEEP", "exclamationmark.bubble", max: 1, requires: [.ffmpeg])
    // PDF
    public static let splitPDF = t("splitPDF", "SPLIT", "scissors", max: 1)
    public static let organizePDF = t("organizePDF", "ORGANIZE", "square.grid.3x3", max: 1)
    public static let mergePDFs = t("mergePDFs", "MERGE", "doc.on.doc", min: 2)
    // Архивы
    public static let extract = t("extract", "EXTRACT", "archivebox", .instant)

    public static func forCategory(_ c: FileCategory) -> [ToolDef] {
        switch c {
        case .image: return [compress, metadata, editImage, annotate, addBackground, cropImage, redactImage, readQR, createPDF, collage]
        case .video: return [compress, metadata, mute, trimVideo, cropVideo, speed, snapshot, splitVideo, redactVideo, joinVideos]
        case .audio: return [compress, metadata, normalize, visualize, trimAudio, channels, bleep]
        case .pdf: return [compress, metadata, splitPDF, organizePDF, mergePDFs]
        case .archive: return [extract, metadata]
        default: return [metadata]
        }
    }
}

/// Отвечает на вопрос «что показать в колесе для этих файлов».
public struct Registry: Sendable {
    public var available: Set<Requirement>

    public init(available: Set<Requirement>) { self.available = available }

    /// Целевые форматы по категориям (собственный формат исключается).
    public static let outputs: [FileCategory: [String]] = [
        .image: ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp", "pdf"],
        .video: ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif", "mp3"],
        .audio: ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"],
        .pdf: ["docx", "pages", "pptx", "xlsx", "jpg", "png", "epub", "txt", "md"],
        .document: ["docx", "pages", "pdf", "txt", "md", "html", "epub", "png", "jpg"],
        .slides: ["pdf", "pptx", "jpg", "png"],
        .spreadsheet: ["xlsx", "ods", "csv", "tsv", "pdf"],
        .epub: ["pdf", "docx", "pages", "txt", "md", "html"],
        .subtitle: ["srt", "vtt", "txt"],
        .archive: ["zip", "tar", "gz"],
    ]

    static func requirements(category: FileCategory, sourceExt: String, target: String) -> Set<Requirement> {
        var r: Set<Requirement> = []
        switch category {
        case .video, .audio: r.insert(.ffmpeg)
        case .image where target == "webp": r.insert(.cwebp)
        case .slides: r.insert(.keynote)
        default: break
        }
        if target == "pages" || sourceExt == "pages" { r.insert(.pages) }
        if sourceExt == "xls" || sourceExt == "numbers" { r.insert(.numbers) }
        if sourceExt == "key" { r.insert(.keynote) }
        return r
    }

    public func items(for urls: [URL], kind: WheelKind) -> [WheelItem] {
        guard !urls.isEmpty else { return [] }
        switch kind {
        case .actions:
            return ActionKind.allCases.map { WheelItem(payload: .action($0)) }
        case .convert:
            return formats(for: urls).map { WheelItem(payload: .format($0)) }
        case .tools:
            return tools(for: urls).map { WheelItem(payload: .tool($0)) }
        }
    }

    public func formats(for urls: [URL]) -> [FormatOption] {
        let categories = Set(urls.map(FileCategory.of))
        guard categories.count == 1, let category = categories.first, let targets = Self.outputs[category] else { return [] }
        let sources = Set(urls.map { FileCategory.canonical(ext: $0.pathExtension) })
        return targets.compactMap { target in
            // Не предлагаем формат, если все файлы уже в нём.
            if sources == [target] { return nil }
            var req: Set<Requirement> = []
            for s in sources { req.formUnion(Self.requirements(category: category, sourceExt: s, target: target)) }
            guard req.isSubset(of: available) else { return nil }
            return FormatOption(ext: target, requires: req)
        }
    }

    public func tools(for urls: [URL]) -> [ToolDef] {
        let categories = Set(urls.map(FileCategory.of))
        guard categories.count == 1, let category = categories.first else { return [] }
        return Tools.forCategory(category).filter { tool in
            urls.count >= tool.minFiles
                && (tool.maxFiles.map { urls.count <= $0 } ?? true)
                && tool.requires.isSubset(of: available)
                && !(tool.id == Tools.compress.id && category == .archive)
        }
    }
}
