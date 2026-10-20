import Foundation

public struct DropwheelError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Колбэк прогресса 0…1; `nil` — неопределённый.
public typealias ProgressHandler = @Sendable (Double?) -> Void

/// Где лежат внешние инструменты. Путь можно переопределить в настройках.
public struct ExternalTools: Sendable {
    public var ffmpeg: URL?
    public var ffprobe: URL?
    public var cwebp: URL?

    public static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    public init(ffmpeg: URL? = nil, ffprobe: URL? = nil, cwebp: URL? = nil) {
        self.ffmpeg = ffmpeg; self.ffprobe = ffprobe; self.cwebp = cwebp
    }

    public static func locate(_ name: String, override: String? = nil) -> URL? {
        let fm = FileManager.default
        if let override, !override.isEmpty, fm.isExecutableFile(atPath: override) { return URL(fileURLWithPath: override) }
        var dirs = searchPaths
        if let path = ProcessInfo.processInfo.environment["PATH"] { dirs += path.split(separator: ":").map(String.init) }
        for dir in dirs {
            let p = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    public static func discover(ffmpegOverride: String? = nil) -> ExternalTools {
        let ffmpeg = locate("ffmpeg", override: ffmpegOverride)
        let ffprobe = ffmpeg.map { $0.deletingLastPathComponent().appendingPathComponent("ffprobe") }
            .flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil } ?? locate("ffprobe")
        return ExternalTools(ffmpeg: ffmpeg, ffprobe: ffprobe, cwebp: locate("cwebp"))
    }

    public static func appInstalled(_ bundleID: String) -> Bool {
        let paths = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        let names = ["com.apple.iWork.Pages": "Pages.app", "com.apple.iWork.Keynote": "Keynote.app", "com.apple.iWork.Numbers": "Numbers.app"]
        guard let name = names[bundleID] else { return false }
        return paths.contains { FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent(name)) }
    }

    public var available: Set<Requirement> {
        var s: Set<Requirement> = []
        if ffmpeg != nil, ffprobe != nil { s.insert(.ffmpeg) }
        if cwebp != nil { s.insert(.cwebp) }
        if Self.appInstalled("com.apple.iWork.Pages") { s.insert(.pages) }
        if Self.appInstalled("com.apple.iWork.Keynote") { s.insert(.keynote) }
        if Self.appInstalled("com.apple.iWork.Numbers") { s.insert(.numbers) }
        return s
    }
}

/// Запуск дочернего процесса с отменой через Task cancellation.
public enum ProcessRunner {
    @discardableResult
    public static func run(_ exe: URL, _ args: [String], onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        CommandLog.recorder?.record(exe, args)
        let process = Process()
        process.executableURL = exe
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let collected = LockedBuffer()
        let errBuffer = LockedBuffer()
        let lines = LineSplitter()
        let state = CancelState()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            collected.append(d)
            // Строки собираются целиком: кусок из pipe может оборваться посреди строки.
            if let onLine { lines.feed(d).forEach(onLine) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { errBuffer.append(d) }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                process.terminationHandler = { p in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    collected.append(out.fileHandleForReading.readDataToEndOfFile())
                    errBuffer.append(err.fileHandleForReading.readDataToEndOfFile())
                    if let onLine, let rest = lines.flush() { onLine(rest) }
                    if state.cancelled {
                        cont.resume(throwing: CancellationError())
                    } else if p.terminationStatus != 0 || p.terminationReason == .uncaughtSignal {
                        let tail = errBuffer.string.split(whereSeparator: \.isNewline).suffix(4).joined(separator: "\n")
                        let how = p.terminationReason == .uncaughtSignal ? "аварийно завершился (сигнал \(p.terminationStatus))" : "завершился с кодом \(p.terminationStatus)"
                        cont.resume(throwing: DropwheelError("\(exe.lastPathComponent) \(how)\n\(tail)"))
                    } else {
                        cont.resume(returning: collected.string)
                    }
                }
                // Отмена могла прийти раньше запуска: тогда процесс не стартуем вовсе.
                guard state.begin(process) else { cont.resume(throwing: CancellationError()); return }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            state.cancel()
        }
    }
}

/// Общее состояние отмены между onCancel и запуском процесса (они могут идти в разных потоках).
final class CancelState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private(set) var cancelled = false

    /// false — отмена уже случилась, запускать нельзя.
    func begin(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        process = p
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}

/// Режет поток байтов на целые строки.
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func feed(_ d: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(d)
        var result: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            result.append(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return result
    }

    func flush() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll() }
        return String(decoding: buffer, as: UTF8.self)
    }
}

final class LockedBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

/// Рабочая папка задачи; результат переносится в цель атомарно.
public enum Scratch {
    public static func dir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Dropwheel/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Переносит готовый временный файл в итоговое место, не перезаписывая чужие файлы.
    public static func commit(_ temp: URL, to dest: URL) throws -> URL {
        let fm = FileManager.default
        var final = dest
        if fm.fileExists(atPath: final.path) {
            final = OutputNamer.unique(in: dest.deletingLastPathComponent(),
                                       base: dest.deletingPathExtension().lastPathComponent,
                                       ext: dest.pathExtension.isEmpty ? nil : dest.pathExtension)
        }
        try fm.moveItem(at: temp, to: final)
        return final
    }
}

/// Запись «сначала во временное место, потом перенос»: при ошибке или отмене рядом с оригиналом
/// не остаётся полупустых файлов и папок.
public enum Staged {
    public static func file(beside dest: URL, _ write: (URL) throws -> Void) throws -> URL {
        let dir = try Scratch.dir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let temp = dir.appendingPathComponent("out").appendingPathExtension(dest.pathExtension)
        try write(temp)
        return try Scratch.commit(temp, to: dest)
    }

    public static func fileAsync(beside dest: URL, _ write: (URL) async throws -> Void) async throws -> URL {
        let dir = try Scratch.dir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let temp = dir.appendingPathComponent("out").appendingPathExtension(dest.pathExtension)
        try await write(temp)
        return try Scratch.commit(temp, to: dest)
    }

    public static func folderAsync(beside original: URL, suffix: String, _ fill: (URL) async throws -> Void) async throws -> URL {
        let dir = try Scratch.dir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let temp = dir.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try await fill(temp)
        let dest = OutputNamer.siblingFolder(of: original, suffix: suffix)
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    public static func folder(beside original: URL, suffix: String, _ fill: (URL) throws -> Void) throws -> URL {
        let dir = try Scratch.dir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let temp = dir.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try fill(temp)
        // Имя выбираем в самом конце, чтобы не занять его раньше времени.
        let dest = OutputNamer.siblingFolder(of: original, suffix: suffix)
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }
}
