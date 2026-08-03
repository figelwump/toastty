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
    let source: AppActionSource

    init(
        windowID: UUID,
        workspaceID: UUID,
        source: AppActionSource = .unknown
    ) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.source = source
    }

    static func == (lhs: PendingWorkspaceCloseRequest, rhs: PendingWorkspaceCloseRequest) -> Bool {
        lhs.windowID == rhs.windowID && lhs.workspaceID == rhs.workspaceID
    }
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

enum ScratchpadPanelCreatePolicy: String, CaseIterable, Equatable, Sendable {
    case reuse
    case new
}

struct ScratchpadPanelSetContentRequest: Equatable, Sendable {
    var sessionID: String
    var title: String?
    var content: String
    var expectedRevision: Int?
    var createPolicy: ScratchpadPanelCreatePolicy

    init(
        sessionID: String,
        title: String? = nil,
        content: String,
        expectedRevision: Int? = nil,
        createPolicy: ScratchpadPanelCreatePolicy = .reuse
    ) {
        self.sessionID = sessionID
        self.title = WebPanelState.normalizedTitle(title)
        self.content = content
        self.expectedRevision = expectedRevision
        self.createPolicy = createPolicy
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

struct ScratchpadPanelPatchContentRequest: Equatable, Sendable {
    var sessionID: String
    var patch: String
    var expectedRevision: Int
}

struct ScratchpadPanelPatchContentOutcome: Equatable, Sendable {
    let windowID: UUID
    let workspaceID: UUID
    let panelID: UUID
    let documentID: UUID
    let previousRevision: Int
    let revision: Int
    let appliedEditCount: Int
    let created: Bool
}

struct ScratchpadPanelCreateOutcome: Equatable, Sendable {
    let windowID: UUID
    let workspaceID: UUID
    let panelID: UUID
    let documentID: UUID
    let revision: Int
}

struct ScratchpadPanelRebindOutcome: Equatable, Sendable {
    let windowID: UUID
    let workspaceID: UUID
    let panelID: UUID
    let documentID: UUID
    let revision: Int
    let sessionID: String
}

struct ScratchpadPanelUnbindOutcome: Equatable, Sendable {
    let windowID: UUID
    let workspaceID: UUID
    let panelID: UUID
    let documentID: UUID
    let revision: Int
}

struct ScratchpadSessionLinkCleanupFailure: Equatable, Sendable {
    let panelID: UUID
    let errorDescription: String
}

struct ScratchpadSessionLinkCleanupOutcome: Equatable, Sendable {
    let clearedPanelIDs: [UUID]
    let clearedDocumentIDs: [UUID]
    let failures: [ScratchpadSessionLinkCleanupFailure]

    var didClearLinks: Bool {
        clearedPanelIDs.isEmpty == false
    }
}

enum ScratchpadPanelError: LocalizedError, Equatable {
    case missingSession(String)
    case missingSourcePanel(UUID)
    case sourcePanelIsNotTerminal(UUID)
    case createPanelFailed
    case updatePanelFailed(UUID)
    case missingScratchpadState(UUID)
    case missingDocument(UUID)
    case missingLinkedScratchpad(String)
    case targetSessionOutsideScratchpadTab(String)
    case sessionAlreadyLinkedToScratchpad(String, UUID)

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
        case .missingLinkedScratchpad(let sessionID):
            return "no Scratchpad is linked to active session: \(sessionID)"
        case .targetSessionOutsideScratchpadTab(let sessionID):
            return "target session is not in the Scratchpad tab: \(sessionID)"
        case .sessionAlreadyLinkedToScratchpad(let sessionID, let panelID):
            return "target session \(sessionID) is already linked to Scratchpad panel: \(panelID.uuidString)"
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
