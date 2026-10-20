import Foundation

/// Аудио и видео через ffmpeg/ffprobe.
public struct MediaEngine: Sendable {
    public let tools: ExternalTools
    public init(tools: ExternalTools) { self.tools = tools }

    public struct Info: Sendable {
        public var duration: Double
        public var width: Int?
        public var height: Int?
        public var fps: Double?
        public var hasAudio: Bool
        public var hasVideo: Bool
        public var audioChannels: Int?
    }

    func ffmpeg() throws -> URL {
        guard let f = tools.ffmpeg else { throw DropwheelError("Нужен ffmpeg: brew install ffmpeg") }
        return f
    }

    public func probe(_ url: URL) async throws -> Info {
        guard let probe = tools.ffprobe else { throw DropwheelError("Нужен ffprobe: brew install ffmpeg") }
        let json = try await ProcessRunner.run(probe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path])
        guard let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { throw DropwheelError("ffprobe вернул пустой ответ") }
        let streams = obj["streams"] as? [[String: Any]] ?? []
        let format = obj["format"] as? [String: Any] ?? [:]
        let video = streams.first { ($0["codec_type"] as? String) == "video" && (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0) == 0 }
        let audio = streams.first { ($0["codec_type"] as? String) == "audio" }
        var fps: Double?
        if let r = video?["avg_frame_rate"] as? String {
            let parts = r.split(separator: "/").compactMap { Double($0) }
            if parts.count == 2, parts[1] > 0 { fps = parts[0] / parts[1] }
        }
        return Info(duration: Double(format["duration"] as? String ?? "") ?? 0,
                    width: video?["width"] as? Int, height: video?["height"] as? Int, fps: fps,
                    hasAudio: audio != nil, hasVideo: video != nil,
                    audioChannels: audio?["channels"] as? Int)
    }

    /// Аргументы кодирования под целевой контейнер.
    public static func encodeArgs(target: String, hasVideo: Bool) -> [String] {
        let x264 = ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p"]
        switch target {
        case "mp4", "mov": return (hasVideo ? x264 : ["-vn"]) + ["-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
        case "mkv": return (hasVideo ? x264 : ["-vn"]) + ["-c:a", "aac", "-b:a", "160k"]
        case "webm": return (hasVideo ? ["-c:v", "libsvtav1", "-crf", "35", "-preset", "8", "-pix_fmt", "yuv420p"] : ["-vn"]) + ["-c:a", "libopus", "-b:a", "128k"]
        case "avi": return (hasVideo ? ["-c:v", "mpeg4", "-q:v", "3"] : ["-vn"]) + ["-c:a", "libmp3lame", "-q:a", "3"]
        case "wmv": return (hasVideo ? ["-c:v", "wmv2", "-b:v", "3M"] : ["-vn"]) + ["-c:a", "wmav2", "-b:a", "192k"]
        case "gif": return ["-an", "-vf", "fps=12,scale='min(720,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a", "-loop", "0"]
        // Аудио
        case "mp3": return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a": return ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case "wav": return ["-vn", "-c:a", "pcm_s16le"]
        case "flac": return ["-vn", "-c:a", "flac"]
        case "ogg": return ["-vn", "-c:a", "vorbis", "-strict", "-2", "-ac", "2", "-q:a", "5"]
        case "opus": return ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        case "aiff": return ["-vn", "-c:a", "pcm_s16be"]
        case "wma": return ["-vn", "-c:a", "wmav2", "-b:a", "192k"]
        default: return []
        }
    }

    /// Запускает ffmpeg и переводит `-progress` в 0…1 по длительности.
    public func run(_ args: [String], duration: Double, progress: @escaping ProgressHandler) async throws {
        let exe = try ffmpeg()
        let full = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"] + args
        try await ProcessRunner.run(exe, full) { line in
            guard duration > 0 else { return progress(nil) }
            if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
                let v = Double(line.split(separator: "=").last ?? "") ?? 0
                progress(min(1, max(0, v / 1_000_000 / duration)))
            }
        }
    }

    public func convert(_ input: URL, to ext: String, output: URL, progress: @escaping ProgressHandler) async throws {
        let info = try await probe(input)
        if ext == "mp3" || !info.hasVideo, !info.hasAudio { throw DropwheelError("В файле нет звуковой дорожки") }
        let args = ["-i", input.path] + Self.encodeArgs(target: ext, hasVideo: info.hasVideo) + ["-map_metadata", "0", output.path]
        try await run(args, duration: info.duration, progress: progress)
    }

    /// Универсальный путь для инструментов: свой набор аргументов между входом и выходом.
    public func process(_ input: URL, output: URL, args: [String], preInput: [String] = [], progress: @escaping ProgressHandler) async throws {
        let info = try await probe(input)
        try await run(preInput + ["-i", input.path] + args + [output.path], duration: info.duration, progress: progress)
    }
}
