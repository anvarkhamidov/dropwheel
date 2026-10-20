import Foundation

/// Группа файлов, от которой зависит состав колеса.
public enum FileCategory: String, CaseIterable, Sendable {
    case image, video, audio, pdf, document, slides, spreadsheet, epub, subtitle, archive, other

    /// Расширения входа для каждой категории.
    static let extensions: [FileCategory: Set<String>] = [
        .image: ["jpg", "jpeg", "png", "webp", "heic", "heif", "tiff", "tif", "avif", "bmp", "gif", "svg"],
        .video: ["mp4", "mov", "mkv", "webm", "avi", "wmv", "m4v"],
        .audio: ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "aif", "wma", "aac"],
        .pdf: ["pdf"],
        .document: ["docx", "pages", "md", "markdown", "txt", "rtf", "rtfd", "odt"],
        .slides: ["pptx", "ppt", "key"],
        .spreadsheet: ["xlsx", "xls", "ods", "csv", "tsv", "numbers"],
        .epub: ["epub"],
        .subtitle: ["srt", "vtt"],
        .archive: ["zip", "tar", "gz", "tgz", "rar"],
    ]

    public static func of(_ url: URL) -> FileCategory {
        of(ext: url.pathExtension)
    }

    public static func of(ext raw: String) -> FileCategory {
        let ext = raw.lowercased()
        for (category, set) in extensions where set.contains(ext) { return category }
        return .other
    }

    /// Нормализованное расширение: jpeg → jpg, tif → tiff и т.п. Нужно, чтобы не предлагать «конвертировать в себя».
    public static func canonical(ext raw: String) -> String {
        switch raw.lowercased() {
        case "jpeg": return "jpg"
        case "tif": return "tiff"
        case "heif": return "heic"
        case "aif": return "aiff"
        case "markdown": return "md"
        case "tgz": return "gz"
        case "m4v": return "mp4"
        default: return raw.lowercased()
        }
    }

    public var title: String {
        switch self {
        case .image: return "Изображения"
        case .video: return "Видео"
        case .audio: return "Аудио"
        case .pdf: return "PDF"
        case .document: return "Документы"
        case .slides: return "Презентации"
        case .spreadsheet: return "Таблицы"
        case .epub: return "EPUB"
        case .subtitle: return "Субтитры"
        case .archive: return "Архивы"
        case .other: return "Прочее"
        }
    }
}
