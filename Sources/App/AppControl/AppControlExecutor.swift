import CoreState
import CryptoKit
import Foundation

struct AppControlActionOutcome {
    let didMutateState: Bool
    let result: [String: AutomationJSONValue]?
}

@MainActor
final class AppControlExecutor {
    private weak var store: AppStore?
    private let terminalRuntimeRegistry: TerminalRuntimeRegistry
    private let webPanelRuntimeRegistry: WebPanelRuntimeRegistry
    private let sessionRuntimeStore: SessionRuntimeStore
    private let focusedPanelCommandController: FocusedPanelCommandController
    private let agentLaunchService: AgentLaunchService
    private let reloadConfigurationAction: (@MainActor () -> Void)?
    private let scratchpadDocumentStore: ScratchpadDocumentStore

    init(
        store: AppStore,
        terminalRuntimeRegistry: TerminalRuntimeRegistry,
        webPanelRuntimeRegistry: WebPanelRuntimeRegistry,
        sessionRuntimeStore: SessionRuntimeStore,
        focusedPanelCommandController: FocusedPanelCommandController,
        agentLaunchService: AgentLaunchService,
        reloadConfigurationAction: (@MainActor () -> Void)?,
        scratchpadDocumentStore: ScratchpadDocumentStore? = nil
    ) {
        self.store = store
        self.terminalRuntimeRegistry = terminalRuntimeRegistry
        self.webPanelRuntimeRegistry = webPanelRuntimeRegistry
        self.sessionRuntimeStore = sessionRuntimeStore
        self.focusedPanelCommandController = focusedPanelCommandController
        self.agentLaunchService = agentLaunchService
        self.reloadConfigurationAction = reloadConfigurationAction
        self.scratchpadDocumentStore = scratchpadDocumentStore ?? webPanelRuntimeRegistry.scratchpadDocumentStore
    }

    func listActionDescriptors() -> [AppControlCommandDescriptor] {
        AppControlActionID.allCases.compactMap { action in
            if action == .configReload, reloadConfigurationAction == nil {
                return nil
            }
            return action.descriptor
        }
    }

    func listQueryDescriptors() -> [AppControlCommandDescriptor] {
        AppControlQueryID.allCases.map(\.descriptor)
    }

    func runAction(id rawID: String, args: [String: AutomationJSONValue]) throws -> AppControlActionOutcome {
        guard let action = AppControlActionID.resolve(rawID) else {
            throw AutomationSocketError.invalidPayload("unsupported action: \(rawID)")
        }

        switch action {
        case .windowCreate:
            return .init(
                didMutateState: try requiredStore().createWindowFromCommand(preferredWindowID: try resolveOptionalWindowID(args: args)),
                result: nil
            )

        case .windowSidebarToggle:
            return .init(
                didMutateState: try requiredStore().send(.toggleSidebar(windowID: try resolveWindowID(args: args))),
                result: nil
            )

        case .workspaceCreate:
            let store = try requiredStore()
            let windowID = try resolveWindowID(args: args)
            let existingWorkspaceIDs = Set(store.state.window(id: windowID)?.workspaceIDs ?? [])
            let didMutateState = store.send(
                .createWorkspace(
                    windowID: windowID,
                    title: normalizedOptionalText(args.stringValue("title")),
                    activate: args.boolValue("activate") ?? true
                )
            )
            guard didMutateState else {
                return .init(didMutateState: false, result: nil)
            }
            guard let updatedWindow = store.state.window(id: windowID),
                  let workspaceID = updatedWindow.workspaceIDs.last(where: { existingWorkspaceIDs.contains($0) == false }) else {
                throw AutomationSocketError.invalidPayload("workspace.create did not return a created workspace")
            }
            return .init(
                didMutateState: true,
                result: [
                    "windowID": .string(windowID.uuidString),
                    "workspaceID": .string(workspaceID.uuidString),
                ]
            )

        case .workspaceSelect:
            let selection = try resolveWorkspaceSelection(args: args)
            let targetWorkspaceID: UUID
            if let workspaceID = args.uuid("workspaceID") {
                targetWorkspaceID = workspaceID
            } else if let index = args.intValue("index") {
                guard index > 0 else {
                    throw AutomationSocketError.invalidPayload("index must be greater than zero")
                }
                guard index <= selection.window.workspaceIDs.count else {
                    throw AutomationSocketError.invalidPayload("index does not exist")
                }
                targetWorkspaceID = selection.window.workspaceIDs[index - 1]
            } else {
                throw AutomationSocketError.invalidPayload("workspaceID or index is required")
            }

            return .init(
                didMutateState: try requiredStore().selectWorkspace(
                    windowID: selection.windowID,
                    workspaceID: targetWorkspaceID,
                    preferringUnreadSessionPanelIn: sessionRuntimeStore
                ),
                result: nil
            )

        case .workspaceRename:
            let title = try requireTextParameter("title", args: args)
            return .init(
                didMutateState: try requiredStore().send(.renameWorkspace(workspaceID: try resolveWorkspaceID(args: args), title: title)),
                result: nil
            )

        case .workspaceClose:
            return .init(
                didMutateState: try requiredStore().send(.closeWorkspace(workspaceID: try resolveWorkspaceID(args: args))),
                result: nil
            )

        case .workspaceTabCreate:
            return .init(
                didMutateState: try requiredStore().send(.createWorkspaceTab(workspaceID: try resolveWorkspaceID(args: args), seed: nil)),
                result: nil
            )

        case .workspaceTabSelect:
            let workspaceID = try resolveWorkspaceID(args: args)
            let tabID = try resolveWorkspaceTabID(args: args, workspaceID: workspaceID, allowSelectedTabFallback: false)
            return .init(
                didMutateState: try requiredStore().send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: tabID)),
                result: nil
            )

        case .workspaceTabSelectPrevious:
            return .init(
                didMutateState: try requiredStore().selectAdjacentWorkspaceTab(
                    preferredWindowID: try resolveWindowID(args: args),
                    direction: .previous
                ),
                result: nil
            )

        case .workspaceTabSelectNext:
            return .init(
                didMutateState: try requiredStore().selectAdjacentWorkspaceTab(
                    preferredWindowID: try resolveWindowID(args: args),
                    direction: .next
                ),
                result: nil
            )

        case .workspaceTabRename:
            let workspaceID = try resolveWorkspaceID(args: args)
            let tabID = try resolveWorkspaceTabID(args: args, workspaceID: workspaceID, allowSelectedTabFallback: true)
            return .init(
                didMutateState: try requiredStore().send(
                    .setWorkspaceTabCustomTitle(
                        workspaceID: workspaceID,
                        tabID: tabID,
                        title: normalizedOptionalText(args.stringValue("title"))
                    )
                ),
                result: nil
            )

        case .workspaceTabClose:
            let workspaceID = try resolveWorkspaceID(args: args)
            let tabID = try resolveWorkspaceTabID(args: args, workspaceID: workspaceID, allowSelectedTabFallback: true)
            return .init(
                didMutateState: try requiredStore().send(.closeWorkspaceTab(workspaceID: workspaceID, tabID: tabID)),
                result: nil
            )

        case .workspaceReopenLastClosedPanel:
            return .init(
                didMutateState: try requiredStore().send(.reopenLastClosedPanel(workspaceID: try resolveWorkspaceID(args: args))),
                result: nil
            )

        case .panelFocusNextUnreadOrActive:
            return .init(
                didMutateState: try requiredStore().focusNextUnreadOrActivePanelFromCommand(
                    preferredWindowID: try resolveWindowID(args: args),
                    sessionRuntimeStore: sessionRuntimeStore
                ),
                result: nil
            )

        case .workspaceSplitHorizontal:
            return .init(
                didMutateState: try requiredStore().send(.splitFocusedSlot(workspaceID: try resolveWorkspaceID(args: args), orientation: .horizontal)),
                result: nil
            )

        case .workspaceSplitVertical:
            return .init(
                didMutateState: try requiredStore().send(.splitFocusedSlot(workspaceID: try resolveWorkspaceID(args: args), orientation: .vertical)),
                result: nil
            )

        case .workspaceSplitRight:
            return try splitInDirection(.right, args: args)
        case .workspaceSplitDown:
            return try splitInDirection(.down, args: args)
        case .workspaceSplitLeft:
            return try splitInDirection(.left, args: args)
        case .workspaceSplitUp:
            return try splitInDirection(.up, args: args)

        case .workspaceSplitRightWithProfile:
            return try splitWithProfile(direction: .right, args: args)
        case .workspaceSplitDownWithProfile:
            return try splitWithProfile(direction: .down, args: args)

        case .panelClose:
            return .init(
                didMutateState: focusedPanelCommandController.closeFocusedPanel(in: try resolveWorkspaceID(args: args)).didMutateState,
                result: nil
            )

        case .workspaceFocusSlotPrevious:
            return try focusSlot(.previous, args: args)
        case .workspaceFocusSlotNext:
            return try focusSlot(.next, args: args)
        case .workspaceFocusSlotLeft:
            return try focusSlot(.left, args: args)
        case .workspaceFocusSlotRight:
            return try focusSlot(.right, args: args)
        case .workspaceFocusSlotUp:
            return try focusSlot(.up, args: args)
        case .workspaceFocusSlotDown:
            return try focusSlot(.down, args: args)

        case .workspaceFocusPanel:
            guard let panelID = args.uuid("panelID") else {
                throw AutomationSocketError.invalidPayload("panelID must be a UUID")
            }
            return .init(
                didMutateState: try requiredStore().send(.focusPanel(workspaceID: try resolveWorkspaceID(args: args), panelID: panelID)),
                result: nil
            )

        case .workspaceResizeSplitLeft:
            return try resizeSplit(.left, args: args)
        case .workspaceResizeSplitRight:
            return try resizeSplit(.right, args: args)
        case .workspaceResizeSplitUp:
            return try resizeSplit(.up, args: args)
        case .workspaceResizeSplitDown:
            return try resizeSplit(.down, args: args)

        case .workspaceEqualizeSplits:
            return .init(
                didMutateState: try requiredStore().send(.equalizeLayoutSplits(workspaceID: try resolveWorkspaceID(args: args))),
                result: nil
            )

        case .panelCreateBrowser:
            return .init(
                didMutateState: try requiredStore().createBrowserPanel(
                    workspaceID: try resolveWorkspaceID(args: args),
                    request: BrowserPanelCreateRequest(
                        initialURL: normalizedOptionalText(args.stringValue("url")),
                        placementOverride: try webPanelPlacement(args: args)
                    )
                ),
                result: nil
            )

        case .panelCreateLocalDocument:
            guard let filePath = normalizedOptionalText(args.stringValue("filePath")) else {
                throw AutomationSocketError.invalidPayload("filePath is required")
            }
            return .init(
                didMutateState: try requiredStore().createLocalDocumentPanel(
                    workspaceID: try resolveWorkspaceID(args: args),
                    request: LocalDocumentPanelCreateRequest(
                        filePath: filePath,
                        placementOverride: try webPanelPlacement(args: args)
                    )
                ),
                result: nil
            )

        case .panelScratchpadSetContent:
            return try setScratchpadContent(args: args)

        case .panelLocalDocumentSearchStart:
            let resolved = try resolveLocalDocumentTarget(payload: args)
            let runtime = webPanelRuntimeRegistry.localDocumentRuntime(for: resolved.panelID)
            runtime.apply(webState: resolved.webState)
            return .init(
                didMutateState: runtime.startSearch(),
                result: nil
            )

        case .panelLocalDocumentSearchUpdateQuery:
            guard let query = args.stringValue("query") else {
                throw AutomationSocketError.invalidPayload("query is required")
            }
            let resolved = try resolveLocalDocumentTarget(payload: args)
            let runtime = webPanelRuntimeRegistry.localDocumentRuntime(for: resolved.panelID)
            runtime.apply(webState: resolved.webState)
            let before = runtime.searchState()
            runtime.updateSearchQuery(query)
            return .init(
                didMutateState: before != runtime.searchState(),
                result: nil
            )

        case .panelLocalDocumentSearchNext:
            let resolved = try resolveLocalDocumentTarget(payload: args)
            let runtime = webPanelRuntimeRegistry.localDocumentRuntime(for: resolved.panelID)
            runtime.apply(webState: resolved.webState)
            return .init(
                didMutateState: runtime.findNext(),
                result: nil
            )

        case .panelLocalDocumentSearchPrevious:
            let resolved = try resolveLocalDocumentTarget(payload: args)
            let runtime = webPanelRuntimeRegistry.localDocumentRuntime(for: resolved.panelID)
            runtime.apply(webState: resolved.webState)
            return .init(
                didMutateState: runtime.findPrevious(),
                result: nil
            )

        case .panelLocalDocumentSearchHide:
            let resolved = try resolveLocalDocumentTarget(payload: args)
            let runtime = webPanelRuntimeRegistry.localDocumentRuntime(for: resolved.panelID)
            runtime.apply(webState: resolved.webState)
            return .init(
                didMutateState: runtime.endSearch(),
                result: nil
            )

        case .panelFocusModeToggle:
            return .init(
                didMutateState: terminalRuntimeRegistry.toggleFocusedPanelMode(workspaceID: try resolveWorkspaceID(args: args)),
                result: nil
            )

        case .appFontIncrease:
            return .init(didMutateState: try requiredStore().send(.increaseWindowTerminalFont(windowID: try resolveWindowID(args: args))), result: nil)
        case .appFontDecrease:
            return .init(didMutateState: try requiredStore().send(.decreaseWindowTerminalFont(windowID: try resolveWindowID(args: args))), result: nil)
        case .appFontReset:
            return .init(didMutateState: try requiredStore().send(.resetWindowTerminalFont(windowID: try resolveWindowID(args: args))), result: nil)
        case .appMarkdownTextIncrease:
            return .init(didMutateState: try requiredStore().send(.increaseWindowMarkdownTextScale(windowID: try resolveWindowID(args: args))), result: nil)
        case .appMarkdownTextDecrease:
            return .init(didMutateState: try requiredStore().send(.decreaseWindowMarkdownTextScale(windowID: try resolveWindowID(args: args))), result: nil)
        case .appMarkdownTextReset:
            return .init(didMutateState: try requiredStore().send(.resetWindowMarkdownTextScale(windowID: try resolveWindowID(args: args))), result: nil)

        case .appBrowserZoomIncrease:
            return try browserZoomAction(action: .increase, args: args)
        case .appBrowserZoomDecrease:
            return try browserZoomAction(action: .decrease, args: args)
        case .appBrowserZoomReset:
            return try browserZoomAction(action: .reset, args: args)

        case .agentLaunch:
            guard let profileID = normalizedOptionalText(args.stringValue("profileID")) else {
                throw AutomationSocketError.invalidPayload("profileID is required")
            }
            let result = try agentLaunchService.launch(
                profileID: profileID,
                workspaceID: args.uuid("workspaceID"),
                panelID: args.uuid("panelID")
            )
            var response: [String: AutomationJSONValue] = [
                "profileID": .string(result.agent.rawValue),
                "agent": .string(result.agent.rawValue),
                "displayName": .string(result.displayName),
                "sessionID": .string(result.sessionID),
                "windowID": .string(result.windowID.uuidString),
                "workspaceID": .string(result.workspaceID.uuidString),
                "panelID": .string(result.panelID.uuidString),
                "command": .string(result.commandLine),
            ]
            if let cwd = result.cwd {
                response["cwd"] = .string(cwd)
            }
            if let repoRoot = result.repoRoot {
                response["repoRoot"] = .string(repoRoot)
            }
            return .init(didMutateState: true, result: response)

        case .configReload:
            guard let reloadConfigurationAction else {
                throw AutomationSocketError.invalidPayload("config.reload is unavailable in this launch context")
            }
            reloadConfigurationAction()
            return .init(didMutateState: true, result: nil)

        case .terminalSendText:
            guard let text = args.stringValue("text") else {
                throw AutomationSocketError.invalidPayload("text is required")
            }
            let submit = args.boolValue("submit") ?? false
            let allowUnavailable = args.boolValue("allowUnavailable") ?? false
            let resolved = try resolveTerminalTarget(payload: args)
            if terminalRuntimeRegistry.sendText(text, submit: submit, panelID: resolved.panelID) {
                return .init(
                    didMutateState: false,
                    result: [
                        "workspaceID": .string(resolved.workspaceID.uuidString),
                        "panelID": .string(resolved.panelID.uuidString),
                        "submitted": .bool(submit),
                        "available": .bool(true),
                    ]
                )
            }
            if allowUnavailable {
                return .init(
                    didMutateState: false,
                    result: [
                        "workspaceID": .string(resolved.workspaceID.uuidString),
                        "panelID": .string(resolved.panelID.uuidString),
                        "submitted": .bool(submit),
                        "available": .bool(false),
                    ]
                )
            }
            throw AutomationSocketError.invalidPayload("terminal surface unavailable for panelID \(resolved.panelID.uuidString)")

        case .terminalDropImageFiles:
            let rawFiles = args.stringArrayValue("files")
            guard rawFiles.isEmpty == false else {
                throw AutomationSocketError.invalidPayload("files must include at least one path")
            }
            let normalizedFiles: [String]
            do {
                normalizedFiles = try SocketEventNormalizer.normalizeFiles(rawFiles, cwd: args.stringValue("cwd"))
            } catch let normalizationError as SocketEventNormalizationError {
                switch normalizationError {
                case .missingCWDForRelativePath(let path):
                    throw AutomationSocketError.invalidPayload("cwd is required when files include relative path: \(path)")
                }
            }
            let allowUnavailable = args.boolValue("allowUnavailable") ?? false
            let resolved = try resolveTerminalTarget(payload: args)
            switch terminalRuntimeRegistry.automationDropImageFiles(normalizedFiles, panelID: resolved.panelID) {
            case .sent(let imageCount):
                return .init(
                    didMutateState: false,
                    result: [
                        "workspaceID": .string(resolved.workspaceID.uuidString),
                        "panelID": .string(resolved.panelID.uuidString),
                        "requestedFileCount": .int(normalizedFiles.count),
                        "acceptedImageCount": .int(imageCount),
                        "available": .bool(true),
                    ]
                )
            case .noImageFiles:
                throw AutomationSocketError.invalidPayload("files payload did not contain any image paths")
            case .unavailableSurface:
                if allowUnavailable {
                    return .init(
                        didMutateState: false,
                        result: [
                            "workspaceID": .string(resolved.workspaceID.uuidString),
                            "panelID": .string(resolved.panelID.uuidString),
                            "requestedFileCount": .int(normalizedFiles.count),
                            "acceptedImageCount": .int(0),
                            "available": .bool(false),
                        ]
                    )
                }
                throw AutomationSocketError.invalidPayload("terminal surface unavailable for panelID \(resolved.panelID.uuidString)")
            }
        }
    }

    func runQuery(id rawID: String, args: [String: AutomationJSONValue]) throws -> [String: AutomationJSONValue] {
        guard let query = AppControlQueryID.resolve(rawID) else {
            throw AutomationSocketError.invalidPayload("unsupported query: \(rawID)")
        }

        switch query {
        case .workspaceSnapshot:
            return try workspaceSnapshot(workspaceID: try resolveWorkspaceID(args: args))

        case .terminalState:
            let resolved = try resolveTerminalTarget(payload: args)
            return try terminalStateSnapshot(
                windowID: resolved.windowID,
                workspaceID: resolved.workspaceID,
                panelID: resolved.panelID
            )

        case .terminalVisibleText:
            let resolved = try resolveTerminalTarget(payload: args)
            guard let text = terminalRuntimeRegistry.readVisibleText(panelID: resolved.panelID) else {
                throw AutomationSocketError.invalidPayload("terminal visible text unavailable for panelID \(resolved.panelID.uuidString)")
            }
            var result: [String: AutomationJSONValue] = [
                "workspaceID": .string(resolved.workspaceID.uuidString),
                "panelID": .string(resolved.panelID.uuidString),
                "text": .string(text),
            ]
            if let needle = normalizedOptionalText(args.stringValue("contains")) {
                result["contains"] = .bool(text.contains(needle))
            }
            return result

        case .panelLocalDocumentState:
            let resolved = try resolveLocalDocumentTarget(payload: args)
            let runtime = webPanelRuntimeRegistry.localDocumentRuntime(for: resolved.panelID)
            runtime.apply(webState: resolved.webState)
            return localDocumentPanelStateSnapshot(
                workspaceID: resolved.workspaceID,
                panelID: resolved.panelID,
                webState: resolved.webState,
                runtimeState: runtime.automationState()
            )

        case .panelBrowserState:
            let resolved = try resolveBrowserTarget(payload: args)
            let runtime = webPanelRuntimeRegistry.browserRuntime(for: resolved.panelID)
            runtime.apply(webState: resolved.webState)
            return browserPanelStateSnapshot(
                workspaceID: resolved.workspaceID,
                panelID: resolved.panelID,
                webState: resolved.webState,
                runtimeState: runtime.automationState()
            )

        case .panelScratchpadState:
            let resolved = try resolveScratchpadTarget(payload: args)
            let runtime = webPanelRuntimeRegistry.scratchpadRuntime(for: resolved.panelID)
            runtime.apply(webState: resolved.webState)
            return scratchpadPanelStateSnapshot(
                workspaceID: resolved.workspaceID,
                panelID: resolved.panelID,
                webState: resolved.webState,
                runtimeState: runtime.automationState()
            )
        }
    }
}

private extension AppControlExecutor {
    enum BrowserZoomAction {
        case increase
        case decrease
        case reset
    }

    func requiredStore() throws -> AppStore {
        guard let store else {
            throw AutomationSocketError.internalError("app store unavailable")
        }
        return store
    }

    func splitInDirection(_ direction: SlotSplitDirection, args: [String: AutomationJSONValue]) throws -> AppControlActionOutcome {
        .init(
            didMutateState: try requiredStore().send(.splitFocusedSlotInDirection(workspaceID: try resolveWorkspaceID(args: args), direction: direction)),
            result: nil
        )
    }

    func splitWithProfile(direction: SlotSplitDirection, args: [String: AutomationJSONValue]) throws -> AppControlActionOutcome {
        .init(
            didMutateState: terminalRuntimeRegistry.splitFocusedSlotInDirectionWithTerminalProfile(
                workspaceID: try resolveWorkspaceID(args: args),
                direction: direction,
                profileBinding: try profileBinding(args: args)
            ),
            result: nil
        )
    }

    func focusSlot(_ direction: SlotFocusDirection, args: [String: AutomationJSONValue]) throws -> AppControlActionOutcome {
        .init(
            didMutateState: try requiredStore().send(.focusSlot(workspaceID: try resolveWorkspaceID(args: args), direction: direction)),
            result: nil
        )
    }

    func resizeSplit(_ direction: SplitResizeDirection, args: [String: AutomationJSONValue]) throws -> AppControlActionOutcome {
        .init(
            didMutateState: try requiredStore().send(
                .resizeFocusedSlotSplit(
                    workspaceID: try resolveWorkspaceID(args: args),
                    direction: direction,
                    amount: max(args.intValue("amount") ?? 1, 1)
                )
            ),
            result: nil
        )
    }

    func browserZoomAction(
        action: BrowserZoomAction,
        args: [String: AutomationJSONValue]
    ) throws -> AppControlActionOutcome {
        let target = try resolveBrowserTarget(payload: args)
        let didMutate: Bool
        switch action {
        case .increase:
            didMutate = try requiredStore().send(.increaseBrowserPanelPageZoom(panelID: target.panelID))
        case .decrease:
            didMutate = try requiredStore().send(.decreaseBrowserPanelPageZoom(panelID: target.panelID))
        case .reset:
            didMutate = try requiredStore().send(.resetBrowserPanelPageZoom(panelID: target.panelID))
        }
        return .init(didMutateState: didMutate, result: nil)
    }

    func setScratchpadContent(args: [String: AutomationJSONValue]) throws -> AppControlActionOutcome {
        let store = try requiredStore()
        guard let sessionID = normalizedOptionalText(args.stringValue("sessionID")) else {
            throw AutomationSocketError.invalidPayload("sessionID is required")
        }
        let content = try scratchpadContent(args: args, sessionID: sessionID)

        let outcome: ScratchpadPanelSetContentOutcome
        do {
            outcome = try store.setScratchpadContentForSession(
                request: ScratchpadPanelSetContentRequest(
                    sessionID: sessionID,
                    title: normalizedOptionalText(args.stringValue("title")),
                    content: content,
                    expectedRevision: args.intValue("expectedRevision")
                ),
                sessionRuntimeStore: sessionRuntimeStore,
                documentStore: scratchpadDocumentStore
            )
        } catch let error as ScratchpadDocumentStoreError {
            throw AutomationSocketError.invalidPayload(error.localizedDescription)
        } catch let error as ScratchpadPanelError {
            throw AutomationSocketError.invalidPayload(error.localizedDescription)
        }

        return .init(
            didMutateState: true,
            result: [
                "windowID": .string(outcome.windowID.uuidString),
                "workspaceID": .string(outcome.workspaceID.uuidString),
                "panelID": .string(outcome.panelID.uuidString),
                "documentID": .string(outcome.documentID.uuidString),
                "revision": .int(outcome.revision),
                "created": .bool(outcome.created),
            ]
        )
    }

    func scratchpadContent(args: [String: AutomationJSONValue], sessionID: String) throws -> String {
        let inlineContent = args.stringValue("content")
        let filePath = normalizedOptionalText(args.stringValue("filePath"))

        if inlineContent != nil, filePath != nil {
            throw AutomationSocketError.invalidPayload("provide either filePath or content, not both")
        }
        if let inlineContent {
            return inlineContent
        }
        guard let filePath else {
            throw AutomationSocketError.invalidPayload("filePath or content is required")
        }

        let resolvedURL = resolvedScratchpadContentFileURL(filePath, sessionID: sessionID)
        do {
            return try String(contentsOf: resolvedURL, encoding: .utf8)
        } catch {
            throw AutomationSocketError.invalidPayload("could not read filePath: \(error.localizedDescription)")
        }
    }

    func resolvedScratchpadContentFileURL(_ filePath: String, sessionID: String) -> URL {
        let expanded = (filePath as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }

        let basePath = sessionRuntimeStore
            .sessionRegistry
            .activeSession(sessionID: sessionID)?
            .cwd
        let baseURL = basePath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return baseURL.appendingPathComponent(expanded).standardizedFileURL
    }

    func requireTextParameter(_ name: String, args: [String: AutomationJSONValue]) throws -> String {
        guard let value = normalizedOptionalText(args.stringValue(name)) else {
            throw AutomationSocketError.invalidPayload("\(name) is required")
        }
        return value
    }

    func profileBinding(args: [String: AutomationJSONValue]) throws -> TerminalProfileBinding {
        guard let profileID = normalizedOptionalText(args.stringValue("profileID")) else {
            throw AutomationSocketError.invalidPayload("profileID is required")
        }
        return TerminalProfileBinding(profileID: profileID)
    }

    func webPanelPlacement(args: [String: AutomationJSONValue]) throws -> WebPanelPlacement {
        guard let rawValue = normalizedOptionalText(args.stringValue("placement")) else {
            return .rootRight
        }
        guard let placement = WebPanelPlacement(rawValue: rawValue) else {
            throw AutomationSocketError.invalidPayload("placement must be one of: rootRight, newTab, splitRight")
        }
        return placement
    }

    func resolveOptionalWindowID(args: [String: AutomationJSONValue]) throws -> UUID? {
        guard let rawWindowID = args.stringValue("windowID") else {
            return nil
        }
        guard let windowID = UUID(uuidString: rawWindowID) else {
            throw AutomationSocketError.invalidPayload("windowID must be a UUID")
        }
        guard try requiredStore().state.window(id: windowID) != nil else {
            throw AutomationSocketError.invalidPayload("windowID does not exist")
        }
        return windowID
    }

    func resolveWorkspaceSelection(args: [String: AutomationJSONValue]) throws -> WindowWorkspaceSelection {
        let store = try requiredStore()
        if let rawWorkspaceID = args.stringValue("workspaceID") {
            guard let workspaceID = UUID(uuidString: rawWorkspaceID) else {
                throw AutomationSocketError.invalidPayload("workspaceID must be a UUID")
            }
            guard let selection = store.state.workspaceSelection(containingWorkspaceID: workspaceID) else {
                throw AutomationSocketError.invalidPayload("workspaceID does not exist")
            }
            if let rawWindowID = args.stringValue("windowID") {
                guard let windowID = UUID(uuidString: rawWindowID) else {
                    throw AutomationSocketError.invalidPayload("windowID must be a UUID")
                }
                guard selection.windowID == windowID else {
                    throw AutomationSocketError.invalidPayload("workspaceID does not belong to windowID")
                }
            }
            return selection
        }

        if let rawWindowID = args.stringValue("windowID") {
            guard let windowID = UUID(uuidString: rawWindowID) else {
                throw AutomationSocketError.invalidPayload("windowID must be a UUID")
            }
            guard let selection = store.state.workspaceSelection(in: windowID) else {
                throw AutomationSocketError.invalidPayload("windowID does not exist")
            }
            return selection
        }

        if let selection = store.state.soleWorkspaceSelection() {
            return selection
        }

        if store.state.windows.isEmpty {
            throw AutomationSocketError.invalidPayload("no window is available")
        }

        throw AutomationSocketError.invalidPayload("workspaceID or windowID is required when multiple windows exist")
    }

    func resolveWorkspaceID(args: [String: AutomationJSONValue]) throws -> UUID {
        try resolveWorkspaceSelection(args: args).workspaceID
    }

    func resolveWorkspaceTabID(
        args: [String: AutomationJSONValue],
        workspaceID: UUID,
        allowSelectedTabFallback: Bool
    ) throws -> UUID {
        let store = try requiredStore()
        guard let workspace = store.state.workspacesByID[workspaceID] else {
            throw AutomationSocketError.invalidPayload("workspaceID does not exist")
        }

        if let rawTabID = args.stringValue("tabID") {
            guard let tabID = UUID(uuidString: rawTabID) else {
                throw AutomationSocketError.invalidPayload("tabID must be a UUID")
            }
            guard workspace.tabsByID[tabID] != nil else {
                throw AutomationSocketError.invalidPayload("tabID does not exist")
            }
            return tabID
        }

        if let index = args.intValue("index") {
            guard index > 0 else {
                throw AutomationSocketError.invalidPayload("index must be greater than zero")
            }
            guard index <= workspace.tabIDs.count else {
                throw AutomationSocketError.invalidPayload("index does not exist")
            }
            return workspace.tabIDs[index - 1]
        }

        if allowSelectedTabFallback, let selectedTabID = workspace.resolvedSelectedTabID {
            return selectedTabID
        }

        throw AutomationSocketError.invalidPayload("index or tabID is required")
    }

    func resolveWindowID(args: [String: AutomationJSONValue]) throws -> UUID {
        let store = try requiredStore()
        if let rawWindowID = args.stringValue("windowID") {
            guard let windowID = UUID(uuidString: rawWindowID) else {
                throw AutomationSocketError.invalidPayload("windowID must be a UUID")
            }
            guard store.state.window(id: windowID) != nil else {
                throw AutomationSocketError.invalidPayload("windowID does not exist")
            }
            return windowID
        }

        if store.state.windows.count == 1, let windowID = store.state.windows.first?.id {
            return windowID
        }

        if store.state.windows.isEmpty {
            throw AutomationSocketError.invalidPayload("no window is available")
        }

        throw AutomationSocketError.invalidPayload("windowID is required when multiple windows exist")
    }

    func resolveTerminalTarget(payload: [String: AutomationJSONValue]) throws -> (windowID: UUID, workspaceID: UUID, panelID: UUID) {
        let store = try requiredStore()
        if let rawPanelID = payload.stringValue("panelID") {
            guard let panelID = UUID(uuidString: rawPanelID) else {
                throw AutomationSocketError.invalidPayload("panelID must be a UUID")
            }
            guard let location = locatePanel(panelID) else {
                throw AutomationSocketError.invalidPayload("panelID does not exist")
            }
            guard let workspace = store.state.workspacesByID[location.workspaceID],
                  let panelState = workspace.panelState(for: panelID),
                  case .terminal = panelState else {
                throw AutomationSocketError.invalidPayload("panelID is not a terminal panel")
            }
            return (location.windowID, location.workspaceID, panelID)
        }

        let selection = try resolveWorkspaceSelection(args: payload)
        let workspaceID = selection.workspaceID
        let workspace = selection.workspace
        if let focusedPanelID = workspace.focusedPanelID,
           let panelState = workspace.panels[focusedPanelID],
           case .terminal = panelState {
            return (selection.windowID, workspaceID, focusedPanelID)
        }
        for leaf in workspace.layoutTree.allSlotInfos {
            let panelID = leaf.panelID
            if let panelState = workspace.panels[panelID], case .terminal = panelState {
                return (selection.windowID, workspaceID, panelID)
            }
        }
        throw AutomationSocketError.invalidPayload("workspace has no terminal panel to target")
    }

    func resolveLocalDocumentTarget(
        payload: [String: AutomationJSONValue]
    ) throws -> (workspaceID: UUID, panelID: UUID, webState: WebPanelState) {
        let store = try requiredStore()
        if let rawPanelID = payload.stringValue("panelID") {
            guard let panelID = UUID(uuidString: rawPanelID) else {
                throw AutomationSocketError.invalidPayload("panelID must be a UUID")
            }
            guard let location = locatePanel(panelID) else {
                throw AutomationSocketError.invalidPayload("panelID does not exist")
            }
            guard let workspace = store.state.workspacesByID[location.workspaceID],
                  let panelState = workspace.panelState(for: panelID),
                  case .web(let webState) = panelState,
                  webState.definition == .localDocument else {
                throw AutomationSocketError.invalidPayload("panelID is not a local document panel")
            }
            return (location.workspaceID, panelID, webState)
        }

        let workspaceID = try resolveWorkspaceID(args: payload)
        guard let workspace = store.state.workspacesByID[workspaceID] else {
            throw AutomationSocketError.invalidPayload("workspaceID does not exist")
        }
        if let focusedPanelID = workspace.focusedPanelID,
           let panelState = workspace.panels[focusedPanelID],
           case .web(let webState) = panelState,
           webState.definition == .localDocument {
            return (workspaceID, focusedPanelID, webState)
        }
        for leaf in workspace.layoutTree.allSlotInfos {
            let panelID = leaf.panelID
            guard let panelState = workspace.panels[panelID],
                  case .web(let webState) = panelState,
                  webState.definition == .localDocument else {
                continue
            }
            return (workspaceID, panelID, webState)
        }
        throw AutomationSocketError.invalidPayload("workspace has no local document panel to target")
    }

    func resolveBrowserTarget(
        payload: [String: AutomationJSONValue]
    ) throws -> (workspaceID: UUID, panelID: UUID, webState: WebPanelState) {
        let store = try requiredStore()
        if let rawPanelID = payload.stringValue("panelID") {
            guard let panelID = UUID(uuidString: rawPanelID) else {
                throw AutomationSocketError.invalidPayload("panelID must be a UUID")
            }
            guard let location = locatePanel(panelID) else {
                throw AutomationSocketError.invalidPayload("panelID does not exist")
            }
            guard let workspace = store.state.workspacesByID[location.workspaceID],
                  let panelState = workspace.panelState(for: panelID),
                  case .web(let webState) = panelState,
                  webState.definition == .browser else {
                throw AutomationSocketError.invalidPayload("panelID is not a browser panel")
            }
            return (location.workspaceID, panelID, webState)
        }

        let workspaceID = try resolveWorkspaceID(args: payload)
        guard let workspace = store.state.workspacesByID[workspaceID] else {
            throw AutomationSocketError.invalidPayload("workspaceID does not exist")
        }
        if let focusedPanelID = workspace.focusedPanelID,
           let panelState = workspace.panels[focusedPanelID],
           case .web(let webState) = panelState,
           webState.definition == .browser {
            return (workspaceID, focusedPanelID, webState)
        }
        for leaf in workspace.layoutTree.allSlotInfos {
            let panelID = leaf.panelID
            guard let panelState = workspace.panels[panelID],
                  case .web(let webState) = panelState,
                  webState.definition == .browser else {
                continue
            }
            return (workspaceID, panelID, webState)
        }
        throw AutomationSocketError.invalidPayload("workspace has no browser panel to target")
    }

    func resolveScratchpadTarget(
        payload: [String: AutomationJSONValue]
    ) throws -> (workspaceID: UUID, panelID: UUID, webState: WebPanelState) {
        let store = try requiredStore()
        if let rawPanelID = payload.stringValue("panelID") {
            guard let panelID = UUID(uuidString: rawPanelID) else {
                throw AutomationSocketError.invalidPayload("panelID must be a UUID")
            }
            guard let location = locatePanel(panelID) else {
                throw AutomationSocketError.invalidPayload("panelID does not exist")
            }
            guard let workspace = store.state.workspacesByID[location.workspaceID],
                  let panelState = workspace.panelState(for: panelID),
                  case .web(let webState) = panelState,
                  webState.definition == .scratchpad else {
                throw AutomationSocketError.invalidPayload("panelID is not a Scratchpad panel")
            }
            return (location.workspaceID, panelID, webState)
        }

        let workspaceID = try resolveWorkspaceID(args: payload)
        guard let workspace = store.state.workspacesByID[workspaceID] else {
            throw AutomationSocketError.invalidPayload("workspaceID does not exist")
        }
        if let focusedPanelID = workspace.focusedPanelID,
           let panelState = workspace.panels[focusedPanelID],
           case .web(let webState) = panelState,
           webState.definition == .scratchpad {
            return (workspaceID, focusedPanelID, webState)
        }
        for leaf in workspace.layoutTree.allSlotInfos {
            let panelID = leaf.panelID
            guard let panelState = workspace.panels[panelID],
                  case .web(let webState) = panelState,
                  webState.definition == .scratchpad else {
                continue
            }
            return (workspaceID, panelID, webState)
        }
        throw AutomationSocketError.invalidPayload("workspace has no Scratchpad panel to target")
    }

    func terminalStateSnapshot(
        windowID: UUID,
        workspaceID: UUID,
        panelID: UUID
    ) throws -> [String: AutomationJSONValue] {
        let store = try requiredStore()
        guard let workspace = store.state.workspacesByID[workspaceID] else {
            throw AutomationSocketError.invalidPayload("workspaceID does not exist")
        }
        guard let panelState = workspace.panelState(for: panelID),
              case .terminal(let terminalState) = panelState else {
            throw AutomationSocketError.invalidPayload("panelID is not a terminal panel")
        }
        return [
            "windowID": .string(windowID.uuidString),
            "workspaceID": .string(workspaceID.uuidString),
            "panelID": .string(panelID.uuidString),
            "title": .string(terminalState.title),
            "cwd": .string(terminalState.cwd),
            "shell": .string(terminalState.shell),
            "profileID": terminalState.profileBinding.map { .string($0.profileID) } ?? .null,
        ]
    }

    func localDocumentPanelStateSnapshot(
        workspaceID: UUID,
        panelID: UUID,
        webState: WebPanelState,
        runtimeState: LocalDocumentPanelRuntimeAutomationState
    ) -> [String: AutomationJSONValue] {
        var result: [String: AutomationJSONValue] = [
            "workspaceID": .string(workspaceID.uuidString),
            "panelID": .string(panelID.uuidString),
            "stateTitle": .string(webState.title),
            "stateFilePath": webState.filePath.map { .string($0) } ?? .null,
            "stateFormat": webState.localDocument.map { .string($0.format.rawValue) } ?? .null,
            "hostLifecycleState": .string(runtimeState.lifecycleState.automationLabel),
            "hostAttachmentID": runtimeState.lifecycleState.attachmentToken.map { .string($0.rawValue.uuidString) } ?? .null,
            "currentTheme": .string(runtimeState.currentTheme.rawValue),
            "hasCurrentBootstrap": .bool(runtimeState.currentBootstrap != nil),
            "pendingBootstrapScript": .bool(runtimeState.hasPendingBootstrapScript),
            "currentAssetPath": runtimeState.currentAssetPath.map { .string($0) } ?? .null,
            "searchIsPresented": .bool(runtimeState.searchState?.isPresented == true),
            "searchQuery": runtimeState.searchState.map { .string($0.query) } ?? .null,
            "searchLastMatchFound": runtimeState.searchState?.lastMatchFound.map { .bool($0) } ?? .null,
            "searchFieldFocused": .bool(runtimeState.isSearchFieldFocused),
        ]

        if let bootstrap = runtimeState.currentBootstrap {
            result["bootstrapContractVersion"] = .int(bootstrap.contractVersion)
            result["bootstrapFilePath"] = bootstrap.filePath.map { .string($0) } ?? .null
            result["bootstrapDisplayName"] = .string(bootstrap.displayName)
            result["bootstrapFormat"] = .string(bootstrap.format.rawValue)
            result["bootstrapShouldHighlight"] = .bool(bootstrap.shouldHighlight)
            result["bootstrapContentRevision"] = .int(bootstrap.contentRevision)
            result["bootstrapIsEditing"] = .bool(bootstrap.isEditing)
            result["bootstrapIsDirty"] = .bool(bootstrap.isDirty)
            result["bootstrapHasExternalConflict"] = .bool(bootstrap.hasExternalConflict)
            result["bootstrapIsSaving"] = .bool(bootstrap.isSaving)
            result["bootstrapSaveErrorMessage"] = bootstrap.saveErrorMessage.map { .string($0) } ?? .null
            result["bootstrapTheme"] = .string(bootstrap.theme.rawValue)
            result["bootstrapTextScale"] = .double(bootstrap.textScale)
            result["bootstrapContentLength"] = .int(bootstrap.content.utf8.count)
            result["bootstrapContentSHA256"] = .string(Self.sha256Hex(bootstrap.content))
        } else {
            result["bootstrapContractVersion"] = .null
            result["bootstrapFilePath"] = .null
            result["bootstrapDisplayName"] = .null
            result["bootstrapFormat"] = .null
            result["bootstrapShouldHighlight"] = .null
            result["bootstrapContentRevision"] = .null
            result["bootstrapIsEditing"] = .null
            result["bootstrapIsDirty"] = .null
            result["bootstrapHasExternalConflict"] = .null
            result["bootstrapIsSaving"] = .null
            result["bootstrapSaveErrorMessage"] = .null
            result["bootstrapTheme"] = .null
            result["bootstrapTextScale"] = .null
            result["bootstrapContentLength"] = .null
            result["bootstrapContentSHA256"] = .null
        }

        return result
    }

    func browserPanelStateSnapshot(
        workspaceID: UUID,
        panelID: UUID,
        webState: WebPanelState,
        runtimeState: BrowserPanelRuntimeAutomationState
    ) -> [String: AutomationJSONValue] {
        [
            "workspaceID": .string(workspaceID.uuidString),
            "panelID": .string(panelID.uuidString),
            "stateTitle": .string(webState.title),
            "stateRestorableURL": webState.restorableURL.map { .string($0) } ?? .null,
            "statePageZoom": .double(webState.effectiveBrowserPageZoom),
            "statePageZoomOverride": webState.browserPageZoom.map { .double($0) } ?? .null,
            "hostLifecycleState": .string(runtimeState.lifecycleState.automationLabel),
            "hostAttachmentID": runtimeState.lifecycleState.attachmentToken.map { .string($0.rawValue.uuidString) } ?? .null,
            "runtimePageZoom": .double(runtimeState.pageZoom),
        ]
    }

    func scratchpadPanelStateSnapshot(
        workspaceID: UUID,
        panelID: UUID,
        webState: WebPanelState,
        runtimeState: ScratchpadPanelRuntimeAutomationState
    ) -> [String: AutomationJSONValue] {
        var result: [String: AutomationJSONValue] = [
            "workspaceID": .string(workspaceID.uuidString),
            "panelID": .string(panelID.uuidString),
            "stateTitle": .string(webState.title),
            "stateDocumentID": webState.scratchpad.map { .string($0.documentID.uuidString) } ?? .null,
            "stateRevision": webState.scratchpad.map { .int($0.revision) } ?? .null,
            "stateSessionID": webState.scratchpad?.sessionLink.map { .string($0.sessionID) } ?? .null,
            "hostLifecycleState": .string(runtimeState.lifecycleState.automationLabel),
            "hostAttachmentID": runtimeState.lifecycleState.attachmentToken.map { .string($0.rawValue.uuidString) } ?? .null,
            "currentTheme": .string(runtimeState.currentTheme.rawValue),
            "hasCurrentBootstrap": .bool(runtimeState.currentBootstrap != nil),
            "pendingBootstrapScript": .bool(runtimeState.hasPendingBootstrapScript),
            "currentAssetPath": runtimeState.currentAssetPath.map { .string($0) } ?? .null,
        ]

        if let bootstrap = runtimeState.currentBootstrap {
            result["bootstrapContractVersion"] = .int(bootstrap.contractVersion)
            result["bootstrapDocumentID"] = bootstrap.documentID.map { .string($0.uuidString) } ?? .null
            result["bootstrapDisplayName"] = .string(bootstrap.displayName)
            result["bootstrapRevision"] = bootstrap.revision.map { .int($0) } ?? .null
            result["bootstrapMissingDocument"] = .bool(bootstrap.missingDocument)
            result["bootstrapMessage"] = bootstrap.message.map { .string($0) } ?? .null
            result["bootstrapTheme"] = .string(bootstrap.theme.rawValue)
            result["bootstrapContentLength"] = bootstrap.contentHTML.map { .int($0.utf8.count) } ?? .null
            result["bootstrapContentSHA256"] = bootstrap.contentHTML.map { .string(Self.sha256Hex($0)) } ?? .null
        } else {
            result["bootstrapContractVersion"] = .null
            result["bootstrapDocumentID"] = .null
            result["bootstrapDisplayName"] = .null
            result["bootstrapRevision"] = .null
            result["bootstrapMissingDocument"] = .null
            result["bootstrapMessage"] = .null
            result["bootstrapTheme"] = .null
            result["bootstrapContentLength"] = .null
            result["bootstrapContentSHA256"] = .null
        }

        return result
    }

    func workspaceSnapshot(workspaceID: UUID) throws -> [String: AutomationJSONValue] {
        let store = try requiredStore()
        guard let workspace = store.state.workspacesByID[workspaceID] else {
            throw AutomationSocketError.invalidPayload("workspaceID does not exist")
        }

        let slotInfos = workspace.layoutTree.allSlotInfos
        let tabIDs = workspace.tabIDs.map { AutomationJSONValue.string($0.uuidString) }
        let slotIDs = slotInfos.map { AutomationJSONValue.string($0.slotID.uuidString) }
        let slotPanelIDs = slotInfos.map { AutomationJSONValue.string($0.panelID.uuidString) }
        let slotMappings = slotInfos.map { slotInfo in
            AutomationJSONValue.object([
                "slotID": .string(slotInfo.slotID.uuidString),
                "panelID": .string(slotInfo.panelID.uuidString),
            ])
        }
        let selectedTabID = workspace.resolvedSelectedTabID
        let selectedTabIndex: Int? = selectedTabID.flatMap { tabID in
            workspace.tabIDs.firstIndex(of: tabID).map { $0 + 1 }
        }
        let rootSplitRatio: AutomationJSONValue
        switch workspace.layoutTree {
        case .split(_, _, let ratio, _, _):
            rootSplitRatio = .double(ratio)
        case .slot:
            rootSplitRatio = .null
        }

        return [
            "workspaceID": .string(workspaceID.uuidString),
            "tabCount": .int(workspace.tabIDs.count),
            "selectedTabID": selectedTabID.map { .string($0.uuidString) } ?? .null,
            "selectedTabIndex": selectedTabIndex.map { .int($0) } ?? .null,
            "tabIDs": .array(tabIDs),
            "slotCount": .int(slotInfos.count),
            "panelCount": .int(workspace.panels.count),
            "focusedPanelID": workspace.focusedPanelID.map { .string($0.uuidString) } ?? .null,
            "rootSplitRatio": rootSplitRatio,
            "slotIDs": .array(slotIDs),
            "slotPanelIDs": .array(slotPanelIDs),
            "slotMappings": .array(slotMappings),
            "layoutSignature": .string(layoutSignature(for: workspace)),
        ]
    }

    func layoutSignature(for workspace: WorkspaceState) -> String {
        let slotSignature = workspace.layoutTree.allSlotInfos
            .map { "\($0.slotID.uuidString):\($0.panelID.uuidString)" }
            .joined(separator: ",")
        let focusSignature = workspace.focusedPanelID?.uuidString ?? "nil"
        let rootSignature: String
        switch workspace.layoutTree {
        case .split(_, _, let ratio, _, _):
            rootSignature = String(format: "%.6f", ratio)
        case .slot:
            rootSignature = "slot"
        }
        return "focus=\(focusSignature);root=\(rootSignature);slots=\(slotSignature)"
    }

    func normalizedOptionalText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func locatePanel(_ panelID: UUID) -> (windowID: UUID, workspaceID: UUID)? {
        guard let store else {
            return nil
        }
        guard let selection = store.state.workspaceSelection(containingPanelID: panelID) else {
            return nil
        }
        return (selection.windowID, selection.workspaceID)
    }
}

private extension Dictionary where Key == String, Value == AutomationJSONValue {
    func stringValue(_ key: String) -> String? {
        switch self[key] {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        default:
            return nil
        }
    }

    func intValue(_ key: String) -> Int? {
        switch self[key] {
        case .int(let value):
            return value
        case .string(let value):
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    func boolValue(_ key: String) -> Bool? {
        switch self[key] {
        case .bool(let value):
            return value
        case .string(let value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    func uuid(_ key: String) -> UUID? {
        guard let value = stringValue(key) else {
            return nil
        }
        return UUID(uuidString: value)
    }

    func stringArrayValue(_ key: String) -> [String] {
        switch self[key] {
        case .string(let value):
            return [value]
        case .array(let values):
            return values.compactMap {
                switch $0 {
                case .string(let value):
                    return value
                case .int(let value):
                    return String(value)
                case .double(let value):
                    return String(value)
                case .bool(let value):
                    return value ? "true" : "false"
                default:
                    return nil
                }
            }
        default:
            return []
        }
    }
}
