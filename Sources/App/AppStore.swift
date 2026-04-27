import AppKit
import CoreState
import Foundation

enum TabNavigationDirection: Equatable {
    case previous
    case next
}

struct WindowCommandSelection {
    let windowID: UUID
    let window: WindowState
    let workspace: WorkspaceState
}

struct PendingWorkspaceCloseRequest: Equatable {
    let windowID: UUID
    let workspaceID: UUID
}

struct PendingWorkspaceRenameRequest: Equatable {
    let windowID: UUID
    let workspaceID: UUID
}

struct PendingWorkspaceTabRenameRequest: Equatable {
    let windowID: UUID
    let workspaceID: UUID
    let tabID: UUID
}

struct PendingSidebarSessionFlashRequest: Equatable {
    let requestID: UUID
    let windowID: UUID
    let workspaceID: UUID
    let panelID: UUID?
}

struct PendingPanelFlashRequest: Equatable {
    let requestID: UUID
    let windowID: UUID
    let workspaceID: UUID
    let panelID: UUID
}

struct PendingBrowserLocationFocusRequest: Equatable {
    let requestID: UUID
    let windowID: UUID
    let workspaceID: UUID
    let panelID: UUID
}

private struct NextActiveCycleAnchor: Equatable {
    let windowID: UUID
    let workspaceID: UUID
    let selectedTabID: UUID
    let focusedPanelID: UUID?
}

private enum NextActiveCycleSegment: String, Equatable {
    case workingForward = "fallback_working"
    case later = "fallback_later"
    case workingWrapped = "fallback_working_wrapped"
}

private struct NextActiveCycleEntry: Equatable {
    let panelID: UUID
    let segment: NextActiveCycleSegment
}

private struct NextActiveCycleState: Equatable {
    let anchor: NextActiveCycleAnchor
    let entries: [NextActiveCycleEntry]
    let lastReturnedIndex: Int
}

struct BrowserPanelCreateRequest: Equatable, Sendable {
    static let defaultPlacement: WebPanelPlacement = .rightPanel

    var initialURL: String?
    var placementOverride: WebPanelPlacement?

    init(
        initialURL: String? = nil,
        placementOverride: WebPanelPlacement? = nil
    ) {
        self.initialURL = WebPanelState.normalizedInitialURL(initialURL)
        self.placementOverride = placementOverride
    }

    var resolvedPlacement: WebPanelPlacement {
        placementOverride ?? Self.defaultPlacement
    }
}

struct LocalDocumentPanelCreateRequest: Equatable, Sendable {
    static let defaultPlacement: WebPanelPlacement = .rightPanel

    var filePath: String
    var lineNumber: Int?
    var placementOverride: WebPanelPlacement?
    var formatOverride: LocalDocumentFormat?

    init(
        filePath: String,
        lineNumber: Int? = nil,
        placementOverride: WebPanelPlacement? = nil,
        formatOverride: LocalDocumentFormat? = nil
    ) {
        self.filePath = filePath
        self.lineNumber = lineNumber.flatMap { $0 > 0 ? $0 : nil }
        self.placementOverride = placementOverride
        self.formatOverride = formatOverride
    }

    var resolvedPlacement: WebPanelPlacement {
        placementOverride ?? Self.defaultPlacement
    }
}

enum LocalDocumentPanelOpenOutcome: Equatable {
    case opened(panelID: UUID)
    case focusedExisting(panelID: UUID)

    var panelID: UUID {
        switch self {
        case .opened(let panelID), .focusedExisting(let panelID):
            return panelID
        }
    }
}

struct ScratchpadPanelSetContentRequest: Equatable, Sendable {
    var sessionID: String
    var title: String?
    var content: String
    var expectedRevision: Int?

    init(
        sessionID: String,
        title: String? = nil,
        content: String,
        expectedRevision: Int? = nil
    ) {
        self.sessionID = sessionID
        self.title = WebPanelState.normalizedTitle(title)
        self.content = content
        self.expectedRevision = expectedRevision
    }
}

struct ScratchpadPanelSetContentOutcome: Equatable, Sendable {
    let windowID: UUID
    let workspaceID: UUID
    let panelID: UUID
    let documentID: UUID
    let revision: Int
    let created: Bool
}

enum ScratchpadPanelError: LocalizedError, Equatable {
    case missingSession(String)
    case missingSourcePanel(UUID)
    case sourcePanelIsNotTerminal(UUID)
    case createPanelFailed
    case updatePanelFailed(UUID)
    case missingScratchpadState(UUID)
    case missingDocument(UUID)

    var errorDescription: String? {
        switch self {
        case .missingSession(let sessionID):
            return "active session does not exist: \(sessionID)"
        case .missingSourcePanel(let panelID):
            return "source terminal panel does not exist: \(panelID.uuidString)"
        case .sourcePanelIsNotTerminal(let panelID):
            return "source panel is not a terminal panel: \(panelID.uuidString)"
        case .createPanelFailed:
            return "scratchpad panel could not be created"
        case .updatePanelFailed(let panelID):
            return "scratchpad panel could not be updated: \(panelID.uuidString)"
        case .missingScratchpadState(let panelID):
            return "scratchpad panel has no scratchpad state: \(panelID.uuidString)"
        case .missingDocument(let documentID):
            return "scratchpad document is missing: \(documentID.uuidString)"
        }
    }
}

struct FocusedBrowserPanelCommandSelection: Equatable {
    let windowID: UUID
    let workspaceID: UUID
    let panelID: UUID
}

struct FocusedLocalDocumentPanelCommandSelection: Equatable {
    let windowID: UUID
    let workspaceID: UUID
    let panelID: UUID
}

enum FocusedScaleCommandTarget: Equatable {
    case terminal(windowID: UUID)
    case markdown(windowID: UUID)
    case browser(windowID: UUID, panelID: UUID)

    var windowID: UUID {
        switch self {
        case .terminal(let windowID), .markdown(let windowID), .browser(let windowID, _):
            return windowID
        }
    }

    var increaseMenuTitle: String {
        switch self {
        case .browser:
            return "Zoom In"
        case .terminal, .markdown:
            return "Increase Text Size"
        }
    }

    var decreaseMenuTitle: String {
        switch self {
        case .browser:
            return "Zoom Out"
        case .terminal, .markdown:
            return "Decrease Text Size"
        }
    }

    var resetMenuTitle: String {
        switch self {
        case .browser:
            return "Actual Size"
        case .terminal, .markdown:
            return "Reset Text Size"
        }
    }
}

private enum WorkspaceCommandTarget {
    case existingWindow(UUID)
    case newWindow
}

@MainActor
final class AppStore: ObservableObject {
    typealias ActionAppliedObserver = @MainActor (AppAction, AppState, AppState) -> Void
    typealias CommandCreateWindowFrameProvider = @MainActor () -> CGRectCodable?
    typealias WindowActivationHandler = @MainActor (UUID) -> Void
    private static let newWindowCascadeOffset: Double = 30
    static let nextUnreadOrActionRequiredFallbackStatusKinds: Set<SessionStatusKind> = [
        .needsApproval,
        .error,
    ]
    static let nextUnreadOrWorkingFallbackStatusKinds: Set<SessionStatusKind> = [.working]

    @Published private(set) var state: AppState
    /// Persisted compatibility flag that switches windows into the wider
    /// sidebar layout once managed session-status UI has been used at least
    /// once. It originally tracked agent launches, but process-watch rows
    /// should opt into the same expanded session-status treatment.
    @Published private(set) var hasEverLaunchedAgent: Bool
    @Published private(set) var askBeforeQuitting: Bool
    @Published private(set) var urlRoutingPreferences = URLRoutingPreferences()
    @Published private(set) var localDocumentRoutingPreferences = LocalDocumentRoutingPreferences()

    /// Set by workspace rename commands; the sidebar in the target window
    /// observes this to enter inline-rename mode for the target workspace.
    @Published var pendingRenameWorkspaceRequest: PendingWorkspaceRenameRequest?
    /// Set by tab rename commands; the selected workspace view in the target
    /// window observes this to enter inline-rename mode for the target tab.
    @Published var pendingRenameWorkspaceTabRequest: PendingWorkspaceTabRenameRequest?
    @Published var pendingCloseWorkspaceRequest: PendingWorkspaceCloseRequest?
    /// Set by exhausted navigation commands so the target sidebar can briefly
    /// pulse the currently selected session row, or the workspace row when no
    /// session row is visible.
    @Published var pendingSidebarSessionFlashRequest: PendingSidebarSessionFlashRequest?
    /// Set by explicit panel navigation so the target workspace view can briefly
    /// pulse the destination terminal panel.
    @Published var pendingPanelFlashRequest: PendingPanelFlashRequest?
    /// Set by blank browser creation so the target panel can focus its
    /// location field once the browser chrome is visible.
    @Published var pendingBrowserLocationFocusRequest: PendingBrowserLocationFocusRequest?

    private let reducer = AppReducer()
    private let persistUserSettings: Bool
    private let commandCreateWindowFrameProvider: CommandCreateWindowFrameProvider
    private let windowActivationHandler: WindowActivationHandler
    private var actionAppliedObservers: [UUID: ActionAppliedObserver] = [:]
    private var nextActiveCycleState: NextActiveCycleState?

    init(
        state: AppState = .bootstrap(),
        persistTerminalFontPreference: Bool = true,
        initialHasEverLaunchedAgent: Bool = false,
        initialAskBeforeQuitting: Bool = true,
        commandCreateWindowFrameProvider: @escaping CommandCreateWindowFrameProvider = AppStore.currentCommandCreateWindowFrame,
        windowActivationHandler: @escaping WindowActivationHandler = AppStore.activateWindowInAppKit
    ) {
        self.state = state
        hasEverLaunchedAgent = initialHasEverLaunchedAgent
        askBeforeQuitting = initialAskBeforeQuitting
        // This flag suppresses all UserDefaults-backed writes in tests and automation runs.
        persistUserSettings = persistTerminalFontPreference
        self.commandCreateWindowFrameProvider = commandCreateWindowFrameProvider
        self.windowActivationHandler = windowActivationHandler
    }

    @discardableResult
    func send(_ action: AppAction) -> Bool {
        let actionName = action.logName
        ToasttyLog.debug(
            "Dispatching app action",
            category: .store,
            metadata: ["action": actionName]
        )
        var next = state
        let previousState = state
        guard reducer.send(action, state: &next) else {
            ToasttyLog.warning(
                "Reducer rejected app action",
                category: .store,
                metadata: ["action": actionName]
            )
            return false
        }
        state = next
        prunePendingCommandRequests()
        let observers = Array(actionAppliedObservers.values)
        for observer in observers {
            observer(action, previousState, next)
        }
        ToasttyLog.debug(
            "Applied app action",
            category: .store,
            metadata: [
                "action": actionName,
                "selected_window_id": state.selectedWindowID?.uuidString ?? "<none>",
            ]
        )
        return true
    }

    func replaceState(_ state: AppState) {
        self.state = state
        nextActiveCycleState = nil
    }

    func window(id windowID: UUID) -> WindowState? {
        state.window(id: windowID)
    }

    func selectedWorkspaceID(in windowID: UUID) -> UUID? {
        state.selectedWorkspaceID(in: windowID)
    }

    func selectedWorkspace(in windowID: UUID) -> WorkspaceState? {
        state.workspaceSelection(in: windowID)?.workspace
    }

    @discardableResult
    func selectWorkspace(
        windowID: UUID,
        workspaceID: UUID,
        preferringUnreadSessionPanelIn sessionRuntimeStore: SessionRuntimeStore?
    ) -> Bool {
        let previousWorkspaceID = selectedWorkspaceID(in: windowID)
        guard send(.selectWorkspace(windowID: windowID, workspaceID: workspaceID)) else {
            return false
        }

        guard previousWorkspaceID != workspaceID,
              let sessionRuntimeStore,
              let workspace = state.workspacesByID[workspaceID],
              let preferredPanelID = sessionRuntimeStore.preferredUnreadStatusPanelID(in: workspace) else {
            return true
        }

        _ = send(.focusPanel(workspaceID: workspaceID, panelID: preferredPanelID))
        return true
    }

    func commandWindowID(preferredWindowID: UUID?) -> UUID? {
        guard case .existingWindow(let windowID)? = createWorkspaceCommandTarget(preferredWindowID: preferredWindowID) else {
            return nil
        }
        return windowID
    }

    func commandSelection(preferredWindowID: UUID?) -> WindowCommandSelection? {
        if let preferredWindowID {
            // A focused scene/window should be authoritative. If SwiftUI is still
            // tearing it down, disable the command rather than rerouting it to
            // whichever window happens to be globally selected next.
            guard let selection = state.workspaceSelection(in: preferredWindowID) else {
                return nil
            }
            return WindowCommandSelection(
                windowID: selection.windowID,
                window: selection.window,
                workspace: selection.workspace
            )
        }

        guard let selection = state.selectedWorkspaceSelection() else {
            return nil
        }

        return WindowCommandSelection(
            windowID: selection.windowID,
            window: selection.window,
            workspace: selection.workspace
        )
    }

    func canCreateWorkspaceFromCommand(preferredWindowID: UUID?) -> Bool {
        createWorkspaceCommandTarget(preferredWindowID: preferredWindowID) != nil
    }

    func preferredLocalDocumentOpenDirectoryURL(preferredWindowID: UUID?) -> URL? {
        guard let selection = commandSelection(preferredWindowID: preferredWindowID),
              let focusedPanelID = selection.workspace.focusedPanelID,
              selection.workspace.slotID(containingPanelID: focusedPanelID) != nil,
              case .terminal(let terminalState)? = selection.workspace.panels[focusedPanelID],
              let cwd = terminalState.expectedProcessWorkingDirectory else {
            return nil
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        // The picker should follow the terminal's live cwd, not a restored
        // launch seed that may no longer reflect the shell's current location.
        return URL(fileURLWithPath: cwd, isDirectory: true)
    }

    func focusedBrowserPanelSelection(
        preferredWindowID: UUID?
    ) -> FocusedBrowserPanelCommandSelection? {
        guard let selection = commandSelection(preferredWindowID: preferredWindowID),
              let focusedPanel = Self.focusedCommandPanel(in: selection.workspace),
              case .web(let webState) = focusedPanel.panelState,
              webState.definition == .browser else {
            return nil
        }

        return FocusedBrowserPanelCommandSelection(
            windowID: selection.windowID,
            workspaceID: selection.workspace.id,
            panelID: focusedPanel.panelID
        )
    }

    func focusedLocalDocumentPanelSelection(
        preferredWindowID: UUID?
    ) -> FocusedLocalDocumentPanelCommandSelection? {
        guard let selection = commandSelection(preferredWindowID: preferredWindowID),
              let focusedPanel = Self.focusedCommandPanel(in: selection.workspace),
              case .web(let webState) = focusedPanel.panelState,
              webState.definition == .localDocument else {
            return nil
        }

        return FocusedLocalDocumentPanelCommandSelection(
            windowID: selection.windowID,
            workspaceID: selection.workspace.id,
            panelID: focusedPanel.panelID
        )
    }

    func focusedScaleCommandTarget(
        preferredWindowID: UUID?
    ) -> FocusedScaleCommandTarget? {
        guard let selection = commandSelection(preferredWindowID: preferredWindowID),
              let focusedPanel = Self.focusedCommandPanel(in: selection.workspace) else {
            return nil
        }

        switch focusedPanel.panelState {
        case .terminal:
            return .terminal(windowID: selection.windowID)
        case .web(let webState):
            switch webState.definition {
            case .localDocument:
                return .markdown(windowID: selection.windowID)
            case .browser:
                return .browser(windowID: selection.windowID, panelID: focusedPanel.panelID)
            case .scratchpad, .diff:
                return nil
            }
        }
    }

    @discardableResult
    func createWorkspaceTabFromCommand(preferredWindowID: UUID?) -> Bool {
        guard let selection = commandSelection(preferredWindowID: preferredWindowID) else {
            return false
        }

        return send(
            .createWorkspaceTab(
                workspaceID: selection.workspace.id,
                seed: windowLaunchSeed(from: selection)
            )
        )
    }

    @discardableResult
    func createBrowserPanel(
        workspaceID: UUID,
        request: BrowserPanelCreateRequest
    ) -> Bool {
        guard let existingWorkspace = state.workspacesByID[workspaceID] else {
            return false
        }

        let existingPanelIDs = Set(existingWorkspace.allPanelsByID.keys)
        let shouldRequestLocationFocus = request.initialURL == nil

        guard send(
            .createWebPanel(
                workspaceID: workspaceID,
                panel: WebPanelState(
                    definition: .browser,
                    initialURL: request.initialURL
                ),
                placement: request.resolvedPlacement
            )
        ) else {
            return false
        }

        guard shouldRequestLocationFocus,
              let selection = state.workspaceSelection(containingWorkspaceID: workspaceID),
              let createdPanelID = createdBrowserPanelID(
                  in: selection.workspace,
                  previousPanelIDs: existingPanelIDs
              ) else {
            return true
        }

        pendingBrowserLocationFocusRequest = PendingBrowserLocationFocusRequest(
            requestID: UUID(),
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            panelID: createdPanelID
        )
        return true
    }

    @discardableResult
    func createBrowserPanelFromCommand(
        preferredWindowID: UUID?,
        request: BrowserPanelCreateRequest
    ) -> Bool {
        guard let selection = commandSelection(preferredWindowID: preferredWindowID) else {
            return false
        }

        return createBrowserPanel(
            workspaceID: selection.workspace.id,
            request: request
        )
    }

    @discardableResult
    func createLocalDocumentPanel(
        workspaceID: UUID,
        request: LocalDocumentPanelCreateRequest
    ) -> Bool {
        createLocalDocumentPanelOutcome(
            workspaceID: workspaceID,
            request: request
        ) != nil
    }

    func createLocalDocumentPanelOutcome(
        workspaceID: UUID,
        request: LocalDocumentPanelCreateRequest
    ) -> LocalDocumentPanelOpenOutcome? {
        guard let workspace = state.workspacesByID[workspaceID],
              let resolvedLocalDocument = Self.resolvedLocalDocument(
                  request.filePath,
                  formatOverride: request.formatOverride
              ) else {
            return nil
        }

        if let existingPanelID = existingLocalDocumentPanelID(
            in: workspace,
            normalizedFilePath: resolvedLocalDocument.normalizedFilePath
        ) {
            if request.resolvedPlacement == .rightPanel,
               let existingTabID = workspace.rightAuxPanelTabID(containingPanelID: existingPanelID) {
                if workspace.rightAuxPanel.activeTabID != existingTabID ||
                    workspace.rightAuxPanel.isVisible == false ||
                    workspace.rightAuxPanel.focusedPanelID != existingPanelID {
                    guard send(
                        .selectRightAuxPanelTab(
                            workspaceID: workspaceID,
                            tabID: existingTabID,
                            focus: true
                        )
                    ) else {
                        return nil
                    }
                }
            } else {
                guard focusPanel(containing: existingPanelID) else {
                    return nil
                }
            }
            return .focusedExisting(panelID: existingPanelID)
        }

        let existingPanelIDs = Set(workspace.allPanelsByID.keys)
        let displayName = Self.localDocumentDisplayName(for: resolvedLocalDocument.normalizedFilePath)
        guard send(
            .createWebPanel(
                workspaceID: workspaceID,
                panel: WebPanelState(
                    definition: .localDocument,
                    title: displayName,
                    localDocument: LocalDocumentState(
                        filePath: resolvedLocalDocument.normalizedFilePath,
                        format: resolvedLocalDocument.format
                    )
                ),
                placement: request.resolvedPlacement
            )
        ) else {
            return nil
        }

        guard let selection = state.workspaceSelection(containingWorkspaceID: workspaceID),
              let panelID = createdLocalDocumentPanelID(
                  in: selection.workspace,
                  previousPanelIDs: existingPanelIDs
              ) else {
            return nil
        }

        return .opened(panelID: panelID)
    }

    @discardableResult
    func createLocalDocumentPanelFromCommand(
        preferredWindowID: UUID?,
        request: LocalDocumentPanelCreateRequest
    ) -> Bool {
        createLocalDocumentPanelFromCommandOutcome(
            preferredWindowID: preferredWindowID,
            request: request
        ) != nil
    }

    func createLocalDocumentPanelFromCommandOutcome(
        preferredWindowID: UUID?,
        request: LocalDocumentPanelCreateRequest
    ) -> LocalDocumentPanelOpenOutcome? {
        guard let selection = commandSelection(preferredWindowID: preferredWindowID) else {
            return nil
        }

        return createLocalDocumentPanelOutcome(
            workspaceID: selection.workspace.id,
            request: request
        )
    }

    func setScratchpadContentForSession(
        request: ScratchpadPanelSetContentRequest,
        sessionRuntimeStore: SessionRuntimeStore,
        documentStore: ScratchpadDocumentStore
    ) throws -> ScratchpadPanelSetContentOutcome {
        guard let session = sessionRuntimeStore.sessionRegistry.activeSession(sessionID: request.sessionID) else {
            throw ScratchpadPanelError.missingSession(request.sessionID)
        }

        let sourcePanelID = session.panelID
        guard let sourceSelection = state.workspaceSelection(containingPanelID: sourcePanelID) else {
            throw ScratchpadPanelError.missingSourcePanel(sourcePanelID)
        }
        guard case .terminal = sourceSelection.workspace.panelState(for: sourcePanelID) else {
            throw ScratchpadPanelError.sourcePanelIsNotTerminal(sourcePanelID)
        }

        let sessionLink = ScratchpadSessionLink(
            sessionID: session.sessionID,
            agent: session.agent,
            sourcePanelID: sourcePanelID,
            sourceWorkspaceID: sourceSelection.workspaceID,
            repoRoot: session.repoRoot,
            cwd: session.cwd,
            displayTitle: session.displayTitleOverride,
            startedAt: session.startedAt
        )

        if let existing = linkedScratchpadPanel(sessionID: session.sessionID) {
            guard let scratchpad = existing.webState.scratchpad else {
                throw ScratchpadPanelError.missingScratchpadState(existing.panelID)
            }
            let document = try documentStore.replaceContent(
                documentID: scratchpad.documentID,
                title: request.title,
                content: request.content,
                expectedRevision: request.expectedRevision,
                sessionLink: sessionLink
            )
            let nextScratchpad = ScratchpadState(
                documentID: document.documentID,
                sessionLink: sessionLink,
                revision: document.revision
            )
            guard send(
                .updateScratchpadPanelState(
                    panelID: existing.panelID,
                    scratchpad: nextScratchpad,
                    title: request.title
                )
            ) else {
                throw ScratchpadPanelError.updatePanelFailed(existing.panelID)
            }
            markScratchpadUpdatedIfUnfocused(
                workspaceID: existing.workspaceID,
                panelID: existing.panelID
            )
            return ScratchpadPanelSetContentOutcome(
                windowID: existing.windowID,
                workspaceID: existing.workspaceID,
                panelID: existing.panelID,
                documentID: document.documentID,
                revision: document.revision,
                created: false
            )
        }

        if let expectedRevision = request.expectedRevision,
           expectedRevision != 0 {
            throw ScratchpadDocumentStoreError.staleRevision(
                expectedRevision: expectedRevision,
                currentRevision: 0
            )
        }

        let document = try documentStore.createDocument(
            title: request.title,
            content: request.content,
            sessionLink: sessionLink
        )
        let scratchpad = ScratchpadState(
            documentID: document.documentID,
            sessionLink: sessionLink,
            revision: document.revision
        )

        guard focusPanel(containing: sourcePanelID) else {
            throw ScratchpadPanelError.missingSourcePanel(sourcePanelID)
        }
        guard let focusedSourceSelection = state.workspaceSelection(containingPanelID: sourcePanelID) else {
            throw ScratchpadPanelError.missingSourcePanel(sourcePanelID)
        }

        let previousPanelIDs = Set(focusedSourceSelection.workspace.allPanelsByID.keys)
        guard send(
            .createWebPanel(
                workspaceID: focusedSourceSelection.workspaceID,
                panel: WebPanelState(
                    definition: .scratchpad,
                    title: document.title,
                    scratchpad: scratchpad
                ),
                placement: .rightPanel
            )
        ) else {
            throw ScratchpadPanelError.createPanelFailed
        }

        guard let createdSelection = state.workspaceSelection(containingWorkspaceID: focusedSourceSelection.workspaceID),
              let panelID = createdScratchpadPanelID(
                  in: createdSelection.workspace,
                  previousPanelIDs: previousPanelIDs
              ) else {
            throw ScratchpadPanelError.createPanelFailed
        }

        _ = focusPanel(containing: sourcePanelID)
        markScratchpadUpdatedIfUnfocused(
            workspaceID: createdSelection.workspaceID,
            panelID: panelID
        )

        return ScratchpadPanelSetContentOutcome(
            windowID: createdSelection.windowID,
            workspaceID: createdSelection.workspaceID,
            panelID: panelID,
            documentID: document.documentID,
            revision: document.revision,
            created: true
        )
    }

    @discardableResult
    func showScratchpadForCurrentSession(
        preferredWindowID: UUID?,
        sessionRuntimeStore: SessionRuntimeStore,
        documentStore: ScratchpadDocumentStore
    ) -> Bool {
        guard let selection = commandSelection(preferredWindowID: preferredWindowID),
              let focusedPanelID = selection.workspace.focusedPanelID,
              let session = sessionRuntimeStore.sessionRegistry.activeSession(for: focusedPanelID),
              case .terminal = selection.workspace.panelState(for: focusedPanelID) else {
            return false
        }

        if let existing = linkedScratchpadPanel(sessionID: session.sessionID) {
            return focusPanel(containing: existing.panelID)
        }

        if let selectedTabID = selection.workspace.resolvedSelectedTabID,
           let selectedTab = selection.workspace.tab(id: selectedTabID),
           let closedRecord = selectedTab.recentlyClosedPanels.last,
           case .web(let webState) = closedRecord.panelState,
           webState.definition == .scratchpad,
           webState.scratchpad?.sessionLink?.sessionID == session.sessionID {
            return send(.reopenLastClosedPanel(workspaceID: selection.workspace.id))
        }

        let sessionLink = ScratchpadSessionLink(
            sessionID: session.sessionID,
            agent: session.agent,
            sourcePanelID: focusedPanelID,
            sourceWorkspaceID: selection.workspace.id,
            repoRoot: session.repoRoot,
            cwd: session.cwd,
            displayTitle: session.displayTitleOverride,
            startedAt: session.startedAt
        )
        let document: ScratchpadDocument
        do {
            document = try documentStore.createDocument(
                title: nil,
                content: "",
                sessionLink: sessionLink
            )
        } catch {
            return false
        }

        return send(
            .createWebPanel(
                workspaceID: selection.workspace.id,
                panel: WebPanelState(
                    definition: .scratchpad,
                    title: document.title,
                    scratchpad: ScratchpadState(
                        documentID: document.documentID,
                        sessionLink: sessionLink,
                        revision: document.revision
                    )
                ),
                placement: .rightPanel
            )
        )
    }

    func canFocusNextUnreadOrActivePanelFromCommand(
        preferredWindowID: UUID?,
        sessionRuntimeStore: SessionRuntimeStore?
    ) -> Bool {
        nextUnreadOrActivePanelTarget(
            preferredWindowID: preferredWindowID,
            sessionRuntimeStore: sessionRuntimeStore,
            updatingCycleState: false
        ) != nil
    }

    @discardableResult
    func focusNextUnreadOrActivePanelFromCommand(
        preferredWindowID: UUID?,
        sessionRuntimeStore: SessionRuntimeStore?
    ) -> Bool {
        guard let selection = commandSelection(preferredWindowID: preferredWindowID) else {
            return false
        }
        guard let target = nextUnreadOrActivePanelTarget(
            preferredWindowID: preferredWindowID,
            sessionRuntimeStore: sessionRuntimeStore
        ) else {
            requestSidebarFlashForExhaustedUnreadOrActiveJump(
                selection: selection
            )
            return false
        }
        return focusPanelTarget(target, flashPanelOnSuccess: true)
    }

    @discardableResult
    func selectWorkspaceTabFromCommand(preferredWindowID: UUID?, shortcutNumber: Int) -> Bool {
        guard shortcutNumber > 0 else { return false }
        guard let workspace = commandSelection(preferredWindowID: preferredWindowID)?.workspace else {
            return false
        }
        let tabIndex = shortcutNumber - 1
        let orderedTabs = workspace.orderedTabs
        guard orderedTabs.indices.contains(tabIndex) else { return false }
        let targetTabID = orderedTabs[tabIndex].id
        if workspace.resolvedSelectedTabID == targetTabID {
            return true
        }
        return send(.selectWorkspaceTab(workspaceID: workspace.id, tabID: targetTabID))
    }

    @discardableResult
    func selectAdjacentWorkspaceTab(preferredWindowID: UUID?, direction: TabNavigationDirection) -> Bool {
        guard let workspace = commandSelection(preferredWindowID: preferredWindowID)?.workspace else {
            return false
        }
        let tabs = workspace.orderedTabs
        guard tabs.count > 1 else { return false }
        guard let selectedID = workspace.resolvedSelectedTabID,
              let currentIndex = tabs.firstIndex(where: { $0.id == selectedID }) else {
            return false
        }
        let nextIndex: Int
        switch direction {
        case .previous:
            nextIndex = currentIndex > 0 ? currentIndex - 1 : tabs.count - 1
        case .next:
            nextIndex = currentIndex < tabs.count - 1 ? currentIndex + 1 : 0
        }
        return send(.selectWorkspaceTab(workspaceID: workspace.id, tabID: tabs[nextIndex].id))
    }

    @discardableResult
    func createWindowFromCommand(preferredWindowID: UUID?) -> Bool {
        let selection = commandSelection(preferredWindowID: preferredWindowID)
        return send(
            .createWindow(
                seed: windowLaunchSeed(from: selection),
                initialFrame: commandCreateWindowFrame(cascadingFromSourceWindow: selection != nil)
            )
        )
    }

    @discardableResult
    func createWorkspaceFromCommand(preferredWindowID: UUID?) -> Bool {
        guard let target = createWorkspaceCommandTarget(preferredWindowID: preferredWindowID) else {
            return false
        }

        switch target {
        case .existingWindow(let windowID):
            return send(.createWorkspace(windowID: windowID, title: nil, activate: true))
        case .newWindow:
            return send(
                .createWindow(
                    seed: nil,
                    initialFrame: commandCreateWindowFrame(cascadingFromSourceWindow: false)
                )
            )
        }
    }

    @discardableResult
    func renameSelectedWorkspaceFromCommand(preferredWindowID: UUID?) -> Bool {
        guard let selection = commandSelection(preferredWindowID: preferredWindowID) else { return false }
        pendingRenameWorkspaceRequest = PendingWorkspaceRenameRequest(
            windowID: selection.windowID,
            workspaceID: selection.workspace.id
        )
        return true
    }

    func canRenameSelectedWorkspaceTabFromCommand(preferredWindowID: UUID?) -> Bool {
        guard let workspace = commandSelection(preferredWindowID: preferredWindowID)?.workspace else { return false }
        guard let selectedTabID = workspace.resolvedSelectedTabID else {
            return false
        }
        return workspace.tab(id: selectedTabID) != nil
    }

    @discardableResult
    func renameSelectedWorkspaceTabFromCommand(preferredWindowID: UUID?) -> Bool {
        guard let selection = commandSelection(preferredWindowID: preferredWindowID) else { return false }
        let workspace = selection.workspace
        guard let selectedTabID = workspace.resolvedSelectedTabID,
              workspace.tab(id: selectedTabID) != nil else {
            return false
        }
        pendingRenameWorkspaceTabRequest = PendingWorkspaceTabRenameRequest(
            windowID: selection.windowID,
            workspaceID: workspace.id,
            tabID: selectedTabID
        )
        return true
    }

    @discardableResult
    func requestWorkspaceClose(workspaceID: UUID) -> Bool {
        guard let selection = state.workspaceSelection(containingWorkspaceID: workspaceID) else { return false }
        return requestWorkspaceClose(
            windowID: selection.windowID,
            workspaceID: selection.workspaceID
        )
    }

    @discardableResult
    func closeSelectedWorkspaceFromCommand(preferredWindowID: UUID?) -> Bool {
        guard let selection = commandSelection(preferredWindowID: preferredWindowID) else { return false }
        return requestWorkspaceClose(
            windowID: selection.windowID,
            workspaceID: selection.workspace.id
        )
    }

    func consumePendingWorkspaceCloseRequest(
        windowID: UUID
    ) -> PendingWorkspaceCloseRequest? {
        guard let request = pendingCloseWorkspaceRequest,
              request.windowID == windowID else { return nil }
        pendingCloseWorkspaceRequest = nil
        return request
    }

    func consumePendingWorkspaceRenameRequest(
        windowID: UUID
    ) -> PendingWorkspaceRenameRequest? {
        guard let request = pendingRenameWorkspaceRequest,
              request.windowID == windowID else { return nil }
        pendingRenameWorkspaceRequest = nil
        return request
    }

    func consumePendingWorkspaceTabRenameRequest(
        windowID: UUID
    ) -> PendingWorkspaceTabRenameRequest? {
        guard let request = pendingRenameWorkspaceTabRequest,
              request.windowID == windowID else { return nil }
        pendingRenameWorkspaceTabRequest = nil
        return request
    }

    func consumePendingSidebarSessionFlashRequest(
        windowID: UUID,
        requestID: UUID
    ) -> PendingSidebarSessionFlashRequest? {
        guard let request = pendingSidebarSessionFlashRequest,
              request.windowID == windowID,
              request.requestID == requestID else { return nil }
        pendingSidebarSessionFlashRequest = nil
        return request
    }

    func consumePendingPanelFlashRequest(
        windowID: UUID,
        requestID: UUID
    ) -> PendingPanelFlashRequest? {
        guard let request = pendingPanelFlashRequest,
              request.windowID == windowID,
              request.requestID == requestID else { return nil }
        pendingPanelFlashRequest = nil
        return request
    }

    func consumePendingBrowserLocationFocusRequest(
        windowID: UUID
    ) -> PendingBrowserLocationFocusRequest? {
        guard let request = pendingBrowserLocationFocusRequest,
              request.windowID == windowID else { return nil }
        pendingBrowserLocationFocusRequest = nil
        return request
    }

    @discardableResult
    func focusExplicitlyNavigatedPanel(
        windowID: UUID,
        workspaceID: UUID,
        panelID: UUID
    ) -> Bool {
        focusPanel(
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID,
            flashPanelOnSuccess: true
        )
    }

    @discardableResult
    func focusDroppedImagePanel(
        windowID: UUID,
        workspaceID: UUID,
        panelID: UUID
    ) -> Bool {
        focusPanel(
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID,
            flashPanelOnSuccess: false,
            alwaysActivateWindow: true
        )
    }

    @discardableResult
    func focusPanel(containing panelID: UUID) -> Bool {
        guard let selection = state.workspaceSelection(containingPanelID: panelID) else {
            return false
        }

        return focusPanel(
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            panelID: panelID,
            flashPanelOnSuccess: false
        )
    }

    @discardableResult
    func confirmWorkspaceClose(windowID: UUID, workspaceID: UUID) -> Bool {
        let request = PendingWorkspaceCloseRequest(windowID: windowID, workspaceID: workspaceID)
        if pendingCloseWorkspaceRequest == request {
            pendingCloseWorkspaceRequest = nil
        }
        guard let selection = state.workspaceSelection(containingWorkspaceID: workspaceID),
              selection.windowID == windowID else { return false }
        let didCloseWorkspace = send(.closeWorkspace(workspaceID: workspaceID))
        if didCloseWorkspace, pendingRenameWorkspaceRequest?.workspaceID == workspaceID {
            pendingRenameWorkspaceRequest = nil
        }
        return didCloseWorkspace
    }

    private func prunePendingCommandRequests() {
        if let request = pendingRenameWorkspaceRequest,
           pendingRenameWorkspaceRequestIsValid(request) == false {
            pendingRenameWorkspaceRequest = nil
        }

        if let request = pendingRenameWorkspaceTabRequest,
           pendingRenameWorkspaceTabRequestIsValid(request) == false {
            pendingRenameWorkspaceTabRequest = nil
        }

        if let request = pendingCloseWorkspaceRequest,
           pendingWorkspaceCloseRequestIsValid(request) == false {
            pendingCloseWorkspaceRequest = nil
        }

        if let request = pendingSidebarSessionFlashRequest,
           pendingSidebarSessionFlashRequestIsValid(request) == false {
            pendingSidebarSessionFlashRequest = nil
        }

        if let request = pendingPanelFlashRequest,
           pendingPanelFlashRequestIsValid(request) == false {
            pendingPanelFlashRequest = nil
        }

        if let request = pendingBrowserLocationFocusRequest,
           pendingBrowserLocationFocusRequestIsValid(request) == false {
            pendingBrowserLocationFocusRequest = nil
        }
    }

    private func pendingRenameWorkspaceRequestIsValid(_ request: PendingWorkspaceRenameRequest) -> Bool {
        pendingWorkspaceRequestExists(windowID: request.windowID, workspaceID: request.workspaceID)
    }

    private func pendingRenameWorkspaceTabRequestIsValid(_ request: PendingWorkspaceTabRenameRequest) -> Bool {
        guard pendingWorkspaceRequestExists(windowID: request.windowID, workspaceID: request.workspaceID),
              let workspace = state.workspacesByID[request.workspaceID] else {
            return false
        }
        return workspace.tab(id: request.tabID) != nil
    }

    private func pendingWorkspaceCloseRequestIsValid(_ request: PendingWorkspaceCloseRequest) -> Bool {
        pendingWorkspaceRequestExists(windowID: request.windowID, workspaceID: request.workspaceID)
    }

    private func pendingSidebarSessionFlashRequestIsValid(
        _ request: PendingSidebarSessionFlashRequest
    ) -> Bool {
        guard pendingWorkspaceRequestExists(windowID: request.windowID, workspaceID: request.workspaceID),
              let workspace = state.workspacesByID[request.workspaceID] else {
            return false
        }
        guard let panelID = request.panelID else {
            return true
        }
        return workspace.panelState(for: panelID) != nil
    }

    private func pendingPanelFlashRequestIsValid(_ request: PendingPanelFlashRequest) -> Bool {
        guard pendingWorkspaceRequestExists(windowID: request.windowID, workspaceID: request.workspaceID),
              let workspace = state.workspacesByID[request.workspaceID] else {
            return false
        }
        return workspace.panelState(for: request.panelID) != nil
    }

    private func pendingBrowserLocationFocusRequestIsValid(
        _ request: PendingBrowserLocationFocusRequest
    ) -> Bool {
        guard pendingWorkspaceRequestExists(windowID: request.windowID, workspaceID: request.workspaceID),
              let workspace = state.workspacesByID[request.workspaceID],
              case .web(let webState)? = workspace.panelState(for: request.panelID) else {
            return false
        }
        return webState.definition == .browser
    }

    private func pendingWorkspaceRequestExists(windowID: UUID, workspaceID: UUID) -> Bool {
        guard let window = state.window(id: windowID),
              window.workspaceIDs.contains(workspaceID),
              state.workspacesByID[workspaceID] != nil else {
            return false
        }
        return true
    }

    var selectedWindow: WindowState? {
        guard let selectedWindowID = state.selectedWindowID else { return nil }
        return state.window(id: selectedWindowID)
    }

    var selectedWorkspace: WorkspaceState? {
        state.selectedWorkspaceSelection()?.workspace
    }

    @discardableResult
    func addActionAppliedObserver(_ observer: @escaping ActionAppliedObserver) -> UUID {
        let token = UUID()
        actionAppliedObservers[token] = observer
        return token
    }

    func removeActionAppliedObserver(_ token: UUID) {
        actionAppliedObservers.removeValue(forKey: token)
    }

    func recordSessionStatusSidebarExpansionEligibility() {
        guard hasEverLaunchedAgent == false else { return }
        hasEverLaunchedAgent = true
        guard persistUserSettings else { return }
        ToasttySettingsStore.persistHasEverLaunchedAgent(true)
    }

    func recordSuccessfulAgentLaunch() {
        recordSessionStatusSidebarExpansionEligibility()
    }

    func setAskBeforeQuitting(_ askBeforeQuitting: Bool) {
        guard self.askBeforeQuitting != askBeforeQuitting else { return }
        self.askBeforeQuitting = askBeforeQuitting
        guard persistUserSettings else { return }
        ToasttySettingsStore.persistAskBeforeQuitting(askBeforeQuitting)
    }

    func setURLRoutingPreferences(_ preferences: URLRoutingPreferences) {
        urlRoutingPreferences = preferences
    }

    func setLocalDocumentRoutingPreferences(_ preferences: LocalDocumentRoutingPreferences) {
        localDocumentRoutingPreferences = preferences
    }

    @discardableResult
    func openURLInBrowser(
        preferredWindowID: UUID?,
        url: URL,
        placement: URLBrowserOpenPlacement
    ) -> Bool {
        createBrowserPanelFromCommand(
            preferredWindowID: preferredWindowID,
            request: BrowserPanelCreateRequest(
                initialURL: url.absoluteString,
                placementOverride: placement.webPanelPlacement
            )
        )
    }

    private func createWorkspaceCommandTarget(preferredWindowID: UUID?) -> WorkspaceCommandTarget? {
        if let preferredWindowID {
            guard state.window(id: preferredWindowID) != nil else {
                return state.windows.isEmpty ? .newWindow : nil
            }
            return .existingWindow(preferredWindowID)
        }

        if let selectedWindowID = state.selectedWindowID,
           state.window(id: selectedWindowID) != nil {
            return .existingWindow(selectedWindowID)
        }

        if let firstWindowID = state.windows.first?.id {
            return .existingWindow(firstWindowID)
        }

        return .newWindow
    }

    private func nextUnreadOrActivePanelTarget(
        preferredWindowID: UUID?,
        sessionRuntimeStore: SessionRuntimeStore?,
        updatingCycleState: Bool = true
    ) -> PanelNavigationTarget? {
        guard let selection = commandSelection(preferredWindowID: preferredWindowID),
              let selectedTabID = selection.workspace.resolvedSelectedTabID else {
            return nil
        }

        if let unreadTarget = state.nextUnreadPanel(
            fromWindowID: selection.windowID,
            workspaceID: selection.workspace.id,
            tabID: selectedTabID,
            focusedPanelID: selection.workspace.focusedPanelID
        ) {
            if updatingCycleState {
                nextActiveCycleState = nil
            }
            logNextUnreadOrActivePanelResolution(
                selection: selection,
                selectedTabID: selectedTabID,
                resolution: "unread",
                target: unreadTarget,
                sessionRuntimeStore: sessionRuntimeStore,
                cycleResetReason: "unread_preemption"
            )
            return unreadTarget
        }

        guard let sessionRuntimeStore else {
            if updatingCycleState {
                nextActiveCycleState = nil
            }
            logNextUnreadOrActivePanelResolution(
                selection: selection,
                selectedTabID: selectedTabID,
                resolution: "none",
                target: nil,
                sessionRuntimeStore: nil,
                cycleResetReason: "no_session_runtime_store"
            )
            return nil
        }

        let attentionPanelIDs = sessionRuntimeStore.activePanelIDs(
            matching: Self.nextUnreadOrActionRequiredFallbackStatusKinds
        )
        if let target = nextUnreadOrActiveFallbackTarget(
            selection: selection,
            selectedTabID: selectedTabID,
            matchingPanelIDs: attentionPanelIDs
        ) {
            if updatingCycleState {
                nextActiveCycleState = nil
            }
            logNextUnreadOrActivePanelResolution(
                selection: selection,
                selectedTabID: selectedTabID,
                resolution: "fallback_attention",
                target: target,
                sessionRuntimeStore: sessionRuntimeStore,
                cycleResetReason: "attention_preemption"
            )
            return target
        }

        let activeCycleResolution = nextUnreadOrActiveCycleTarget(
            selection: selection,
            selectedTabID: selectedTabID,
            sessionRuntimeStore: sessionRuntimeStore,
            updatingCycleState: updatingCycleState
        )
        logNextUnreadOrActivePanelResolution(
            selection: selection,
            selectedTabID: selectedTabID,
            resolution: activeCycleResolution.resolution,
            target: activeCycleResolution.target,
            sessionRuntimeStore: sessionRuntimeStore,
            cycleResetReason: activeCycleResolution.cycleResetReason
        )
        return activeCycleResolution.target
    }

    private func nextUnreadOrActiveFallbackTarget(
        selection: WindowCommandSelection,
        selectedTabID: UUID,
        matchingPanelIDs: Set<UUID>,
        includeCurrentWorkspaceWrap: Bool = true
    ) -> PanelNavigationTarget? {
        guard matchingPanelIDs.isEmpty == false else {
            return nil
        }

        return state.nextMatchingPanel(
            fromWindowID: selection.windowID,
            workspaceID: selection.workspace.id,
            tabID: selectedTabID,
            focusedPanelID: selection.workspace.focusedPanelID,
            includeCurrentWorkspaceWrap: includeCurrentWorkspaceWrap
        ) { _, panelID in
            matchingPanelIDs.contains(panelID)
        }
    }

    private func nextUnreadOrActiveCycleTarget(
        selection: WindowCommandSelection,
        selectedTabID: UUID,
        sessionRuntimeStore: SessionRuntimeStore,
        updatingCycleState: Bool
    ) -> (target: PanelNavigationTarget?, resolution: String, cycleResetReason: String?) {
        let currentAnchor = NextActiveCycleAnchor(
            windowID: selection.windowID,
            workspaceID: selection.workspace.id,
            selectedTabID: selectedTabID,
            focusedPanelID: selection.workspace.focusedPanelID
        )
        var cycleResetReason: String?

        if let cycleState = nextActiveCycleState {
            if let expectedCurrentTarget = panelNavigationTarget(for: cycleState.entries[cycleState.lastReturnedIndex].panelID),
               expectedCurrentTarget.windowID == selection.windowID,
               expectedCurrentTarget.workspaceID == selection.workspace.id,
               expectedCurrentTarget.tabID == selectedTabID,
               expectedCurrentTarget.panelID == selection.workspace.focusedPanelID {
                let rebuiltEntries = buildNextActiveCycleEntries(
                    anchor: cycleState.anchor,
                    sessionRuntimeStore: sessionRuntimeStore
                )
                if rebuiltEntries == cycleState.entries {
                    let nextIndex = cycleState.lastReturnedIndex < cycleState.entries.count - 1
                        ? cycleState.lastReturnedIndex + 1
                        : 0
                    let nextEntry = cycleState.entries[nextIndex]
                    if let target = panelNavigationTarget(for: nextEntry.panelID) {
                        if updatingCycleState {
                            nextActiveCycleState = NextActiveCycleState(
                                anchor: cycleState.anchor,
                                entries: cycleState.entries,
                                lastReturnedIndex: nextIndex
                            )
                        }
                        return (target, nextEntry.segment.rawValue, nil)
                    }
                    cycleResetReason = "cycle_target_missing"
                } else {
                    cycleResetReason = "cycle_entries_changed"
                }
            } else {
                cycleResetReason = "focus_changed"
            }
            if updatingCycleState {
                nextActiveCycleState = nil
            }
        }

        let entries = buildNextActiveCycleEntries(
            anchor: currentAnchor,
            sessionRuntimeStore: sessionRuntimeStore
        )
        guard let firstEntry = entries.first,
              let target = panelNavigationTarget(for: firstEntry.panelID) else {
            return (nil, "none", cycleResetReason)
        }

        if updatingCycleState {
            nextActiveCycleState = NextActiveCycleState(
                anchor: currentAnchor,
                entries: entries,
                lastReturnedIndex: 0
            )
        }
        return (target, firstEntry.segment.rawValue, cycleResetReason)
    }

    private func buildNextActiveCycleEntries(
        anchor: NextActiveCycleAnchor,
        sessionRuntimeStore: SessionRuntimeStore
    ) -> [NextActiveCycleEntry] {
        let workingPanelIDs = sessionRuntimeStore.activePanelIDs(
            matching: Self.nextUnreadOrWorkingFallbackStatusKinds
        )
        let laterPanelIDs = sessionRuntimeStore.activeLaterPanelIDs()
        var entries: [NextActiveCycleEntry] = []
        var seenPanelIDs = Set<UUID>()

        let forwardWorkingTargets = orderedNextUnreadOrActiveFallbackTargets(
            anchor: anchor,
            matchingPanelIDs: workingPanelIDs,
            includeCurrentWorkspaceWrap: false
        )
        entries.append(contentsOf: forwardWorkingTargets.map { target in
            seenPanelIDs.insert(target.panelID)
            return NextActiveCycleEntry(panelID: target.panelID, segment: .workingForward)
        })

        let laterTargets = orderedNextUnreadOrActiveFallbackTargets(
            anchor: anchor,
            matchingPanelIDs: laterPanelIDs.subtracting(seenPanelIDs)
        )
        entries.append(contentsOf: laterTargets.map { target in
            seenPanelIDs.insert(target.panelID)
            return NextActiveCycleEntry(panelID: target.panelID, segment: .later)
        })

        let wrappedWorkingTargets = orderedNextUnreadOrActiveFallbackTargets(
            anchor: anchor,
            matchingPanelIDs: workingPanelIDs.subtracting(seenPanelIDs)
        )
        entries.append(contentsOf: wrappedWorkingTargets.map { target in
            seenPanelIDs.insert(target.panelID)
            return NextActiveCycleEntry(panelID: target.panelID, segment: .workingWrapped)
        })

        if entries.isEmpty == false,
           let focusedPanelID = anchor.focusedPanelID,
           seenPanelIDs.contains(focusedPanelID) == false {
            if workingPanelIDs.contains(focusedPanelID) {
                entries.append(NextActiveCycleEntry(panelID: focusedPanelID, segment: .workingWrapped))
            } else if laterPanelIDs.contains(focusedPanelID) {
                entries.append(NextActiveCycleEntry(panelID: focusedPanelID, segment: .later))
            }
        }

        return entries
    }

    private func orderedNextUnreadOrActiveFallbackTargets(
        anchor: NextActiveCycleAnchor,
        matchingPanelIDs: Set<UUID>,
        includeCurrentWorkspaceWrap: Bool = true
    ) -> [PanelNavigationTarget] {
        guard matchingPanelIDs.isEmpty == false else {
            return []
        }

        var remainingPanelIDs = matchingPanelIDs
        var orderedTargets: [PanelNavigationTarget] = []

        while let target = state.nextMatchingPanel(
            fromWindowID: anchor.windowID,
            workspaceID: anchor.workspaceID,
            tabID: anchor.selectedTabID,
            focusedPanelID: anchor.focusedPanelID,
            includeCurrentWorkspaceWrap: includeCurrentWorkspaceWrap,
            matches: { _, panelID in
            remainingPanelIDs.contains(panelID)
            }
        ) {
            orderedTargets.append(target)
            remainingPanelIDs.remove(target.panelID)
        }

        return orderedTargets
    }

    private func panelNavigationTarget(for panelID: UUID) -> PanelNavigationTarget? {
        guard let selection = state.workspaceSelection(containingPanelID: panelID),
              let tabID = selection.workspace.tabID(containingPanelID: panelID) else {
            return nil
        }

        return PanelNavigationTarget(
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            tabID: tabID,
            panelID: panelID
        )
    }

    private func createdBrowserPanelID(
        in workspace: WorkspaceState,
        previousPanelIDs: Set<UUID>
    ) -> UUID? {
        let createdPanelIDs = Set(workspace.allPanelsByID.keys).subtracting(previousPanelIDs)

        if let activePanelID = workspace.rightAuxPanel.activePanelID,
           createdPanelIDs.contains(activePanelID),
           case .web(let webState)? = workspace.rightAuxPanel.panelState(for: activePanelID),
           webState.definition == .browser {
            return activePanelID
        }

        if let focusedPanelID = workspace.focusedPanelID,
           createdPanelIDs.contains(focusedPanelID),
           case .web(let webState)? = workspace.panels[focusedPanelID],
           webState.definition == .browser {
            return focusedPanelID
        }

        return createdPanelIDs.first { panelID in
            guard case .web(let webState)? = workspace.allPanelsByID[panelID] else {
                return false
            }
            return webState.definition == .browser
        }
    }

    private func createdLocalDocumentPanelID(
        in workspace: WorkspaceState,
        previousPanelIDs: Set<UUID>
    ) -> UUID? {
        let createdPanelIDs = Set(workspace.allPanelsByID.keys).subtracting(previousPanelIDs)

        if let activePanelID = workspace.rightAuxPanel.activePanelID,
           createdPanelIDs.contains(activePanelID),
           case .web(let webState)? = workspace.rightAuxPanel.panelState(for: activePanelID),
           webState.definition == .localDocument {
            return activePanelID
        }

        if let focusedPanelID = workspace.focusedPanelID,
           createdPanelIDs.contains(focusedPanelID),
           case .web(let webState)? = workspace.panels[focusedPanelID],
           webState.definition == .localDocument {
            return focusedPanelID
        }

        return createdPanelIDs.first { panelID in
            guard case .web(let webState)? = workspace.allPanelsByID[panelID] else {
                return false
            }
            return webState.definition == .localDocument
        }
    }

    private func createdScratchpadPanelID(
        in workspace: WorkspaceState,
        previousPanelIDs: Set<UUID>
    ) -> UUID? {
        let createdPanelIDs = Set(workspace.allPanelsByID.keys).subtracting(previousPanelIDs)

        if let activePanelID = workspace.rightAuxPanel.activePanelID,
           createdPanelIDs.contains(activePanelID),
           case .web(let webState)? = workspace.rightAuxPanel.panelState(for: activePanelID),
           webState.definition == .scratchpad {
            return activePanelID
        }

        if let focusedPanelID = workspace.focusedPanelID,
           createdPanelIDs.contains(focusedPanelID),
           case .web(let webState)? = workspace.panels[focusedPanelID],
           webState.definition == .scratchpad {
            return focusedPanelID
        }

        return createdPanelIDs.first { panelID in
            guard case .web(let webState)? = workspace.allPanelsByID[panelID] else {
                return false
            }
            return webState.definition == .scratchpad
        }
    }

    private func linkedScratchpadPanel(
        sessionID: String
    ) -> (windowID: UUID, workspaceID: UUID, panelID: UUID, webState: WebPanelState)? {
        for window in state.windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = state.workspacesByID[workspaceID] else {
                    continue
                }
                for (panelID, panelState) in workspace.allPanelsByID {
                    guard case .web(let webState) = panelState,
                          webState.definition == .scratchpad,
                          webState.scratchpad?.sessionLink?.sessionID == sessionID else {
                        continue
                    }
                    return (window.id, workspaceID, panelID, webState)
                }
            }
        }
        return nil
    }

    private func markScratchpadUpdatedIfUnfocused(workspaceID: UUID, panelID: UUID) {
        guard let workspace = state.workspacesByID[workspaceID] else {
            return
        }
        guard workspace.focusedPanelID != panelID,
              workspace.rightAuxPanel.focusedPanelID != panelID else {
            return
        }
        _ = send(.recordDesktopNotification(workspaceID: workspaceID, panelID: panelID))
    }

    private func requestSidebarFlashForExhaustedUnreadOrActiveJump(
        selection: WindowCommandSelection
    ) {
        pendingSidebarSessionFlashRequest = PendingSidebarSessionFlashRequest(
            requestID: UUID(),
            windowID: selection.windowID,
            workspaceID: selection.workspace.id,
            panelID: selection.workspace.focusedPanelID
        )

        if let focusedPanelID = selection.workspace.focusedPanelID {
            requestPanelFlash(
                windowID: selection.windowID,
                workspaceID: selection.workspace.id,
                panelID: focusedPanelID
            )
        }
    }

    private func logNextUnreadOrActivePanelResolution(
        selection: WindowCommandSelection,
        selectedTabID: UUID,
        resolution: String,
        target: PanelNavigationTarget?,
        sessionRuntimeStore: SessionRuntimeStore?,
        cycleResetReason: String?
    ) {
        let selectedTabUnreadPanelIDs = selection.workspace.tab(id: selectedTabID)?.unreadPanelIDs ?? []
        let workspaceUnreadPanelIDs = selection.workspace.unreadPanelIDs
        let attentionPanelStatuses = sessionRuntimeStore.map { runtimeStore in
            runtimeStore
                .activePanelIDs(matching: Self.nextUnreadOrActionRequiredFallbackStatusKinds)
                .sorted { $0.uuidString < $1.uuidString }
                .compactMap { panelID in
                    guard let status = runtimeStore.panelStatus(for: panelID)?.status.kind.rawValue else {
                        return nil
                    }
                    return "\(panelID.uuidString):\(status)"
                }
                .joined(separator: ",")
        } ?? ""
        let workingPanelStatuses = sessionRuntimeStore.map { runtimeStore in
            runtimeStore
                .activePanelIDs(matching: Self.nextUnreadOrWorkingFallbackStatusKinds)
                .sorted { $0.uuidString < $1.uuidString }
                .compactMap { panelID in
                    guard let status = runtimeStore.panelStatus(for: panelID)?.status.kind.rawValue else {
                        return nil
                    }
                    return "\(panelID.uuidString):\(status)"
                }
                .joined(separator: ",")
        } ?? ""
        let laterPanelIDs = sessionRuntimeStore.map { runtimeStore in
            runtimeStore
                .activeLaterPanelIDs()
                .sorted { $0.uuidString < $1.uuidString }
                .map(\.uuidString)
                .joined(separator: ",")
        } ?? ""

        var metadata: [String: String] = [
            "resolution": resolution,
            "window_id": selection.windowID.uuidString,
            "workspace_id": selection.workspace.id.uuidString,
            "selected_tab_id": selectedTabID.uuidString,
            "focused_panel_id": selection.workspace.focusedPanelID?.uuidString ?? "none",
            "selected_tab_unread_panel_ids": Self.commaSeparatedUUIDs(selectedTabUnreadPanelIDs),
            "workspace_unread_panel_ids": Self.commaSeparatedUUIDs(workspaceUnreadPanelIDs),
            "attention_panel_statuses": attentionPanelStatuses.isEmpty ? "none" : attentionPanelStatuses,
            "working_panel_statuses": workingPanelStatuses.isEmpty ? "none" : workingPanelStatuses,
            "later_panel_ids": laterPanelIDs.isEmpty ? "none" : laterPanelIDs,
        ]
        if let cycleState = nextActiveCycleState {
            metadata["active_cycle_anchor_window_id"] = cycleState.anchor.windowID.uuidString
            metadata["active_cycle_anchor_workspace_id"] = cycleState.anchor.workspaceID.uuidString
            metadata["active_cycle_anchor_tab_id"] = cycleState.anchor.selectedTabID.uuidString
            metadata["active_cycle_anchor_focused_panel_id"] = cycleState.anchor.focusedPanelID?.uuidString ?? "none"
            metadata["active_cycle_last_returned_index"] = String(cycleState.lastReturnedIndex)
            metadata["active_cycle_entries"] = cycleState.entries.map {
                "\($0.panelID.uuidString):\($0.segment.rawValue)"
            }.joined(separator: ",")
        }
        if let cycleResetReason {
            metadata["active_cycle_reset_reason"] = cycleResetReason
        }

        if let target {
            metadata["target_window_id"] = target.windowID.uuidString
            metadata["target_workspace_id"] = target.workspaceID.uuidString
            metadata["target_tab_id"] = target.tabID.uuidString
            metadata["target_panel_id"] = target.panelID.uuidString
            if let sessionRuntimeStore,
               let targetStatus = sessionRuntimeStore.panelStatus(for: target.panelID)?.status.kind.rawValue {
                metadata["target_status_kind"] = targetStatus
            }
            if let sessionRuntimeStore {
                metadata["target_later_flagged"] = sessionRuntimeStore
                    .activeLaterPanelIDs()
                    .contains(target.panelID) ? "true" : "false"
            }
        }

        ToasttyLog.debug(
            "Resolved next unread or active panel target",
            category: .store,
            metadata: metadata
        )
    }

    private static func commaSeparatedUUIDs<S: Sequence>(_ ids: S) -> String where S.Element == UUID {
        let values = ids.map(\.uuidString).sorted()
        return values.isEmpty ? "none" : values.joined(separator: ",")
    }

    private static func focusedCommandPanel(in workspace: WorkspaceState) -> (panelID: UUID, panelState: PanelState)? {
        if let focusedPanelID = workspace.rightAuxPanel.focusedPanelID,
           let panelState = workspace.rightAuxPanel.panelState(for: focusedPanelID) {
            return (focusedPanelID, panelState)
        }

        guard let focusedPanelID = workspace.focusedPanelID,
              workspace.slotID(containingPanelID: focusedPanelID) != nil,
              let panelState = workspace.panels[focusedPanelID] else {
            return nil
        }
        return (focusedPanelID, panelState)
    }

    private func existingLocalDocumentPanelID(
        in workspace: WorkspaceState,
        normalizedFilePath: String
    ) -> UUID? {
        for tab in workspace.orderedTabs {
            for (panelID, panelState) in tab.panels {
                guard case .web(let webState) = panelState,
                      webState.definition == .localDocument,
                      webState.localDocument?.filePath == normalizedFilePath else {
                    continue
                }
                return panelID
            }
        }
        for tab in workspace.rightAuxPanel.orderedTabs {
            guard case .web(let webState) = tab.panelState,
                  webState.definition == .localDocument,
                  webState.localDocument?.filePath == normalizedFilePath else {
                continue
            }
            return tab.panelID
        }
        return nil
    }

    private static func resolvedLocalDocument(
        _ value: String,
        formatOverride: LocalDocumentFormat? = nil
    ) -> (normalizedFilePath: String, format: LocalDocumentFormat)? {
        guard let trimmed = WebPanelState.normalizedFilePath(value) else {
            return nil
        }

        let url = URL(fileURLWithPath: trimmed).standardizedFileURL.resolvingSymlinksInPath()
        let normalizedFilePath = url.path
        guard normalizedFilePath.isEmpty == false,
              let format = formatOverride ?? LocalDocumentClassifier.format(
                  forFilePath: normalizedFilePath
              ) else {
            return nil
        }

        return (normalizedFilePath, format)
    }

    private static func localDocumentDisplayName(for normalizedFilePath: String) -> String {
        let name = URL(fileURLWithPath: normalizedFilePath).lastPathComponent
        return name.isEmpty ? WebPanelDefinition.localDocument.defaultTitle : name
    }

    @discardableResult
    private func focusPanelTarget(
        _ target: PanelNavigationTarget,
        flashPanelOnSuccess: Bool = false
    ) -> Bool {
        focusPanel(
            windowID: target.windowID,
            workspaceID: target.workspaceID,
            panelID: target.panelID,
            flashPanelOnSuccess: flashPanelOnSuccess
        )
    }

    @discardableResult
    private func focusPanel(
        windowID: UUID,
        workspaceID: UUID,
        panelID: UUID,
        flashPanelOnSuccess: Bool,
        alwaysActivateWindow: Bool = false
    ) -> Bool {
        let previousSelectedWindowID = state.selectedWindowID
        let requiresWorkspaceSelection = state.selectedWorkspaceID(in: windowID) != workspaceID

        if state.selectedWindowID != windowID || requiresWorkspaceSelection {
            guard send(.selectWorkspace(windowID: windowID, workspaceID: workspaceID)) else {
                return false
            }
        }

        guard send(.focusPanel(workspaceID: workspaceID, panelID: panelID)) else {
            return false
        }

        if let selectedWindowID = state.selectedWindowID,
           alwaysActivateWindow || selectedWindowID != previousSelectedWindowID {
            windowActivationHandler(selectedWindowID)
        }

        if flashPanelOnSuccess {
            requestPanelFlash(
                windowID: windowID,
                workspaceID: workspaceID,
                panelID: panelID
            )
        }

        return true
    }

    private func requestPanelFlash(windowID: UUID, workspaceID: UUID, panelID: UUID) {
        pendingPanelFlashRequest = PendingPanelFlashRequest(
            requestID: UUID(),
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID
        )
    }

    private func windowLaunchSeed(from selection: WindowCommandSelection?) -> WindowLaunchSeed? {
        guard let selection else { return nil }

        let windowFontOverride = state.normalizedTerminalFontOverride(
            state.effectiveTerminalFontPoints(for: selection.windowID)
        )
        let windowMarkdownTextScaleOverride = AppState.normalizedMarkdownTextScaleOverride(
            state.effectiveMarkdownTextScale(for: selection.windowID)
        )

        guard let focusedPanelID = selection.workspace.focusedPanelID,
              case .terminal(let terminalState)? = selection.workspace.panels[focusedPanelID] else {
            guard windowFontOverride != nil || windowMarkdownTextScaleOverride != nil else { return nil }
            return WindowLaunchSeed(
                windowTerminalFontSizePointsOverride: windowFontOverride,
                windowMarkdownTextScaleOverride: windowMarkdownTextScaleOverride
            )
        }

        return WindowLaunchSeed(
            terminalCWD: terminalState.workingDirectorySeed,
            terminalProfileBinding: terminalState.profileBinding ?? state.defaultTerminalProfileBinding,
            windowTerminalFontSizePointsOverride: windowFontOverride,
            windowMarkdownTextScaleOverride: windowMarkdownTextScaleOverride
        )
    }

    private func commandCreateWindowFrame(cascadingFromSourceWindow: Bool) -> CGRectCodable? {
        guard let frame = commandCreateWindowFrameProvider() else { return nil }
        guard cascadingFromSourceWindow else { return frame }
        return Self.cascadeWindowFrame(frame)
    }

    private static func currentCommandCreateWindowFrame() -> CGRectCodable? {
        if let frame = NSApp.mainWindow?.frame {
            return CGRectCodable(frame)
        }
        if let frame = NSApp.keyWindow?.frame {
            return CGRectCodable(frame)
        }
        return nil
    }

    private static func cascadeWindowFrame(_ frame: CGRectCodable) -> CGRectCodable {
        CGRectCodable(
            x: frame.x + newWindowCascadeOffset,
            y: frame.y - newWindowCascadeOffset,
            width: frame.width,
            height: frame.height
        )
    }

    private static func activateWindowInAppKit(id windowID: UUID) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == windowID.uuidString }) else {
            return
        }
        window.makeKeyAndOrderFront(nil)
    }

    @discardableResult
    private func requestWorkspaceClose(windowID: UUID, workspaceID: UUID) -> Bool {
        guard let selection = state.workspaceSelection(containingWorkspaceID: workspaceID),
              selection.windowID == windowID else {
            return false
        }
        let request = PendingWorkspaceCloseRequest(windowID: windowID, workspaceID: workspaceID)
        if let pendingCloseWorkspaceRequest {
            return pendingCloseWorkspaceRequest == request
        }
        pendingCloseWorkspaceRequest = request
        return true
    }
}
