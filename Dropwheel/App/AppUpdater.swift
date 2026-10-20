import AppKit
import Observation
import Sparkle

/// Обновления по воздуху через Sparkle 2. Лента и сборки лежат в GitHub Releases (SUFeedURL в Info.plist),
/// каждая сборка подписана ключом EdDSA из связки ключей разработчика (SUPublicEDKey).
///
/// Приложение живёт в строке меню и почти никогда не закрывается, поэтому «поставить при выходе»
/// означало бы «никогда». Скачанное обновление ставим сразу, как только нет активных задач:
/// Sparkle заменяет приложение и перезапускает его за секунду.
@MainActor
@Observable
final class AppUpdater: NSObject {
    /// Можно ли сейчас вручную проверить обновления (Sparkle запрещает, пока идёт проверка).
    private(set) var canCheck = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var pendingInstall: (() -> Void)?
    @ObservationIgnored private var retryTimer: Timer?
    @ObservationIgnored private let isBusy: () -> Bool

    init(isBusy: @escaping () -> Bool) {
        self.isBusy = isBusy
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    var updater: SPUUpdater { controller.updater }

    /// Запуск после старта приложения (не в демо-режиме и не в Debug: там подпись ad-hoc,
    /// и Sparkle всё равно отверг бы обновление).
    func start() {
        #if DEBUG
        return
        #else
        controller.startUpdater()
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] u, _ in
            let can = u.canCheckForUpdates
            Task { @MainActor in self?.canCheck = can }
        }
        #endif
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyInstalls: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    private func installWhenIdle() {
        guard let install = pendingInstall else { return }
        if isBusy() {
            // Идёт конвертация: перезапуск оборвал бы её. Повторим через минуту.
            retryTimer?.invalidate()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.installWhenIdle() }
            }
            return
        }
        pendingInstall = nil
        appLog.notice("обновление: ставлю скачанную версию и перезапускаюсь")
        install()
    }
}

extension AppUpdater: @MainActor SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        appLog.notice("обновление: скачана версия \(item.displayVersionString, privacy: .public)")
        pendingInstall = immediateInstallHandler
        installWhenIdle()
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        appLog.error("обновление: \(error.localizedDescription, privacy: .public)")
    }
}

extension AppUpdater: @MainActor SPUStandardUserDriverDelegate {
    /// Приложение без окна в Dock: плановые напоминания не должны выхватывать фокус.
    var supportsGentleScheduledUpdateReminders: Bool { true }
}
