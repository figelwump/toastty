import AppKit

@MainActor
enum WindowMovementSuppression {
    struct Options: OptionSet {
        let rawValue: Int

        static let movable = Options(rawValue: 1 << 0)
        static let backgroundDragging = Options(rawValue: 1 << 1)
        static let resizing = Options(rawValue: 1 << 2)

        static let movement: Options = [.movable, .backgroundDragging]
        static let all: Options = [.movement, .resizing]
    }

    private struct Token: Hashable {
        let owner: ObjectIdentifier
        let reason: String
    }

    private struct SuppressedWindowState {
        weak var window: NSWindow?
        let originalIsMovable: Bool
        let originalIsMovableByWindowBackground: Bool
        let originalAllowsResizing: Bool
        var tokens: [Token: Options]
    }

    private static var statesByWindowID: [ObjectIdentifier: SuppressedWindowState] = [:]
    private static var windowIDByToken: [Token: ObjectIdentifier] = [:]

    static func suppress(
        window: NSWindow?,
        owner: AnyObject,
        reason: String,
        options: Options = .all
    ) {
        suppress(window: window, ownerID: ObjectIdentifier(owner), reason: reason, options: options)
    }

    static func restore(owner: AnyObject, reason: String) {
        restore(ownerID: ObjectIdentifier(owner), reason: reason)
    }

    static func restore(ownerID: ObjectIdentifier, reason: String) {
        let token = Token(owner: ownerID, reason: reason)
        guard let windowID = windowIDByToken.removeValue(forKey: token),
              var state = statesByWindowID[windowID] else {
            return
        }

        state.tokens.removeValue(forKey: token)
        guard state.tokens.isEmpty else {
            statesByWindowID[windowID] = state
            if let window = state.window {
                applySuppression(to: window, state: state)
            }
            return
        }

        if let window = state.window {
            restoreWindow(window, to: state)
        }
        statesByWindowID.removeValue(forKey: windowID)
    }

    static func resetForTesting() {
        for (windowID, state) in statesByWindowID {
            if let window = state.window {
                restoreWindow(window, to: state)
            }
            statesByWindowID.removeValue(forKey: windowID)
        }
        windowIDByToken.removeAll()
    }

    private static func suppress(
        window: NSWindow?,
        ownerID: ObjectIdentifier,
        reason: String,
        options: Options
    ) {
        guard let window else { return }

        let token = Token(owner: ownerID, reason: reason)
        let windowID = ObjectIdentifier(window)
        if let existingWindowID = windowIDByToken[token], existingWindowID != windowID {
            restore(ownerID: ownerID, reason: reason)
        }

        if var state = statesByWindowID[windowID] {
            guard state.window != nil else {
                removeState(for: windowID)
                return suppress(window: window, ownerID: ownerID, reason: reason, options: options)
            }
            state.tokens[token] = options
            statesByWindowID[windowID] = state
            windowIDByToken[token] = windowID
            applySuppression(to: window, state: state)
        } else {
            let state = SuppressedWindowState(
                window: window,
                originalIsMovable: window.isMovable,
                originalIsMovableByWindowBackground: window.isMovableByWindowBackground,
                originalAllowsResizing: window.styleMask.contains(.resizable),
                tokens: [token: options]
            )
            statesByWindowID[windowID] = state
            windowIDByToken[token] = windowID
            applySuppression(to: window, state: state)
        }
    }

    private static func removeState(for windowID: ObjectIdentifier) {
        guard let state = statesByWindowID.removeValue(forKey: windowID) else { return }
        for token in state.tokens.keys {
            windowIDByToken.removeValue(forKey: token)
        }
    }

    private static func applySuppression(to window: NSWindow, state: SuppressedWindowState) {
        let options = state.tokens.values.reduce(Options()) { partialResult, options in
            partialResult.union(options)
        }

        window.isMovable = options.contains(.movable) ? false : state.originalIsMovable
        window.isMovableByWindowBackground = options.contains(.backgroundDragging)
            ? false
            : state.originalIsMovableByWindowBackground
        if options.contains(.resizing) {
            window.styleMask.remove(.resizable)
        } else if state.originalAllowsResizing {
            window.styleMask.insert(.resizable)
        } else {
            window.styleMask.remove(.resizable)
        }
    }

    private static func restoreWindow(_ window: NSWindow, to state: SuppressedWindowState) {
        window.isMovable = state.originalIsMovable
        window.isMovableByWindowBackground = state.originalIsMovableByWindowBackground
        if state.originalAllowsResizing {
            window.styleMask.insert(.resizable)
        } else {
            window.styleMask.remove(.resizable)
        }
    }
}
