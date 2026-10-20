import Foundation

/// Запоминает внешние команды задачи (ffmpeg, cwebp…), чтобы показать их пользователю:
/// видно, что именно запускалось, и это можно повторить в терминале.
public final class CommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    public init() {}

    public var commands: [String] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    func record(_ exe: URL, _ args: [String]) {
        let line = ([exe.path] + args).map(ShellQuote.quote).joined(separator: " ")
        lock.lock(); items.append(line); lock.unlock()
    }
}

public enum CommandLog {
    /// Задаётся на время задачи: `CommandLog.$recorder.withValue(r) { … }`.
    @TaskLocal public static var recorder: CommandRecorder?
}

public enum ShellQuote {
    /// Безопасная для sh/zsh запись аргумента: без кавычек, если можно, иначе в одинарных.
    public static func quote(_ s: String) -> String {
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_./=:,+@%".unicodeScalars.contains($0) }) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
