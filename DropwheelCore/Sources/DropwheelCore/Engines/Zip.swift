import Foundation

/// Тонкая обёртка над системными zip/unzip для OOXML, ODF и EPUB.
public enum Zip {
    static let sh = URL(fileURLWithPath: "/bin/sh")

    /// Упаковывает содержимое папки. `storedFirst` — файл, который должен лежать первым и без сжатия (mimetype).
    public static func pack(_ dir: URL, to output: URL, storedFirst: String? = nil) async throws {
        try? FileManager.default.removeItem(at: output)
        if let first = storedFirst {
            try await ProcessRunner.run(sh, ["-c", "cd \"$0\" && /usr/bin/zip -qX0 \"$1\" \"$2\" && /usr/bin/zip -qXr9D \"$1\" . -x \"$2\" -x '.DS_Store'",
                                             dir.path, output.path, first])
        } else {
            try await ProcessRunner.run(sh, ["-c", "cd \"$0\" && /usr/bin/zip -qXr9D \"$1\" . -x '.DS_Store'", dir.path, output.path])
        }
    }

    public static func unpack(_ archive: URL, into dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-qq", "-o", archive.path, "-d", dir.path])
    }

    /// Пишет набор файлов `путь → содержимое` в папку.
    public static func write(_ files: [String: Data], into dir: URL) throws {
        for (path, data) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }
}

extension String {
    var xmlEscaped: String {
        var s = self
        for (a, b) in [("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;")] { s = s.replacingOccurrences(of: a, with: b) }
        // Управляющие символы недопустимы в XML 1.0.
        return String(s.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\n" || $0 == "\t" || $0 == "\r" })
    }
    var data: Data { Data(utf8) }
}
