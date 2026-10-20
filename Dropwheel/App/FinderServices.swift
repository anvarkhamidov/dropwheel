import AppKit
import DropwheelCore

/// Быстрые действия Finder (правый клик → «Быстрые действия» / «Службы»).
/// Для тех, кто привык к правому клику: то же колесо, но без жеста, у курсора.
/// Регистрация — NSServices в Info.plist (project.yml), сюда приходят вызовы.
@MainActor
final class FinderServices: NSObject {
    private unowned let coordinator: Coordinator

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        super.init()
    }

    func register() {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    @objc func openConvertWheel(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        open(.convert, pboard, error)
    }

    @objc func openToolsWheel(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        open(.tools, pboard, error)
    }

    @objc func openActionsWheel(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        open(.actions, pboard, error)
    }

    private func open(_ kind: WheelKind, _ pboard: NSPasteboard, _ error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let files = DragWatcher.fileURLs(in: pboard)
        guard !files.isEmpty else {
            error.pointee = "Dropwheel: не получены файлы" as NSString
            return
        }
        gestureLog.notice("finder service: kind=\(kind.rawValue, privacy: .public) файлов=\(files.count, privacy: .public)")
        // Режим клика: выбор мышью или стрелками и Return, Esc — закрыть.
        coordinator.wheel.show(kind: kind, files: files, at: NSEvent.mouseLocation, clickMode: true)
    }
}
