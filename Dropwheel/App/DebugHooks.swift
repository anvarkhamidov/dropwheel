import AppKit
import SwiftUI
import DropwheelCore

/// Флаги запуска для проверки без мыши (только Debug):
///   -DropwheelDemoFiles "/a.png,/b.png"   файлы для демо
///   -DropwheelDemoWheel convert|tools|actions [-DropwheelDemoHover 2]
///   -DropwheelDemoTool tool.cropImage
///   -DropwheelDemoAction act.copyPath     выполнить действие и выйти
///   -DropwheelDemoConvert png             конвертировать файлы через центр задач
///   -DropwheelSnapshot /tmp/out.png       снимок окна через 1.5 с, затем выход
@MainActor
enum DebugHooks {
    /// Только аргументы командной строки: постоянные настройки не должны включать демо-режим.
    static let args: [String: Any] = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)

    static var isActive: Bool {
        #if DEBUG
        return args["DropwheelDemoFiles"] != nil
        #else
        return false
        #endif
    }

    static func string(_ key: String) -> String? { args[key] as? String }
    static func double(_ key: String) -> Double { (args[key] as? String).flatMap(Double.init) ?? 0 }

    static func run(_ c: Coordinator) {
        guard isActive, let list = string("DropwheelDemoFiles") else { return }
        let files = list.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        let snapshot = string("DropwheelSnapshot")
        if let look = string("DropwheelAppearance") { NSApp.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua) }
        var target: (() -> NSWindow?)?

        // Как в жизни: прогрев успевает пройти до первого drag. -DropwheelNoPrewarm 1 — замер холодного показа.
        if string("DropwheelNoPrewarm") != "1" { c.wheel.prewarm() }

        if let kindRaw = string("DropwheelDemoWheel"), let kind = WheelKind(rawValue: kindRaw) {
            // Подальше от курсора: иначе наведение мышью сбивает заданный сегмент на снимке.
            var point = NSScreen.main.map { NSPoint(x: $0.visibleFrame.midX, y: $0.visibleFrame.midY) } ?? .zero
            let mouse = NSEvent.mouseLocation
            if hypot(mouse.x - point.x, mouse.y - point.y) < 360 { point.x += mouse.x > point.x ? -420 : 420 }
            // -DropwheelDemoAt x,y — центр колеса в экранных координатах (скриншоты поверх окна Finder).
            if let at = string("DropwheelDemoAt") {
                let xy = at.split(separator: ",").compactMap { Double($0) }
                if xy.count == 2 { point = NSPoint(x: xy[0], y: xy[1]) }
            }
            // Своё окно-фон под колесом: на реальном снимке экрана видно размытие стекла,
            // а в кадр не попадает ничего чужого.
            // С -DropwheelDemoAt фон стоит по центру экрана, а колесо — в заданной точке поверх него.
            if let bg = string("DropwheelBackdrop") {
                let screenCenter = NSScreen.main.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? point
                showBackdrop(bg, at: args["DropwheelDemoAt"] != nil ? screenCenter : point)
            }
            // DropwheelDemoPassive=1 — показ как при живом drag: без активации приложения.
            c.wheel.show(kind: kind, files: files, at: point, clickMode: string("DropwheelDemoPassive") != "1")
            if args["DropwheelDemoHover"] != nil { c.wheel.model.hovered = Int(string("DropwheelDemoHover") ?? "") ?? 0 }
            // -DropwheelDemoCycle 0.4 — переключать выделение по кругу (проверка: модель → отрисовка).
            if double("DropwheelDemoCycle") > 0 {
                Timer.scheduledTimer(withTimeInterval: double("DropwheelDemoCycle"), repeats: true) { _ in
                    MainActor.assumeIsolated {
                        let n = max(c.wheel.model.items.count, 1)
                        c.wheel.model.hovered = ((c.wheel.model.hovered ?? -1) + 1) % n
                        gestureLog.notice("demo: hovered=\(c.wheel.model.hovered ?? -1, privacy: .public)")
                    }
                }
            }
            // -DropwheelDemoHitTest 1 — какое окно реально получит мышь/drag над кнопкой и в зазоре.
            if string("DropwheelDemoHitTest") == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let panel = NSApp.windows.first(where: { $0 is WheelPanel && $0.isVisible }) else { return }
                    let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
                    let probes: [(String, NSPoint)] = [
                        ("кнопка сверху", NSPoint(x: center.x, y: center.y + 85)),
                        ("зазор между кнопками", NSPoint(x: center.x + 85 * sin(.pi / 7), y: center.y + 85 * cos(.pi / 7))),
                        ("ступица", center),
                    ]
                    for (name, p) in probes {
                        let hit = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
                        let who = hit == panel.windowNumber ? "колесо" : (hit == backdrop?.windowNumber ? "окно ПОД колесом" : "другое окно \(hit)")
                        gestureLog.notice("demo: hit-test \(name, privacy: .public) → \(who, privacy: .public)")
                    }
                }
            }
            // -DropwheelDemoHoverAt x,y — вызвать тот же путь, что и мышь/drag (проверка: ввод → модель).
            if let at = string("DropwheelDemoHoverAt") {
                let xy = at.split(separator: ",").compactMap { Double($0) }
                if xy.count == 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        c.wheel.hover(at: NSPoint(x: xy[0], y: xy[1]))
                        gestureLog.notice("demo: hover(at: \(xy[0], privacy: .public),\(xy[1], privacy: .public)) → hovered=\(c.wheel.model.hovered ?? -1, privacy: .public)")
                    }
                }
            }
            target = { NSApp.windows.first { $0 is WheelPanel && $0.isVisible } }
        }
        // -DropwheelClipboardSelfTest 1 — запись в историю через отдельный буфер: текст, файлы, картинка, пароль.
        if string("DropwheelClipboardSelfTest") == "1" { clipboardSelfTest(files: files); return }
        // -DropwheelDemoClipboard 1 — панель истории буфера (вместе с -DropwheelClipboardDir — своя папка с демо-записями).
        if string("DropwheelDemoClipboard") == "1" {
            if string("DropwheelClipboardSeed") == "1" { seedClipboard(c.clipboard, files: files) }
            c.clipboard.apply(enabled: true, limit: 200, hotKey: .off)
            let screenCenter = NSScreen.main.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? .zero
            if let bg = string("DropwheelBackdrop") { showBackdrop(bg, at: screenCenter) }
            c.clipboard.panel.show()
            if let panel = NSApp.windows.first(where: { $0 is ClipboardPanel }) {
                // Для снимка — по центру фона.
                panel.setFrameOrigin(NSPoint(x: screenCenter.x - panel.frame.width / 2, y: screenCenter.y - panel.frame.height / 2))
            }
            target = { NSApp.windows.first { $0 is ClipboardPanel && $0.isVisible } }
        }
        // -DropwheelDemoSettings general|clipboard|updates|tools — окно настроек на этой вкладке (проверка высоты).
        if let raw = string("DropwheelDemoSettings"), let tab = SettingsView.Tab(rawValue: raw) {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(coordinator: c, tab: tab)))
            w.title = "Dropwheel Settings"
            w.center()
            w.makeKeyAndOrderFront(nil)
            target = { w }
        }
        if let toolID = string("DropwheelDemoTool"),
           let tool = c.registry.tools(for: files).first(where: { $0.id == toolID }) {
            c.presenter.open(tool, files: files)
            target = { NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.fullSizeContentView) } }
        }
        if let ext = string("DropwheelDemoConvert"), let option = c.registry.formats(for: files).first(where: { $0.ext == ext }) {
            c.jobs.convert(files, to: option)
            target = { NSApp.windows.first { $0.isVisible && $0.level == .floating } }
        }
        if let actionID = string("DropwheelDemoAction"), let action = ActionKind.allCases.first(where: { $0.id == actionID }) {
            FileActions.perform(action, files: files, settings: c.settings, shelf: c.shelf)
            if action == .float { target = { NSApp.windows.first { $0.isVisible && $0.level == .floating } } }
        }

        guard let snapshot else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (double("DropwheelSnapshotDelay").nonZero ?? 1.5)) {
            if let cmd = c.jobs.lastCommand { gestureLog.notice("demo: последняя команда: \(cmd, privacy: .public)") }
            if let backdrop {
                // Реальный экран, но только область своего окна-фона (вместе с колесом над ним).
                captureScreen(of: backdrop.frame, to: snapshot)
                // Второй кадр через паузу — сравнить состояние во времени.
                if let second = string("DropwheelSnapshot2") {
                    // Не sleep: run loop должен крутиться, чтобы таймеры срабатывали и кадры рисовались.
                    RunLoop.main.run(until: Date().addingTimeInterval(double("DropwheelSnapshot2Delay").nonZero ?? 0.5))
                    captureScreen(of: backdrop.frame, to: second)
                }
            } else if let w = target?() ?? NSApp.keyWindow, let view = w.contentView {
                save(view, to: URL(fileURLWithPath: snapshot))
            } else {
                NSLog("Dropwheel: нет окна для снимка")
            }
            NSApp.terminate(nil)
        }
    }

    static func clipboardSelfTest(files: [URL]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-selftest-\(UUID().uuidString)")
        let pb = NSPasteboard(name: NSPasteboard.Name("local.dropwheel.selftest"))
        let history = ClipboardHistory(directory: dir, pasteboard: pb)
        history.apply(enabled: true, limit: 200, hotKey: .off)
        var steps: [(String, () -> Void)] = [
            ("text", { pb.clearContents(); pb.setString("Hello from self-test", forType: .string) }),
            ("files", { pb.clearContents(); pb.writeObjects(files.map { $0 as NSURL }) }),
            ("password", {
                pb.clearContents()
                pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
                pb.setString("hunter2", forType: .string)
                pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            }),
        ]
        if let img = files.first.flatMap({ NSImage(contentsOf: $0) })?.tiffRepresentation {
            steps.append(("image", { pb.clearContents(); pb.setData(img, forType: .tiff) }))
        }
        steps.append(("duplicate text", { pb.clearContents(); pb.setString("Hello from self-test", forType: .string) }))
        for (name, step) in steps {
            step()
            history.poll()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8)) // картинка кодируется в фоне
            gestureLog.notice("selftest: после \(name, privacy: .public): \(history.items.map { "\($0.kind.rawValue):\($0.title)" }.joined(separator: " | "), privacy: .public)")
        }
        // Возврат записи в буфер не должен порождать новую запись.
        if let files = history.items.first(where: { $0.kind == .files }) {
            history.copy(files)
            history.poll()
        }
        let kinds = history.items.map(\.kind.rawValue)
        let leaked = history.items.contains { $0.text == "hunter2" }
        let ok = !leaked && kinds.count == (steps.count - 2) && history.items.first?.kind == .files
        gestureLog.notice("selftest: итог \(ok ? "OK" : "FAIL", privacy: .public) порядок=\(kinds.joined(separator: ","), privacy: .public) пароль_сохранён=\(leaked, privacy: .public)")
        pb.releaseGlobally()
        try? FileManager.default.removeItem(at: dir)
        NSApp.terminate(nil)
    }

    /// Демо-записи для снимка панели истории: тексты, картинка и файлы из -DropwheelDemoFiles.
    static func seedClipboard(_ history: ClipboardHistory, files: [URL]) {
        let store = history.store
        store.clear(keepPinned: false)
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        store.addText("Flight SK 4012 · Bergen → Leknes, departs 08:15", source: ("com.apple.mail", "Mail"), date: ago(180))
        store.addText("brew install ffmpeg webp", source: ("com.apple.Terminal", "Terminal"), date: ago(95))
        let docs = files.filter { ["pdf", "mp4"].contains($0.pathExtension.lowercased()) }
        if !docs.isEmpty { store.addFiles(docs, source: ("com.apple.finder", "Finder"), date: ago(42)) }
        if let photo = files.first(where: { ["heic", "jpg", "png"].contains($0.pathExtension.lowercased()) }),
           let rep = NSImage(contentsOf: photo).flatMap({ $0.tiffRepresentation }).flatMap(NSBitmapImageRep.init(data:)),
           let png = rep.representation(using: .png, properties: [:]) {
            store.addImage(png: png, width: rep.pixelsWide, height: rep.pixelsHigh, source: ("com.apple.Preview", "Preview"), date: ago(12))
        }
        store.addText("Reine at dawn. Hike to Reinebringen if the weather holds — start before 6, the trail gets busy.",
                      source: ("com.apple.Notes", "Notes"), date: ago(4))
        store.addText("https://example.com/norway/lofoten-ferry-timetable", source: ("com.apple.Safari", "Safari"), date: ago(1))
        if let flight = store.items.first(where: { $0.text?.hasPrefix("Flight") == true }) { store.togglePin(flight.id) }
    }

    static var backdrop: NSWindow?

    static func showBackdrop(_ imagePath: String, at center: NSPoint) {
        // Размер — по картинке (снимок окна в точках), по умолчанию квадрат 440.
        let image = NSImage(contentsOfFile: imagePath)
        let size = image.map { $0.size.width > 0 ? $0.size : NSSize(width: 440, height: 440) } ?? NSSize(width: 440, height: 440)
        let w = NSWindow(contentRect: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
                         styleMask: .borderless, backing: .buffered, defer: false)
        // Сразу под панелями колеса и буфера (.popUpMenu): выше окон «поверх всех» других приложений.
        w.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        // Непрозрачный белый фон: в скруглённых углах снимка окна не просвечивает чужой экран.
        w.backgroundColor = .white
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        w.contentView = view
        w.orderFrontRegardless()
        backdrop = w
    }

    /// screencapture ждёт координаты с началом в левом верхнем углу главного экрана.
    static func captureScreen(of frame: NSRect, to path: String) {
        let height = NSScreen.screens.first?.frame.height ?? 0
        // Снимаем только если в этой области над нашим фоном нет ни одного чужого окна:
        // иначе в кадр попадёт содержимое других приложений.
        guard let backdrop, backdrop.isVisible else { NSLog("Dropwheel: фона нет на экране — снимок отменён"); return }
        let area = CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
        let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], CGWindowID(backdrop.windowNumber)) as? [[String: Any]] ?? []
        let pid = ProcessInfo.processInfo.processIdentifier
        let foreign = above.filter { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) != pid,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: b) else { return false }
            return bounds.intersects(area)
        }
        guard foreign.isEmpty else {
            let owners = foreign.compactMap { $0[kCGWindowOwnerName as String] as? String }
            NSLog("Dropwheel: над фоном чужие окна (\(owners.joined(separator: ", "))) — снимок отменён")
            return
        }
        let rect = "\(Int(frame.minX)),\(Int(height - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-R", rect, path]
        try? p.run()
        p.waitUntilExit()
    }

    static func save(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

extension Double { var nonZero: Double? { self == 0 ? nil : self } }
