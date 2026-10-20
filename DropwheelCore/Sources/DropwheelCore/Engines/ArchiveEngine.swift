import Foundation

/// ZIP/TAR/GZIP через системные zip и bsdtar (bsdtar ещё и читает RAR).
public enum ArchiveEngine {
    static let tar = URL(fileURLWithPath: "/usr/bin/tar")
    static let zip = URL(fileURLWithPath: "/usr/bin/zip")
    static let gzip = URL(fileURLWithPath: "/usr/bin/gzip")

    /// `photos.tar.gz` → `photos`, `a.zip` → `a`.
    public static func baseName(_ url: URL) -> String {
        var name = url.lastPathComponent
        for suffix in [".tar.gz", ".tgz", ".tar", ".zip", ".gz", ".rar"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        return name
    }

    public static func isPlainGzip(_ url: URL) -> Bool {
        let n = url.lastPathComponent.lowercased()
        return n.hasSuffix(".gz") && !n.hasSuffix(".tar.gz")
    }

    /// Распаковка в папку `dir`.
    public static func extract(_ input: URL, into dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if isPlainGzip(input) {
            // Одиночный .gz: распаковываем gzip, затем пробуем как tar.
            let out = dir.appendingPathComponent(String(input.lastPathComponent.dropLast(3)))
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "/usr/bin/gzip -dc \"$0\" > \"$1\"", input.path, out.path])
            return
        }
        try await ProcessRunner.run(tar, ["-xf", input.path, "-C", dir.path])
    }

    public static func convert(_ input: URL, to ext: String, output: URL, scratch: URL) async throws {
        let content = scratch.appendingPathComponent("content", isDirectory: true)
        try await extract(input, into: content)
        let items = try FileManager.default.contentsOfDirectory(atPath: content.path).filter { $0 != "__MACOSX" && $0 != ".DS_Store" }
        guard !items.isEmpty else { throw DropwheelError("Архив пустой") }
        switch ext {
        case "zip":
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "cd \"$0\" && /usr/bin/zip -qry \"$1\" .", content.path, output.path])
        case "tar":
            try await ProcessRunner.run(tar, ["-cf", output.path, "-C", content.path] + items)
        case "gz":
            try await ProcessRunner.run(tar, ["-czf", output.path, "-C", content.path] + items)
        default:
            throw DropwheelError("Формат \(ext.uppercased()) не поддерживается для архивов")
        }
    }

    /// Инструмент EXTRACT: папка рядом с архивом.
    public static func extractBeside(_ input: URL) async throws -> URL {
        let dest = OutputNamer.unique(in: input.deletingLastPathComponent(), base: baseName(input), ext: nil)
        let scratch = try Scratch.dir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let content = scratch.appendingPathComponent("content", isDirectory: true)
        try await extract(input, into: content)
        try FileManager.default.moveItem(at: content, to: dest)
        return dest
    }
}
