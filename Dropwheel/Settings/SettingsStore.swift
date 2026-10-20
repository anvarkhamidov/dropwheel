import AppKit
import Observation
import DropwheelCore
import ServiceManagement

/// Модификатор, который открывает колесо. Отдельные клавиши-буквы не подходят:
/// во время drag приложение-источник держит клавиатуру, видны только модификаторы.
enum TriggerKey: String, CaseIterable, Identifiable {
    case shift, command, control, option, function
    var id: String { rawValue }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .command: return .command
        case .control: return .control
        case .option: return .option
        case .function: return .function
        }
    }

    var title: String {
        switch self {
        case .shift: return "⇧ Shift"
        case .command: return "⌘ Command"
        case .control: return "⌃ Control"
        case .option: return "⌥ Option"
        case .function: return "fn Fn"
        }
    }

    var glyph: String {
        switch self {
        case .shift: return "⇧"
        case .command: return "⌘"
        case .control: return "⌃"
        case .option: return "⌥"
        case .function: return "fn"
        }
    }
}

enum TerminalApp: String, CaseIterable, Identifiable {
    case terminal, iterm
    var id: String { rawValue }
    var title: String { self == .terminal ? "Терминал" : "iTerm2" }
    var bundleID: String { self == .terminal ? "com.apple.Terminal" : "com.googlecode.iterm2" }
}

@MainActor
@Observable
final class SettingsStore {
    private let defaults = UserDefaults.standard

    var convertKey: TriggerKey { didSet { save("convertKey", convertKey.rawValue) } }
    var toolsKey: TriggerKey { didSet { save("toolsKey", toolsKey.rawValue) } }
    var actionsKey: TriggerKey { didSet { save("actionsKey", actionsKey.rawValue) } }
    var terminalApp: TerminalApp { didSet { save("terminalApp", terminalApp.rawValue) } }
    var revealInFinder: Bool { didSet { save("revealInFinder", revealInFinder) } }
    var ffmpegPath: String { didSet { save("ffmpegPath", ffmpegPath); onToolsChanged?() } }
    var onboardingDone: Bool { didSet { save("onboardingDone", onboardingDone) } }

    /// Колбэк для пересчёта доступных внешних инструментов.
    @ObservationIgnored var onToolsChanged: (() -> Void)?

    init() {
        convertKey = TriggerKey(rawValue: defaults.string(forKey: "convertKey") ?? "") ?? .shift
        toolsKey = TriggerKey(rawValue: defaults.string(forKey: "toolsKey") ?? "") ?? .command
        actionsKey = TriggerKey(rawValue: defaults.string(forKey: "actionsKey") ?? "") ?? .control
        terminalApp = TerminalApp(rawValue: defaults.string(forKey: "terminalApp") ?? "") ?? .terminal
        revealInFinder = defaults.object(forKey: "revealInFinder") as? Bool ?? true
        ffmpegPath = defaults.string(forKey: "ffmpegPath") ?? ""
        onboardingDone = defaults.bool(forKey: "onboardingDone")
    }

    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }

    /// Какое колесо открывает этот модификатор.
    func wheel(for key: TriggerKey) -> WheelKind? {
        if key == convertKey { return .convert }
        if key == toolsKey { return .tools }
        if key == actionsKey { return .actions }
        return nil
    }

    var hasConflict: Bool { Set([convertKey, toolsKey, actionsKey]).count < 3 }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                appLog.error("автозапуск не изменён: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
