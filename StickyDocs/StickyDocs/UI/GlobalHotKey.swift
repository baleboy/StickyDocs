import AppKit
import Carbon.HIToolbox

/// Minimal Carbon global hot key. Unlike SwiftUI's `.keyboardShortcut`, this
/// fires while any app is frontmost, which is the whole point for a menu-bar
/// app: the shortcut has to be reachable from inside whatever window is
/// currently in the way. `RegisterEventHotKey` needs no Accessibility
/// permission and works under the App Sandbox.
@MainActor
final class GlobalHotKey {

    private static let signature: OSType = 0x53544B59  // 'STKY'
    // Carbon dispatches to a C function pointer, which can't capture context,
    // so handlers are looked up by hot key id from this table.
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextId: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32

    /// - Parameters:
    ///   - keyCode: a `kVK_*` virtual key code.
    ///   - modifiers: Carbon modifier mask (`cmdKey`, `optionKey`, ...).
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.id = Self.nextId
        Self.nextId += 1

        Self.installEventHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)

        // Fails when another app already owns the combination system-wide. The
        // caller degrades to the menu item rather than treating this as fatal.
        guard status == noErr, let ref else {
            NSLog("[StickyDocs] failed to register global hot key (status \(status))")
            return nil
        }

        self.hotKeyRef = ref
        Self.handlers[id] = handler
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        let id = self.id
        Task { @MainActor in GlobalHotKey.handlers.removeValue(forKey: id) }
    }

    private static func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
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
            guard status == noErr, hotKeyID.signature == GlobalHotKey.signature else { return status }

            // Carbon delivers this on the main thread, but hop explicitly so
            // the @MainActor handler is reached through a checked path.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalHotKey.handlers[hotKeyID.id]?() }
            }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
