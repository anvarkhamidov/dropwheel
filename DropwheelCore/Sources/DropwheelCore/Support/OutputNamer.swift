import Foundation

/// Подбирает имя результата рядом с оригиналом и никогда не перезаписывает существующий файл.
public enum OutputNamer {
    /// `photo.png` + `jpg` → `photo.jpg`; если занято — `photo 2.jpg`, `photo 3.jpg`…
    public static func sibling(of input: URL, ext: String, suffix: String? = nil, fileManager: FileManager = .default) -> URL {
        let dir = input.deletingLastPathComponent()
        var base = input.deletingPathExtension().lastPathComponent
        if let suffix, !suffix.isEmpty { base += " " + suffix }
        return unique(in: dir, base: base, ext: ext, fileManager: fileManager)
    }

    /// Папка рядом с оригиналом для многофайловых результатов (страницы PDF, кадры, части видео).
    public static func siblingFolder(of input: URL, suffix: String, fileManager: FileManager = .default) -> URL {
        let dir = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent + " " + suffix
        return unique(in: dir, base: base, ext: nil, fileManager: fileManager)
    }

    public static func unique(in dir: URL, base: String, ext: String?, fileManager: FileManager = .default) -> URL {
        func make(_ name: String) -> URL {
            if let ext, !ext.isEmpty { return dir.appendingPathComponent(name).appendingPathExtension(ext) }
            return dir.appendingPathComponent(name, isDirectory: true)
        }
        var candidate = make(base)
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = make("\(base) \(n)")
            n += 1
        }
        return candidate
    }
}
