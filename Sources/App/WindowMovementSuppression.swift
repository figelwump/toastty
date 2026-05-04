import AppKit

@MainActor
enum WindowMovementSuppression {
    private struct Token: Hashable {
        let owner: ObjectIdentifier
        let reason: String
    }

    private struct SuppressedWindowState {
        weak var window: NSWindow?
        let originalIsMovable: Bool
        var tokens: Set<Token>
    }

    private static var statesByWindowID: [ObjectIdentifier: SuppressedWindowState] = [:]
    private static var windowIDByToken: [Token: ObjectIdentifier] = [:]

    static func suppress(window: NSWindow?, owner: AnyObject, reason: String) {
        suppress(window: window, ownerID: ObjectIdentifier(owner), reason: reason)
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

        state.tokens.remove(token)
        guard state.tokens.isEmpty else {
            statesByWindowID[windowID] = state
            return
        }

        if let window = state.window {
            window.isMovable = state.originalIsMovable
        }
        statesByWindowID.removeValue(forKey: windowID)
    }

    static func resetForTesting() {
        for (windowID, state) in statesByWindowID {
            if let window = state.window {
                window.isMovable = state.originalIsMovable
            }
            statesByWindowID.removeValue(forKey: windowID)
        }
        windowIDByToken.removeAll()
    }

    private static func suppress(window: NSWindow?, ownerID: ObjectIdentifier, reason: String) {
        guard let window else { return }

        let token = Token(owner: ownerID, reason: reason)
        let windowID = ObjectIdentifier(window)
        if let existingWindowID = windowIDByToken[token], existingWindowID != windowID {
            restore(ownerID: ownerID, reason: reason)
        } else if windowIDByToken[token] == windowID {
            return
        }

        if var state = statesByWindowID[windowID] {
            guard state.window != nil else {
                removeState(for: windowID)
                return suppress(window: window, ownerID: ownerID, reason: reason)
            }
            state.tokens.insert(token)
            statesByWindowID[windowID] = state
        } else {
            statesByWindowID[windowID] = SuppressedWindowState(
                window: window,
                originalIsMovable: window.isMovable,
                tokens: [token]
            )
        }

        windowIDByToken[token] = windowID
        if window.isMovable {
            window.isMovable = false
        }
    }

    private static func removeState(for windowID: ObjectIdentifier) {
        guard let state = statesByWindowID.removeValue(forKey: windowID) else { return }
        for token in state.tokens {
            windowIDByToken.removeValue(forKey: token)
        }
    }
}
