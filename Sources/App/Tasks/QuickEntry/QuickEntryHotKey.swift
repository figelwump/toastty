import AppKit
import Carbon.HIToolbox
import CoreState
import Foundation
import SwiftUI

/// The system-wide shortcut that opens the quick entry panel.
///
/// Carbon's `RegisterEventHotKey` needs no Accessibility permission, unlike
/// a global event monitor. The system delivers the key press to Toastty
/// whichever app is in front, including Toastty itself, and the press does
/// not reach the app in front.
@MainActor
final class QuickEntryHotKey {
    enum Registration: Equatable {
        case registered(QuickEntryShortcut)
        /// `tasks.toml` turns the shortcut off.
        case off
        /// The system refused it, usually because another app holds it.
        case failed(QuickEntryShortcut, OSStatus)
    }

    private static let signature: OSType = 0x5473_5145 // "TsQE"
    private static let identifier: UInt32 = 1

    private let onPress: @MainActor () -> Void
    // Released in deinit, which is not main-actor isolated. Carbon
    // references are plain pointers that any thread may release.
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?
    private(set) var registration: Registration = .off

    init(onPress: @escaping @MainActor () -> Void) {
        self.onPress = onPress
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    /// Replaces any earlier registration.
    @discardableResult
    func register(_ shortcut: QuickEntryShortcut?) -> Registration {
        unregister()
        guard let shortcut else {
            registration = .off
            return registration
        }
        let handlerStatus = installHandlerIfNeeded()
        guard handlerStatus == noErr else {
            registration = .failed(shortcut, handlerStatus)
            return registration
        }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            Self.carbonKeyCode(for: shortcut.key),
            Self.carbonModifiers(for: shortcut.modifiers),
            EventHotKeyID(signature: Self.signature, id: Self.identifier),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        if status == noErr, let reference {
            hotKeyRef = reference
            registration = .registered(shortcut)
        } else {
            registration = .failed(shortcut, status)
        }
        return registration
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        registration = .off
    }

    private func installHandlerIfNeeded() -> OSStatus {
        guard handlerRef == nil else { return noErr }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
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
                guard status == noErr,
                      hotKeyID.signature == QuickEntryHotKey.signature,
                      hotKeyID.id == QuickEntryHotKey.identifier else {
                    return OSStatus(eventNotHandledErr)
                }
                // Carbon delivers application events on the main thread.
                let hotKey = Unmanaged<QuickEntryHotKey>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated {
                    hotKey.onPress()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    // MARK: - Key mapping

    static func carbonModifiers(for modifiers: QuickEntryShortcut.Modifiers) -> UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        return UInt32(flags)
    }

    /// The virtual key code of the key that types this character on a US
    /// keyboard. Every key that ``QuickEntryShortcut`` accepts has one.
    static func carbonKeyCode(for key: QuickEntryShortcut.Key) -> UInt32 {
        let code: Int
        switch key {
        case .space: code = kVK_Space
        case .return: code = kVK_Return
        case .tab: code = kVK_Tab
        case .function(let number): code = functionKeyCodes[number - 1]
        case .character(let character): code = characterKeyCodes[character] ?? kVK_ANSI_T
        }
        return UInt32(code)
    }

    private static let functionKeyCodes = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    static let characterKeyCodes: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
        "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
    ]
}

extension QuickEntryShortcut {
    /// The same keys as a menu shortcut. File ▸ New Task… shows it; while
    /// the global shortcut is registered, the system takes the key press
    /// before the menu sees it, so the panel opens once.
    var keyboardShortcut: KeyboardShortcut {
        var eventModifiers: SwiftUI.EventModifiers = []
        if modifiers.contains(.command) { eventModifiers.insert(.command) }
        if modifiers.contains(.option) { eventModifiers.insert(.option) }
        if modifiers.contains(.control) { eventModifiers.insert(.control) }
        if modifiers.contains(.shift) { eventModifiers.insert(.shift) }
        let keyEquivalent: KeyEquivalent
        switch key {
        case .character(let character): keyEquivalent = KeyEquivalent(character)
        case .space: keyEquivalent = .space
        case .return: keyEquivalent = .return
        case .tab: keyEquivalent = .tab
        case .function(let number):
            let scalar = UnicodeScalar(UInt32(NSF1FunctionKey + number - 1)) ?? " "
            keyEquivalent = KeyEquivalent(Character(scalar))
        }
        return KeyboardShortcut(keyEquivalent, modifiers: eventModifiers)
    }
}
