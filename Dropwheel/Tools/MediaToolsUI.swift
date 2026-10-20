import AVFoundation
import AVKit
import Observation
import DropwheelCore
import SwiftUI

/// Плеер с текущей позицией для таймлайнов.
@MainActor
@Observable
final class PlayerModel {
    let player: AVPlayer
    var time: Double = 0
    var duration: Double = 0
    var fps: Double = 25
    var size = CGSize(width: 16, height: 9)
    @ObservationIgnored private var observer: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.time = t.seconds.isFinite ? t.seconds : 0 }
        }
        Task {
            let asset = AVURLAsset(url: url)
            if let d = try? await asset.load(.duration) { duration = d.seconds.isFinite ? d.seconds : 0 }
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                if let r = try? await track.load(.nominalFrameRate), r > 0 { fps = Double(r) }
                if let s = try? await track.load(.naturalSize), let t = try? await track.load(.preferredTransform) {
                    let r = CGRect(origin: .zero, size: s).applying(t)
                    size = CGSize(width: abs(r.width), height: abs(r.height))
                }
            }
        }
    }

    func seek(_ t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        time = t
    }

    func step(_ frames: Int) { seek(min(max(0, time + Double(frames) / fps), duration)) }

    /// Кадр в момент времени для превью (редакция и кроп видео).
    func frame(at t: Double, url: URL) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: 1280, height: 1280)
        return try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
    }
}

/// Запуск инструмента ffmpeg: временный файл → рядом с оригиналом.
func runMedia(_ url: URL, ext: String? = nil, suffix: String, tools: ExternalTools, args: [String], pre: [String] = [],
              progress: @escaping ProgressHandler) async throws -> URL {
    let e = ext ?? url.pathExtension.lowercased()
    return try await Staged.fileAsync(beside: OutputNamer.sibling(of: url, ext: e, suffix: suffix)) { out in
        try await MediaEngine(tools: tools).process(url, output: out, args: args, preInput: pre, progress: progress)
    }
}

/// Кнопки покадрового шага.
struct FrameStepper: View {
    let model: PlayerModel
    var body: some View {
        HStack(spacing: Tokens.Space.s1) {
            Button { model.step(-1) } label: { Image(systemName: "backward.frame") }.help("Кадр назад (←)").keyboardShortcut(.leftArrow, modifiers: [])
            Button { model.player.timeControlStatus == .playing ? model.player.pause() : model.player.play() } label: {
                Image(systemName: model.player.timeControlStatus == .playing ? "pause.fill" : "play.fill")
            }.keyboardShortcut(.space, modifiers: [])
            Button { model.step(1) } label: { Image(systemName: "forward.frame") }.help("Кадр вперёд (→)").keyboardShortcut(.rightArrow, modifiers: [])
            Text(Timecode.string(model.time)).font(Tokens.Font.mono).foregroundStyle(Tokens.Palette.textMuted)
        }
    }
}

// MARK: TRIM (видео и аудио)

struct TrimTool: View {
    let ctx: ToolContext
    let isAudio: Bool
    @State private var model: PlayerModel?
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var wave: [Float] = []
    @State private var silenceOnly = false

    var body: some View {
        ToolChrome(title: isAudio ? "Обрезка аудио" : "Обрезка видео", canSave: end > start, close: ctx.close, save: save) {
            if let model {
                if !isAudio { PreviewBox(height: 300) { PlayerView(player: model.player) } }
                FrameStepper(model: model)
                if isAudio { Toggle("Только убрать тишину в начале и в конце", isOn: $silenceOnly) }
                if !silenceOnly {
                    RangeTimeline(duration: model.duration, start: $start, end: $end, playhead: model.time, waveform: wave) { model.seek($0) }
                    HStack {
                        TimecodeField(label: "Начало", value: $start, range: 0...max(model.duration, 0.01))
                        Button("← курсор") { start = min(model.time, end - 0.05) }.help("Начало = текущая позиция (I)").keyboardShortcut("i", modifiers: [])
                        Spacer()
                        TimecodeField(label: "Конец", value: $end, range: 0...max(model.duration, 0.01))
                        Button("курсор →") { end = max(model.time, start + 0.05) }.help("Конец = текущая позиция (O)").keyboardShortcut("o", modifiers: [])
                    }
                    Text("Останется: \(Timecode.string(max(0, end - start)))").font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textMuted)
                }
            } else { ProgressView() }
        }
        .task {
            let m = PlayerModel(url: ctx.file)
            model = m
            for _ in 0..<50 where m.duration == 0 { try? await Task.sleep(nanoseconds: 50_000_000) }
            end = m.duration
            if isAudio { wave = await loadWaveform(ctx.file, tools: ctx.tools) }
        }
        .onDisappear { model?.player.pause() }
    }

    private func save() {
        let url = ctx.file, tools = ctx.tools, s = start, e = end, audio = isAudio, silence = silenceOnly
        ctx.submit("Обрезка") { progress in
            let ext = url.pathExtension.lowercased()
            let args = silence ? MediaTools.trimSilence(ext: ext) : MediaTools.trim(start: s, end: e, ext: ext, hasVideo: !audio)
            return [try await runMedia(url, suffix: "обрезан", tools: tools, args: args) { p in progress(0, p) }]
        }
    }
}

// MARK: CROP VIDEO

struct CropVideoTool: View {
    let ctx: ToolContext
    @State private var model: PlayerModel?
    @State private var frame: CGImage?
    @State private var rect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    @State private var ratio: CropImageTool.Ratio = .free

    var body: some View {
        ToolChrome(title: "Кроп видео", close: ctx.close, save: save) {
            PreviewBox(height: 320) {
                if let frame {
                    Image(decorative: frame, scale: 1).resizable().scaledToFit()
                        .overlay(SelectionRect(rect: $rect, aspect: ratio.value(original: aspect(of: frame)), imageAspect: aspect(of: frame)))
                } else { ProgressView() }
            }
            if let model {
                HStack {
                    Picker("Пропорции", selection: $ratio) { ForEach(CropImageTool.Ratio.allCases) { Text($0.rawValue).tag($0) } }
                        .frame(width: 220)
                        .onChange(of: ratio) { _, r in
                            if let v = r.value(original: model.size.width / max(model.size.height, 1)) {
                                let ia = model.size.width / max(model.size.height, 1)
                                var w: CGFloat = 1, h = ia / v
                                if h > 1 { h = 1; w = v / ia }
                                rect = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
                            }
                        }
                    Spacer()
                    Text("\(Int(rect.width * model.size.width)) × \(Int(rect.height * model.size.height)) px · звук сохранится")
                        .font(Tokens.Font.mono).foregroundStyle(Tokens.Palette.textMuted)
                }
            }
        }
        .task {
            let m = PlayerModel(url: ctx.file); model = m
            for _ in 0..<50 where m.duration == 0 { try? await Task.sleep(nanoseconds: 50_000_000) }
            frame = await m.frame(at: min(1, m.duration / 2), url: ctx.file)
        }
    }

    private func save() {
        guard let size = model?.size else { return }
        let url = ctx.file, tools = ctx.tools, r = rect
        ctx.submit("Кроп видео") { progress in
            let args = MediaTools.crop(x: Int(r.minX * size.width), y: Int(r.minY * size.height),
                                       width: Int(r.width * size.width), height: Int(r.height * size.height), ext: url.pathExtension.lowercased())
            return [try await runMedia(url, suffix: "кроп", tools: tools, args: args) { p in progress(0, p) }]
        }
    }
}

// MARK: SPEED

struct SpeedTool: View {
    let ctx: ToolContext
    @State private var speed: Double = 2
    @State private var keepPitch = true
    @State private var info: MediaEngine.Info?

    var body: some View {
        ToolChrome(title: "Скорость", canSave: speed != 1, close: ctx.close, save: save) {
            ToolSection(title: "Множитель") {
                HStack {
                    ForEach([0.25, 0.5, 0.75, 1.5, 2, 4], id: \.self) { v in
                        Button("×\(v.formatted())") { speed = v }.buttonStyle(.bordered).tint(speed == v ? Tokens.Palette.accent : nil)
                    }
                }
                SliderRow(label: "Скорость", value: $speed, range: 0.25...4, step: 0.05, unit: "×", defaultValue: 1, format: "%.2f")
                if let info {
                    Text("Было \(Timecode.string(info.duration)) → станет \(Timecode.string(info.duration / speed))")
                        .font(Tokens.Font.mono).foregroundStyle(Tokens.Palette.textMuted)
                }
            }
            if info?.hasAudio != false {
                Toggle("Сохранить высоту голоса", isOn: $keepPitch)
            } else {
                Text("В видео нет звука — изменится только картинка.").font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textMuted)
            }
        }
        .task { info = try? await MediaEngine(tools: ctx.tools).probe(ctx.file) }
    }

    private func save() {
        let url = ctx.file, tools = ctx.tools, s = speed, pitch = keepPitch, audio = info?.hasAudio ?? true
        ctx.submit("Скорость ×\(s.formatted())") { progress in
            let args = MediaTools.speed(s, keepPitch: pitch, hasAudio: audio, ext: url.pathExtension.lowercased())
            return [try await runMedia(url, suffix: "×\(s.formatted())", tools: tools, args: args) { p in progress(0, p) }]
        }
    }
}

// MARK: SNAPSHOT

struct SnapshotTool: View {
    let ctx: ToolContext
    @State private var model: PlayerModel?
    @State private var times: [Double] = []

    var body: some View {
        ToolChrome(title: "Кадры из видео", canSave: !times.isEmpty, saveTitle: "Сохранить \(times.count) PNG", close: ctx.close, save: save) {
            if let model {
                PreviewBox(height: 300) { PlayerView(player: model.player) }
                HStack {
                    FrameStepper(model: model)
                    Spacer()
                    Button("Добавить этот кадр") { if !times.contains(model.time) { times.append(model.time); times.sort() } }
                        .keyboardShortcut(.return, modifiers: [])
                }
                ToolSection(title: "Выбранные кадры") {
                    if times.isEmpty { Text("Пока ни одного. Найдите кадр и нажмите «Добавить» (Return).").font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textMuted) }
                    ForEach(times, id: \.self) { t in
                        HStack {
                            Button(Timecode.string(t)) { model.seek(t) }.buttonStyle(.link).font(Tokens.Font.mono)
                            Spacer()
                            Button { times.removeAll { $0 == t } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                                .accessibilityLabel("Убрать кадр \(Timecode.string(t))")
                        }
                    }
                }
            } else { ProgressView() }
        }
        .task { model = PlayerModel(url: ctx.file) }
        .onDisappear { model?.player.pause() }
    }

    private func save() {
        let url = ctx.file, tools = ctx.tools, list = times
        ctx.submit("Кадры") { progress in
            if list.count == 1 {
                let snap = MediaTools.snapshot(at: list[0])
                return [try await runMedia(url, ext: "png", suffix: "кадр \(Timecode.string(list[0]).replacingOccurrences(of: ":", with: "."))",
                                           tools: tools, args: snap.args, pre: snap.pre) { _ in }]
            }
            return [try await Staged.folderAsync(beside: url, suffix: "кадры") { folder in
                for (i, t) in list.enumerated() {
                    progress(i, nil)
                    let snap = MediaTools.snapshot(at: t)
                    let out = folder.appendingPathComponent(String(format: "кадр %02d — %@.png", i + 1, Timecode.string(t).replacingOccurrences(of: ":", with: ".")))
                    try await MediaEngine(tools: tools).process(url, output: out, args: snap.args, preInput: snap.pre) { _ in }
                }
            }]
        }
    }
}

// MARK: SPLIT

struct SplitVideoTool: View {
    let ctx: ToolContext
    @State private var model: PlayerModel?
    @State private var equal = false
    @State private var parts: Double = 2
    @State private var cuts: [Double] = []
    @State private var dummyStart: Double = 0
    @State private var dummyEnd: Double = 0

    private var effectiveCuts: [Double] {
        guard let d = model?.duration else { return [] }
        return equal ? MediaTools.equalCuts(duration: d, parts: Int(parts)) : cuts
    }

    var body: some View {
        ToolChrome(title: "Разделить видео", canSave: !effectiveCuts.isEmpty, close: ctx.close, save: save) {
            if let model {
                PreviewBox(height: 280) { PlayerView(player: model.player) }
                FrameStepper(model: model)
                Picker("Как делить", selection: $equal) { Text("По точкам").tag(false); Text("На равные части").tag(true) }
                    .pickerStyle(.segmented).labelsHidden()
                RangeTimeline(duration: model.duration, start: $dummyStart, end: $dummyEnd, playhead: model.time, markers: effectiveCuts) { model.seek($0) }
                    .allowsHitTesting(true)
                if equal {
                    SliderRow(label: "Частей", value: $parts, range: 2...20, step: 1, defaultValue: 2, format: "%.0f")
                } else {
                    HStack {
                        Button("Разрезать здесь") { if !cuts.contains(model.time) { cuts.append(model.time); cuts.sort() } }
                            .keyboardShortcut(.return, modifiers: [])
                        Button("Убрать все точки") { cuts.removeAll() }.disabled(cuts.isEmpty)
                    }
                    ForEach(cuts, id: \.self) { c in
                        HStack {
                            Text(Timecode.string(c)).font(Tokens.Font.mono)
                            Spacer()
                            Button { cuts.removeAll { $0 == c } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                        }
                    }
                }
                Text("Получится частей: \(MediaTools.segments(duration: model.duration, cuts: effectiveCuts).count). Все сохранятся в одну папку.")
                    .font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textMuted)
            } else { ProgressView() }
        }
        .task {
            let m = PlayerModel(url: ctx.file); model = m
            for _ in 0..<50 where m.duration == 0 { try? await Task.sleep(nanoseconds: 50_000_000) }
            dummyEnd = m.duration
        }
        .onDisappear { model?.player.pause() }
    }

    private func save() {
        guard let d = model?.duration else { return }
        let url = ctx.file, tools = ctx.tools, segs = MediaTools.segments(duration: d, cuts: effectiveCuts)
        let ext = url.pathExtension.lowercased()
        ctx.submit("Разделение") { progress in
            [try await Staged.folderAsync(beside: url, suffix: "части") { folder in
                let base = url.deletingPathExtension().lastPathComponent
                for (i, s) in segs.enumerated() {
                    try Task.checkCancellation()
                    let out = folder.appendingPathComponent(String(format: "%@ часть %02d.%@", base, i + 1, ext))
                    try await MediaEngine(tools: tools).process(url, output: out, args: MediaTools.trim(start: s.0, end: s.1, ext: ext, hasVideo: true)) { p in
                        progress(0, p.map { (Double(i) + $0) / Double(segs.count) })
                    }
                }
            }]
        }
    }
}

// MARK: REDACT VIDEO

struct RedactVideoTool: View {
    struct Item: Identifiable { let id = UUID(); var rect: CGRect; var start: Double; var end: Double }
    let ctx: ToolContext
    @State private var model: PlayerModel?
    @State private var frame: CGImage?
    @State private var items: [Item] = []
    @State private var selected: UUID?
    @State private var blur = true

    var body: some View {
        ToolChrome(title: "Скрыть в видео", canSave: !items.isEmpty, close: ctx.close, save: save) {
            if let model {
                PreviewBox(height: 300) {
                    if let frame {
                        Image(decorative: frame, scale: 1).resizable().scaledToFit()
                            .overlay {
                                ForEach($items) { $item in
                                    if model.time >= item.start && model.time <= item.end {
                                        SelectionRect(rect: $item.rect, color: selected == item.id ? Tokens.Palette.accent : .white, dimOutside: false)
                                    }
                                }
                            }
                    } else { ProgressView() }
                }
                HStack {
                    FrameStepper(model: model)
                    Spacer()
                    Button("Добавить область") {
                        let it = Item(rect: CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.25), start: model.time, end: min(model.duration, model.time + 3))
                        items.append(it); selected = it.id
                    }
                }
                Slider(value: Binding(get: { model.time }, set: { model.seek($0) }), in: 0...max(model.duration, 0.01))
                    .tint(Tokens.Palette.accent).accessibilityLabel("Позиция")
                Picker("Как скрыть", selection: $blur) { Text("Размыть").tag(true); Text("Закрасить").tag(false) }
                    .pickerStyle(.segmented).labelsHidden()
                ToolSection(title: "Области") {
                    ForEach($items) { $item in
                        HStack {
                            Button { selected = item.id; model.seek(item.start) } label: { Image(systemName: selected == item.id ? "largecircle.fill.circle" : "circle") }
                                .buttonStyle(.plain)
                            TimecodeField(label: "с", value: $item.start, range: 0...model.duration)
                            TimecodeField(label: "по", value: $item.end, range: 0...model.duration)
                            Spacer()
                            Button { items.removeAll { $0.id == item.id } } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                                .accessibilityLabel("Удалить область")
                        }
                    }
                }
            } else { ProgressView() }
        }
        .task {
            let m = PlayerModel(url: ctx.file); model = m
            for _ in 0..<50 where m.duration == 0 { try? await Task.sleep(nanoseconds: 50_000_000) }
            frame = await m.frame(at: 0, url: ctx.file)
        }
        .onChange(of: model?.time) { _, t in
            guard let t, let m = model else { return }
            Task { frame = await m.frame(at: t, url: ctx.file) ?? frame }
        }
    }

    private func save() {
        guard let size = model?.size else { return }
        let url = ctx.file, tools = ctx.tools
        let list = items.map { MediaTools.VideoRedaction(rect: $0.rect, start: $0.start, end: $0.end, blur: blur) }
        ctx.submit("Скрытие в видео") { progress in
            let args = MediaTools.redact(list, width: Int(size.width), height: Int(size.height), ext: url.pathExtension.lowercased())
            return [try await runMedia(url, suffix: "скрыто", tools: tools, args: args) { p in progress(0, p) }]
        }
    }
}

// MARK: JOIN

struct JoinVideosTool: View {
    let ctx: ToolContext
    @State private var order: [URL] = []
    @State private var infos: [URL: MediaEngine.Info] = [:]

    var body: some View {
        ToolChrome(title: "Склеить видео", canSave: order.count >= 2 && infos.count == order.count, close: ctx.close, save: save) {
            Text("Перетащите клипы в нужном порядке. Размер и частота кадров берутся у первого клипа, результат — MP4.")
                .font(Tokens.Font.body).foregroundStyle(Tokens.Palette.textMuted)
            List {
                ForEach(order, id: \.self) { url in
                    HStack {
                        Image(systemName: "line.3.horizontal").foregroundStyle(Tokens.Palette.textMuted)
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if let i = infos[url] {
                            Text("\(i.width ?? 0)×\(i.height ?? 0) · \(Timecode.string(i.duration))").font(Tokens.Font.mono).foregroundStyle(Tokens.Palette.textMuted)
                        } else { ProgressView().controlSize(.small) }
                    }
                }
                .onMove { order.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(height: min(CGFloat(order.count) * 32 + 16, 320))
        }
        .task {
            order = ctx.files
            for f in ctx.files { infos[f] = try? await MediaEngine(tools: ctx.tools).probe(f) }
        }
    }

    private func save() {
        let list = order, tools = ctx.tools
        let info = list.compactMap { infos[$0] }
        guard let first = info.first else { return }
        let total = info.reduce(0) { $0 + $1.duration }
        ctx.submit("Склейка") { progress in
            let args = MediaTools.join(count: list.count, width: first.width ?? 1280, height: first.height ?? 720, fps: first.fps ?? 30,
                                       hasAudio: info.map(\.hasAudio), durations: info.map(\.duration))
            let pre = list.flatMap { ["-i", $0.path] }
            return [try await Staged.fileAsync(beside: OutputNamer.sibling(of: list[0], ext: "mp4", suffix: "склейка")) { out in
                try await MediaEngine(tools: tools).run(pre + args + [out.path], duration: total) { p in progress(0, p) }
            }]
        }
    }
}

// MARK: NORMALIZE

struct NormalizeTool: View {
    let ctx: ToolContext
    @State private var lufs: Double = -16
    @State private var lra: Double = 11
    @State private var tp: Double = -1.5
    @State private var measured: String?

    var body: some View {
        ToolChrome(title: "Выровнять громкость", close: ctx.close, save: save) {
            ToolSection(title: "Цель") {
                HStack {
                    Button("Подкаст −16") { lufs = -16 }; Button("Стриминг −14") { lufs = -14 }; Button("ТВ −23") { lufs = -23 }
                }.buttonStyle(.bordered)
                SliderRow(label: "Громкость", value: $lufs, range: -30...(-8), step: 0.5, unit: "LUFS", defaultValue: -16, format: "%.1f")
                SliderRow(label: "Диапазон", value: $lra, range: 1...20, step: 0.5, unit: "LU", defaultValue: 11, format: "%.1f")
                SliderRow(label: "Пик", value: $tp, range: -6...0, step: 0.1, unit: "dBTP", defaultValue: -1.5, format: "%.1f")
            }
            ToolSection(title: "Сейчас") {
                Text(measured ?? "Измеряю…").font(Tokens.Font.mono).foregroundStyle(Tokens.Palette.textMuted)
                Text("Новая громкость: \(String(format: "%.1f", lufs)) LUFS, пик не выше \(String(format: "%.1f", tp)) dBTP")
                    .font(Tokens.Font.mono).foregroundStyle(Tokens.Palette.text)
            }
        }
        .task { measured = await measure() }
    }

    private func measure() async -> String {
        guard let ffmpeg = ctx.tools.ffmpeg else { return "Нет ffmpeg" }
        // loudnorm в режиме анализа пишет JSON в stderr; перенаправляем через sh в stdout.
        let out = try? await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "\"$0\" -hide_banner -nostdin -i \"$1\" -af loudnorm=print_format=json -f null - 2>&1 | tail -n 14", ffmpeg.path, ctx.file.path])
        guard let out, let i = out.firstMatch(of: /"input_i"\s*:\s*"([-\d.]+)"/)?.1, let p = out.firstMatch(of: /"input_tp"\s*:\s*"([-\d.]+)"/)?.1,
              let r = out.firstMatch(of: /"input_lra"\s*:\s*"([-\d.]+)"/)?.1 else { return "Не удалось измерить" }
        return "Громкость \(i) LUFS · диапазон \(r) LU · пик \(p) dBTP"
    }

    private func save() {
        let url = ctx.file, tools = ctx.tools, a = lufs, b = lra, c = tp
        ctx.submit("Нормализация") { progress in
            let ext = url.pathExtension.lowercased()
            return [try await runMedia(url, ext: ext, suffix: "выровнен", tools: tools, args: MediaTools.normalize(lufs: a, lra: b, truePeak: c, ext: ext)) { p in progress(0, p) }]
        }
    }
}

// MARK: VISUALIZE

struct VisualizerTool: View {
    let ctx: ToolContext
    @State private var style: MediaTools.VisualizerStyle = .wave
    @State private var shape: MediaTools.VisualizerShape = .square
    @State private var color = Color.white
    @State private var image: URL?

    var body: some View {
        ToolChrome(title: "Видео из аудио", canSave: style != .still || image != nil, close: ctx.close, save: save) {
            ToolSection(title: "Картинка") {
                Picker("Стиль", selection: $style) {
                    Text("Волна").tag(MediaTools.VisualizerStyle.wave); Text("Столбики").tag(MediaTools.VisualizerStyle.bars); Text("Только фон").tag(MediaTools.VisualizerStyle.still)
                }.pickerStyle(.segmented).labelsHidden()
                Picker("Формат", selection: $shape) {
                    Text("16:9").tag(MediaTools.VisualizerShape.landscape); Text("9:16").tag(MediaTools.VisualizerShape.portrait); Text("1:1").tag(MediaTools.VisualizerShape.square)
                }.pickerStyle(.segmented).labelsHidden()
                if style != .still { ColorPicker("Цвет волны", selection: $color) }
                HStack {
                    Button(image == nil ? "Выбрать фон…" : "Сменить фон…") {
                        let p = NSOpenPanel(); p.allowedContentTypes = [.image]
                        if p.runModal() == .OK { image = p.url }
                    }
                    if let image { Text(image.lastPathComponent).lineLimit(1).foregroundStyle(Tokens.Palette.textMuted)
                        Button("Убрать") { self.image = nil }.buttonStyle(.link) }
                }
                if style == .still && image == nil {
                    Text("Для «только фон» выберите изображение.").font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.warning)
                }
            }
        }
    }

    private func save() {
        let url = ctx.file, tools = ctx.tools
        let n = NSColor(color).usingColorSpace(.sRGB) ?? .white
        let hex = String(format: "0x%02X%02X%02X", Int(n.redComponent * 255), Int(n.greenComponent * 255), Int(n.blueComponent * 255))
        let v = MediaTools.visualizer(style: style, shape: shape, color: hex, image: image)
        ctx.submit("Видео из аудио") { progress in
            // Дополнительный вход (картинка) идёт после основного: собираем аргументы вручную.
            let info = try await MediaEngine(tools: tools).probe(url)
            return [try await Staged.fileAsync(beside: OutputNamer.sibling(of: url, ext: "mp4", suffix: "видео")) { out in
                try await MediaEngine(tools: tools).run(["-i", url.path] + v.extraInputs + v.args + [out.path], duration: info.duration) { p in progress(0, p) }
            }]
        }
    }
}

// MARK: CHANNELS

struct ChannelsTool: View {
    let ctx: ToolContext
    @State private var mono = false
    @State private var left: Double = 1
    @State private var right: Double = 1
    @State private var previewPlayer: AVAudioPlayer?
    @State private var busy = false
    @State private var previewError: String?

    var body: some View {
        ToolChrome(title: "Каналы", close: ctx.close, save: save) {
            Picker("Режим", selection: $mono) { Text("Стерео").tag(false); Text("Моно").tag(true) }.pickerStyle(.segmented).labelsHidden()
            ToolSection(title: "Громкость каналов") {
                SliderRow(label: "Левый", value: $left, range: 0...2, step: 0.05, unit: "×", defaultValue: 1, format: "%.2f")
                SliderRow(label: "Правый", value: $right, range: 0...2, step: 0.05, unit: "×", defaultValue: 1, format: "%.2f")
            }
            ToolSection(title: "Прослушать 10 секунд") {
                HStack {
                    Button("Только левый") { preview(l: 1, r: 0) }
                    Button("Только правый") { preview(l: 0, r: 1) }
                    Button("Результат") { preview(l: left, r: right, asMono: mono) }
                    Button("Стоп") { previewPlayer?.stop() }
                    if busy { ProgressView().controlSize(.small) }
                }.disabled(busy)
                if let previewError { Text(previewError).font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.danger) }
            }
        }
        .onDisappear { previewPlayer?.stop() }
    }

    private func preview(l: Double, r: Double, asMono: Bool = false) {
        busy = true
        let url = ctx.file, tools = ctx.tools
        previewError = nil
        Task {
            defer { busy = false }
            do {
                let dir = try Scratch.dir()
                let out = dir.appendingPathComponent("preview.m4a")
                let args = ["-t", "10"] + MediaTools.channels(mono: asMono, left: l, right: r, ext: "m4a")
                try await MediaEngine(tools: tools).process(url, output: out, args: args) { _ in }
                previewPlayer = try AVAudioPlayer(contentsOf: out)
                previewPlayer?.play()
            } catch {
                previewError = "Не удалось подготовить прослушивание: \(error.localizedDescription)"
            }
        }
    }

    private func save() {
        let url = ctx.file, tools = ctx.tools, m = mono, l = left, r = right
        ctx.submit(m ? "В моно" : "Каналы") { progress in
            let ext = url.pathExtension.lowercased()
            return [try await runMedia(url, suffix: m ? "моно" : "каналы", tools: tools, args: MediaTools.channels(mono: m, left: l, right: r, ext: ext)) { p in progress(0, p) }]
        }
    }
}

// MARK: BLEEP

struct BleepTool: View {
    struct Range: Identifiable { let id = UUID(); var start: Double; var end: Double }
    let ctx: ToolContext
    @State private var model: PlayerModel?
    @State private var wave: [Float] = []
    @State private var ranges: [Range] = []
    @State private var selected: UUID?
    @State private var bleeped: AVAudioPlayer?
    @State private var busy = false
    @State private var previewError: String?

    private var selectedIndex: Int? { ranges.firstIndex { $0.id == selected } }

    var body: some View {
        ToolChrome(title: "Запикать", canSave: !ranges.isEmpty, close: ctx.close, save: save) {
            if let model {
                FrameStepper(model: model)
                if let i = selectedIndex {
                    RangeTimeline(duration: model.duration, start: $ranges[i].start, end: $ranges[i].end, playhead: model.time,
                                  regions: ranges.map { ($0.start, $0.end) }, waveform: wave) { model.seek($0) }
                } else {
                    RangeTimeline(duration: model.duration, start: .constant(0), end: .constant(0), playhead: model.time,
                                  regions: ranges.map { ($0.start, $0.end) }, waveform: wave) { model.seek($0) }
                }
                HStack {
                    Button("Запикать с этого места") {
                        let r = Range(start: model.time, end: min(model.duration, model.time + 1)); ranges.append(r); selected = r.id
                    }.keyboardShortcut(.return, modifiers: [])
                    Spacer()
                    Button("Оригинал") { bleeped?.stop(); model.player.play() }
                    Button("С пиканьем") { previewBleeped() }.disabled(ranges.isEmpty || busy)
                }
                if let previewError { Text(previewError).font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.danger) }
                ToolSection(title: "Фрагменты") {
                    ForEach($ranges) { $r in
                        HStack {
                            Button { selected = r.id; model.seek(r.start) } label: { Image(systemName: selected == r.id ? "largecircle.fill.circle" : "circle") }
                                .buttonStyle(.plain).accessibilityLabel("Выбрать фрагмент")
                            TimecodeField(label: "с", value: $r.start, range: 0...model.duration)
                            TimecodeField(label: "по", value: $r.end, range: 0...model.duration)
                            Spacer()
                            Button { ranges.removeAll { $0.id == r.id } } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                                .accessibilityLabel("Удалить фрагмент")
                        }
                    }
                }
            } else { ProgressView() }
        }
        .task {
            model = PlayerModel(url: ctx.file)
            wave = await loadWaveform(ctx.file, tools: ctx.tools)
        }
        .onDisappear { model?.player.pause(); bleeped?.stop() }
    }

    private func previewBleeped() {
        guard let d = model?.duration else { return }
        busy = true
        model?.player.pause()
        let url = ctx.file, tools = ctx.tools, list = ranges.map { ($0.start, $0.end) }
        previewError = nil
        Task {
            defer { busy = false }
            do {
                let dir = try Scratch.dir()
                let out = dir.appendingPathComponent("bleep.m4a")
                try await MediaEngine(tools: tools).process(url, output: out, args: MediaTools.bleep(list, duration: d, ext: "m4a")) { _ in }
                bleeped = try AVAudioPlayer(contentsOf: out)
                bleeped?.currentTime = max(0, (list.first?.0 ?? 0) - 1)
                bleeped?.play()
            } catch {
                previewError = "Не удалось подготовить прослушивание: \(error.localizedDescription)"
            }
        }
    }

    private func save() {
        guard let d = model?.duration else { return }
        let url = ctx.file, tools = ctx.tools, list = ranges.map { ($0.start, $0.end) }
        ctx.submit("Пиканье") { progress in
            [try await runMedia(url, suffix: "запикано", tools: tools, args: MediaTools.bleep(list, duration: d, ext: url.pathExtension.lowercased())) { p in progress(0, p) }]
        }
    }
}
