import CoreState
import Foundation

/// Cancels an observation when released or cancelled.
@MainActor
public final class LinuxObservation {
    private var onCancel: (() -> Void)?

    public init(_ onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        onCancel?()
        onCancel = nil
    }

    isolated deinit {
        onCancel?()
    }
}

/// The GTK frontend's only view of application state.
///
/// The UI reads `state`, dispatches `AppAction`s through `send`, and
/// re-renders from observation callbacks; it never mutates state directly.
/// Today `ReducerStoreBinding` implements this with CoreState's reducer.
/// When the app-logic layer brings the macOS `AppStore` to Linux, an
/// `AppStore`-backed binding replaces it without UI changes:
///
/// - `state` → `AppStore.state`
/// - `send` → `AppStore.send(_:)` (which also runs persistence, terminal
///   runtime side effects and automation bookkeeping)
/// - `observe` → `AppStore`'s state publisher (`objectWillChange`/`$state`),
///   delivered on the main thread after the change lands
/// - `sessions` → `SessionRuntimeStore` (sidebar session rows, later flags)
/// - `commands` → the app-level controllers for commands that are not plain
///   reducer actions (new window with seed, navigation history, config files,
///   agent launch, process watch, Remote Access, diagnostics)
@MainActor
public protocol LinuxStoreBinding: AnyObject {
    var state: AppState { get }

    /// Dispatches an action. Returns whether state changed.
    @discardableResult
    func send(_ action: AppAction) -> Bool

    /// `handler` runs on the main thread after every state change.
    func observe(_ handler: @escaping @MainActor (AppState) -> Void) -> LinuxObservation

    var sessions: any LinuxSessionSource { get }

    var commands: any LinuxAppCommandHandling { get }
}

/// Managed-agent session data shown in the sidebar. Backed by
/// `SessionRuntimeStore` once the app-logic layer lands.
@MainActor
public protocol LinuxSessionSource: AnyObject {
    /// Sessions for a workspace in sidebar order.
    func sessions(workspaceID: UUID) -> [WorkspaceSessionStatus]
    func isFlaggedForLater(sessionID: String) -> Bool
    func setFlaggedForLater(sessionID: String, flagged: Bool)
    func pendingQuestion(sessionID: String) -> String?
    func observe(_ handler: @escaping @MainActor () -> Void) -> LinuxObservation
}

extension LinuxSessionSource {
    /// An unanswered agent question for the session (Codex's async
    /// `request_user_input_async`); nil when none is waiting.
    public func pendingQuestion(sessionID: String) -> String? { nil }
}

/// Outcome of an app-level command.
public enum LinuxCommandResult: Equatable, Sendable {
    case handled
    /// The command exists on macOS but its Linux implementation is not wired
    /// yet; the UI shows a toast instead of failing silently.
    case unavailable(String)
    case failed(String)
}

/// Commands beyond plain reducer actions. Each has a stable Toastty command
/// ID from `LinuxCommandTable`.
@MainActor
public protocol LinuxAppCommandHandling: AnyObject {
    func perform(commandID: String, windowID: UUID?) -> LinuxCommandResult
}

// MARK: - Reducer-backed implementation

/// `LinuxStoreBinding` over CoreState's `AppReducer`, with no persistence or
/// runtime side effects. Used until the real `AppStore` compiles on Linux,
/// and by tests.
@MainActor
public final class ReducerStoreBinding: LinuxStoreBinding {
    public private(set) var state: AppState
    public let sessions: any LinuxSessionSource
    public var commands: any LinuxAppCommandHandling

    private let reducer = AppReducer()
    private var observers: [UUID: @MainActor (AppState) -> Void] = [:]
    private var isNotifying = false
    private var pendingNotification = false
    /// Every dispatched action, for tests and the debug log.
    public private(set) var actionLog: [String] = []

    public init(
        state: AppState = .bootstrap(),
        sessions: (any LinuxSessionSource)? = nil,
        commands: (any LinuxAppCommandHandling)? = nil
    ) {
        self.state = state
        self.sessions = sessions ?? EmptySessionSource()
        self.commands = commands ?? UnavailableAppCommands()
    }

    @discardableResult
    public func send(_ action: AppAction) -> Bool {
        actionLog.append(action.logName)
        let changed = reducer.send(action, state: &state)
        if changed {
            notify()
        }
        return changed
    }

    /// Replaces state wholesale (restore, tests).
    public func replaceState(_ newState: AppState) {
        state = newState
        notify()
    }

    public func observe(_ handler: @escaping @MainActor (AppState) -> Void) -> LinuxObservation {
        let id = UUID()
        observers[id] = handler
        return LinuxObservation { [weak self] in
            MainActor.assumeIsolated { _ = self?.observers.removeValue(forKey: id) }
        }
    }

    private func notify() {
        // Re-entrant sends (an observer dispatching) coalesce into one more
        // pass so observers always end on the latest state.
        if isNotifying {
            pendingNotification = true
            return
        }
        isNotifying = true
        repeat {
            pendingNotification = false
            for handler in observers.values {
                handler(state)
            }
        } while pendingNotification
        isNotifying = false
    }
}

@MainActor
public final class EmptySessionSource: LinuxSessionSource {
    public init() {}
    public func sessions(workspaceID: UUID) -> [WorkspaceSessionStatus] { [] }
    public func isFlaggedForLater(sessionID: String) -> Bool { false }
    public func setFlaggedForLater(sessionID: String, flagged: Bool) {}
    public func observe(_ handler: @escaping @MainActor () -> Void) -> LinuxObservation { LinuxObservation {} }
}

@MainActor
public final class UnavailableAppCommands: LinuxAppCommandHandling {
    public init() {}
    public func perform(commandID: String, windowID: UUID?) -> LinuxCommandResult {
        .unavailable("\(LinuxCommandTable.title(commandID)) is not available on Linux yet")
    }
}
