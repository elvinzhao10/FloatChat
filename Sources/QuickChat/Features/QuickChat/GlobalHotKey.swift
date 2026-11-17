import Carbon.HIToolbox

/// A system-wide hotkey registered with Carbon's `RegisterEventHotKey` (the same mechanism
/// ChatGPT's Electron `globalShortcut` uses). Call `unregister()` to release it.
@MainActor
final class GlobalHotKey {
    private static var handlers: [UInt32: @MainActor () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// A one-shot registration probe. Other apps' local shortcuts are not discoverable.
    static func availabilityIssue(_ shortcut: Shortcut) -> String? {
        if shortcut.keyCode == UInt32(kVK_Space), [UInt32(cmdKey), UInt32(controlKey), UInt32(cmdKey | optionKey)].contains(shortcut.carbonModifiers) {
            return "Reserved by macOS. Choose another combination."
        }
        do {
            let probe = try GlobalHotKey(shortcut) {}
            probe.unregister()
            return nil
        } catch {
            return "Unavailable for global registration. Another app may be using it."
        }
    }

    /// Registers `shortcut`; throws if the system refuses it.
    init(_ shortcut: Shortcut, handler: @escaping @MainActor () -> Void) throws {
        Self.installEventHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4350_4C53) /* 'CPLS' */, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            throw FeatureError("Couldn't register the shortcut \(shortcut.displayString) (error \(status)).",
                               recoverySuggestion: "Another app may be using it. Choose a different shortcut.")
        }
        self.ref = ref
        Self.handlers[id] = handler
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.handlers[id] = nil
    }

    #if DEBUG
    static func runAvailabilitySelfTest() -> Bool {
        let choices = [kVK_F18, kVK_F19, kVK_F20].map {
            Shortcut(keyCode: UInt32($0), carbonModifiers: UInt32(controlKey | optionKey | shiftKey))
        }
        guard let candidate = choices.first(where: { availabilityIssue($0) == nil }),
              let owner = try? GlobalHotKey(candidate, handler: {}) else { return false }
        let detectsConflict = availabilityIssue(candidate) != nil
        owner.unregister()
        let detectsRelease = availabilityIssue(candidate) == nil
        let reserved = availabilityIssue(Shortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey))) != nil
        print("Shortcut checks: registered conflict=\(detectsConflict), released=\(detectsRelease), system reserved=\(reserved)")
        return detectsConflict && detectsRelease && reserved
    }
    #endif

    private static func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            // Carbon delivers hotkey events on the main thread.
            MainActor.assumeIsolated { GlobalHotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
