import Carbon.HIToolbox
import Foundation

@MainActor
final class GlobalShortcutService {
    static let registrationOptions = UInt32(kEventHotKeyExclusive)
    static let defaultKeyCode = UInt32(kVK_ANSI_2)
    static let defaultModifiers = UInt32(cmdKey | optionKey)

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handler: (() -> Void)?

    func registerDefault(handler: @escaping () -> Void) throws {
        self.handler = handler

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard installStatus == noErr else {
            throw GlobalShortcutError.registrationFailed(status: installStatus)
        }

        let hotKeyID = EventHotKeyID(
            signature: OSType(0x43555452), // “CUTR”
            id: 1
        )
        let registerStatus = RegisterEventHotKey(
            Self.defaultKeyCode,
            Self.defaultModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            Self.registrationOptions,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            unregister()
            throw GlobalShortcutError.registrationFailed(status: registerStatus)
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        handler = nil
    }

    private func handleHotKey() {
        handler?()
    }

    private static let eventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return noErr }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr else { return status }

        let service = Unmanaged<GlobalShortcutService>
            .fromOpaque(userData)
            .takeUnretainedValue()
        Task { @MainActor in
            service.handleHotKey()
        }
        return noErr
    }
}

enum GlobalShortcutError: LocalizedError {
    case registrationFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .registrationFailed:
            "无法注册全局截图快捷键 ⌥⌘2，可能与其他应用冲突。"
        }
    }
}
