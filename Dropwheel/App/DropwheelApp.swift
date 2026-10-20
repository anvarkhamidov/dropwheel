import AppKit
import os
import ServiceManagement

let appLog = Logger(subsystem: "local.dropwheel.app", category: "app")
import DropwheelCore
import SwiftUI

@main
struct DropwheelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Dropwheel", image: "MenuIcon") {
            MenuContent(coordinator: delegate.coordinator)
        }
        Settings {
            SettingsView(coordinator: delegate.coordinator)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var coordinator = Coordinator()
    private var onboarding: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = coordinator
        if DebugHooks.isActive { DebugHooks.run(coordinator); return }
        enableLoginItemOnFirstInstall()
        coordinator.updater.start()
        if !coordinator.settings.onboardingDone { showOnboarding() }
    }

    /// При первом запуске из /Applications один раз включаем автозапуск. Дальше решает переключатель
    /// в настройках: если его выключили, приложение само его не вернёт.
    private func enableLoginItemOnFirstInstall() {
        let defaults = UserDefaults.standard
        let installed = Bundle.main.bundlePath.hasPrefix("/Applications/")
        if installed, !defaults.bool(forKey: "loginItemOffered") {
            defaults.set(true, forKey: "loginItemOffered")
            coordinator.settings.launchAtLogin = true
        }
        appLog.notice("автозапуск: \(String(describing: SMAppService.mainApp.status), privacy: .public), путь=\(Bundle.main.bundlePath, privacy: .public)")
    }

    func showOnboarding() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(coordinator: coordinator) { [weak self] in
            self?.coordinator.settings.onboardingDone = true
            self?.onboarding?.close()
        })
        window.center()
        onboarding = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Меню в строке меню: подсказка по клавишам, ручной запуск колёс, полка, настройки.
struct MenuContent: View {
    let coordinator: Coordinator

    var body: some View {
        let s = coordinator.settings
        Text("Тяните файл и нажмите:")
        Text("\(s.convertKey.glyph)  форматы")
        Text("\(s.toolsKey.glyph)  инструменты")
        Text("\(s.actionsKey.glyph)  действия")
        Divider()
        Menu("Открыть колесо для файлов") {
            Button("Форматы…") { coordinator.openWheelFromMenu(kind: .convert) }
            Button("Инструменты…") { coordinator.openWheelFromMenu(kind: .tools) }
            Button("Действия…") { coordinator.openWheelFromMenu(kind: .actions) }
        }
        Button("Показать полку") { coordinator.shelf.show() }
        Button("Скопировать последнюю команду") {
            if let cmd = coordinator.jobs.lastCommand { copyToClipboard(cmd) }
        }
        .disabled(coordinator.jobs.lastCommand == nil)
        .help("Точная команда ffmpeg или другого инструмента из последней задачи — её можно повторить в терминале")
        if !coordinator.tools.available.contains(.ffmpeg) {
            Divider()
            Text("Нет ffmpeg: аудио и видео отключены")
        }
        Divider()
        SettingsLink { Text("Настройки…") }.keyboardShortcut(",")
        Button("Проверить обновления…") { coordinator.updater.checkForUpdates() }
            .disabled(!coordinator.updater.canCheck)
        Button("Как это работает") { (NSApp.delegate as? AppDelegate)?.showOnboarding() }
        Button("Выйти из Dropwheel") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
