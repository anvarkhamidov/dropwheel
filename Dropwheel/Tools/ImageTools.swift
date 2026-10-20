import CoreImage
import DropwheelCore
import SwiftUI

/// Сохранить обработанную картинку рядом с оригиналом в том же формате (SVG/GIF → PNG).
func saveImage(_ image: CGImage, beside url: URL, suffix: String, tools: ExternalTools) async throws -> URL {
    var ext = FileCategory.canonical(ext: url.pathExtension)
    if ["svg", "gif"].contains(ext) { ext = "png" }
    if ext == "webp", tools.cwebp == nil { ext = "png" }
    let dest = OutputNamer.sibling(of: url, ext: ext, suffix: suffix)
    let scratch = try Scratch.dir()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let temp = scratch.appendingPathComponent("out").appendingPathExtension(ext)
    try await ImageEngine(tools: tools).write(image, to: temp, ext: ext, quality: 0.92, metadata: nil)
    return try Scratch.commit(temp, to: dest)
}

/// Отношение сторон картинки (ширина/высота).
func aspect(of image: CGImage?) -> CGFloat {
    guard let image, image.height > 0 else { return 1 }
    return CGFloat(image.width) / CGFloat(image.height)
}

// MARK: EDIT

struct EditPhotoTool: View {
    let ctx: ToolContext
    @State private var a = ImageOps.Adjustments()
    @State private var preview: CGImage?
    @State private var source: CIImage?
    @State private var showOriginal = false
    @State private var generation = 0

    var body: some View {
        ToolChrome(title: "Правка фото", canSave: !a.isIdentity, close: ctx.close, save: save) {
            PreviewBox(height: 320) {
                if let preview { Image(decorative: preview, scale: 1).resizable().scaledToFit() }
                else { ProgressView() }
            }
            .overlay(alignment: .topTrailing) {
                Button(showOriginal ? "Результат" : "Оригинал") { showOriginal.toggle(); render() }
                    .buttonStyle(.bordered).controlSize(.small).padding(Tokens.Space.s2)
                    .disabled(a.isIdentity)
            }
            ToolSection(title: "Свет") {
                SliderRow(label: "Экспозиция", value: $a.exposure, range: -3...3, unit: "EV", format: "%+.2f")
                SliderRow(label: "Яркость", value: $a.brightness, range: -100...100)
                SliderRow(label: "Контраст", value: $a.contrast, range: -100...100)
                SliderRow(label: "Светлые", value: $a.highlights, range: -100...100)
                SliderRow(label: "Тени", value: $a.shadows, range: -100...100)
            }
            ToolSection(title: "Цвет") {
                SliderRow(label: "Насыщенность", value: $a.saturation, range: -100...100)
                SliderRow(label: "Сочность", value: $a.vibrance, range: -100...100)
                SliderRow(label: "Температура", value: $a.temperature, range: -100...100)
                SliderRow(label: "Оттенок", value: $a.tint, range: -100...100)
            }
            ToolSection(title: "Детали") {
                SliderRow(label: "Резкость", value: $a.sharpness, range: 0...100, format: "%.0f")
                SliderRow(label: "Чёткость", value: $a.clarity, range: 0...100, format: "%.0f")
                SliderRow(label: "Убрать дымку", value: $a.dehaze, range: 0...100, format: "%.0f")
                SliderRow(label: "Шумоподавление", value: $a.noiseReduction, range: 0...100, format: "%.0f")
            }
            ToolSection(title: "Эффекты") {
                SliderRow(label: "Зерно", value: $a.grain, range: 0...100, format: "%.0f")
                SliderRow(label: "Виньетка", value: $a.vignette, range: 0...100, format: "%.0f")
            }
        }
        .task {
            let url = ctx.file
            if let cg = await Task.detached(operation: { previewImage(url, maxPixel: 1400) }).value { source = CIImage(cgImage: cg); render() }
        }
        .onChange(of: a) { render() }
    }

    /// Рендер вне главного потока; если слайдер успел сдвинуться ещё раз, устаревший кадр отбрасывается.
    private func render() {
        guard let source else { return }
        generation += 1
        let gen = generation, adj = a, original = showOriginal
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                ImageOps.render(original ? source : ImageOps.adjust(source, adj))
            }.value
            if gen == generation { preview = image }
        }
    }

    private func save() {
        let url = ctx.file, tools = ctx.tools, adj = a
        ctx.submit("Правка фото") { _ in
            let full = CIImage(cgImage: try ImageEngine.loadCGImage(url))
            guard let out = ImageOps.render(ImageOps.adjust(full, adj)) else { throw DropwheelError("Не удалось обработать фото") }
            return [try await saveImage(out, beside: url, suffix: "изменён", tools: tools)]
        }
    }
}

// MARK: CROP

struct CropImageTool: View {
    let ctx: ToolContext
    enum Ratio: String, CaseIterable, Identifiable {
        case free = "Свободно", original = "Как у фото", square = "1:1", r43 = "4:3", r32 = "3:2", r169 = "16:9", r916 = "9:16", r45 = "4:5"
        var id: String { rawValue }
        func value(original: CGFloat) -> CGFloat? {
            switch self {
            case .free: return nil
            case .original: return original
            case .square: return 1
            case .r43: return 4.0 / 3
            case .r32: return 3.0 / 2
            case .r169: return 16.0 / 9
            case .r916: return 9.0 / 16
            case .r45: return 4.0 / 5
            }
        }
    }
    @State private var preview: CGImage?
    @State private var rect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    @State private var ratio: Ratio = .free
    @State private var exact = false
    @State private var outW: Double = 1080
    @State private var outH: Double = 1080

    private var pixelSize: CGSize { ImageEngine.pixelSize(ctx.file) ?? CGSize(width: 1, height: 1) }

    var body: some View {
        ToolChrome(title: ctx.files.count > 1 ? "Кроп \(ctx.files.count) фото" : "Кроп", close: ctx.close, save: save) {
            PreviewBox(height: 340) {
                if let preview {
                    Image(decorative: preview, scale: 1).resizable().scaledToFit()
                        .overlay(SelectionRect(rect: $rect, aspect: ratio.value(original: aspect(of: preview)), imageAspect: aspect(of: preview)))
                } else { ProgressView() }
            }
            ToolSection(title: "Пропорции") {
                Picker("Пропорции", selection: $ratio) { ForEach(Ratio.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden()
                    .onChange(of: ratio) { _, r in applyRatio(r) }
                let w = Int(rect.width * pixelSize.width), h = Int(rect.height * pixelSize.height)
                Text("Область: \(w) × \(h) px").font(Tokens.Font.mono).foregroundStyle(Tokens.Palette.textMuted)
            }
            ToolSection(title: "Размер результата") {
                Toggle("Точные размеры в пикселях", isOn: $exact)
                if exact {
                    HStack {
                        TextField("Ширина", value: $outW, format: .number).frame(width: 90)
                        Text("×")
                        TextField("Высота", value: $outH, format: .number).frame(width: 90)
                        Text("px").foregroundStyle(Tokens.Palette.textMuted)
                    }
                    .onChange(of: outW) { _, _ in if ratio == .free { rect = fitted(CGFloat(outW / max(outH, 1))) } }
                    .onChange(of: outH) { _, _ in if ratio == .free { rect = fitted(CGFloat(outW / max(outH, 1))) } }
                }
            }
            if ctx.files.count > 1 {
                Text("Та же область (в долях кадра) применится ко всем выбранным фото.").font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textMuted)
            }
        }
        .task { preview = previewImage(ctx.file) }
    }

    /// Максимальная центрированная область нужной пропорции.
    private func fitted(_ r: CGFloat) -> CGRect {
        let imgAspect = pixelSize.width / pixelSize.height
        var w: CGFloat = 1, h = imgAspect / r
        if h > 1 { h = 1; w = r / imgAspect }
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    private func applyRatio(_ r: Ratio) {
        if let v = r.value(original: pixelSize.width / pixelSize.height) { rect = fitted(v) }
    }

    private func save() {
        let files = ctx.files, tools = ctx.tools, norm = rect
        let size: CGSize? = exact ? CGSize(width: outW, height: outH) : nil
        ctx.submit("Кроп") { progress in
            var out: [URL] = []
            for (i, f) in files.enumerated() {
                progress(i, nil)
                let img = try ImageEngine.loadCGImage(f)
                let r = CGRect(x: norm.minX * CGFloat(img.width), y: norm.minY * CGFloat(img.height),
                               width: norm.width * CGFloat(img.width), height: norm.height * CGFloat(img.height))
                guard var cropped = ImageOps.crop(img, to: r) else { throw DropwheelError("Пустая область кропа") }
                if let size, let resized = ImageOps.resize(cropped, to: size) { cropped = resized }
                out.append(try await saveImage(cropped, beside: f, suffix: "кроп", tools: tools))
            }
            return out
        }
    }
}

// MARK: ADD BG

struct AddBackgroundTool: View {
    let ctx: ToolContext
    @State private var preview: CGImage?
    @State private var source: CGImage?
    @State private var fillIndex = 0
    @State private var customImage: URL?
    @State private var blur: Double = 20
    @State private var ratio: CropImageTool.Ratio = .original
    @State private var padding: Double = 8
    @State private var corner: Double = 3
    @State private var shadow: Double = 50

    static let fills: [ImageOps.Fill] = [
        .gradient([(0.36, 0.55, 0.98), (0.73, 0.43, 0.95)], angle: 45),
        .gradient([(0.99, 0.73, 0.45), (0.95, 0.38, 0.47)], angle: 30),
        .gradient([(0.40, 0.85, 0.78), (0.20, 0.50, 0.85)], angle: 60),
        .gradient([(0.96, 0.96, 0.98), (0.80, 0.86, 0.95)], angle: 90),
        .gradient([(0.10, 0.12, 0.20), (0.25, 0.20, 0.40)], angle: 120),
        .solid(r: 1, g: 1, b: 1), .solid(r: 0.11, g: 0.11, b: 0.12), .solid(r: 0.93, g: 0.93, b: 0.95),
        .solid(r: 0.18, g: 0.36, b: 0.92), .solid(r: 0.15, g: 0.55, b: 0.35), .solid(r: 0.85, g: 0.25, b: 0.25), .solid(r: 0.98, g: 0.80, b: 0.30),
    ]

    private var fill: ImageOps.Fill {
        if fillIndex == -1, let customImage { return .image(customImage, blur: blur / 10) }
        return Self.fills[max(0, fillIndex)]
    }

    private var frame: ImageOps.Frame {
        var f = ImageOps.Frame()
        f.fill = fill
        f.aspect = ratio.value(original: aspect(of: source))
        f.padding = padding / 100
        f.cornerRadius = corner / 100
        f.shadow = shadow / 100
        return f
    }

    var body: some View {
        ToolChrome(title: "Фон", close: ctx.close, save: save) {
            PreviewBox(height: 320) {
                if let preview { Image(decorative: preview, scale: 1).resizable().scaledToFit().padding(Tokens.Space.s2) } else { ProgressView() }
            }
            ToolSection(title: "Фон") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: Tokens.Space.s2), count: 13), spacing: Tokens.Space.s2) {
                    ForEach(Self.fills.indices, id: \.self) { i in
                        Swatch(fill: Self.fills[i], selected: fillIndex == i).onTapGesture { fillIndex = i }
                            .accessibilityAddTraits(.isButton).accessibilityLabel("Фон \(i + 1)")
                    }
                    Button(action: pickImage) {
                        Image(systemName: "photo.badge.plus").frame(width: 28, height: 28)
                            .background(Tokens.Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm).strokeBorder(fillIndex == -1 ? Tokens.Palette.accent : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain).accessibilityLabel("Своё изображение для фона")
                }
                if fillIndex == -1 { SliderRow(label: "Размытие фона", value: $blur, range: 0...100, defaultValue: 20, format: "%.0f") }
            }
            ToolSection(title: "Холст") {
                Picker("Пропорции", selection: $ratio) { ForEach(CropImageTool.Ratio.allCases.filter { $0 != .free }) { Text($0.rawValue).tag($0) } }
                SliderRow(label: "Отступ", value: $padding, range: 0...40, unit: "%", defaultValue: 8, format: "%.0f")
                SliderRow(label: "Скругление", value: $corner, range: 0...25, unit: "%", defaultValue: 3, format: "%.0f")
                SliderRow(label: "Тень", value: $shadow, range: 0...100, unit: "%", defaultValue: 50, format: "%.0f")
            }
        }
        .task { source = previewImage(ctx.file, maxPixel: 900); render() }
        .onChange(of: fillIndex) { render() }
        .onChange(of: ratio) { render() }
        .onChange(of: padding) { render() }
        .onChange(of: corner) { render() }
        .onChange(of: shadow) { render() }
        .onChange(of: blur) { render() }
    }

    private func render() {
        guard let source else { return }
        preview = try? ImageOps.frame(source, frame)
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { customImage = url; fillIndex = -1; render() }
    }

    private func save() {
        let url = ctx.file, tools = ctx.tools, f = frame
        ctx.submit("Фон") { _ in
            let out = try ImageOps.frame(try ImageEngine.loadCGImage(url), f)
            // Скругления и тень дают прозрачность только при отсутствии фона, поэтому формат исходника годится.
            return [try await saveImage(out, beside: url, suffix: "с фоном", tools: tools)]
        }
    }
}

struct Swatch: View {
    let fill: ImageOps.Fill
    let selected: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: Tokens.Radius.sm)
            .fill(style)
            .frame(width: 28, height: 28)
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm).strokeBorder(Tokens.Palette.border))
            .padding(2)
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm + 2).strokeBorder(selected ? Tokens.Palette.accent : .clear, lineWidth: 2))
    }
    private var style: AnyShapeStyle {
        switch fill {
        case let .solid(r, g, b): return AnyShapeStyle(Color(red: r, green: g, blue: b))
        case let .gradient(stops, _): return AnyShapeStyle(LinearGradient(colors: stops.map { Color(red: $0.0, green: $0.1, blue: $0.2) }, startPoint: .topLeading, endPoint: .bottomTrailing))
        case .image: return AnyShapeStyle(Tokens.Palette.surfaceSunken)
        }
    }
}

// MARK: REDACT

struct RedactImageTool: View {
    let ctx: ToolContext
    @State private var preview: CGImage?
    @State private var regions: [CGRect] = []
    @State private var selected: Int?
    @State private var style: ImageOps.RedactStyle = .blur
    @State private var detecting = false
    @State private var note: String?

    var body: some View {
        ToolChrome(title: "Скрыть лишнее", canSave: !regions.isEmpty, close: ctx.close, save: save) {
            PreviewBox(height: 340) {
                if let preview {
                    let shown = ImageOps.redact(preview, regions: regions, style: style) ?? preview
                    Image(decorative: shown, scale: 1).resizable().scaledToFit()
                        .overlay {
                            ForEach(regions.indices, id: \.self) { i in
                                SelectionRect(rect: Binding(get: { regions[i] }, set: { regions[i] = $0; selected = i }),
                                              color: selected == i ? Tokens.Palette.accent : Color.white, dimOutside: false)
                            }
                        }
                } else { ProgressView() }
            }
            HStack {
                Button("Найти лица") { detect(faces: true, text: false) }
                Button("Найти текст") { detect(faces: false, text: true) }
                Button("Добавить область") { regions.append(CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.2)); selected = regions.count - 1 }
                Spacer()
                Button("Удалить выбранную", role: .destructive) { if let s = selected, s < regions.count { regions.remove(at: s); selected = nil } }
                    .disabled(selected == nil)
            }
            .disabled(detecting)
            if detecting { ProgressView("Ищу…").controlSize(.small) }
            if let note { Text(note).font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textMuted) }
            ToolSection(title: "Как скрыть") {
                Picker("Стиль", selection: $style) {
                    Text("Размыть").tag(ImageOps.RedactStyle.blur)
                    Text("Пикселизировать").tag(ImageOps.RedactStyle.pixelate)
                    Text("Закрасить").tag(ImageOps.RedactStyle.solid)
                }.pickerStyle(.segmented).labelsHidden()
            }
        }
        .task { preview = previewImage(ctx.file, maxPixel: 1400) }
    }

    private func detect(faces: Bool, text: Bool) {
        guard let preview else { return }
        detecting = true
        Task {
            let found = (try? await Task.detached { try VisionService.detectSensitive(preview, faces: faces, text: text) }.value) ?? []
            regions += found
            note = found.isEmpty ? "Ничего не найдено" : "Найдено областей: \(found.count). Их можно двигать и удалять."
            detecting = false
        }
    }

    private func save() {
        let url = ctx.file, tools = ctx.tools, r = regions, s = style
        ctx.submit("Скрытие") { _ in
            guard let out = ImageOps.redact(try ImageEngine.loadCGImage(url), regions: r, style: s) else { throw DropwheelError("Не удалось обработать фото") }
            return [try await saveImage(out, beside: url, suffix: "скрыто", tools: tools)]
        }
    }
}

// MARK: ANNOTATE

struct AnnotateTool: View {
    let ctx: ToolContext
    @State private var preview: CGImage?
    @State private var items: [ImageOps.Annotation] = []
    @State private var kind: ImageOps.Annotation.Kind = .arrow
    @State private var color = Color(red: 0.94, green: 0.24, blue: 0.18)
    @State private var width: Double = 6
    @State private var text = "Текст"
    @State private var drawing: ImageOps.Annotation?

    private static let kinds: [(ImageOps.Annotation.Kind, String, String)] = [
        (.arrow, "Стрелка", "arrow.up.right"), (.rectangle, "Рамка", "rectangle"), (.ellipse, "Овал", "circle"),
        (.line, "Линия", "line.diagonal"), (.highlight, "Маркер", "highlighter"), (.pen, "Карандаш", "scribble"),
        (.text, "Текст", "textformat"), (.number, "Номер", "1.circle"),
    ]

    var body: some View {
        ToolChrome(title: "Пометки", canSave: !items.isEmpty, close: ctx.close, save: save) {
            HStack(spacing: Tokens.Space.s1) {
                ForEach(Self.kinds, id: \.0) { k, title, symbol in
                    Button { kind = k } label: { Image(systemName: symbol).frame(width: 28, height: 24) }
                        .buttonStyle(.bordered).tint(kind == k ? Tokens.Palette.accent : nil)
                        .help(title).accessibilityLabel(title)
                }
                Spacer()
                ColorPicker("Цвет", selection: $color).labelsHidden()
                Button("Отменить") { _ = items.popLast() }.disabled(items.isEmpty).keyboardShortcut("z", modifiers: .command)
            }
            if kind == .text { TextField("Текст надписи", text: $text) }
            SliderRow(label: "Толщина", value: $width, range: 2...20, defaultValue: 6, format: "%.0f")
            PreviewBox(height: 360) {
                if let preview {
                    let shown = ImageOps.annotate(preview, items + (drawing.map { [$0] } ?? [])) ?? preview
                    Image(decorative: shown, scale: 1).resizable().scaledToFit()
                        .overlay(GeometryReader { geo in
                            Color.clear.contentShape(Rectangle()).gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { g in
                                        let p = CGPoint(x: g.location.x / geo.size.width, y: g.location.y / geo.size.height)
                                        if drawing == nil {
                                            var a = ImageOps.Annotation(kind: kind, points: [p, p])
                                            a.color = rgb(color); a.width = width / 1000; a.text = text
                                            a.number = items.filter { $0.kind == .number }.count + 1
                                            drawing = a
                                        } else if kind == .pen { drawing?.points.append(p) }
                                        else { drawing?.points[1] = p }
                                    }
                                    .onEnded { _ in if let d = drawing { items.append(d) }; drawing = nil })
                        })
                } else { ProgressView() }
            }
        }
        .task { preview = previewImage(ctx.file, maxPixel: 1400) }
    }

    private func rgb(_ c: Color) -> [Double] {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .red
        return [Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent)]
    }

    private func save() {
        let url = ctx.file, tools = ctx.tools, list = items
        ctx.submit("Пометки") { _ in
            guard let out = ImageOps.annotate(try ImageEngine.loadCGImage(url), list) else { throw DropwheelError("Не удалось нарисовать пометки") }
            return [try await saveImage(out, beside: url, suffix: "с пометками", tools: tools)]
        }
    }
}

// MARK: COLLAGE

struct CollageTool: View {
    let ctx: ToolContext
    @State private var order: [URL] = []
    @State private var thumbs: [URL: CGImage] = [:]
    @State private var layout: ImageOps.CollageLayout = .grid
    @State private var width: Double = 2400
    @State private var height: Double = 2400
    @State private var spacing: Double = 1
    @State private var corner: Double = 0
    @State private var bg = Color.white
    @State private var preview: CGImage?

    private var config: ImageOps.Collage {
        var c = ImageOps.Collage()
        c.layout = layout; c.width = width; c.height = height; c.spacing = spacing / 100; c.corner = corner / 100
        let n = NSColor(bg).usingColorSpace(.sRGB) ?? .white
        c.background = (Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent))
        return c
    }

    var body: some View {
        ToolChrome(title: "Коллаж", close: ctx.close, save: save) {
            PreviewBox(height: 300) {
                if let preview { Image(decorative: preview, scale: 1).resizable().scaledToFit().padding(Tokens.Space.s2) } else { ProgressView() }
            }
            ToolSection(title: "Раскладка") {
                Picker("Раскладка", selection: $layout) {
                    Text("Сетка").tag(ImageOps.CollageLayout.grid); Text("Ряд").tag(ImageOps.CollageLayout.row)
                    Text("Столбец").tag(ImageOps.CollageLayout.column); Text("Главное фото").tag(ImageOps.CollageLayout.featured)
                }.pickerStyle(.segmented).labelsHidden()
                HStack {
                    Text("Размер").font(Tokens.Font.body)
                    TextField("Ширина", value: $width, format: .number).frame(width: 80)
                    Text("×"); TextField("Высота", value: $height, format: .number).frame(width: 80)
                    Text("px").foregroundStyle(Tokens.Palette.textMuted)
                    Spacer()
                    ColorPicker("Фон", selection: $bg)
                }
                SliderRow(label: "Отступы", value: $spacing, range: 0...6, step: 0.5, unit: "%", defaultValue: 1, format: "%.1f")
                SliderRow(label: "Скругление", value: $corner, range: 0...10, unit: "%", defaultValue: 0, format: "%.0f")
            }
            ToolSection(title: "Порядок") {
                List {
                    ForEach(order, id: \.self) { url in
                        HStack {
                            if let t = thumbs[url] { Image(decorative: t, scale: 1).resizable().scaledToFill().frame(width: 36, height: 36).clipped() }
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .onMove { order.move(fromOffsets: $0, toOffset: $1); render() }
                }
                .frame(height: min(CGFloat(order.count) * 44 + 8, 220))
            }
        }
        .task {
            order = ctx.files
            let files = ctx.files
            let loaded = await Task.detached { files.map { ($0, previewImage($0, maxPixel: 600)) } }.value
            for (f, t) in loaded { thumbs[f] = t }
            render()
        }
        .onChange(of: layout) { render() }
        .onChange(of: spacing) { render() }
        .onChange(of: corner) { render() }
        .onChange(of: bg) { render() }
        .onChange(of: width) { render() }
        .onChange(of: height) { render() }
    }

    private func render() {
        var c = config
        let scale = 700 / max(c.width, c.height)
        c.width *= scale; c.height *= scale
        preview = ImageOps.collage(order.compactMap { thumbs[$0] }, c)
    }

    private func save() {
        let files = order, c = config, tools = ctx.tools
        ctx.submit("Коллаж") { _ in
            let images = try files.map { try ImageEngine.loadCGImage($0, maxPixel: Int(max(c.width, c.height))) }
            guard let out = ImageOps.collage(images, c) else { throw DropwheelError("Не удалось собрать коллаж") }
            let dest = OutputNamer.sibling(of: files[0], ext: "jpg", suffix: "коллаж")
            return [try await Staged.fileAsync(beside: dest) { try await ImageEngine(tools: tools).write(out, to: $0, ext: "jpg", quality: 0.92) }]
        }
    }
}
