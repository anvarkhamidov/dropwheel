import Foundation

/// Форматы iWork и рендер PPT(X) через установленные Pages, Keynote и Numbers (AppleScript).
/// При первом вызове macOS попросит разрешение на управление приложением (Automation).
public enum OfficeScripting {
    static let osascript = URL(fileURLWithPath: "/usr/bin/osascript")

    static func run(_ script: String, _ args: [String]) async throws {
        do {
            try await ProcessRunner.run(osascript, ["-e", script] + args)
        } catch let e as DropwheelError where e.message.contains("-1743") {
            throw DropwheelError("Нет разрешения управлять приложением. Разрешите в Настройках → Конфиденциальность → Автоматизация")
        }
    }

    /// Открывает файл в Pages и сохраняет как .pages.
    public static func pagesSave(_ input: URL, as output: URL) async throws {
        try await run("""
        on run argv
          set inFile to POSIX file (item 1 of argv)
          set outFile to POSIX file (item 2 of argv)
          tell application "Pages"
            set d to open inFile
            save d in outFile
            close d saving no
          end tell
        end run
        """, [input.path, output.path])
    }

    /// Экспорт из Pages: format — "Microsoft Word", "PDF", "unformatted text", "EPUB".
    public static func pagesExport(_ input: URL, to output: URL, format: String) async throws {
        try await run("""
        on run argv
          set inFile to POSIX file (item 1 of argv)
          set outFile to POSIX file (item 2 of argv)
          tell application "Pages"
            set d to open inFile
            export d to outFile as \(format)
            close d saving no
          end tell
        end run
        """, [input.path, output.path])
    }

    /// XLS / Numbers → XLSX через Numbers.
    public static func numbersExport(_ input: URL, to output: URL) async throws {
        try await run("""
        on run argv
          set inFile to POSIX file (item 1 of argv)
          set outFile to POSIX file (item 2 of argv)
          tell application "Numbers"
            set d to open inFile
            export d to outFile as Microsoft Excel
            close d saving no
          end tell
        end run
        """, [input.path, output.path])
    }

    /// PPT/PPTX/Key → PDF, PPTX или картинки слайдов через Keynote.
    public static func exportSlides(_ input: URL, to ext: String, scratch: URL) async throws -> [URL] {
        if ext == "pdf" || ext == "pptx" {
            let format = ext == "pdf" ? "PDF" : "Microsoft PowerPoint"
            let temp = scratch.appendingPathComponent("slides.\(ext)")
            try await run("""
            on run argv
              set inFile to POSIX file (item 1 of argv)
              set outFile to POSIX file (item 2 of argv)
              tell application "Keynote"
                set d to open inFile
                export d to outFile as \(format)
                close d saving no
              end tell
            end run
            """, [input.path, temp.path])
            return [try Scratch.commit(temp, to: OutputNamer.sibling(of: input, ext: ext))]
        }
        let folder = scratch.appendingPathComponent("slides", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let imageFormat = ext == "png" ? "PNG" : "JPEG"
        try await run("""
        on run argv
          set inFile to POSIX file (item 1 of argv)
          set outFolder to POSIX file (item 2 of argv)
          tell application "Keynote"
            set d to open inFile
            export d to outFolder as slide images with properties {image format:\(imageFormat), skipped slides:false}
            close d saving no
          end tell
        end run
        """, [input.path, folder.path])
        let dest = OutputNamer.siblingFolder(of: input, suffix: ext.uppercased())
        try FileManager.default.moveItem(at: folder, to: dest)
        return [dest]
    }
}
