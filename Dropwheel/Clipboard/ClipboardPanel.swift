import AppKit
import DropwheelCore
import SwiftUI

/// Панель, которая принимает клавиатуру, но не активирует приложение: после выбора записи
/// фокус остаётся в том приложении, где вы работали, и ⌘V вставляет сразу туда.
final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class ClipboardPanelController: NSObject, NSWindowDelegate {
    private unowned let history: ClipboardHistory
    private var panel: ClipboardPanel?

    init(history: ClipboardHistory) {
        self.history = history
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { isVisible ? close() : show() }

    func show() {
        let p = panel ?? makePanel()
        panel = p
        // Новый экземпляр содержимого: поиск пустой, выделена первая запись.
        p.contentView = NSHostingView(rootView: ClipboardView(history: history) { [weak self] in self?.close() })
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = NSSize(width: Tokens.Clipboard.width, height: Tokens.Clipboard.height)
            // Как Spotlight: по центру, в верхней трети.
            p.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.62 - size.height / 2,
                              width: size.width, height: size.height), display: false)
        }
        p.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.orderOut(nil) }

    private func makePanel() -> ClipboardPanel {
        let p = ClipboardPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                               backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.acceptsMouseMovedEvents = true
        p.delegate = self
        return p
    }

    /// Клик мимо панели — закрыть, как у системных всплывающих окон.
    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { close() }
    }
}

struct ClipboardView: View {
    let history: ClipboardHistory
    let close: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var searchFocused: Bool
    /// Наведение выбирает строку только после движения мыши: панель часто открывается прямо под курсором,
    /// и без этого выделялась бы случайная строка вместо первой.
    @State private var hoverArmed = false
    @State private var mouseMonitor: Any?

    private var results: [ClipItem] {
        _ = history.items // подписка на изменения истории
        return history.search(query)
    }

    var body: some View {
        let list = results
        VStack(spacing: 0) {
            HStack(spacing: Tokens.Space.s2) {
                Image(systemName: "magnifyingglass").foregroundStyle(Tokens.Palette.textMuted)
                TextField("Поиск в истории буфера", text: $query)
                    .textFieldStyle(.plain)
                    .font(Tokens.Font.title)
                    .focused($searchFocused)
                    .onChange(of: query) { selection = 0 }
            }
            .padding(.horizontal, Tokens.Space.s4)
            .padding(.vertical, Tokens.Space.s3)

            Divider()

            if list.isEmpty {
                VStack(spacing: Tokens.Space.s2) {
                    Image(systemName: "list.clipboard").font(.system(size: 28)).foregroundStyle(Tokens.Palette.textMuted)
                    Text(query.isEmpty ? "История пуста" : "Ничего не найдено").font(Tokens.Font.section)
                    Text(query.isEmpty ? "Скопируйте текст, картинку или файлы — они появятся здесь." : "Попробуйте другое слово.")
                        .font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                                ClipRow(item: item, index: i, selected: i == selection, thumbnail: history.thumbnail(for: item))
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { choose(item) }
                                    .onHover { if $0 && hoverArmed { selection = i } }
                            }
                        }
                        .padding(Tokens.Space.s2)
                    }
                    .onChange(of: selection) { _, i in
                        if list.indices.contains(i) { proxy.scrollTo(list[i].id) }
                    }
                }
            }

            Divider()
            HStack(spacing: Tokens.Space.s4) {
                hint("↩", "скопировать")
                hint("⌘P", "закрепить")
                hint("⌘⌫", "удалить")
                Spacer()
                hint("esc", "закрыть")
            }
            .padding(.horizontal, Tokens.Space.s4)
            .padding(.vertical, Tokens.Space.s2)
        }
        .frame(width: Tokens.Clipboard.width, height: Tokens.Clipboard.height)
        .background(PanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.window, style: .continuous))
        .onAppear {
            searchFocused = true
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
                hoverArmed = true
                return event
            }
        }
        .onDisappear {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            mouseMonitor = nil
        }
        .onKeyPress(phases: .down) { press in handle(press, list) }
    }

    private func handle(_ press: KeyPress, _ list: [ClipItem]) -> KeyPress.Result {
        let selected = list.indices.contains(selection) ? list[selection] : nil
        if press.modifiers.contains(.command) {
            if let digit = Int(press.characters), (1...9).contains(digit), list.indices.contains(digit - 1) {
                choose(list[digit - 1]); return .handled
            }
            if press.characters == "p", let selected { history.togglePin(selected); return .handled }
            if press.key == .delete, let selected {
                history.remove(selected)
                selection = min(selection, max(list.count - 2, 0))
                return .handled
            }
            return .ignored
        }
        switch press.key {
        case .downArrow: selection = min(selection + 1, max(list.count - 1, 0)); return .handled
        case .upArrow: selection = max(selection - 1, 0); return .handled
        case .return: if let selected { choose(selected) }; return .handled
        case .escape: close(); return .handled
        default: return .ignored
        }
    }

    private func choose(_ item: ClipItem) {
        history.copy(item)
        close()
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(Tokens.Font.caption.monospaced()).foregroundStyle(Tokens.Palette.text)
            Text(text).font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textMuted)
        }
    }
}

private struct ClipRow: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    let thumbnail: NSImage?

    var body: some View {
        HStack(spacing: Tokens.Space.s3) {
            preview
                .frame(width: Tokens.Clipboard.thumb, height: Tokens.Clipboard.thumb)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? " " : item.title)
                    .font(Tokens.Font.body)
                    .foregroundStyle(Tokens.Palette.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Palette.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: Tokens.Space.s2)
            if item.pinned {
                Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(Tokens.Palette.accent)
            }
            if index < 9 {
                Text("⌘\(index + 1)").font(Tokens.Font.caption.monospaced()).foregroundStyle(Tokens.Palette.textMuted)
            }
        }
        .padding(.horizontal, Tokens.Space.s3)
        .frame(height: Tokens.Clipboard.rowHeight)
        .background(selected ? Tokens.Palette.accent.opacity(0.16) : .clear,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var preview: some View {
        if let thumbnail {
            Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: item.kind == .image ? .fill : .fit)
        } else {
            Image(systemName: "text.alignleft")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Tokens.Palette.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Tokens.Palette.accent.opacity(0.12))
        }
    }

    private var subtitle: String {
        let when = RelativeDateTimeFormatter.clip.localizedString(for: item.date, relativeTo: Date())
        var parts = [String]()
        if let name = item.sourceName { parts.append(name) }
        if item.kind == .text, let text = item.text, text.count > item.title.count + 1 { parts.append("\(text.count) симв.") }
        parts.append(when)
        return parts.joined(separator: " · ")
    }
}

/// Фон панели: стекло на macOS 26+, матовый материал раньше.
private struct PanelBackground: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: Tokens.Radius.window, style: .continuous))
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }
}

private extension RelativeDateTimeFormatter {
    static let clip: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.unitsStyle = .short
        return f
    }()
}
