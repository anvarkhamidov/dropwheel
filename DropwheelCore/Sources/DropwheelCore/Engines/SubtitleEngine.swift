import Foundation

/// SRT ⇄ VTT и извлечение текста субтитров.
public enum SubtitleEngine {
    public struct Cue: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String
    }

    public static func parse(_ raw: String) -> [Cue] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2, let s = time(parts[0]), let e = time(parts[1].split(separator: " ").first.map(String.init) ?? parts[1]) else { continue }
            let body = lines[(timingIndex + 1)...].joined(separator: "\n")
            cues.append(Cue(start: s, end: e, text: body))
        }
        return cues
    }

    /// `00:01:02,500`, `01:02.500`, `00:01:02.500`.
    static func time(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = s.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for p in parts { guard let v = Double(p) else { return nil }; total = total * 60 + v }
        return total
    }

    static func stamp(_ t: Double, separator: String) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, separator, ms % 1000)
    }

    public static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { i, c in
            "\(i + 1)\n\(stamp(c.start, separator: ",")) --> \(stamp(c.end, separator: ","))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    public static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { "\(stamp($0.start, separator: ".")) --> \(stamp($0.end, separator: "."))\n\($0.text)\n" }.joined(separator: "\n")
    }

    /// Только слова, без разметки вида <i> и {\an8}.
    public static func plain(_ cues: [Cue]) -> String {
        cues.map { $0.text.replacingOccurrences(of: "<[^>]+>|\\{[^}]+\\}", with: "", options: .regularExpression) }
            .joined(separator: "\n") + "\n"
    }

    public static func convert(_ input: URL, to ext: String, output: URL) throws {
        let data = try Data(contentsOf: input)
        let raw = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let cues = parse(raw)
        guard !cues.isEmpty else { throw DropwheelError("В файле не найдено ни одной реплики") }
        let out: String
        switch ext {
        case "srt": out = srt(cues)
        case "vtt": out = vtt(cues)
        case "txt": out = plain(cues)
        default: throw DropwheelError("Формат \(ext.uppercased()) не поддерживается для субтитров")
        }
        try out.write(to: output, atomically: true, encoding: .utf8)
    }
}
