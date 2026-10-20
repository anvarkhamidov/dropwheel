import AppKit
import Observation
import DropwheelCore

/// Связывает жест, колесо, задачи, действия и окна инструментов.
@MainActor
@Observable
final class Coordinator {
    let settings = SettingsStore()
    let jobs = JobCenter()
    @ObservationIgnored let shelf = FloatShelfController()
    @ObservationIgnored let watcher = DragWatcher()
    @ObservationIgnored private(set) var wheel: WheelController!
    @ObservationIgnored private(set) var progress: ProgressPanelController!
    @ObservationIgnored private(set) var presenter: ToolPresenter!
    @ObservationIgnored private(set) var services: FinderServices!
    @ObservationIgnored private(set) var updater: AppUpdater!

    private(set) var tools = ExternalTools.discover()
    var registry: Registry { Registry(available: tools.available) }

    init() {
        wheel = WheelController(registry: { [unowned self] in self.registry })
        progress = ProgressPanelController(center: jobs)
        updater = AppUpdater(isBusy: { [unowned self] in self.jobs.isBusy })
        presenter = ToolPresenter(coordinator: self)
        jobs.tools = { [unowned self] in self.tools }
        jobs.revealInFinder = { [unowned self] in self.settings.revealInFinder }
        settings.onToolsChanged = { [unowned self] in self.refreshTools() }
        refreshTools()

        wheel.onPick = { [unowned self] item, files in self.handle(item, files: files) }
        watcher.onTrigger = { [unowned self] flags, files, point in self.trigger(flags, files: files, at: point) }
        watcher.onDragEnded = { [unowned self] in self.wheel.dragEnded() }
        watcher.start()
        services = FinderServices(coordinator: self)
        services.register()
        // После старта run loop: прогреваем колесо, чтобы первое открытие было мгновенным.
        if DebugHooks.string("DropwheelNoPrewarm") != "1" {
            DispatchQueue.main.async { [weak self] in self?.wheel.prewarm() }
        }
    }

    func refreshTools() {
        tools = ExternalTools.discover(ffmpegOverride: settings.ffmpegPath.isEmpty ? nil : settings.ffmpegPath)
    }

    private func trigger(_ flags: NSEvent.ModifierFlags, files: [URL], at point: NSPoint) {
        // Если нажато сразу несколько модификаторов, побеждает первый по порядку колёс.
        gestureLog.notice("trigger: flags=\(flags.rawValue, privacy: .public) файлов=\(files.count, privacy: .public)")
        for key in [settings.convertKey, settings.toolsKey, settings.actionsKey] where flags.contains(key.flag) {
            guard let kind = settings.wheel(for: key) else { continue }
            if wheel.isVisible && wheel.model.kind == kind { return }
            wheel.show(kind: kind, files: files, at: point)
            return
        }
    }

    /// Открыть колесо без drag: из меню для выбранных файлов (и для проверки без мыши).
    func openWheelFromMenu(kind: WheelKind) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = kind == .actions
        panel.prompt = "Выбрать"
        panel.message = "Выберите файлы — колесо откроется для них"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let point = NSScreen.main.map { NSPoint(x: $0.visibleFrame.midX, y: $0.visibleFrame.midY) } ?? .zero
        wheel.show(kind: kind, files: panel.urls, at: point, clickMode: true)
    }

    func handle(_ item: WheelItem, files: [URL]) {
        switch item.payload {
        case .format(let option):
            jobs.convert(files, to: option)
        case .action(let action):
            FileActions.perform(action, files: files, settings: settings, shelf: shelf)
        case .tool(let tool):
            if tool.kind == .instant { runInstant(tool, files: files) } else { presenter.open(tool, files: files) }
        }
    }

    // MARK: Мгновенные инструменты

    private func runInstant(_ tool: ToolDef, files: [URL]) {
        let tools = self.tools
        switch tool.id {
        case Tools.createPDF.id:
            jobs.run("Сборка PDF", files: files) { progress in
                let dest = OutputNamer.sibling(of: files[0], ext: "pdf", suffix: "из \(files.count) изображений")
                return [try Staged.file(beside: dest) { out in
                    try ImageEngine(tools: tools).makePDF(files, output: out) { p in progress(0, p) }
                }]
            }
        case Tools.mute.id:
            jobs.run("Без звука", files: files) { progress in
                var outs: [URL] = []
                for (i, f) in files.enumerated() {
                    let dest = OutputNamer.sibling(of: f, ext: f.pathExtension, suffix: "без звука")
                    let scratch = try Scratch.dir()
                    defer { try? FileManager.default.removeItem(at: scratch) }
                    let temp = scratch.appendingPathComponent("out").appendingPathExtension(f.pathExtension)
                    try await MediaEngine(tools: tools).process(f, output: temp, args: ["-map", "0", "-map", "-0:a", "-c", "copy"]) { p in progress(i, p) }
                    outs.append(try Scratch.commit(temp, to: dest))
                }
                return outs
            }
        case Tools.extract.id:
            jobs.run("Распаковка", files: files) { progress in
                var outs: [URL] = []
                for (i, f) in files.enumerated() {
                    progress(i, nil)
                    outs.append(try await ArchiveEngine.extractBeside(f))
                }
                return outs
            }
        case Tools.readQR.id:
            readCodes(files)
        default:
            presenter.open(tool, files: files)
        }
    }

    private func readCodes(_ files: [URL]) {
        let ref = JobRef()
        // Задача стартует после возврата из run, так что ref.job уже будет заполнен.
        ref.job = jobs.run("Чтение QR", files: files, reveal: false) { progress in
            var codes: [String] = []
            for (i, f) in files.enumerated() {
                progress(i, nil)
                codes += try VisionService.readCodes(f)
            }
            let text = codes.joined(separator: "\n")
            await MainActor.run {
                ref.job?.note = codes.isEmpty ? "Коды не найдены" : "Скопировано: \(text)"
                if !codes.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            return []
        }
    }
}
