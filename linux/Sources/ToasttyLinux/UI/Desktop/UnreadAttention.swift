import CGtk
import CoreState
import Foundation

/// Which unread panels count as seen, the same rule as macOS
/// `WorkspaceView.seenUnreadPanelIDs` / `unreadClearCandidate` /
/// `unreadPanelIDsToClear` (WorkspaceView.swift is not part of the Linux
/// build): in the workspace a window shows, the focused split panel and any
/// scratchpad on screen, but only while Toastty is the active application.
public enum SeenUnreadPolicy {
    public struct Candidate: Equatable, Sendable {
        public var workspaceID: UUID
        public var panelIDs: Set<UUID>
    }

    /// macOS waits this long so panels the user only passes through on the
    /// way elsewhere stay unread.
    public static let clearDelayMilliseconds: UInt32 = 300

    public static func seenUnreadPanelIDs(in workspace: WorkspaceState) -> Set<UUID> {
        workspace.unreadPanelIDs.filter { panelID in
            if panelID == workspace.focusedPanelID {
                return true
            }
            guard case .web(let webState)? = workspace.panelState(for: panelID),
                  webState.definition == .scratchpad else {
                return false
            }
            return workspace.panelIsDisplayedInSelectedTab(panelID)
        }
    }

    public static func candidate(workspace: WorkspaceState?, appIsActive: Bool) -> Candidate? {
        guard appIsActive, let workspace else { return nil }
        let panelIDs = seenUnreadPanelIDs(in: workspace)
        guard panelIDs.isEmpty == false else { return nil }
        return Candidate(workspaceID: workspace.id, panelIDs: panelIDs)
    }

    /// Whether a click in `panelID` must send a focus action. macOS sends
    /// `focusPanel` on every mouse down in a panel (`TerminalHostView`,
    /// `BrowserPanelView`), and that action is what reads the panel's unread
    /// mark and the workspace-scoped notification count
    /// (`toastty notify` without a panel). Linux sends it only when it
    /// changes something, so clicks in an already focused, already read
    /// panel do not churn state.
    public static func clickNeedsFocusAction(workspace: WorkspaceState, panelID: UUID) -> Bool {
        if workspace.unreadWorkspaceNotificationCount > 0 { return true }
        if workspace.tabsByID.values.contains(where: { $0.unreadPanelIDs.contains(panelID) }) { return true }
        if workspace.rightAuxPanel.tabID(containingPanelID: panelID) != nil {
            return workspace.rightAuxPanel.focusedPanelID != panelID
        }
        return workspace.focusedPanelID != panelID || workspace.rightAuxPanel.focusedPanelID != nil
    }

    /// Panels from `candidate` that are still unread and still seen after the delay.
    public static func panelIDsToClear(
        currentWorkspace: WorkspaceState?,
        candidate: Candidate,
        appIsActive: Bool
    ) -> Set<UUID> {
        guard appIsActive, let currentWorkspace, currentWorkspace.id == candidate.workspaceID else { return [] }
        return candidate.panelIDs.intersection(seenUnreadPanelIDs(in: currentWorkspace))
    }
}

/// Marks panels read once the user has looked at them, like macOS
/// `WorkspaceView.scheduleSeenUnreadPanelClearIfNeeded`: when a window's
/// selected workspace shows an unread focused panel (selecting the
/// workspace, a notification arriving for the focused panel while Toastty
/// was in the background, Toastty becoming active again), it sends
/// `markPanelNotificationsRead` after `SeenUnreadPolicy.clearDelayMilliseconds`.
/// Without this, unread state on Linux only cleared on an explicit
/// `focusPanel`, so sidebar/tab unread marks and the desktop notifications
/// behind the dock badge outlived the user reading them.
@MainActor
public final class SeenUnreadClearScheduler {
    private let store: any LinuxStoreBinding
    private let isAppActive: @MainActor () -> Bool
    private let delayMilliseconds: UInt32
    private var pending: [UUID: (candidate: SeenUnreadPolicy.Candidate, source: guint)] = [:]

    public init(
        store: any LinuxStoreBinding,
        delayMilliseconds: UInt32 = SeenUnreadPolicy.clearDelayMilliseconds,
        isAppActive: @escaping @MainActor () -> Bool
    ) {
        self.store = store
        self.delayMilliseconds = delayMilliseconds
        self.isAppActive = isAppActive
    }

    /// Windows with a clear scheduled (tests).
    public var pendingWindowIDs: Set<UUID> { Set(pending.keys) }

    /// Re-evaluates every window; call on state changes and when Toastty
    /// gains or loses focus. An unchanged candidate keeps its timer, so
    /// unrelated state churn (titles, sessions) cannot postpone the clear.
    public func refresh(_ state: AppState) {
        let active = isAppActive()
        let liveWindowIDs = Set(state.windows.map(\.id))
        for windowID in pending.keys where liveWindowIDs.contains(windowID) == false {
            cancel(windowID)
        }
        for window in state.windows {
            let candidate = SeenUnreadPolicy.candidate(workspace: state.workspaceSelection(in: window.id)?.workspace, appIsActive: active)
            if let scheduled = pending[window.id], scheduled.candidate == candidate { continue }
            cancel(window.id)
            guard let candidate else { continue }
            let windowID = window.id
            let source = MainLoop.timeout(milliseconds: delayMilliseconds) { [weak self] in
                self?.fire(windowID: windowID)
                return false
            }
            pending[windowID] = (candidate, source)
        }
    }

    public func cancelAll() {
        for windowID in Array(pending.keys) { cancel(windowID) }
    }

    /// Runs a scheduled clear now (tests; the timer calls it otherwise).
    public func fire(windowID: UUID) {
        guard let scheduled = pending.removeValue(forKey: windowID) else { return }
        let state = store.state
        let panelIDs = SeenUnreadPolicy.panelIDsToClear(
            currentWorkspace: state.workspaceSelection(in: windowID)?.workspace,
            candidate: scheduled.candidate,
            appIsActive: isAppActive()
        )
        for panelID in panelIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            store.send(.markPanelNotificationsRead(workspaceID: scheduled.candidate.workspaceID, panelID: panelID))
        }
    }

    private func cancel(_ windowID: UUID) {
        guard let scheduled = pending.removeValue(forKey: windowID) else { return }
        MainLoop.cancel(scheduled.source)
    }
}

/// Desktop notifications Toastty has delivered and not yet withdrawn, with
/// the workspace/panel each one announced.
///
/// Ubuntu Dock (dash-to-dock) badges the launcher icon with the number of
/// the app's notifications still in GNOME Shell's message tray, and GNOME
/// keeps those across app (and shell) restarts until they are clicked,
/// dismissed or withdrawn. macOS has no such coupling (Notification Center
/// entries never badge the Dock), so the shared App layer never removes
/// delivered notifications. On Linux a notification whose unread mark the
/// user has cleared must be withdrawn, or the dock count only ever grows.
public struct DesktopNotificationLedger: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var identifier: String
        public var workspaceID: UUID?
        public var panelID: UUID?

        public init(identifier: String, workspaceID: UUID?, panelID: UUID?) {
            self.identifier = identifier
            self.workspaceID = workspaceID
            self.panelID = panelID
        }
    }

    public private(set) var entries: [Entry] = []

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public var identifiers: [String] { entries.map(\.identifier) }
    public var isEmpty: Bool { entries.isEmpty }

    public mutating func record(identifier: String, userInfo: [String: String]) {
        entries.removeAll { $0.identifier == identifier }
        entries.append(Entry(
            identifier: identifier,
            workspaceID: userInfo[DesktopNotificationUserInfoKey.workspaceID].flatMap(UUID.init(uuidString:)),
            panelID: userInfo[DesktopNotificationUserInfoKey.panelID].flatMap(UUID.init(uuidString:))
        ))
    }

    public mutating func remove(identifiers: [String]) {
        let removed = Set(identifiers)
        entries.removeAll { removed.contains($0.identifier) }
    }

    /// Notifications whose unread mark is gone: the panel was read (or
    /// closed), the workspace-level unread count was cleared, or the
    /// workspace no longer exists. Notifications without a workspace
    /// (nothing in Toastty tracks them as unread) stay until they are
    /// clicked, dismissed, or Toastty quits.
    public func obsoleteIdentifiers(in state: AppState) -> [String] {
        entries.filter { Self.isObsolete($0, in: state) }.map(\.identifier)
    }

    static func isObsolete(_ entry: Entry, in state: AppState) -> Bool {
        guard let workspaceID = entry.workspaceID else { return false }
        guard let workspace = state.workspacesByID[workspaceID] else { return true }
        if let panelID = entry.panelID {
            return workspace.tabsByID.values.contains { $0.unreadPanelIDs.contains(panelID) } == false
        }
        return workspace.unreadWorkspaceNotificationCount == 0
    }

    // MARK: Persistence (stale notifications from a previous run)

    public static func load(from url: URL) -> DesktopNotificationLedger? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    public func save(to url: URL) {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
