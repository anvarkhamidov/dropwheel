import Foundation

/// Сборщики аргументов ffmpeg для инструментов видео и аудио. Чистые функции — их легко тестировать.
public enum MediaTools {
    static func t(_ s: Double) -> String { String(format: "%.3f", max(0, s)) }

    /// Кодек под контейнер результата: тот же, что у входа, но перекодированный, чтобы срез был кадр-в-кадр.
    public static func reencode(ext: String, hasVideo: Bool) -> [String] {
        MediaEngine.encodeArgs(target: ext.lowercased() == "m4v" ? "mp4" : ext.lowercased(), hasVideo: hasVideo)
    }

    public static func trim(start: Double, end: Double, ext: String, hasVideo: Bool) -> [String] {
        ["-ss", t(start), "-to", t(end)] + reencode(ext: ext, hasVideo: hasVideo)
    }

    /// Обрезка тишины по краям (аудио).
    public static func trimSilence(ext: String, thresholdDB: Double = -45) -> [String] {
        let filter = "silenceremove=start_periods=1:start_threshold=\(Int(thresholdDB))dB:start_silence=0.1," +
            "areverse,silenceremove=start_periods=1:start_threshold=\(Int(thresholdDB))dB:start_silence=0.1,areverse"
        return ["-af", filter] + reencode(ext: ext, hasVideo: false)
    }

    /// Кроп видео; координаты в пикселях кадра. Звук сохраняется без перекодирования, если контейнер позволяет.
    public static func crop(x: Int, y: Int, width: Int, height: Int, ext: String) -> [String] {
        let w = width - width % 2, h = height - height % 2 // yuv420p требует чётные размеры
        return ["-vf", "crop=\(w):\(h):\(x):\(y)", "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "copy"]
            + (ext == "mp4" || ext == "mov" ? ["-movflags", "+faststart"] : [])
    }

    /// atempo принимает 0.5…2, поэтому большие коэффициенты собираются цепочкой.
    public static func atempoChain(_ speed: Double) -> String {
        var s = speed, parts: [String] = []
        while s > 2 { parts.append("atempo=2.0"); s /= 2 }
        while s < 0.5 { parts.append("atempo=0.5"); s /= 0.5 }
        parts.append(String(format: "atempo=%.4f", s))
        return parts.joined(separator: ",")
    }

    public static func speed(_ factor: Double, keepPitch: Bool, hasAudio: Bool, ext: String) -> [String] {
        var args = ["-filter:v", String(format: "setpts=PTS/%.4f", factor)]
        if hasAudio {
            args += ["-filter:a", keepPitch ? atempoChain(factor) : String(format: "asetrate=sr*%.4f,aresample=sr", factor).replacingOccurrences(of: "sr", with: "44100")]
        } else {
            args += ["-an"]
        }
        return args + reencode(ext: ext, hasVideo: true).filter { $0 != "-vn" }
    }

    /// Точки разреза (секунды) → отрезки [start, end).
    public static func segments(duration: Double, cuts: [Double]) -> [(Double, Double)] {
        let points = ([0] + cuts.filter { $0 > 0.05 && $0 < duration - 0.05 }.sorted() + [duration])
        return zip(points, points.dropFirst()).map { ($0, $1) }
    }

    public static func equalCuts(duration: Double, parts: Int) -> [Double] {
        guard parts > 1 else { return [] }
        return (1..<parts).map { duration * Double($0) / Double(parts) }
    }

    /// Кадр в момент времени → PNG полного разрешения.
    public static func snapshot(at time: Double) -> (pre: [String], args: [String]) {
        (["-ss", t(time)], ["-frames:v", "1", "-update", "1"])
    }

    /// Области редакции видео: нормализованные прямоугольники со своим интервалом времени.
    public struct VideoRedaction: Sendable, Equatable {
        public var rect: CGRect
        public var start: Double
        public var end: Double
        public var blur: Bool
        public init(rect: CGRect, start: Double, end: Double, blur: Bool) { self.rect = rect; self.start = start; self.end = end; self.blur = blur }
    }

    public static func redactFilter(_ items: [VideoRedaction], width: Int, height: Int) -> String {
        guard !items.isEmpty else { return "null" }
        var chain: [String] = []
        var last = "[0:v]"
        for (i, r) in items.enumerated() {
            let x = Int(r.rect.minX * CGFloat(width)), y = Int(r.rect.minY * CGFloat(height))
            let w = max(2, Int(r.rect.width * CGFloat(width))), h = max(2, Int(r.rect.height * CGFloat(height)))
            let enable = "enable='between(t,\(t(r.start)),\(t(r.end)))'"
            let out = "[v\(i)]"
            if r.blur {
                chain.append("\(last)split[b\(i)][c\(i)];[c\(i)]crop=\(w):\(h):\(x):\(y),boxblur=\(max(2, min(w, h) / 8)):2[k\(i)];[b\(i)][k\(i)]overlay=\(x):\(y):\(enable)\(out)")
            } else {
                chain.append("\(last)drawbox=x=\(x):y=\(y):w=\(w):h=\(h):color=black@1:t=fill:\(enable)\(out)")
            }
            last = out
        }
        return chain.joined(separator: ";")
    }

    public static func redact(_ items: [VideoRedaction], width: Int, height: Int, ext: String) -> [String] {
        let filter = redactFilter(items, width: width, height: height)
        let lastLabel = "[v\(items.count - 1)]"
        return ["-filter_complex", filter, "-map", lastLabel, "-map", "0:a?", "-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "copy"]
            + (ext == "mp4" || ext == "mov" ? ["-movflags", "+faststart"] : [])
    }

    /// Склейка: все клипы приводятся к размеру и fps первого, звук — к 48 кГц стерео (тишина, если его нет).
    public static func join(count: Int, width: Int, height: Int, fps: Double, hasAudio: [Bool], durations: [Double]) -> [String] {
        var filter = ""
        var inputs = ""
        for i in 0..<count {
            filter += "[\(i):v]scale=\(width):\(height):force_original_aspect_ratio=decrease,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(String(format: "%.3f", fps)),format=yuv420p[v\(i)];"
            if hasAudio[i] {
                filter += "[\(i):a]aformat=sample_rates=48000:channel_layouts=stereo[a\(i)];"
            } else {
                // Тишина ровно по длине клипа, чтобы звук и картинка не разъехались после склейки.
                filter += "anullsrc=r=48000:cl=stereo,atrim=0:\(t(durations[i])),asetpts=N/SR/TB[a\(i)];"
            }
            inputs += "[v\(i)][a\(i)]"
        }
        filter += "\(inputs)concat=n=\(count):v=1:a=1[v][a]"
        return ["-filter_complex", filter, "-map", "[v]", "-map", "[a]", "-c:v", "libx264", "-crf", "20", "-preset", "medium",
                "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
    }

    /// Нормализация громкости по EBU R128.
    public static func normalize(lufs: Double, lra: Double, truePeak: Double, ext: String) -> [String] {
        ["-af", String(format: "loudnorm=I=%.1f:LRA=%.1f:TP=%.1f", lufs, lra, truePeak), "-ar", "48000"] + reencode(ext: ext, hasVideo: false)
    }

    public enum VisualizerStyle: String, CaseIterable, Sendable { case wave, bars, still }
    public enum VisualizerShape: String, CaseIterable, Sendable {
        case landscape, portrait, square
        public var size: (Int, Int) {
            switch self { case .landscape: return (1920, 1080); case .portrait: return (1080, 1920); case .square: return (1080, 1080) }
        }
    }

    /// Аудио → MP4 с волной или статичной картинкой.
    public static func visualizer(style: VisualizerStyle, shape: VisualizerShape, color: String, image: URL?) -> (pre: [String], extraInputs: [String], args: [String]) {
        let (w, h) = shape.size
        let base: String
        var extra: [String] = []
        if let image {
            extra = ["-loop", "1", "-i", image.path]
            base = "[1:v]scale=\(w):\(h):force_original_aspect_ratio=increase,crop=\(w):\(h),setsar=1[bg]"
        } else {
            base = "color=c=0x111111:s=\(w)x\(h):r=30[bg]"
        }
        let viz: String
        switch style {
        case .wave: viz = "[0:a]showwaves=s=\(w)x\(h / 3):mode=cline:colors=\(color):rate=30[fg];[bg][fg]overlay=0:(H-h)/2:shortest=1,format=yuv420p[v]"
        case .bars: viz = "[0:a]showfreqs=s=\(w)x\(h / 3):mode=bar:colors=\(color):fscale=log:ascale=sqrt[fg];[bg][fg]overlay=0:H-h-60:shortest=1,format=yuv420p[v]"
        case .still: viz = "[bg]format=yuv420p,fps=30[v]"
        }
        let args = ["-filter_complex", base + ";" + viz, "-map", "[v]", "-map", "0:a", "-c:v", "libx264", "-preset", "medium", "-tune", "stillimage",
                    "-crf", "22", "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart"]
        return ([], extra, args)
    }

    /// Каналы: моно или стерео, громкость каждого канала (0…2).
    public static func channels(mono: Bool, left: Double, right: Double, ext: String) -> [String] {
        let pan = mono
            ? String(format: "pan=mono|c0=%.3f*c0+%.3f*c1", left / 2, right / 2)
            : String(format: "pan=stereo|c0=%.3f*c0|c1=%.3f*c1", left, right)
        return ["-af", pan] + reencode(ext: ext, hasVideo: false)
    }

    /// Пи-и-ип: в интервалах звук глушится и подмешивается синус 1 кГц.
    public static func bleep(_ ranges: [(Double, Double)], duration: Double, ext: String) -> [String] {
        guard !ranges.isEmpty else { return reencode(ext: ext, hasVideo: false) }
        let cond = ranges.map { "between(t,\(t($0.0)),\(t($0.1)))" }.joined(separator: "+")
        let filter = "[0:a]volume=0:enable='\(cond)'[m];sine=f=1000:d=\(t(duration)):sample_rate=48000,volume=0.35,volume=0:enable='not(\(cond))'[b];[m][b]amix=inputs=2:duration=first:normalize=0[out]"
        return ["-filter_complex", filter, "-map", "[out]"] + reencode(ext: ext, hasVideo: false)
    }

    /// Сжатие: CRF для видео или битрейт под целевой размер.
    public static func compressVideo(targetBytes: Int64?, duration: Double, crf: Int, maxHeight: Int?) -> [String] {
        var args: [String] = []
        if let maxHeight { args += ["-vf", "scale=-2:'min(\(maxHeight),ih)'"] }
        if let target = targetBytes, duration > 0 {
            let audioKbps = 96.0
            let totalKbps = Double(target) * 8 / 1000 / duration * 0.96
            let videoKbps = max(150, totalKbps - audioKbps)
            args += ["-c:v", "libx264", "-preset", "medium", "-b:v", "\(Int(videoKbps))k", "-maxrate", "\(Int(videoKbps * 1.3))k", "-bufsize", "\(Int(videoKbps * 2))k"]
            args += ["-c:a", "aac", "-b:a", "\(Int(audioKbps))k"]
        } else {
            args += ["-c:v", "libx264", "-preset", "slow", "-crf", "\(crf)", "-c:a", "aac", "-b:a", "128k"]
        }
        return args + ["-pix_fmt", "yuv420p", "-movflags", "+faststart"]
    }

    public static func compressAudio(kbps: Int, ext: String) -> [String] {
        switch ext.lowercased() {
        case "mp3": return ["-vn", "-c:a", "libmp3lame", "-b:a", "\(kbps)k"]
        case "ogg": return ["-vn", "-c:a", "vorbis", "-strict", "-2", "-ac", "2", "-b:a", "\(kbps)k"]
        case "opus": return ["-vn", "-c:a", "libopus", "-b:a", "\(kbps)k"]
        case "wma": return ["-vn", "-c:a", "wmav2", "-b:a", "\(kbps)k"]
        default: return ["-vn", "-c:a", "aac", "-b:a", "\(kbps)k"] // m4a, а для wav/flac/aiff результат будет m4a
        }
    }

    /// Расширение результата сжатия аудио: lossless-форматы сжимаются в M4A.
    public static func compressedAudioExt(_ ext: String) -> String {
        ["wav", "flac", "aiff", "aif"].contains(ext.lowercased()) ? "m4a" : ext.lowercased()
    }
}
