import AppKit
import Carbon.HIToolbox
import Foundation
#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit

extension TerminalHostView {
    enum GhosttyMouseCursorStyle: Equatable {
        case `default`
        case grabIdle
        case grabActive
        case horizontalText
        case verticalText
        case link
        case resizeLeft
        case resizeRight
        case resizeUp
        case resizeDown
        case resizeUpDown
        case resizeLeftRight
        case contextMenu
        case crosshair
        case operationNotAllowed

        var nsCursor: NSCursor {
            switch self {
            case .default:
                return .arrow
            case .grabIdle:
                return .openHand
            case .grabActive:
                return .closedHand
            case .horizontalText:
                return .iBeam
            case .verticalText:
                return .iBeamCursorForVerticalLayout
            case .link:
                return .pointingHand
            case .resizeLeft:
                if #available(macOS 15.0, *) {
                    return .columnResize(directions: .left)
                }
                return .resizeLeft
            case .resizeRight:
                if #available(macOS 15.0, *) {
                    return .columnResize(directions: .right)
                }
                return .resizeRight
            case .resizeUp:
                if #available(macOS 15.0, *) {
                    return .rowResize(directions: .up)
                }
                return .resizeUp
            case .resizeDown:
                if #available(macOS 15.0, *) {
                    return .rowResize(directions: .down)
                }
                return .resizeDown
            case .resizeUpDown:
                if #available(macOS 15.0, *) {
                    return .rowResize
                }
                return .resizeUpDown
            case .resizeLeftRight:
                if #available(macOS 15.0, *) {
                    return .columnResize
                }
                return .resizeLeftRight
            case .contextMenu:
                return .contextualMenu
            case .crosshair:
                return .crosshair
            case .operationNotAllowed:
                return .operationNotAllowed
            }
        }
    }

    struct GhosttySurfaceHooks: Sendable {
        var setFocus: @Sendable (ghostty_surface_t, Bool) -> Void
        var setOcclusion: @Sendable (ghostty_surface_t, Bool) -> Void
        var refresh: @Sendable (ghostty_surface_t) -> Void
        var sendMousePosition: @Sendable (ghostty_surface_t, Double, Double, ghostty_input_mods_e) -> Void
        var sendMouseButton: @Sendable (
            ghostty_surface_t,
            ghostty_input_mouse_state_e,
            ghostty_input_mouse_button_e,
            ghostty_input_mods_e
        ) -> Bool
        var setMousePressure: @Sendable (ghostty_surface_t, UInt32, Double) -> Void
        var isMouseCaptured: @Sendable (ghostty_surface_t) -> Bool
        var keyTranslationMods: @Sendable (ghostty_surface_t, ghostty_input_mods_e) -> ghostty_input_mods_e
        var sendKey: @Sendable (ghostty_surface_t, ghostty_input_key_s) -> Bool
        var setPreedit: @Sendable (ghostty_surface_t, UnsafePointer<CChar>?, uintptr_t) -> Void
        var sendText: @Sendable (ghostty_surface_t, UnsafePointer<CChar>, uintptr_t) -> Void

        init(
            setFocus: @escaping @Sendable (ghostty_surface_t, Bool) -> Void,
            setOcclusion: @escaping @Sendable (ghostty_surface_t, Bool) -> Void,
            refresh: @escaping @Sendable (ghostty_surface_t) -> Void,
            sendMousePosition: @escaping @Sendable (ghostty_surface_t, Double, Double, ghostty_input_mods_e) -> Void = { surface, x, y, mods in
                ghostty_surface_mouse_pos(surface, x, y, mods)
            },
            sendMouseButton: @escaping @Sendable (
                ghostty_surface_t,
                ghostty_input_mouse_state_e,
                ghostty_input_mouse_button_e,
                ghostty_input_mods_e
            ) -> Bool = { surface, state, button, mods in
                ghostty_surface_mouse_button(surface, state, button, mods)
            },
            setMousePressure: @escaping @Sendable (ghostty_surface_t, UInt32, Double) -> Void = { surface, stage, pressure in
                ghostty_surface_mouse_pressure(surface, stage, pressure)
            },
            isMouseCaptured: @escaping @Sendable (ghostty_surface_t) -> Bool = { surface in
                ghostty_surface_mouse_captured(surface)
            },
            keyTranslationMods: @escaping @Sendable (ghostty_surface_t, ghostty_input_mods_e) -> ghostty_input_mods_e = { surface, mods in
                ghostty_surface_key_translation_mods(surface, mods)
            },
            sendKey: @escaping @Sendable (ghostty_surface_t, ghostty_input_key_s) -> Bool = { surface, keyEvent in
                ghostty_surface_key(surface, keyEvent)
            },
            setPreedit: @escaping @Sendable (ghostty_surface_t, UnsafePointer<CChar>?, uintptr_t) -> Void = { surface, text, length in
                ghostty_surface_preedit(surface, text, length)
            },
            sendText: @escaping @Sendable (ghostty_surface_t, UnsafePointer<CChar>, uintptr_t) -> Void = { surface, text, length in
                ghostty_surface_text(surface, text, length)
            }
        ) {
            self.setFocus = setFocus
            self.setOcclusion = setOcclusion
            self.refresh = refresh
            self.sendMousePosition = sendMousePosition
            self.sendMouseButton = sendMouseButton
            self.setMousePressure = setMousePressure
            self.isMouseCaptured = isMouseCaptured
            self.keyTranslationMods = keyTranslationMods
            self.sendKey = sendKey
            self.setPreedit = setPreedit
            self.sendText = sendText
        }

        static let live = GhosttySurfaceHooks(
            setFocus: { surface, focused in
                ghostty_surface_set_focus(surface, focused)
            },
            setOcclusion: { surface, visible in
                ghostty_surface_set_occlusion(surface, visible)
            },
            refresh: { surface in
                ghostty_surface_refresh(surface)
            },
            sendMousePosition: { surface, x, y, mods in
                ghostty_surface_mouse_pos(surface, x, y, mods)
            },
            sendMouseButton: { surface, state, button, mods in
                ghostty_surface_mouse_button(surface, state, button, mods)
            },
            setMousePressure: { surface, stage, pressure in
                ghostty_surface_mouse_pressure(surface, stage, pressure)
            },
            isMouseCaptured: { surface in
                ghostty_surface_mouse_captured(surface)
            },
            keyTranslationMods: { surface, mods in
                ghostty_surface_key_translation_mods(surface, mods)
            },
            sendKey: { surface, keyEvent in
                ghostty_surface_key(surface, keyEvent)
            },
            setPreedit: { surface, text, length in
                ghostty_surface_preedit(surface, text, length)
            },
            sendText: { surface, text, length in
                ghostty_surface_text(surface, text, length)
            }
        )
    }

    static func ghosttyLinkHoverModifierFlags(
        for flags: NSEvent.ModifierFlags
    ) -> NSEvent.ModifierFlags {
        guard flags.contains(.command), flags.contains(.shift) else {
            return flags
        }

        let rightShiftMask = NSEvent.ModifierFlags(rawValue: UInt(NX_DEVICERSHIFTKEYMASK))
        return flags.subtracting([.shift, rightShiftMask])
    }

    static func ghosttyText(
        eventType: NSEvent.EventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        characterProvider: () -> String?,
        translatedCharacterProvider: () -> String?
    ) -> String? {
        // FlagsChanged events (modifier-only) have no character data;
        // accessing .characters on them triggers an NSEvent assertion.
        guard eventType == .keyDown || eventType == .keyUp else { return nil }
        guard let characters = characterProvider() else { return nil }

        // Bare Tab should stay text so shells keep ordinary completion behavior.
        // Modified Tab must flow through the keycode+modifier path so Ghostty can
        // encode reverse-tab and enhanced keyboard protocol sequences correctly.
        if Int(keyCode) == Int(kVK_Tab) {
            let relevantModifiers = modifierFlags.intersection([
                .shift,
                .control,
                .option,
                .command,
            ])
            return relevantModifiers.isEmpty ? characters : nil
        }

        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return translatedCharacterProvider()
            }

            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }

    static func ghosttyUnshiftedCodepoint(
        eventType: NSEvent.EventType,
        characterProvider: () -> String?
    ) -> UInt32 {
        switch eventType {
        case .keyDown, .keyUp:
            return characterProvider()?.unicodeScalars.first?.value ?? 0
        default:
            return 0
        }
    }

    static func isLocalInterruptKey(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?
    ) -> Bool {
        localInterruptKind(
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            charactersIgnoringModifiers: charactersIgnoringModifiers
        ) != nil
    }

    static func localInterruptKind(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?
    ) -> TerminalLocalInterruptKind? {
        if keyCode == 53 {
            return .escape
        }

        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control),
              charactersIgnoringModifiers?.lowercased() == "c" else {
            return nil
        }
        return .controlC
    }

    static func isShiftModifierKeyCode(_ keyCode: UInt16) -> Bool {
        keyCode == 0x38 || keyCode == 0x3C
    }

    static func ghosttyMouseCursorStyle(
        for shape: ghostty_action_mouse_shape_e
    ) -> GhosttyMouseCursorStyle? {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT:
            return .default
        case GHOSTTY_MOUSE_SHAPE_TEXT:
            return .horizontalText
        case GHOSTTY_MOUSE_SHAPE_GRAB:
            return .grabIdle
        case GHOSTTY_MOUSE_SHAPE_GRABBING:
            return .grabActive
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            return .link
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE:
            return .resizeLeft
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE:
            return .resizeRight
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE:
            return .resizeUp
        case GHOSTTY_MOUSE_SHAPE_S_RESIZE:
            return .resizeDown
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
            return .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
            return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
            return .verticalText
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU:
            return .contextMenu
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
            return .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED:
            return .operationNotAllowed
        default:
            return nil
        }
    }
}
#endif
