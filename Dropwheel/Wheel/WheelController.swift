import AppKit
import QuartzCore
import DropwheelCore
import SwiftUI

/// Плавающая неактивируемая панель с колесом. Она же drop-цель: файл, отпущенный на сегмент,
/// приходит сюда обычным NSDraggingDestination, а исходное приложение (Finder) получает операцию .copy
/// и ничего не делает с оригиналом.
final class WheelPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    init() {
        let size = Tokens.Wheel.windowSize
        super.init(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        // Явно: иначе macOS пропускает мышь и drag сквозь прозрачные участки окна. Стекло рисует система,
        // и для оконного сервера кнопки «прозрачны» — файл, отпущенный на кнопку, падал в окно под колесом.
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .none
    }
}

@MainActor
final class WheelController {
    let model = WheelModel()
    var registry: () -> Registry
    /// Выбран сегмент: что и для каких файлов.
    var onPick: ((WheelItem, [URL]) -> Void)?

    private let panel = WheelPanel()
    private let dropView: WheelDropView
    private var dismissWork: DispatchWorkItem?
    private(set) var isVisible = false
    private var clickMode = false
    private var warmedUp = false

    init(registry: @escaping () -> Registry) {
        self.registry = registry
        let size = Tokens.Wheel.windowSize
        let root = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))

        // Подложка и кнопки целиком в SwiftUI (см. WheelView): размер подложки зависит от числа кнопок.
        let host = NSHostingView(rootView: WheelView(model: model))
        host.frame = root.bounds
        host.autoresizingMask = [.width, .height]
        root.addSubview(host)

        dropView = WheelDropView(frame: root.bounds)
        dropView.autoresizingMask = [.width, .height]
        root.addSubview(dropView)

        panel.contentView = root
        dropView.controller = self
    }

    // MARK: Показ

    /// Показать колесо для файлов в точке экрана. `clickMode` — открыто из меню, без drag: выбор кликом или клавишами.
    func show(kind: WheelKind, files: [URL], at screenPoint: NSPoint, clickMode: Bool = false) {
        dismissWork?.cancel()
        self.clickMode = clickMode
        model.kind = kind
        model.files = files
        model.items = registry().items(for: files, kind: kind)
        model.hovered = clickMode && !model.items.isEmpty ? 0 : nil
        model.flashing = nil

        gestureLog.notice("wheel.show: kind=\(kind.rawValue, privacy: .public) items=\(self.model.items.count, privacy: .public) clickMode=\(clickMode, privacy: .public)")
        let started = CACurrentMediaTime()
        let size = Tokens.Wheel.windowSize
        var origin = NSPoint(x: screenPoint.x - size / 2, y: screenPoint.y - size / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(screenPoint, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX - 30), f.maxX - size + 30)
            origin.y = min(max(origin.y, f.minY - 30), f.maxY - size + 30)
        }
        panel.setFrameOrigin(origin)
        panel.allowsKey = clickMode
        if clickMode {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(dropView)
        } else {
            panel.orderFrontRegardless()
        }
        isVisible = true
        model.presented = false
        withAnimation(Tokens.Motion.appear) { model.presented = true }
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: "Колесо: \(model.items.count) вариантов", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        if model.items.isEmpty { scheduleDismiss(after: 1.2) }
        // Замер «вызов → первый отрисованный кадр»: следующий проход run loop после display.
        panel.displayIfNeeded()
        CATransaction.flush()
        let first = !warmedUp
        warmedUp = true
        DispatchQueue.main.async {
            gestureLog.notice("wheel: показ за \(Int((CACurrentMediaTime() - started) * 1000), privacy: .public) мс, первый=\(first, privacy: .public)")
        }
        let p = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            gestureLog.debug("wheel после показа: visible=\(p.isVisible, privacy: .public) onScreen=\(p.occlusionState.contains(.visible), privacy: .public) frame=\(NSStringFromRect(p.frame), privacy: .public) screen=\(p.screen?.localizedName ?? "nil", privacy: .public) presented=\(self?.model.presented ?? false, privacy: .public)")
        }
    }

    /// Один невидимый показ при запуске: первый настоящий открывается без задержки
    /// на инициализацию SwiftUI, Core Animation и размытия (холодный показ — 45–60 мс).
    func prewarm() {
        guard !warmedUp, !isVisible else { return }
        gestureLog.debug("wheel.prewarm")
        model.items = registry().items(for: [URL(fileURLWithPath: "/prewarm.png")], kind: .convert)
        model.presented = true
        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        CATransaction.flush()
        panel.orderOut(nil)
        panel.alphaValue = 1
        model.items = []
        model.presented = false
        warmedUp = true
    }

    func dismiss() {
        dismissWork?.cancel()
        guard isVisible else { return }
        gestureLog.notice("wheel.dismiss")
        isVisible = false
        withAnimation(Tokens.Motion.dismiss) { model.presented = false }
        // Панель убираем, когда колесо уже растаяло (длительность — как у Motion.dismiss).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, !self.isVisible else { return }
            self.panel.orderOut(nil)
            self.model.hovered = nil
        }
    }

    /// Drag закончился: даём drop-обработчику шанс отработать раньше, чем панель исчезнет.
    func dragEnded() {
        guard !clickMode else { return }
        scheduleDismiss(after: 0.35)
    }

    func scheduleDismiss(after delay: TimeInterval) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in Task { @MainActor in self?.dismiss() } }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Ввод (вызывается из WheelDropView)

    func hover(at viewPoint: NSPoint) {
        let size = Tokens.Wheel.windowSize
        // NSView: y вверх; геометрия колеса: y вниз от центра.
        let p = CGPoint(x: viewPoint.x - size / 2, y: size / 2 - viewPoint.y)
        let idx = model.geometry.index(at: p)
        if idx != model.hovered {
            model.hovered = idx
            if let idx, idx < model.items.count {
                NSAccessibility.post(element: panel, notification: .announcementRequested,
                                     userInfo: [.announcement: model.items[idx].label])
            }
        }
    }

    func clearHover() { if !clickMode { model.hovered = nil } }

    func moveSelection(_ delta: Int) {
        guard !model.items.isEmpty else { return }
        let n = model.items.count
        model.hovered = ((model.hovered ?? 0) + delta + n) % n
    }

    /// Сработал выбор: drop файлов, клик или Return.
    @discardableResult
    func commit(urls: [URL]? = nil) -> Bool {
        guard let idx = model.hovered, idx < model.items.count else { dismiss(); return false }
        let item = model.items[idx]
        let files = (urls?.isEmpty == false ? urls! : model.files)
        gestureLog.notice("wheel.commit: \(item.id, privacy: .public) файлов=\(files.count, privacy: .public)")
        model.flashing = idx
        onPick?(item, files)
        scheduleDismiss(after: 0.08)
        return true
    }
}

/// Прозрачный слой поверх колеса: принимает drop, мышь и клавиши.
final class WheelDropView: NSView {
    weak var controller: WheelController?
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    // Drag & drop
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        gestureLog.debug("drop: draggingEntered")
        return draggingUpdated(sender)
    }

    private var lastLogged: (Int?, UInt) = (nil, .max)

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        let hovered = MainActor.assumeIsolated { () -> Int? in
            controller?.hover(at: p)
            return controller?.model.hovered
        }
        let mask = sender.draggingSourceOperationMask
        let op = hovered != nil ? DropPolicy.operation(for: mask) : []
        if lastLogged.0 != hovered || lastLogged.1 != mask.rawValue {
            lastLogged = (hovered, mask.rawValue)
            gestureLog.debug("drop: updated hovered=\(hovered.map(String.init) ?? "nil", privacy: .public) mask=\(mask.rawValue, privacy: .public) → op=\(op.rawValue, privacy: .public)")
        }
        return op
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        gestureLog.debug("drop: draggingExited")
        lastLogged = (nil, .max)
        MainActor.assumeIsolated { controller?.clearHover() }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        gestureLog.debug("drop: prepareForDragOperation")
        return true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        gestureLog.debug("drop: draggingEnded")
        lastLogged = (nil, .max)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = DragWatcher.fileURLs(in: sender.draggingPasteboard)
        gestureLog.notice("drop: performDragOperation файлов=\(urls.count, privacy: .public)")
        let p = convert(sender.draggingLocation, from: nil)
        return MainActor.assumeIsolated {
            controller?.hover(at: p)
            return controller?.commit(urls: urls) ?? false
        }
    }

    // Мышь (режим без drag)
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        MainActor.assumeIsolated { controller?.hover(at: p) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        MainActor.assumeIsolated {
            controller?.hover(at: p)
            controller?.commit()
        }
    }

    // Клавиатура (режим без drag): стрелки, Return, Esc
    override func keyDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            switch event.keyCode {
            case 53: controller?.dismiss()                       // Esc
            case 36, 76, 49: controller?.commit()                // Return, Enter, пробел
            case 123, 126: controller?.moveSelection(-1)         // ← ↑
            case 124, 125, 48: controller?.moveSelection(1)      // → ↓ Tab
            default: super.keyDown(with: event)
            }
        }
    }
}
