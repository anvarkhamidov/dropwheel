import PDFKit
import DropwheelCore
import SwiftUI

/// Миниатюра страницы PDF.
func pageThumb(_ page: PDFPage, size: CGFloat = 220) -> NSImage {
    page.thumbnail(of: NSSize(width: size, height: size), for: .mediaBox)
}

// MARK: MERGE

struct MergePDFsTool: View {
    let ctx: ToolContext
    @State private var order: [URL] = []
    @State private var pages: [URL: Int] = [:]

    var body: some View {
        ToolChrome(title: "Объединить PDF", canSave: order.count >= 2, close: ctx.close, save: save) {
            Text("Порядок — как в Finder. Перетащите документы, чтобы поменять его.").font(Tokens.Font.body).foregroundStyle(Tokens.Palette.textMuted)
            List {
                ForEach(order, id: \.self) { url in
                    HStack {
                        Image(systemName: "line.3.horizontal").foregroundStyle(Tokens.Palette.textMuted)
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 24, height: 24)
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(pages[url] ?? 0) стр.").font(Tokens.Font.mono).foregroundStyle(Tokens.Palette.textMuted)
                    }
                }
                .onMove { order.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(height: min(CGFloat(order.count) * 34 + 16, 360))
            Text("Всего страниц: \(order.reduce(0) { $0 + (pages[$1] ?? 0) })").font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textMuted)
        }
        .task {
            order = ctx.files
            for f in ctx.files { pages[f] = PDFDocument(url: f)?.pageCount ?? 0 }
        }
    }

    private func save() {
        let list = order, tools = ctx.tools
        ctx.submit("Объединение PDF") { progress in [try PDFEngine(tools: tools).merge(list) { p in progress(0, p) }] }
    }
}

// MARK: ORGANIZE

struct OrganizePDFTool: View {
    struct Page: Identifiable, Equatable { let id = UUID(); let index: Int; var rotation: Int }
    let ctx: ToolContext
    @State private var doc: PDFDocument?
    @State private var pages: [Page] = []
    @State private var thumbs: [Int: NSImage] = [:]
    @State private var dragging: Page?

    private var changed: Bool { pages.map(\.index) != Array(0..<(doc?.pageCount ?? 0)) || pages.contains { $0.rotation != 0 } }

    var body: some View {
        ToolChrome(title: "Страницы PDF", canSave: changed && !pages.isEmpty, close: ctx.close, save: save) {
            Text("Перетаскивайте страницы, чтобы поменять порядок. Наведите курсор, чтобы повернуть, дублировать или удалить.")
                .font(Tokens.Font.body).foregroundStyle(Tokens.Palette.textMuted)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: Tokens.Space.s3)], spacing: Tokens.Space.s3) {
                ForEach(pages) { page in
                    PageCell(image: thumbs[page.index], number: (pages.firstIndex(of: page) ?? 0) + 1, rotation: page.rotation,
                             rotate: { rotate(page) }, duplicate: { duplicate(page) }, delete: { pages.removeAll { $0.id == page.id } })
                        .onDrag { dragging = page; return NSItemProvider(object: page.id.uuidString as NSString) }
                        .onDrop(of: [.text], delegate: PageDrop(target: page, pages: $pages, dragging: $dragging))
                }
            }
        }
        .task {
            guard let d = PDFDocument(url: ctx.file) else { return }
            doc = d
            pages = (0..<d.pageCount).map { Page(index: $0, rotation: 0) }
            for i in 0..<d.pageCount { if let p = d.page(at: i) { thumbs[i] = pageThumb(p) } }
        }
    }

    private func rotate(_ p: Page) { if let i = pages.firstIndex(of: p) { pages[i].rotation = (pages[i].rotation + 90) % 360 } }
    private func duplicate(_ p: Page) { if let i = pages.firstIndex(of: p) { pages.insert(Page(index: p.index, rotation: p.rotation), at: i + 1) } }

    private func save() {
        let url = ctx.file, tools = ctx.tools, spec = pages.map { (index: $0.index, rotation: $0.rotation) }
        ctx.submit("Порядок страниц") { _ in [try PDFEngine(tools: tools).organize(url, pages: spec)] }
    }
}

private struct PageCell: View {
    let image: NSImage?
    let number: Int
    let rotation: Int
    let rotate: () -> Void
    let duplicate: () -> Void
    let delete: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: Tokens.Space.s1) {
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.Radius.sm).fill(Tokens.Palette.surface)
                if let image { Image(nsImage: image).resizable().scaledToFit().rotationEffect(.degrees(Double(rotation))).padding(Tokens.Space.s1) }
                if hover {
                    HStack(spacing: Tokens.Space.s1) {
                        iconButton("rotate.right", "Повернуть", rotate)
                        iconButton("plus.square.on.square", "Дублировать", duplicate)
                        iconButton("trash", "Удалить", delete)
                    }
                    .padding(Tokens.Space.s1)
                    .background(.regularMaterial, in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, Tokens.Space.s1)
                }
            }
            .frame(height: 160)
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm).strokeBorder(Tokens.Palette.border))
            Text("\(number)").font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textMuted)
        }
        .onHover { hover = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Страница \(number)")
    }

    private func iconButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 22) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

private struct PageDrop: DropDelegate {
    let target: OrganizePDFTool.Page
    @Binding var pages: [OrganizePDFTool.Page]
    @Binding var dragging: OrganizePDFTool.Page?

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target, let from = pages.firstIndex(of: d), let to = pages.firstIndex(of: target) else { return }
        withAnimation(.easeOut(duration: 0.15)) { pages.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

// MARK: SPLIT

struct SplitPDFTool: View {
    let ctx: ToolContext
    enum Mode: String, CaseIterable { case every, ranges }
    @State private var mode: Mode = .every
    @State private var every: Double = 1
    @State private var rangesText = ""
    @State private var count = 0

    private var ranges: [ClosedRange<Int>]? {
        switch mode {
        case .every: return PDFEngine.evenRanges(pageCount: count, every: Int(every))
        case .ranges: return Self.parse(rangesText, max: count)
        }
    }

    /// «1-3, 5, 7-9» → [1...3, 5...5, 7...9]. nil — ошибка ввода.
    static func parse(_ text: String, max: Int) -> [ClosedRange<Int>]? {
        var out: [ClosedRange<Int>] = []
        for part in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            let ends = part.split(separator: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let a = ends.first ?? nil, let b = ends.last ?? nil, ends.count <= 2, a >= 1, b >= a, b <= max else { return nil }
            out.append(a...b)
        }
        return out.isEmpty ? nil : out
    }

    var body: some View {
        ToolChrome(title: "Разделить PDF", canSave: (ranges?.count ?? 0) > 0, close: ctx.close, save: save) {
            Text("Страниц в документе: \(count)").font(Tokens.Font.body).foregroundStyle(Tokens.Palette.textMuted)
            Picker("Как делить", selection: $mode) { Text("Каждые N страниц").tag(Mode.every); Text("По диапазонам").tag(Mode.ranges) }
                .pickerStyle(.segmented).labelsHidden()
            if mode == .every {
                SliderRow(label: "Страниц в части", value: $every, range: 1...Double(max(count, 1)), step: 1, defaultValue: 1, format: "%.0f")
            } else {
                TextField("Например: 1-3, 4, 5-10", text: $rangesText).textFieldStyle(.roundedBorder)
                if !rangesText.isEmpty && ranges == nil {
                    Text("Проверьте диапазоны: номера от 1 до \(count), через запятую").font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.danger)
                }
            }
            if let r = ranges { Text("Получится файлов: \(r.count). Все в одной папке рядом с документом.").font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textMuted) }
        }
        .task { count = PDFDocument(url: ctx.file)?.pageCount ?? 0 }
    }

    private func save() {
        guard let r = ranges else { return }
        let url = ctx.file, tools = ctx.tools
        ctx.submit("Разделение PDF") { _ in [try PDFEngine(tools: tools).split(url, ranges: r)] }
    }
}
