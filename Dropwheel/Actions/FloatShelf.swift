import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class FloatShelfModel {
    var items: [URL] = []

    func add(_ urls: [URL]) {
        for u in urls where !items.contains(u) { items.append(u) }
    }
}

/// Плавающая полка: держит файлы под рукой, пока их не утащат в другое приложение.
/// После перемещения прилипает к ближайшему левому или правому краю экрана.
@MainActor
final class FloatShelfController: NSObject, NSWindowDelegate {
    let model = FloatShelfModel()
    private lazy var panel: NSPanel = makePanel()
    private var snapWork: DispatchWorkItem?

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 220),
                        styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.delegate = self
        p.contentView = NSHostingView(rootView: FloatShelfView(model: model, close: { [weak self] in self?.hide() }))
        return p
    }

    func add(_ urls: [URL]) {
        model.add(urls)
        show()
    }

    func show() {
        if !panel.isVisible, let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - panel.frame.width - 12, y: f.midY - panel.frame.height / 2))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        model.items.removeAll()
    }

    func windowDidMove(_ notification: Notification) {
        snapWork?.cancel()
        let work = DispatchWorkItem { [weak self] in Task { @MainActor in self?.snap() } }
        snapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func snap() {
        guard NSEvent.pressedMouseButtons & 1 == 0, let screen = panel.screen else { return }
        let f = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = frame.midX < f.midX ? f.minX + 12 : f.maxX - frame.width - 12
        frame.origin.y = min(max(frame.origin.y, f.minY + 12), f.maxY - frame.height - 12)
        panel.animator().setFrame(frame, display: true)
    }
}

struct FloatShelfView: View {
    let model: FloatShelfModel
    let close: () -> Void
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack {
                Text("Полка").font(Tokens.Font.section).foregroundStyle(Tokens.Palette.text)
                Spacer()
                if !model.items.isEmpty {
                    Button("Очистить") { model.items.removeAll() }.buttonStyle(.link).font(Tokens.Font.caption)
                }
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20)
                        .background(Tokens.Palette.surfaceSunken, in: Circle())
                }
                .buttonStyle(.plain).foregroundStyle(Tokens.Palette.textMuted)
                .accessibilityLabel("Закрыть полку")
            }
            if model.items.isEmpty {
                VStack(spacing: Tokens.Space.s2) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 24)).foregroundStyle(Tokens.Palette.textMuted)
                    Text("Положите сюда файлы, а потом перетащите их, куда нужно")
                        .font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textMuted).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: Tokens.Space.s1) {
                        ForEach(model.items, id: \.self) { url in
                            HStack(spacing: Tokens.Space.s2) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
                                Text(url.lastPathComponent).font(Tokens.Font.body).lineLimit(1).truncationMode(.middle)
                                    .foregroundStyle(Tokens.Palette.text)
                                Spacer(minLength: 0)
                                Button { model.items.removeAll { $0 == url } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plain).foregroundStyle(Tokens.Palette.textMuted)
                                    .accessibilityLabel("Убрать \(url.lastPathComponent) с полки")
                            }
                            .padding(Tokens.Space.s1)
                            .contentShape(Rectangle())
                            .onDrag { NSItemProvider(object: url as NSURL) }
                        }
                    }
                }
            }
        }
        .padding(Tokens.Space.s3)
        .frame(minWidth: 240, minHeight: 160)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.window, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.window, style: .continuous)
            .strokeBorder(targeted ? Tokens.Palette.accent : Tokens.Palette.border, lineWidth: targeted ? 2 : 1))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: NSURL.self) { obj, _ in
                    if let url = obj as? URL { Task { @MainActor in model.add([url]) } }
                }
            }
            return true
        }
    }
}
