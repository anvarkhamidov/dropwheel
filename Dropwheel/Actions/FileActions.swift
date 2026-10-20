import AppKit
import DropwheelCore

/// Колесо действий: работает с любыми файлами и папками и не трогает содержимое.
@MainActor
enum FileActions {
    static func perform(_ action: ActionKind, files: [URL], settings: SettingsStore, shelf: FloatShelfController) {
        guard !files.isEmpty else { return }
        switch action {
        case .airdrop:
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: files) else {
                alert("AirDrop недоступен", "Включите Wi-Fi и Bluetooth и проверьте настройки AirDrop.")
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            service.perform(withItems: files)
        case .float:
            shelf.add(files)
        case .copy:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(files as [NSURL])
        case .move:
            move(files)
        case .copyPath:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
        case .terminal:
            openInTerminal(files, app: settings.terminalApp)
        }
    }

    static func move(_ files: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Переместить сюда"
        panel.message = files.count == 1 ? "Куда переместить «\(files[0].lastPathComponent)»?" : "Куда переместить \(files.count) объектов?"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        var moved: [URL] = []
        var failures: [String] = []
        for file in files {
            if file.deletingLastPathComponent().standardizedFileURL == target.standardizedFileURL { continue }
            let base = file.deletingPathExtension().lastPathComponent
            let ext = file.pathExtension
            let dest = OutputNamer.unique(in: target, base: base, ext: ext.isEmpty ? nil : ext)
            do {
                try FileManager.default.moveItem(at: file, to: dest)
                moved.append(dest)
            } catch {
                failures.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !moved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(moved) }
        if !failures.isEmpty { alert("Не всё удалось переместить", failures.joined(separator: "\n")) }
    }

    static func openInTerminal(_ files: [URL], app: TerminalApp) {
        // Папка — как есть, файл — его родительская папка. Повторы убираем.
        var dirs: [URL] = []
        for f in files {
            let isDir = (try? f.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let d = isDir ? f : f.deletingLastPathComponent()
            if !dirs.contains(d) { dirs.append(d) }
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
            alert("\(app.title) не найден", "Выберите другое приложение терминала в настройках.")
            return
        }
        NSWorkspace.shared.open(dirs, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    static func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        a.runModal()
    }
}
