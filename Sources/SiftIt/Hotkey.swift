// The shortcut that opens the search panel from any app. Carbon's hot keys need no Accessibility access, unlike a
// monitor of every key.

import AppKit
import Carbon.HIToolbox

/// A key with modifiers, as it's kept in the settings.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// NSEvent.ModifierFlags' raw value, device-independent flags only.
    var modifiers: UInt
    /// The key as typed, for showing: "Space", "K".
    var key: String

    static let standard = Shortcut(
        keyCode: UInt32(kVK_Space), modifiers: NSEvent.ModifierFlags([.shift, .command]).rawValue, key: "Space")

    private static let defaultsKey = "shortcut"

    static var saved: Shortcut {
        get {
            UserDefaults.standard.data(forKey: defaultsKey)
                .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .standard
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey) }
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// "⇧⌘Space", in the order macOS's menus use.
    var display: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key
    }

    var carbonModifiers: UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// The shortcut a key press makes, or nil for one without a modifier that could make it global.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isEmpty, flags != .shift else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: flags.rawValue, key: Shortcut.name(of: event))
    }

    init(keyCode: UInt32, modifiers: UInt, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    private static let named: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func name(of event: NSEvent) -> String {
        if let name = named[Int(event.keyCode)] { return name }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

/// One global shortcut, registered while the app runs.
@MainActor
final class Hotkey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return noErr }
                let hotkey = Unmanaged<Hotkey>.fromOpaque(context).takeUnretainedValue()
                // Carbon's events come on the main thread, from the app's run loop.
                MainActor.assumeIsolated { hotkey.action() }
                return noErr
            },
            1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// Registers the shortcut in place of the one before; false when another app has it.
    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        unregister()
        let id = EventHotKeyID(signature: OSType(0x5349_4654), id: 1)  // "SIFT"
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &reference)
        return status == noErr
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }
}
