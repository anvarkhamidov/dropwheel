import DropwheelCore
import SwiftUI

// MARK: COMPRESS

struct CompressTool: View {
    let ctx: ToolContext
    enum Mode: String, CaseIterable, Identifiable { case preset, percent, size; var id: String { rawValue } }
    @State private var mode: Mode = .preset
    @State private var preset: CompressEngine.Preset = .balanced
    @State private var percent: Double = 50
    @State private var targetMB: Double = 1
    @State private var resize = false
    @State private var maxSide: Double = 2048

    private var category: FileCategory { FileCategory.of(ctx.file) }
    private var totalSize: Int64 { ctx.files.reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int64) ?? 0) } }

    var body: some View {
        ToolChrome(title: "Сжатие", close: ctx.close, save: save) {
            ToolSection(title: ctx.files.count == 1 ? ctx.file.lastPathComponent : "\(ctx.files.count) файлов") {
                Text("Сейчас: \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)). Оригинал не изменится.")
                    .font(Tokens.Font.body).foregroundStyle(Tokens.Palette.textMuted)
            }
            ToolSection(title: "Цель") {
                Picker("Цель", selection: $mode) {
                    Text("Пресет").tag(Mode.preset)
                    Text("На сколько %").tag(Mode.percent)
                    Text("Размер файла").tag(Mode.size)
                }
                .pickerStyle(.segmented).labelsHidden()
                switch mode {
                case .preset:
                    Picker("Пресет", selection: $preset) {
                        ForEach(CompressEngine.Preset.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                case .percent:
                    SliderRow(label: "Уменьшить на", value: $percent, range: 10...90, step: 5, unit: "%", defaultValue: 50, format: "%.0f")
                case .size:
                    HStack {
                        Text("Не больше").font(Tokens.Font.body)
                        TextField("МБ", value: $targetMB, format: .number.precision(.fractionLength(0...2))).frame(width: 80)
                        Text(ctx.files.count > 1 ? "МБ на файл" : "МБ").font(Tokens.Font.body).foregroundStyle(Tokens.Palette.textMuted)
                    }
                }
            }
            if category == .image || category == .video {
                ToolSection(title: "Размер") {
                    Toggle(category == .image ? "Уменьшить изображение" : "Уменьшить кадр", isOn: $resize)
                    if resize {
                        SliderRow(label: category == .image ? "Длинная сторона" : "Высота кадра", value: $maxSide,
                                  range: category == .image ? 320...6000 : 240...2160, step: category == .image ? 16 : 120,
                                  unit: "px", defaultValue: category == .image ? 2048 : 1080, format: "%.0f")
                    }
                }
            }
            if category == .image {
                Text("PNG, TIFF и BMP сохраняются как JPEG, а с прозрачностью — как HEIC.").font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textMuted)
            }
            if category == .audio {
                Text("WAV, FLAC и AIFF сжимаются в M4A.").font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textMuted)
            }
        }
        .onAppear { if category == .video { maxSide = 1080 } }
    }

    private func save() {
        let goal: CompressEngine.Goal
        switch mode {
        case .preset: goal = .preset(preset)
        case .percent: goal = .percent(percent / 100)
        case .size: goal = .targetBytes(Int64(targetMB * 1_000_000))
        }
        let side = resize ? Int(maxSide) : nil
        let tools = ctx.tools, files = ctx.files
        ctx.submit("Сжатие") { progress in
            var out: [URL] = []
            for (i, f) in files.enumerated() {
                try Task.checkCancellation()
                out.append(try await CompressEngine(tools: tools).compress(f, goal: goal, maxSide: side) { p in progress(i, p) })
            }
            return out
        }
    }
}

// MARK: METADATA

struct MetadataTool: View {
    let ctx: ToolContext
    @State private var fields: [MetadataEngine.Field] = []
    @State private var edits: [String: String] = [:]
    @State private var search = ""
    @State private var loading = true
    @State private var error: String?

    private var groups: [(String, [MetadataEngine.Field])] {
        let filtered = search.isEmpty ? fields : fields.filter {
            $0.key.localizedCaseInsensitiveContains(search) || $0.value.localizedCaseInsensitiveContains(search) || $0.group.localizedCaseInsensitiveContains(search)
        }
        var order: [String] = []
        var map: [String: [MetadataEngine.Field]] = [:]
        for f in filtered { if map[f.group] == nil { order.append(f.group) }; map[f.group, default: []].append(f) }
        return order.map { ($0, map[$0]!) }
    }

    private var category: FileCategory { FileCategory.of(ctx.file) }
    private var supportsWrite: Bool { [.image, .video, .audio, .pdf].contains(category) }

    var body: some View {
        ToolChrome(title: "Метаданные", canSave: supportsWrite && !edits.isEmpty, saveTitle: "Сохранить копию", close: ctx.close, save: save) {
            HStack {
                TextField("Поиск по полям", text: $search).textFieldStyle(.roundedBorder)
                if supportsWrite {
                    Button("Удалить всё", role: .destructive, action: stripAll)
                        .help("Создать копию без камеры, места, автора и других скрытых данных")
                }
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            if let error { Text(error).foregroundStyle(Tokens.Palette.danger).font(Tokens.Font.body) }
            if !loading && fields.isEmpty && error == nil {
                Text("Метаданных нет").foregroundStyle(Tokens.Palette.textMuted)
            }
            ForEach(groups, id: \.0) { group, items in
                ToolSection(title: group) {
                    ForEach(items) { field in
                        HStack(alignment: .firstTextBaseline) {
                            Text(field.key).font(Tokens.Font.body).foregroundStyle(Tokens.Palette.textMuted).frame(width: 150, alignment: .leading)
                            if field.editable && supportsWrite {
                                TextField(field.key, text: Binding(
                                    get: { edits[field.key] ?? field.value },
                                    set: { edits[field.key] = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                            } else {
                                Text(field.value.isEmpty ? "—" : field.value).font(Tokens.Font.body).foregroundStyle(Tokens.Palette.text)
                                    .textSelection(.enabled).lineLimit(3)
                            }
                        }
                    }
                }
            }
        }
        .task {
            do { fields = try await MetadataEngine(tools: ctx.tools).read(ctx.file) } catch { self.error = error.localizedDescription }
            loading = false
        }
    }

    private func save() { write(strip: false) }
    private func stripAll() { write(strip: true) }

    private func write(strip: Bool) {
        let url = ctx.file, tools = ctx.tools, changes = edits, category = self.category
        ctx.submit(strip ? "Удаление метаданных" : "Правка метаданных") { progress in
            let engine = MetadataEngine(tools: tools)
            switch category {
            case .image: return [try engine.writeImage(url, changes: changes, stripAll: strip)]
            case .pdf: return [try engine.writePDF(url, changes: changes, stripAll: strip)]
            default: return [try await engine.writeMedia(url, changes: changes, stripAll: strip) { p in progress(0, p) }]
            }
        }
    }
}
