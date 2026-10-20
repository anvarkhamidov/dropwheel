import AppKit
import os

let gestureLog = Logger(subsystem: "local.dropwheel.app", category: "gesture")

/// Замечает перетаскивание файлов в любом приложении и «тап» модификатора во время него.
///
/// Публичного события «начался drag» в macOS нет, поэтому признаки такие:
/// левая кнопка зажата, курсор сдвинулся, и drag-pasteboard обновился после нажатия.
/// Модификаторы и кнопки читаются через `NSEvent.modifierFlags` / `pressedMouseButtons` —
/// это состояние сеанса, для него не нужны разрешения Accessibility или Input Monitoring.
@MainActor
final class DragWatcher {
    enum Phase: Equatable { case idle, pressed, dragging }

    /// Появились файлы в drag и нажат модификатор (фронт 0→1).
    var onTrigger: ((NSEvent.ModifierFlags, [URL], NSPoint) -> Void)?
    /// Кнопка мыши отпущена: drag закончился (drop или отмена).
    var onDragEnded: (() -> Void)?

    private(set) var phase: Phase = .idle
    private var timer: Timer?
    private var monitors: [Any] = []
    private var downLocation: NSPoint = .zero
    private var downChangeCount = 0
    private var lastFlags: NSEvent.ModifierFlags = []
    private(set) var currentFiles: [URL] = []

    static let watchedFlags: NSEvent.ModifierFlags = [.shift, .command, .control, .option, .function]

    func start() {
        gestureLog.notice("start: NSApp.isRunning=\(NSApp.isRunning, privacy: .public) activation=\(NSApp.activationPolicy().rawValue, privacy: .public)")
        // Нажатие ловим монитором: глобальный — в чужих приложениях, локальный — в наших окнах.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            Task { @MainActor in self?.mouseDown() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] e in
            Task { @MainActor in self?.mouseDown() }
            return e
        }) { monitors.append(l) }
        gestureLog.notice("start: мониторов установлено \(self.monitors.count, privacy: .public) из 2")
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        stopPolling()
    }

    private func mouseDown() {
        guard phase == .idle else { gestureLog.debug("mouseDown проигнорирован: phase=\(String(describing: self.phase), privacy: .public)"); return }
        phase = .pressed
        downLocation = NSEvent.mouseLocation
        downChangeCount = NSPasteboard(name: .drag).changeCount
        lastFlags = NSEvent.modifierFlags.intersection(Self.watchedFlags)
        gestureLog.debug("mouseDown: dragChangeCount=\(self.downChangeCount, privacy: .public)")
        startPolling()
    }

    private func startPolling() {
        stopPolling()
        // 60 Гц только пока кнопка зажата; в покое таймера нет.
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        // Во время drag главный run loop крутится в eventTracking — таймер в .common его переживёт.
        timer = t
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let buttonDown = NSEvent.pressedMouseButtons & 1 == 1
        if !buttonDown {
            let wasDragging = phase == .dragging
            phase = .idle
            currentFiles = []
            stopPolling()
            gestureLog.debug("кнопка отпущена: wasDragging=\(wasDragging, privacy: .public)")
            if wasDragging { onDragEnded?() }
            return
        }

        let flags = NSEvent.modifierFlags.intersection(Self.watchedFlags)
        defer { lastFlags = flags }

        if phase == .pressed {
            let p = NSEvent.mouseLocation
            let moved = hypot(p.x - downLocation.x, p.y - downLocation.y) > 4
            let pb = NSPasteboard(name: .drag)
            guard moved, pb.changeCount != downChangeCount else { return }
            let files = Self.fileURLs(in: pb)
            if files.isEmpty {
                gestureLog.debug("drag без файлов: types=\(pb.types?.map(\.rawValue).joined(separator: ",") ?? "nil", privacy: .public)")
                return
            } // тянут не файлы (текст, окно) — не наше дело
            currentFiles = files
            phase = .dragging
            gestureLog.notice("drag файлов: \(files.count, privacy: .public), changeCount=\(pb.changeCount, privacy: .public), расширения=\(files.map { $0.pathExtension.isEmpty ? "<папка/без>" : $0.pathExtension }.joined(separator: ","), privacy: .public)")
            // Модификаторы, зажатые ещё до начала drag, не считаются тапом.
            return
        }

        guard phase == .dragging else { return }
        let rising = flags.subtracting(lastFlags)
        guard !rising.isEmpty else { return }
        gestureLog.notice("тап модификатора: rising=\(rising.rawValue, privacy: .public)")
        // Finder мог дописать pasteboard позже — перечитываем на момент тапа.
        let files = Self.fileURLs(in: NSPasteboard(name: .drag))
        if !files.isEmpty { currentFiles = files }
        onTrigger?(rising, currentFiles, NSEvent.mouseLocation)
    }

    static func fileURLs(in pb: NSPasteboard) -> [URL] {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map(\.standardizedFileURL)
    }
}
