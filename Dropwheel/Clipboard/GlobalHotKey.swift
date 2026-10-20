import Carbon.HIToolbox
import Foundation

/// Сочетание для истории буфера. Только с модификаторами-«аккордами», чтобы не перехватывать обычный ввод.
enum ClipboardHotKey: String, CaseIterable, Identifiable {
    case controlCommandV, optionCommandV, shiftCommandV, controlOptionV, off
    var id: String { rawValue }

    var title: String {
        switch self {
        case .controlCommandV: return "⌃⌘V"
        case .optionCommandV: return "⌥⌘V"
        case .shiftCommandV: return "⇧⌘V"
        case .controlOptionV: return "⌃⌥V"
        case .off: return "Нет"
        }
    }

    /// Carbon-модификаторы для RegisterEventHotKey.
    var carbonModifiers: UInt32? {
        switch self {
        case .controlCommandV: return UInt32(controlKey | cmdKey)
        case .optionCommandV: return UInt32(optionKey | cmdKey)
        case .shiftCommandV: return UInt32(shiftKey | cmdKey)
        case .controlOptionV: return UInt32(controlKey | optionKey)
        case .off: return nil
        }
    }
}

/// Глобальная горячая клавиша через Carbon: работает из любого приложения и не требует доступа
/// к универсальному доступу (в отличие от глобального монитора клавиатуры).
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32

    nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var nextID: UInt32 = 1
    nonisolated(unsafe) private static var handlerInstalled = false

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        Self.installHandlerOnce()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4457_4C48) /* 'DWLH' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, ref != nil else {
            appLog.error("горячая клавиша не зарегистрирована: \(status, privacy: .public)")
            return nil
        }
        Self.handlers[id] = action
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installHandlerOnce() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let action = GlobalHotKey.handlers[hotKeyID.id]
            DispatchQueue.main.async { action?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
