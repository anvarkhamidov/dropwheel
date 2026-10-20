import XCTest
@testable import DropwheelCore

final class CommandLogTests: XCTestCase {
    func testQuoting() {
        XCTAssertEqual(ShellQuote.quote("-c:a"), "-c:a")
        XCTAssertEqual(ShellQuote.quote("/tmp/my file.png"), "'/tmp/my file.png'")
        XCTAssertEqual(ShellQuote.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(ShellQuote.quote(""), "''")
    }

    /// Записанную команду можно вставить в терминал и получить тот же результат —
    /// включая имя с пробелом, кириллицей и апострофом.
    func testRecordedFfmpegCommandReplaysInShell() async throws {
        let tools = ExternalTools.discover()
        try XCTSkipIf(tools.ffmpeg == nil, "ffmpeg не установлен")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DropwheelCmd-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("звук мой's.wav")
        try await ProcessRunner.run(tools.ffmpeg!, ["-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=duration=1", input.path])
        let output = dir.appendingPathComponent("итог мой's.mp3")

        let recorder = CommandRecorder()
        try await CommandLog.$recorder.withValue(recorder) {
            try await MediaEngine(tools: tools).process(input, output: output, args: MediaEngine.encodeArgs(target: "mp3", hasVideo: false)) { _ in }
        }
        let ffmpegLine = try XCTUnwrap(recorder.commands.last { $0.contains("ffmpeg") && $0.contains("libmp3lame") })
        XCTAssertTrue(recorder.commands.contains { $0.contains("ffprobe") }, "probe тоже записан")

        try FileManager.default.removeItem(at: output)
        try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", ffmpegLine])
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "команда из журнала воспроизводит результат")
    }

    func testNoRecorderNoRecording() async throws {
        // Вне задачи журнал не ведётся и ничего не ломается.
        XCTAssertNil(CommandLog.recorder)
        try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/true"), [])
    }
}
