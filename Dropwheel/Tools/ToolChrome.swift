import AVKit
import DropwheelCore
import SwiftUI

/// Всё, что окну инструмента нужно от приложения.
@MainActor
final class ToolContext {
    let tool: ToolDef
    let files: [URL]
    let jobs: JobCenter
    let tools: ExternalTools
    var close: () -> Void = {}

    init(tool: ToolDef, files: [URL], jobs: JobCenter, tools: ExternalTools) {
        self.tool = tool; self.files = files; self.jobs = jobs; self.tools = tools
    }

    var file: URL { files[0] }

    /// Запустить сохранение как задачу и закрыть окно.
    func submit(_ title: String, _ work: @escaping @Sendable (_ progress: @escaping @Sendable (Int, Double?) -> Void) async throws -> [URL]) {
        jobs.run(title, files: files, work)
        close()
    }
}

/// Каркас окна: круглая ✕ слева, заголовок по центру, «Сохранить» справа. ⌘S — сохранить, Esc — закрыть.
struct ToolChrome<Content: View>: View {
    let title: String
    var canSave = true
    var saveTitle = "Сохранить"
    let close: () -> Void
    let save: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title).font(Tokens.Font.title).foregroundStyle(Tokens.Palette.text)
                HStack {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(Tokens.Palette.surfaceSunken, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.Palette.textMuted)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Закрыть")
                    Spacer()
                    Button(saveTitle, action: save)
                        .buttonStyle(.borderedProminent)
                        .tint(Tokens.Palette.accent)
                        .disabled(!canSave)
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
            .padding(.horizontal, Tokens.Space.s4)
            .padding(.vertical, Tokens.Space.s3)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s4) { content }
                    .padding(Tokens.Space.s4)
            }
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 420)
        .background(Tokens.Palette.bg)
    }
}

struct ToolSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Text(title).font(Tokens.Font.section).foregroundStyle(Tokens.Palette.accent)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// Строка «подпись | слайдер | значение | сброс».
struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var unit: String = ""
    var defaultValue: Double = 0
    var format: String = "%+.0f"

    var body: some View {
        HStack(spacing: Tokens.Space.s2) {
            Text(label).font(Tokens.Font.body).foregroundStyle(Tokens.Palette.text).frame(width: 120, alignment: .leading)
            if let step { Slider(value: $value, in: range, step: step).tint(Tokens.Palette.accent) }
            else { Slider(value: $value, in: range).tint(Tokens.Palette.accent) }
            Text(String(format: format, value) + (unit.isEmpty ? "" : " " + unit))
                .font(Tokens.Font.mono).foregroundStyle(Tokens.Palette.textMuted).frame(width: 72, alignment: .trailing)
            Button { value = defaultValue } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.Palette.textMuted)
                .opacity(value == defaultValue ? 0 : 1)
                .disabled(value == defaultValue)
                .accessibilityLabel("Сбросить \(label)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(String(format: format, value) + " " + unit)
    }
}

/// Подложка превью: тёмная, со скруглением.
struct PreviewBox<Content: View>: View {
    var height: CGFloat = 300
    @ViewBuilder let content: Content
    var body: some View {
        ZStack { content }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Tokens.Palette.previewBg, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
    }
}

/// Плеер AVKit для видео и аудио в окнах инструментов.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .inline
        v.showsFrameSteppingButtons = true
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { v.player = player }
}

/// Таймлайн с ручками начала и конца, маркерами и регионами. Значения в секундах.
struct RangeTimeline: View {
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    var playhead: Double = 0
    var markers: [Double] = []
    var regions: [(Double, Double)] = []
    var waveform: [Float] = []
    var onSeek: (Double) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x: (Double) -> CGFloat = { duration > 0 ? CGFloat($0 / duration) * w : 0 }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Tokens.Radius.sm).fill(Tokens.Palette.surfaceSunken)
                if !waveform.isEmpty {
                    Path { p in
                        let mid = geo.size.height / 2
                        for (i, v) in waveform.enumerated() {
                            let px = CGFloat(i) / CGFloat(waveform.count) * w
                            p.move(to: CGPoint(x: px, y: mid - CGFloat(v) * mid * 0.9))
                            p.addLine(to: CGPoint(x: px, y: mid + CGFloat(v) * mid * 0.9))
                        }
                    }.stroke(Tokens.Palette.textMuted.opacity(0.6), lineWidth: 1)
                }
                ForEach(Array(regions.enumerated()), id: \.offset) { _, r in
                    Rectangle().fill(Tokens.Palette.accent.opacity(0.3)).frame(width: max(2, x(r.1) - x(r.0))).offset(x: x(r.0))
                }
                Rectangle().fill(Tokens.Palette.accent.opacity(0.15)).frame(width: max(0, x(end) - x(start))).offset(x: x(start))
                ForEach(markers, id: \.self) { m in
                    Rectangle().fill(Tokens.Palette.warning).frame(width: 2).offset(x: x(m) - 1)
                }
                Rectangle().fill(Tokens.Palette.text).frame(width: 1).offset(x: x(playhead))
                handle.offset(x: x(start) - 4)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        start = min(max(0, Double(g.location.x / w) * duration), end - 0.05); onSeek(start)
                    })
                    .accessibilityLabel("Начало").accessibilityValue(Timecode.string(start))
                handle.offset(x: x(end) - 4)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        end = max(min(duration, Double(g.location.x / w) * duration), start + 0.05); onSeek(end)
                    })
                    .accessibilityLabel("Конец").accessibilityValue(Timecode.string(end))
            }
            .contentShape(Rectangle())
            .onTapGesture { loc in onSeek(Double(loc.x / w) * duration) }
        }
        .frame(height: 48)
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3).fill(Tokens.Palette.accent).frame(width: 8, height: 48)
    }
}

enum Timecode {
    static func string(_ t: Double) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
    static func parse(_ s: String) -> Double? {
        let parts = s.replacingOccurrences(of: ",", with: ".").split(separator: ":").map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for p in parts { guard let v = Double(p) else { return nil }; total = total * 60 + v }
        return total
    }
}

/// Поле времени, которое принимает ввод «мм:сс.ммм».
struct TimecodeField: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    @State private var text = ""

    var body: some View {
        HStack(spacing: Tokens.Space.s2) {
            Text(label).font(Tokens.Font.body).foregroundStyle(Tokens.Palette.textMuted).fixedSize()
            TextField(label, text: $text)
                .font(Tokens.Font.mono)
                .frame(width: 104)
                .onSubmit { if let v = Timecode.parse(text) { value = min(max(v, range.lowerBound), range.upperBound) }; text = Timecode.string(value) }
        }
        .onAppear { text = Timecode.string(value) }
        .onChange(of: value) { _, v in text = Timecode.string(v) }
    }
}

/// Прямоугольник выделения поверх превью: перетаскивается и тянется за углы. Координаты нормализованы 0…1.
struct SelectionRect: View {
    @Binding var rect: CGRect
    var aspect: CGFloat? = nil   // ширина/высота в пикселях исходника
    var imageAspect: CGFloat = 1
    var color: Color = Tokens.Palette.accent
    var dimOutside = true
    @State private var start: CGRect?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let r = CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
            ZStack(alignment: .topLeading) {
                if dimOutside {
                    Path { p in p.addRect(CGRect(origin: .zero, size: size)); p.addRect(r) }
                        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                }
                Rectangle().strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                    .contentShape(Rectangle())
                    .gesture(DragGesture().onChanged { g in
                        let s = start ?? rect; start = s
                        var n = s.offsetBy(dx: g.translation.width / size.width, dy: g.translation.height / size.height)
                        n.origin.x = min(max(0, n.minX), 1 - n.width); n.origin.y = min(max(0, n.minY), 1 - n.height)
                        rect = n
                    }.onEnded { _ in start = nil })
                ForEach(0..<4, id: \.self) { corner in
                    let cx = corner % 2 == 0 ? r.minX : r.maxX, cy = corner < 2 ? r.minY : r.maxY
                    Circle().fill(Color.white).overlay(Circle().stroke(Tokens.Palette.borderInput))
                        .frame(width: 10, height: 10).offset(x: cx - 5, y: cy - 5)
                        .gesture(DragGesture().onChanged { g in
                            let s = start ?? rect; start = s
                            var x0 = s.minX, y0 = s.minY, x1 = s.maxX, y1 = s.maxY
                            let px = min(max(0, (corner % 2 == 0 ? s.minX : s.maxX) + g.translation.width / size.width), 1)
                            let py = min(max(0, (corner < 2 ? s.minY : s.maxY) + g.translation.height / size.height), 1)
                            if corner % 2 == 0 { x0 = min(px, x1 - 0.02) } else { x1 = max(px, x0 + 0.02) }
                            if corner < 2 { y0 = min(py, y1 - 0.02) } else { y1 = max(py, y0 + 0.02) }
                            var n = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
                            if let aspect, aspect > 0 {
                                // Пропорция в нормализованных единицах учитывает форму картинки.
                                let h = n.width * imageAspect / aspect
                                if corner < 2 { n.origin.y = n.maxY - h }
                                n.size.height = h
                                if n.minY < 0 || n.maxY > 1 { return }
                            }
                            rect = n
                        }.onEnded { _ in start = nil })
                }
            }
        }
    }
}

/// Загрузка превью картинки (уменьшенной для скорости).
func previewImage(_ url: URL, maxPixel: Int = 1600) -> CGImage? {
    try? ImageEngine.loadCGImage(url, maxPixel: maxPixel)
}

/// Волновая форма для аудио: пиковые значения по ffmpeg (моно, 200 точек).
func loadWaveform(_ url: URL, tools: ExternalTools, points: Int = 300) async -> [Float] {
    guard let ffmpeg = tools.ffmpeg, let info = try? await MediaEngine(tools: tools).probe(url), info.duration > 0 else { return [] }
    let rate = max(50, Int(Double(points) / info.duration * 40))
    // PCM пишем во временный файл: вывод процесса собирается как текст и испортил бы байты.
    guard let dir = try? Scratch.dir() else { return [] }
    defer { try? FileManager.default.removeItem(at: dir) }
    let raw = dir.appendingPathComponent("w.raw")
    guard (try? await ProcessRunner.run(ffmpeg, ["-v", "error", "-y", "-i", url.path, "-ac", "1", "-ar", "\(rate)", "-f", "s16le", raw.path])) != nil,
          let bytes = try? Data(contentsOf: raw) else { return [] }
    let samples = bytes.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    guard !samples.isEmpty else { return [] }
    let per = max(1, samples.count / points)
    return stride(from: 0, to: samples.count, by: per).map { i in
        let chunk = samples[i..<min(i + per, samples.count)]
        return Float(chunk.map { abs(Int($0)) }.max() ?? 0) / Float(Int16.max)
    }
}
