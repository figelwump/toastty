import AppKit
import CoreState
import Foundation
import UniformTypeIdentifiers
#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit
#endif

struct PreparedImageFileDrop {
    let targetPanelID: UUID
    let imageFileURLs: [URL]
}

enum AutomationImageFileDropResult {
    case sent(imageCount: Int)
    case noImageFiles
    case unavailableSurface
}

@MainActor
final class TerminalRuntimeRegistry: ObservableObject {
    private var controllers: [UUID: TerminalSurfaceController] = [:]
    private weak var store: AppStore?
    #if TOASTTY_HAS_GHOSTTY_KIT
    private var panelIDBySurfaceHandle: [UInt: UUID] = [:]
    private var pendingSplitSourcePanelByNewPanelID: [UUID: UUID] = [:]
    private var previousSelectedWorkspaceID: UUID?
    private var visibilityPulseTask: Task<Void, Never>?
    private var processWorkingDirectoryRefreshTask: Task<Void, Never>?
    private let processWorkingDirectoryResolver = TerminalProcessWorkingDirectoryResolver()
    #endif

    deinit {
        #if TOASTTY_HAS_GHOSTTY_KIT
        visibilityPulseTask?.cancel()
        processWorkingDirectoryRefreshTask?.cancel()
        #endif
    }

    func bind(store: AppStore) {
        if let existingStore = self.store {
            precondition(existingStore === store, "TerminalRuntimeRegistry cannot be rebound to a different AppStore.")
        }
        self.store = store
        store.onActionApplied = { [weak self] action, previousState, nextState in
            self?.handleAppliedStoreAction(
                action,
                previousState: previousState,
                nextState: nextState
            )
        }
        configureGhosttyActionHandler()
        startProcessWorkingDirectoryRefreshLoopIfNeeded()
    }

    @discardableResult
    func splitFocusedPane(workspaceID: UUID, orientation: SplitOrientation) -> Bool {
        sendSplitAction(.splitFocusedPane(workspaceID: workspaceID, orientation: orientation))
    }

    @discardableResult
    func splitFocusedPaneInDirection(workspaceID: UUID, direction: PaneSplitDirection) -> Bool {
        sendSplitAction(.splitFocusedPaneInDirection(workspaceID: workspaceID, direction: direction))
    }

    func controller(for panelID: UUID) -> TerminalSurfaceController {
        if let existing = controllers[panelID] {
            return existing
        }

        let created = TerminalSurfaceController(panelID: panelID, registry: self)
        controllers[panelID] = created
        return created
    }

    func synchronize(with state: AppState) {
        let livePanelIDs = Set(
            state.workspacesByID.values.flatMap { workspace in
                workspace.panels.compactMap { panelID, panelState in
                    if case .terminal = panelState {
                        return panelID
                    }
                    return nil
                }
            }
        )

        for panelID in controllers.keys where !livePanelIDs.contains(panelID) {
            controllers[panelID]?.invalidate()
            controllers.removeValue(forKey: panelID)
            #if TOASTTY_HAS_GHOSTTY_KIT
            processWorkingDirectoryResolver.invalidate(panelID: panelID)
            #endif
        }
        #if TOASTTY_HAS_GHOSTTY_KIT
        pendingSplitSourcePanelByNewPanelID = pendingSplitSourcePanelByNewPanelID.filter {
            livePanelIDs.contains($0.key) && livePanelIDs.contains($0.value)
        }
        #endif

        handleGhosttyWorkspaceSelectionPulseIfNeeded(state: state)
    }

    func applyGlobalFontChange(from previousPoints: Double, to nextPoints: Double) {
        applyGhosttyGlobalFontChangeIfNeeded(from: previousPoints, to: nextPoints)
    }

    func automationSendText(_ text: String, submit: Bool, panelID: UUID) -> Bool {
        guard let controller = controllers[panelID] else {
            return false
        }
        return controller.automationSendText(text, submit: submit)
    }

    func automationReadVisibleText(panelID: UUID) -> String? {
        guard let controller = controllers[panelID] else {
            return nil
        }
        return controller.automationReadVisibleText()
    }

    func automationDropImageFiles(_ filePaths: [String], panelID: UUID) -> AutomationImageFileDropResult {
        guard let controller = controllers[panelID] else {
            return .unavailableSurface
        }

        let candidateURLs = filePaths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let imageFileURLs = Self.normalizedImageFileURLs(from: candidateURLs)
        guard imageFileURLs.isEmpty == false else {
            return .noImageFiles
        }

        if controller.handleImageFileDrop(imageFileURLs) {
            return .sent(imageCount: imageFileURLs.count)
        }
        return .unavailableSurface
    }

    func prepareImageFileDrop(from urls: [URL]) -> PreparedImageFileDrop? {
        #if TOASTTY_HAS_GHOSTTY_KIT
        guard let store else { return nil }
        let imageFileURLs = Self.normalizedImageFileURLs(from: urls)
        guard imageFileURLs.isEmpty == false else { return nil }
        guard let targetPanelID = focusedTerminalPanelIDForDrop(state: store.state) else {
            return nil
        }
        let targetController = controller(for: targetPanelID)
        guard targetController.canAcceptImageFileDrop() else {
            return nil
        }
        return PreparedImageFileDrop(targetPanelID: targetPanelID, imageFileURLs: imageFileURLs)
        #else
        _ = urls
        return nil
        #endif
    }

    @discardableResult
    func handlePreparedImageFileDrop(_ drop: PreparedImageFileDrop) -> Bool {
        #if TOASTTY_HAS_GHOSTTY_KIT
        let targetController = controller(for: drop.targetPanelID)
        let handled = targetController.handleImageFileDrop(drop.imageFileURLs)
        if handled {
            ToasttyLog.debug(
                "Forwarded image file drop to focused terminal",
                category: .input,
                metadata: [
                    "panel_id": drop.targetPanelID.uuidString,
                    "image_count": String(drop.imageFileURLs.count),
                ]
            )
        } else {
            ToasttyLog.warning(
                "Failed to forward image file drop to focused terminal",
                category: .input,
                metadata: [
                    "panel_id": drop.targetPanelID.uuidString,
                    "image_count": String(drop.imageFileURLs.count),
                ]
            )
        }
        return handled
        #else
        _ = drop
        return false
        #endif
    }
}

private extension TerminalRuntimeRegistry {
    @discardableResult
    func sendSplitAction(_ action: AppAction) -> Bool {
        guard let store else { return false }
        return store.send(action)
    }
}

#if TOASTTY_HAS_GHOSTTY_KIT
private extension TerminalRuntimeRegistry {
    enum SplitSourceSurfaceState {
        case none
        case pending
        case ready(sourcePanelID: UUID, surface: ghostty_surface_t)
    }

    func handleAppliedStoreAction(
        _ action: AppAction,
        previousState: AppState,
        nextState: AppState
    ) {
        let splitWorkspaceID: UUID
        switch action {
        case .splitFocusedPane(workspaceID: let workspaceID, orientation: _):
            splitWorkspaceID = workspaceID
        case .splitFocusedPaneInDirection(workspaceID: let workspaceID, direction: _):
            splitWorkspaceID = workspaceID
        default:
            return
        }

        registerPendingSplitSourceIfNeeded(
            workspaceID: splitWorkspaceID,
            previousState: previousState,
            nextState: nextState
        )
    }

    func configureGhosttyActionHandler() {
        GhosttyRuntimeManager.shared.actionHandler = self
    }

    func handleGhosttyWorkspaceSelectionPulseIfNeeded(state: AppState) {
        pulseVisibleSurfacesIfWorkspaceSwitched(state: state)
    }

    func applyGhosttyGlobalFontChangeIfNeeded(from previousPoints: Double, to nextPoints: Double) {
        guard previousPoints != nextPoints else { return }
        for controller in controllers.values {
            controller.applyGhosttyGlobalFontChange(from: previousPoints, to: nextPoints)
        }
    }

    func registerPendingSplitSourceIfNeeded(workspaceID: UUID, previousState: AppState, nextState: AppState) {
        guard let previousWorkspace = previousState.workspacesByID[workspaceID],
              let nextWorkspace = nextState.workspacesByID[workspaceID],
              let sourcePanelID = resolveSplitSourcePanelID(in: previousWorkspace) else {
            return
        }

        let createdPanelIDs = Set(nextWorkspace.panels.keys).subtracting(previousWorkspace.panels.keys)
        guard createdPanelIDs.count == 1,
              let newPanelID = createdPanelIDs.first,
              case .terminal = nextWorkspace.panels[newPanelID],
              case .terminal = nextWorkspace.panels[sourcePanelID] else {
            return
        }

        pendingSplitSourcePanelByNewPanelID[newPanelID] = sourcePanelID
        ToasttyLog.debug(
            "Registered split source panel for Ghostty surface inheritance",
            category: .terminal,
            metadata: [
                "workspace_id": workspaceID.uuidString,
                "source_panel_id": sourcePanelID.uuidString,
                "new_panel_id": newPanelID.uuidString,
            ]
        )
    }

    func splitSourceSurfaceState(for newPanelID: UUID) -> SplitSourceSurfaceState {
        guard let sourcePanelID = pendingSplitSourcePanelByNewPanelID[newPanelID] else {
            return .none
        }
        guard let sourceSurface = controllers[sourcePanelID]?.currentGhosttySurface() else {
            return .pending
        }
        return .ready(sourcePanelID: sourcePanelID, surface: sourceSurface)
    }

    func consumeSplitSource(for newPanelID: UUID) {
        pendingSplitSourcePanelByNewPanelID.removeValue(forKey: newPanelID)
    }

    private func resolveSplitSourcePanelID(in workspace: WorkspaceState) -> UUID? {
        if let focusedPanelID = workspace.focusedPanelID,
           workspace.paneTree.leafContaining(panelID: focusedPanelID) != nil,
           let focusedPanelState = workspace.panels[focusedPanelID],
           focusedPanelState.kind == .terminal {
            return focusedPanelID
        }

        for leaf in workspace.paneTree.allLeafInfos {
            for panelID in leaf.tabPanelIDs where workspace.paneTree.leafContaining(panelID: panelID) != nil {
                guard let panelState = workspace.panels[panelID] else { continue }
                if panelState.kind == .terminal {
                    return panelID
                }
            }
        }
        return nil
    }
}
#else
private extension TerminalRuntimeRegistry {
    func handleAppliedStoreAction(
        _: AppAction,
        previousState _: AppState,
        nextState _: AppState
    ) {}

    func configureGhosttyActionHandler() {}

    func handleGhosttyWorkspaceSelectionPulseIfNeeded(state _: AppState) {}

    func applyGhosttyGlobalFontChangeIfNeeded(from _: Double, to _: Double) {}

    func startProcessWorkingDirectoryRefreshLoopIfNeeded() {}
}
#endif

private extension TerminalRuntimeRegistry {
    static func normalizedImageFileURLs(from urls: [URL]) -> [URL] {
        var normalized: [URL] = []
        var seenPaths: Set<String> = []

        for url in urls {
            let fileURL = url.standardizedFileURL
            guard fileURL.isFileURL else { continue }
            guard isImageFileURL(fileURL) else { continue }
            let path = fileURL.path
            guard seenPaths.insert(path).inserted else { continue }
            normalized.append(fileURL)
        }

        return normalized
    }

    static func isImageFileURL(_ fileURL: URL) -> Bool {
        if let contentType = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return contentType.conforms(to: .image)
        }
        if let inferredType = UTType(filenameExtension: fileURL.pathExtension) {
            return inferredType.conforms(to: .image)
        }
        return false
    }
}

#if TOASTTY_HAS_GHOSTTY_KIT
private extension TerminalRuntimeRegistry {
    func selectedWorkspaceID(state: AppState) -> UUID? {
        guard let selectedWindowID = state.selectedWindowID,
              let selectedWindow = state.windows.first(where: { $0.id == selectedWindowID }) else {
            return nil
        }
        return selectedWindow.selectedWorkspaceID ?? selectedWindow.workspaceIDs.first
    }

    func resolvedActionPanelID(in workspace: WorkspaceState) -> UUID? {
        if let focusedPanelID = workspace.focusedPanelID,
           workspace.panels[focusedPanelID] != nil,
           workspace.paneTree.leafContaining(panelID: focusedPanelID) != nil {
            return focusedPanelID
        }

        for leaf in workspace.paneTree.allLeafInfos {
            guard leaf.tabPanelIDs.isEmpty == false else { continue }
            let selectedIndex = min(max(leaf.selectedIndex, 0), leaf.tabPanelIDs.count - 1)
            let preferredPanelID = leaf.tabPanelIDs[selectedIndex]
            if workspace.panels[preferredPanelID] != nil {
                return preferredPanelID
            }

            if let firstValidPanelID = leaf.tabPanelIDs.first(where: { workspace.panels[$0] != nil }) {
                return firstValidPanelID
            }
        }

        return nil
    }

    func focusedTerminalPanelIDForDrop(state: AppState) -> UUID? {
        guard let workspaceID = selectedWorkspaceID(state: state),
              let workspace = state.workspacesByID[workspaceID],
              let focusedPanelID = workspace.focusedPanelID,
              let panelState = workspace.panels[focusedPanelID],
              case .terminal = panelState,
              workspace.paneTree.leafContaining(panelID: focusedPanelID) != nil else {
            return nil
        }
        return focusedPanelID
    }

    func register(surface: ghostty_surface_t, for panelID: UUID) {
        panelIDBySurfaceHandle[UInt(bitPattern: surface)] = panelID
    }

    func unregister(surface: ghostty_surface_t, for panelID: UUID) {
        let key = UInt(bitPattern: surface)
        if panelIDBySurfaceHandle[key] == panelID {
            panelIDBySurfaceHandle.removeValue(forKey: key)
        }
        processWorkingDirectoryResolver.invalidate(panelID: panelID)
    }

    func panelID(for surface: ghostty_surface_t) -> UUID? {
        panelIDBySurfaceHandle[UInt(bitPattern: surface)]
    }

    func workspaceID(containing panelID: UUID, state: AppState) -> UUID? {
        for window in state.windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = state.workspacesByID[workspaceID] else { continue }
                guard workspace.panels[panelID] != nil else { continue }
                if workspace.paneTree.leafContaining(panelID: panelID) != nil {
                    return workspaceID
                }
            }
        }
        return nil
    }

    func reconcileSurfaceWorkingDirectory(panelID: UUID, workingDirectory: String?, source: String) {
        guard let normalizedWorkingDirectory = Self.normalizedCWDValue(workingDirectory) else {
            return
        }
        guard let store else {
            return
        }

        let state = store.state
        guard let workspaceID = workspaceID(containing: panelID, state: state),
              let workspace = state.workspacesByID[workspaceID],
              let panelState = workspace.panels[panelID],
              case .terminal(let terminalState) = panelState else {
            return
        }
        guard Self.cwdValuesDiffer(normalizedWorkingDirectory, terminalState.cwd) else {
            return
        }

        let handled = store.send(
            .updateTerminalPanelMetadata(
                panelID: panelID,
                title: nil,
                cwd: normalizedWorkingDirectory
            )
        )
        if handled {
            ToasttyLog.debug(
                "Synchronized terminal cwd from Ghostty surface state",
                category: .terminal,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "panel_id": panelID.uuidString,
                    "source": source,
                    "cwd_sample": String(normalizedWorkingDirectory.prefix(120)),
                ]
            )
        } else {
            ToasttyLog.warning(
                "Reducer rejected terminal cwd sync from Ghostty surface state",
                category: .terminal,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "panel_id": panelID.uuidString,
                    "source": source,
                ]
            )
        }
    }

    func resolvedWorkingDirectoryFromProcess(panelID: UUID) -> String? {
        guard let processWorkingDirectory = processWorkingDirectoryResolver.resolveWorkingDirectory(for: panelID) else {
            return nil
        }
        return Self.normalizedCWDValue(processWorkingDirectory)
    }

    @discardableResult
    func refreshWorkingDirectoryFromProcessIfNeeded(panelID: UUID, source: String) -> String? {
        guard let normalizedWorkingDirectory = resolvedWorkingDirectoryFromProcess(panelID: panelID) else {
            return nil
        }

        reconcileSurfaceWorkingDirectory(
            panelID: panelID,
            workingDirectory: normalizedWorkingDirectory,
            source: source
        )
        return normalizedWorkingDirectory
    }

    func startProcessWorkingDirectoryRefreshLoopIfNeeded() {
        guard processWorkingDirectoryRefreshTask == nil else { return }
        processWorkingDirectoryRefreshTask = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                guard let self else { return }
                guard let store else {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }

                self.refreshVisibleTerminalWorkingDirectoriesFromProcess(state: store.state)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func refreshVisibleTerminalWorkingDirectoriesFromProcess(state: AppState) {
        guard let selectedWorkspaceID = selectedWorkspaceID(state: state),
              let workspace = state.workspacesByID[selectedWorkspaceID] else {
            return
        }

        let panelIDs = visibleTerminalPanelIDs(in: workspace)
        guard panelIDs.isEmpty == false else { return }

        for panelID in panelIDs {
            _ = refreshWorkingDirectoryFromProcessIfNeeded(
                panelID: panelID,
                source: "process_poll"
            )
        }
    }

    func pulseVisibleSurfacesIfWorkspaceSwitched(state: AppState) {
        let currentSelectedWorkspaceID = selectedWorkspaceID(state: state)
        guard currentSelectedWorkspaceID != previousSelectedWorkspaceID else { return }

        visibilityPulseTask?.cancel()
        visibilityPulseTask = nil

        guard let currentSelectedWorkspaceID else {
            previousSelectedWorkspaceID = nil
            return
        }

        guard state.workspacesByID[currentSelectedWorkspaceID] != nil else {
            // Do not consume the transition until workspace data is available.
            return
        }

        previousSelectedWorkspaceID = currentSelectedWorkspaceID
        scheduleVisibilityPulse(for: currentSelectedWorkspaceID)
    }

    func scheduleVisibilityPulse(for workspaceID: UUID) {
        ToasttyLog.debug(
            "Scheduling Ghostty visibility refresh pulse after workspace switch",
            category: .ghostty,
            metadata: ["workspace_id": workspaceID.uuidString]
        )

        visibilityPulseTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Defer pulses so SwiftUI/NSViewRepresentable attachment and layout can settle.
            await Task.yield()
            guard Task.isCancelled == false else { return }
            self.pulseVisibleSurfaces(in: workspaceID)

            await Task.yield()
            guard Task.isCancelled == false else { return }
            self.pulseVisibleSurfaces(in: workspaceID)
        }
    }

    func pulseVisibleSurfaces(in workspaceID: UUID) {
        guard let store else { return }
        let currentState = store.state
        guard selectedWorkspaceID(state: currentState) == workspaceID,
              let workspace = currentState.workspacesByID[workspaceID] else {
            return
        }

        let panelIDs = visibleTerminalPanelIDs(in: workspace)
        guard panelIDs.isEmpty == false else { return }
        pulseSurfaces(panelIDs: panelIDs)
    }

    func visibleTerminalPanelIDs(in workspace: WorkspaceState) -> Set<UUID> {
        var panelIDs: Set<UUID> = []
        for leaf in workspace.paneTree.allLeafInfos {
            guard leaf.tabPanelIDs.isEmpty == false else { continue }
            let selectedIndex = min(max(leaf.selectedIndex, 0), leaf.tabPanelIDs.count - 1)
            let selectedPanelID = leaf.tabPanelIDs[selectedIndex]
            guard let panelState = workspace.panels[selectedPanelID],
                  case .terminal = panelState else {
                continue
            }
            panelIDs.insert(selectedPanelID)
        }
        return panelIDs
    }

    func pulseSurfaces(panelIDs: Set<UUID>) {
        for panelID in panelIDs {
            controllers[panelID]?.pulseVisibilityRefresh()
        }
    }
}
#endif

#if TOASTTY_HAS_GHOSTTY_KIT
extension TerminalRuntimeRegistry: GhosttyRuntimeActionHandling {
    func handleGhosttyRuntimeAction(_ action: GhosttyRuntimeAction) -> Bool {
        guard let store else {
            ToasttyLog.warning(
                "Ghostty action dropped because store is unavailable",
                category: .terminal,
                metadata: ["intent": action.logIntentName]
            )
            return false
        }
        let state = store.state

        let panelID: UUID
        let workspaceIDForAction: UUID
        if let surfaceHandle = action.surfaceHandle {
            guard let resolvedPanelID = panelIDBySurfaceHandle[surfaceHandle],
                  let workspaceIDForSurface = workspaceID(containing: resolvedPanelID, state: state) else {
                ToasttyLog.debug(
                    "Ghostty surface action could not resolve panel/workspace",
                    category: .terminal,
                    metadata: [
                        "intent": action.logIntentName,
                        "surface_handle": String(surfaceHandle),
                    ]
                )
                return false
            }
            panelID = resolvedPanelID
            workspaceIDForAction = workspaceIDForSurface
        } else {
            guard let selectedWorkspaceID = selectedWorkspaceID(state: state),
                  let workspace = state.workspacesByID[selectedWorkspaceID],
                  let resolvedPanelID = resolvedActionPanelID(in: workspace) else {
                ToasttyLog.debug(
                    "Ghostty app action could not resolve active panel",
                    category: .terminal,
                    metadata: ["intent": action.logIntentName]
                )
                return false
            }
            panelID = resolvedPanelID
            workspaceIDForAction = selectedWorkspaceID
        }

        // Desktop notifications are handled separately — they should not steal focus.
        if case .desktopNotification(let title, let body) = action.intent {
            return handleDesktopNotification(
                title: title,
                body: body,
                workspaceID: workspaceIDForAction,
                panelID: panelID,
                state: state,
                store: store
            )
        }

        // Metadata updates should not steal focus.
        switch action.intent {
        case .setTerminalTitle(let title):
            return handleTerminalMetadataUpdate(
                title: title,
                cwd: nil,
                workspaceID: workspaceIDForAction,
                panelID: panelID,
                state: state,
                store: store
            )
        case .setTerminalCWD(let cwd):
            return handleTerminalMetadataUpdate(
                title: nil,
                cwd: cwd,
                workspaceID: workspaceIDForAction,
                panelID: panelID,
                state: state,
                store: store
            )
        case .commandFinished(let exitCode):
            return handleCommandFinishedMetadataUpdate(
                exitCode: exitCode,
                workspaceID: workspaceIDForAction,
                panelID: panelID,
                state: state,
                store: store
            )
        default:
            break
        }

        guard store.send(.focusPanel(workspaceID: workspaceIDForAction, panelID: panelID)) else {
            ToasttyLog.warning(
                "Ghostty action failed to focus resolved panel",
                category: .terminal,
                metadata: [
                    "intent": action.logIntentName,
                    "workspace_id": workspaceIDForAction.uuidString,
                    "panel_id": panelID.uuidString,
                ]
            )
            return false
        }

        let handled: Bool
        switch action.intent {
        case .split(let direction):
            handled = splitFocusedPaneInDirection(workspaceID: workspaceIDForAction, direction: direction)

        case .focus(let direction):
            handled = store.send(.focusPane(workspaceID: workspaceIDForAction, direction: direction))

        case .resizeSplit(let direction, let amount):
            handled = store.send(
                .resizeFocusedPaneSplit(
                    workspaceID: workspaceIDForAction,
                    direction: direction,
                    amount: amount
                )
            )

        case .equalizeSplits:
            handled = store.send(.equalizePaneSplits(workspaceID: workspaceIDForAction))

        case .toggleFocusedPanelMode:
            handled = store.send(.toggleFocusedPanelMode(workspaceID: workspaceIDForAction))

        case .setTerminalTitle, .setTerminalCWD, .commandFinished:
            // Already handled above; unreachable.
            handled = false

        case .desktopNotification:
            // Already handled above; unreachable.
            handled = false
        }

        if handled {
            ToasttyLog.debug(
                "Handled Ghostty runtime action in registry",
                category: .terminal,
                metadata: [
                    "intent": action.logIntentName,
                    "workspace_id": workspaceIDForAction.uuidString,
                    "panel_id": panelID.uuidString,
                ]
            )
        } else {
            ToasttyLog.debug(
                "Reducer rejected Ghostty runtime action",
                category: .terminal,
                metadata: [
                    "intent": action.logIntentName,
                    "workspace_id": workspaceIDForAction.uuidString,
                    "panel_id": panelID.uuidString,
                ]
            )
        }
        return handled
    }

    private func handleDesktopNotification(
        title: String,
        body: String,
        workspaceID: UUID,
        panelID: UUID,
        state: AppState,
        store: AppStore
    ) -> Bool {
        let notificationContext = desktopNotificationContext(
            workspaceID: workspaceID,
            panelID: panelID,
            state: state
        )

        let appIsActive = NSApplication.shared.isActive
        let currentSelectedWorkspaceID = selectedWorkspaceID(state: state)
        let panelIsFocused: Bool
        if currentSelectedWorkspaceID == workspaceID,
           let workspace = state.workspacesByID[workspaceID] {
            panelIsFocused = workspace.focusedPanelID == panelID
                && workspace.paneTree.leafContaining(panelID: panelID) != nil
        } else {
            panelIsFocused = false
        }

        if appIsActive && panelIsFocused {
            ToasttyLog.debug(
                "Suppressed desktop notification for focused panel",
                category: .notifications,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "panel_id": panelID.uuidString,
                    "title": title,
                ]
            )
            return true
        }

        store.send(.recordDesktopNotification(workspaceID: workspaceID))

        Task {
            await SystemNotificationSender.send(
                title: title,
                body: body,
                workspaceID: workspaceID,
                panelID: panelID,
                context: notificationContext
            )
        }

        ToasttyLog.info(
            "Delivered desktop notification from Ghostty",
            category: .notifications,
            metadata: [
                "workspace_id": workspaceID.uuidString,
                "panel_id": panelID.uuidString,
                "title": title,
                "app_active": appIsActive ? "true" : "false",
            ]
        )
        return true
    }

    private func desktopNotificationContext(
        workspaceID: UUID,
        panelID: UUID,
        state: AppState
    ) -> DesktopNotificationContext {
        guard let workspace = state.workspacesByID[workspaceID] else {
            return DesktopNotificationContext()
        }
        return DesktopNotificationContext(
            workspaceTitle: workspace.title,
            panelLabel: workspace.panels[panelID]?.notificationLabel
        )
    }

    private func handleTerminalMetadataUpdate(
        title: String?,
        cwd: String?,
        workspaceID: UUID,
        panelID: UUID,
        state: AppState,
        store: AppStore
    ) -> Bool {
        guard let workspace = state.workspacesByID[workspaceID],
              let panelState = workspace.panels[panelID],
              case .terminal(let terminalState) = panelState else {
            ToasttyLog.debug(
                "Skipping terminal metadata update for non-terminal panel",
                category: .terminal,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "panel_id": panelID.uuidString,
                ]
            )
            return false
        }

        let normalizedTitle = Self.normalizedMetadataValue(title)
        var normalizedCWD = Self.normalizedCWDValue(cwd)
        var cwdSource = "explicit"
        if normalizedCWD == nil,
           let normalizedTitle {
            normalizedCWD = Self.inferredCWDFromTitle(normalizedTitle, currentCWD: terminalState.cwd)
            if normalizedCWD != nil {
                cwdSource = "title_inference"
            }
        }
        if normalizedCWD == nil,
           cwd == nil,
           let normalizedTitle,
           normalizedTitle != terminalState.title,
           let visibleText = automationReadVisibleText(panelID: panelID),
           let inferredCWD = Self.inferredCWDFromVisibleTerminalText(
               visibleText,
               currentCWD: terminalState.cwd
           ) {
            normalizedCWD = inferredCWD
            cwdSource = "visible_text_inference"
        }
        if normalizedCWD == nil {
            cwdSource = "none"
        }

        var hasChanges = false
        if let normalizedTitle, normalizedTitle != terminalState.title {
            hasChanges = true
        }
        if let normalizedCWD,
           Self.cwdValuesDiffer(normalizedCWD, terminalState.cwd) {
            hasChanges = true
        }

        guard hasChanges else {
            if normalizedTitle != nil || normalizedCWD != nil {
                ToasttyLog.debug(
                    "Ignoring terminal metadata update because values are unchanged",
                    category: .terminal,
                    metadata: [
                        "workspace_id": workspaceID.uuidString,
                        "panel_id": panelID.uuidString,
                        "title_present": normalizedTitle == nil ? "false" : "true",
                        "cwd_present": normalizedCWD == nil ? "false" : "true",
                        "cwd_source": cwdSource,
                    ]
                )
            }
            return true
        }

        let handled = store.send(
            .updateTerminalPanelMetadata(
                panelID: panelID,
                title: normalizedTitle,
                cwd: normalizedCWD
            )
        )
        if handled {
            let titleSample = normalizedTitle.map { String($0.prefix(80)) } ?? "nil"
            let cwdSample = normalizedCWD.map { String($0.prefix(80)) } ?? "nil"
            ToasttyLog.debug(
                "Applied terminal metadata update from Ghostty",
                category: .terminal,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "panel_id": panelID.uuidString,
                    "title_updated": normalizedTitle == nil ? "false" : "true",
                    "cwd_updated": normalizedCWD == nil ? "false" : "true",
                    "title_sample": titleSample,
                    "cwd_sample": cwdSample,
                    "cwd_source": cwdSource,
                ]
            )
        } else {
            ToasttyLog.warning(
                "Reducer rejected terminal metadata update from Ghostty",
                category: .terminal,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "panel_id": panelID.uuidString,
                    "title_updated": normalizedTitle == nil ? "false" : "true",
                    "cwd_updated": normalizedCWD == nil ? "false" : "true",
                ]
            )
        }
        return handled
    }

    private func handleCommandFinishedMetadataUpdate(
        exitCode: Int?,
        workspaceID: UUID,
        panelID: UUID,
        state: AppState,
        store: AppStore
    ) -> Bool {
        guard let workspace = state.workspacesByID[workspaceID],
              let panelState = workspace.panels[panelID],
              case .terminal(let terminalState) = panelState else {
            return false
        }

        guard exitCode == nil || exitCode == 0 else {
            return true
        }

        guard let visibleText = automationReadVisibleText(panelID: panelID),
              let inferredCWD = Self.inferredCWDFromVisibleTerminalText(
                  visibleText,
                  currentCWD: terminalState.cwd
              ) else {
            return true
        }

        guard Self.cwdValuesDiffer(inferredCWD, terminalState.cwd) else {
            return true
        }

        return handleTerminalMetadataUpdate(
            title: nil,
            cwd: inferredCWD,
            workspaceID: workspaceID,
            panelID: panelID,
            state: state,
            store: store
        )
    }

    private static func normalizedMetadataValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return trimmed
    }

    private static func normalizedCWDValue(_ value: String?) -> String? {
        guard let normalized = normalizedMetadataValue(value) else { return nil }
        if normalized.hasPrefix("file://"),
           let url = URL(string: normalized),
           url.isFileURL {
            let path = url.path
            guard path.isEmpty == false else { return nil }
            return path
        }
        return normalized
    }

    private static func cwdValuesDiffer(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs {
            return false
        }
        return canonicalCWDForComparison(lhs) != canonicalCWDForComparison(rhs)
    }

    private static func canonicalCWDForComparison(_ value: String) -> String {
        guard let normalized = normalizedCWDValue(value) else {
            return value
        }
        let expanded = (normalized as NSString).expandingTildeInPath
        guard expanded.isEmpty == false else {
            return normalized
        }
        return URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func inferredCWDFromTitle(_ title: String, currentCWD: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix("file://") {
            if let normalized = normalizedCWDValue(trimmed) {
                let expanded = (normalized as NSString).expandingTildeInPath
                return URL(fileURLWithPath: expanded)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path
            }
        }

        return predictedCWD(fromCDCommandTitle: trimmed, currentCWD: currentCWD)
    }

    private static func inferredCWDFromVisibleTerminalText(_ visibleText: String, currentCWD: String) -> String? {
        let lines = sanitizedVisibleTerminalLines(visibleText)
        guard lines.isEmpty == false else { return nil }

        for line in lines.reversed() {
            if let promptLine = parsedPromptLine(line) {
                if let command = promptLine.command,
                   let predicted = predictedCWD(fromCDCommandTitle: command, currentCWD: currentCWD) {
                    return predicted
                }

                if let normalizedPromptCWD = normalizedPromptPathToken(promptLine.cwdToken) {
                    return normalizedPromptCWD
                }
            }

            if let loosePromptCWD = inferredCWDFromLoosePromptLine(line) {
                return loosePromptCWD
            }
        }

        return nil
    }

    private static func sanitizedVisibleTerminalLines(_ visibleText: String) -> [String] {
        let filteredScalars = visibleText.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x0A, 0x0D:
                return true
            default:
                return scalar.value >= 0x20 && scalar.value != 0x7F
            }
        }
        let sanitized = String(String.UnicodeScalarView(filteredScalars))
        return sanitized
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private static func parsedPromptLine(_ line: String) -> (cwdToken: String, command: String?)? {
        let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count >= 3 else { return nil }
        guard parts[0].contains("@") else { return nil }
        let promptMarker = parts[2]
        guard promptMarker == "%" || promptMarker == "#" || promptMarker == "$" else {
            return nil
        }

        let cwdToken = parts[1]
        let command: String?
        if parts.count > 3 {
            command = parts.dropFirst(3).joined(separator: " ")
        } else {
            command = nil
        }
        return (cwdToken: cwdToken, command: command)
    }

    private static func inferredCWDFromLoosePromptLine(_ line: String) -> String? {
        let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.isEmpty == false else { return nil }

        for index in stride(from: parts.count - 1, through: 0, by: -1) {
            let token = parts[index]
            if promptMarkerTokens.contains(token) {
                if index > 0,
                   let normalized = normalizedPromptPathCandidate(parts[index - 1]) {
                    return normalized
                }
                continue
            }

            guard token.count > 1,
                  let trailingCharacter = token.last,
                  promptMarkerTokens.contains(String(trailingCharacter)) else {
                continue
            }
            let tokenWithoutPromptMarker = String(token.dropLast())
            if let normalized = normalizedPromptPathCandidate(tokenWithoutPromptMarker) {
                return normalized
            }
        }

        return nil
    }

    private static func normalizedPromptPathCandidate(_ token: String) -> String? {
        var candidate = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.isEmpty == false else { return nil }

        while let firstScalar = candidate.unicodeScalars.first,
              promptPathWrapperCharacters.contains(firstScalar) {
            candidate.removeFirst()
        }
        while let lastScalar = candidate.unicodeScalars.last,
              promptPathWrapperCharacters.contains(lastScalar)
                || promptPathTrailingPunctuationCharacters.contains(lastScalar) {
            candidate.removeLast()
        }
        guard candidate.isEmpty == false else { return nil }

        if candidate.hasPrefix("/") || candidate.hasPrefix("~") || candidate.hasPrefix("file://") {
            return normalizedPromptPathToken(candidate)
        }
        if let colonIndex = candidate.lastIndex(of: ":") {
            let suffix = String(candidate[candidate.index(after: colonIndex)...])
            if suffix.hasPrefix("/") || suffix.hasPrefix("~") || suffix.hasPrefix("file://") {
                return normalizedPromptPathToken(suffix)
            }
        }

        return nil
    }

    private static func normalizedPromptPathToken(_ token: String) -> String? {
        guard token.hasPrefix("/") || token.hasPrefix("~") || token.hasPrefix("file://") else {
            return nil
        }
        guard let normalized = normalizedCWDValue(token) else { return nil }
        let expanded = (normalized as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func predictedCWD(fromCDCommandTitle title: String, currentCWD: String) -> String? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.isEmpty == false else { return nil }

        var command = trimmedTitle
        if command.hasPrefix("builtin ") {
            command = String(command.dropFirst("builtin ".count)).trimmingCharacters(in: .whitespaces)
        }

        let commandComponents = command.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: { $0.isWhitespace }
        )
        guard let executable = commandComponents.first, executable == "cd" else { return nil }

        let rawArgument = commandComponents.count == 1
            ? "~"
            : String(commandComponents[1]).trimmingCharacters(in: .whitespaces)
        guard rawArgument.isEmpty == false else {
            return (NSHomeDirectory() as NSString).standardizingPath
        }
        guard rawArgument != "-" else { return nil }

        // Keep this heuristic intentionally narrow; shell quoting/expansion is
        // too complex to infer safely from title strings alone.
        let argumentComponents = rawArgument.split(whereSeparator: { $0.isWhitespace })
        guard argumentComponents.count == 1, let argument = argumentComponents.first else { return nil }
        let argumentPath = String(argument)
        guard argumentPath.isEmpty == false else { return nil }

        let expandedArgumentPath = (argumentPath as NSString).expandingTildeInPath
        let homeDirectory = (NSHomeDirectory() as NSString).standardizingPath
        let baseDirectory = (currentCWD as NSString).standardizingPath
        let resolvedPath: String
        if expandedArgumentPath != argumentPath || argumentPath.hasPrefix("/") {
            resolvedPath = URL(fileURLWithPath: expandedArgumentPath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        } else {
            let fallbackBase = baseDirectory.isEmpty ? homeDirectory : baseDirectory
            let baseURL = URL(fileURLWithPath: fallbackBase, isDirectory: true).resolvingSymlinksInPath()
            resolvedPath = URL(fileURLWithPath: argumentPath, relativeTo: baseURL)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        }

        let normalizedPath = (resolvedPath as NSString).standardizingPath
        guard normalizedPath.isEmpty == false else { return nil }
        return normalizedPath
    }

    private static let promptMarkerTokens: Set<String> = ["%", "#", "$", ">"]
    private static let promptPathWrapperCharacters = CharacterSet(charactersIn: "\"'`()[]{}<>")
    private static let promptPathTrailingPunctuationCharacters = CharacterSet(charactersIn: ",;")
}
#endif

@MainActor
final class TerminalSurfaceController {
    private let panelID: UUID
    private unowned let registry: TerminalRuntimeRegistry
    private let hostedView: NSView
    private weak var activeSourceContainer: NSView?

    #if TOASTTY_HAS_GHOSTTY_KIT
    private let terminalHostView: TerminalHostView
    private var ghosttySurface: ghostty_surface_t?
    private let ghosttyManager = GhosttyRuntimeManager.shared
    private var usesBackingPixelSurfaceSizing = false
    private var hasDeterminedSurfaceSizingMode = false
    private var lastRenderMetrics: GhosttyRenderMetrics?
    private var lastDisplayID: UInt32?
    private var surfaceCreationStabilityPasses = 0
    private var lastSurfaceCreationSignature: SurfaceCreationSignature?
    private var lastSurfaceDeferralReason: SurfaceCreationDeferralReason?
    private var lastViewportDeferralReason: SurfaceCreationDeferralReason?
    private var diagnostics = SurfaceDiagnostics()

    private let minimumSurfaceHostDimension = 16
    private let requiredStableSurfaceCreationPasses = 2

    private struct GhosttyRenderMetrics: Equatable {
        let viewportWidth: Int
        let viewportHeight: Int
        let scaleThousandths: Int
        let widthPx: Int
        let heightPx: Int
        let columns: Int
        let rows: Int
        let cellWidthPx: Int
        let cellHeightPx: Int
        let pixelSizingEnabled: Bool
    }

    private struct SurfaceCreationSignature: Equatable {
        let windowID: ObjectIdentifier
        let width: Int
        let height: Int
    }

    private enum SurfaceCreationDeferralReason: String {
        case noWindow = "no_window"
        case hiddenHost = "hidden_host"
        case tinyBounds = "tiny_bounds"
        case unstableBounds = "unstable_bounds"
    }

    private struct SurfaceDiagnostics {
        var attachCount = 0
        var updateCount = 0
        var surfaceAttemptCount = 0
        var surfaceSuccessCount = 0
        var surfaceFailureCount = 0
        var surfaceDeferredCount = 0
        var viewportDeferredCount = 0
    }
    #endif

    private let fallbackView = TerminalFallbackView()

    init(panelID: UUID, registry: TerminalRuntimeRegistry) {
        self.panelID = panelID
        self.registry = registry
        #if TOASTTY_HAS_GHOSTTY_KIT
        let hostView = TerminalHostView()
        terminalHostView = hostView
        hostedView = hostView
        terminalHostView.resolveImageFileDrop = { [weak self] urls in
            guard let self else { return nil }
            return self.registry.prepareImageFileDrop(from: urls)
        }
        terminalHostView.performImageFileDrop = { [weak self] drop in
            guard let self else { return false }
            return self.registry.handlePreparedImageFileDrop(drop)
        }
        #else
        hostedView = fallbackView
        #endif
    }

    func attach(into container: NSView) {
        #if TOASTTY_HAS_GHOSTTY_KIT
        diagnostics.attachCount += 1
        #endif
        let sourceContainerChanged = activeSourceContainer !== container
        #if TOASTTY_HAS_GHOSTTY_KIT
        if shouldIgnoreAttach(to: container) {
            ToasttyLog.debug(
                "Ignoring terminal attach from detached container callback",
                category: .ghostty,
                metadata: ["panel_id": panelID.uuidString]
            )
            return
        }
        #endif

        activeSourceContainer = container
        if hostedView.superview !== container {
            hostedView.removeFromSuperview()
            container.addSubview(hostedView)
            hostedView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hostedView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                hostedView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                hostedView.topAnchor.constraint(equalTo: container.topAnchor),
                hostedView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        #if TOASTTY_HAS_GHOSTTY_KIT
        if sourceContainerChanged {
            surfaceCreationStabilityPasses = 0
            lastSurfaceCreationSignature = nil
            lastSurfaceDeferralReason = nil
            refreshSurfaceAfterContainerMove(sourceContainer: container)
        }
        #endif
    }

    func update(
        terminalState: TerminalPanelState,
        focused: Bool,
        fontPoints: Double,
        viewportSize: CGSize,
        backingScaleFactor: CGFloat,
        sourceContainer: NSView
    ) {
        #if TOASTTY_HAS_GHOSTTY_KIT
        diagnostics.updateCount += 1
        if activeSourceContainer !== sourceContainer {
            if shouldPromoteSourceContainer(to: sourceContainer) {
                attach(into: sourceContainer)
            } else {
                ToasttyLog.debug(
                    "Skipping terminal update from stale container callback",
                    category: .ghostty,
                    metadata: [
                        "panel_id": panelID.uuidString,
                    ]
                )
                return
            }
        }

        guard hostedView.superview === sourceContainer else {
            ToasttyLog.debug(
                "Skipping terminal update because host view is not attached to source container",
                category: .ghostty,
                metadata: [
                    "panel_id": panelID.uuidString,
                ]
            )
            return
        }

        ensureGhosttySurface(terminalState: terminalState, fontPoints: fontPoints)
        guard let ghosttySurface else {
            // Keep the host visible while retrying Ghostty surface creation.
            hostedView.isHidden = false
            terminalHostView.setGhosttySurface(nil)
            fallbackView.update(terminalState: terminalState, unavailableReason: "Ghostty surface unavailable")
            swapToFallbackIfNeeded()
            return
        }

        hostedView.isHidden = false
        terminalHostView.setGhosttySurface(ghosttySurface)
        if fallbackView.superview != nil {
            fallbackView.removeFromSuperview()
        }

        let xScale = max(Double(backingScaleFactor), 1)
        let yScale = max(Double(backingScaleFactor), 1)
        let logicalWidth = max(Int(viewportSize.width.rounded(.down)), 1)
        let logicalHeight = max(Int(viewportSize.height.rounded(.down)), 1)
        let hostView = terminalHostView
        if let viewportDeferralReason = evaluateViewportUpdateReadiness(
            for: hostView,
            width: logicalWidth,
            height: logicalHeight
        ) {
            diagnostics.viewportDeferredCount += 1
            let reasonChanged = lastViewportDeferralReason != viewportDeferralReason
            lastViewportDeferralReason = viewportDeferralReason
            if reasonChanged || diagnostics.viewportDeferredCount <= 2 || diagnostics.viewportDeferredCount.isMultiple(of: 60) {
                logSurfaceDiagnostics(
                    message: "Deferring Ghostty viewport update until host is stable",
                    extra: [
                        "reason": viewportDeferralReason.rawValue,
                        "viewport_width": String(logicalWidth),
                        "viewport_height": String(logicalHeight),
                    ]
                )
            }
            return
        }
        lastViewportDeferralReason = nil
        updateDisplayIDIfNeeded(surface: ghosttySurface, sourceContainer: sourceContainer)
        ghostty_surface_set_content_scale(ghosttySurface, xScale, yScale)
        let pixelWidth = max(Int((viewportSize.width * backingScaleFactor).rounded()), 1)
        let pixelHeight = max(Int((viewportSize.height * backingScaleFactor).rounded()), 1)
        let hasUsableViewport = logicalWidth > 16 && logicalHeight > 16
        var measuredSizeForLogging: ghostty_surface_size_s?

        if hasDeterminedSurfaceSizingMode == false {
            ghostty_surface_set_size(ghosttySurface, UInt32(logicalWidth), UInt32(logicalHeight))
            let measuredSize = ghostty_surface_size(ghosttySurface)
            measuredSizeForLogging = measuredSize

            if hasUsableViewport {
                hasDeterminedSurfaceSizingMode = true
                usesBackingPixelSurfaceSizing = shouldUseBackingPixelSurfaceSizing(
                    measuredSize: measuredSize,
                    logicalWidth: logicalWidth,
                    logicalHeight: logicalHeight,
                    expectedPixelWidth: pixelWidth,
                    expectedPixelHeight: pixelHeight,
                    scale: xScale
                )

                if usesBackingPixelSurfaceSizing {
                    ghostty_surface_set_size(ghosttySurface, UInt32(pixelWidth), UInt32(pixelHeight))
                    measuredSizeForLogging = ghostty_surface_size(ghosttySurface)
                    ToasttyLog.debug(
                        "Enabled backing-pixel Ghostty surface sizing for high-DPI rendering",
                        category: .ghostty,
                        metadata: [
                            "panel_id": panelID.uuidString,
                            "scale": String(format: "%.3f", xScale),
                            "logical_width": String(logicalWidth),
                            "logical_height": String(logicalHeight),
                            "pixel_width": String(pixelWidth),
                            "pixel_height": String(pixelHeight),
                            "reported_width_px": String(measuredSize.width_px),
                            "reported_height_px": String(measuredSize.height_px),
                        ]
                    )
                }
            }
        } else if usesBackingPixelSurfaceSizing {
            ghostty_surface_set_size(ghosttySurface, UInt32(pixelWidth), UInt32(pixelHeight))
        } else {
            ghostty_surface_set_size(ghosttySurface, UInt32(logicalWidth), UInt32(logicalHeight))
        }

        logRenderMetricsIfNeeded(
            viewportWidth: logicalWidth,
            viewportHeight: logicalHeight,
            scale: xScale,
            measuredSize: measuredSizeForLogging
        )
        ghostty_surface_set_focus(ghosttySurface, focused)
        ensureFirstResponderIfNeeded(focused: focused)
        #else
        fallbackView.update(terminalState: terminalState, unavailableReason: "Ghostty terminal runtime not enabled in this build")
        #endif
    }

    func invalidate() {
        #if TOASTTY_HAS_GHOSTTY_KIT
        terminalHostView.setGhosttySurface(nil)
        if let ghosttySurface {
            ghosttyManager.unregisterClipboardSurface(forHostView: terminalHostView, surface: ghosttySurface)
            registry.unregister(surface: ghosttySurface, for: panelID)
            ghostty_surface_free(ghosttySurface)
            self.ghosttySurface = nil
        }
        usesBackingPixelSurfaceSizing = false
        hasDeterminedSurfaceSizingMode = false
        lastRenderMetrics = nil
        lastDisplayID = nil
        surfaceCreationStabilityPasses = 0
        lastSurfaceCreationSignature = nil
        lastSurfaceDeferralReason = nil
        lastViewportDeferralReason = nil
        diagnostics = SurfaceDiagnostics()
        #endif
        activeSourceContainer = nil
        fallbackView.removeFromSuperview()
        hostedView.removeFromSuperview()
    }

    func automationSendText(_ text: String, submit: Bool) -> Bool {
        #if TOASTTY_HAS_GHOSTTY_KIT
        guard let ghosttySurface else {
            return false
        }

        if text.isEmpty == false {
            sendSurfaceText(text, to: ghosttySurface)
        }

        if submit {
            sendSurfaceText("\n", to: ghosttySurface)
        }

        return true
        #else
        return false
        #endif
    }

    func automationReadVisibleText() -> String? {
        #if TOASTTY_HAS_GHOSTTY_KIT
        guard let ghosttySurface else {
            return nil
        }

        var textPayload = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )

        guard ghostty_surface_read_text(ghosttySurface, selection, &textPayload) else {
            return nil
        }
        defer {
            ghostty_surface_free_text(ghosttySurface, &textPayload)
        }
        guard let textPointer = textPayload.text else {
            return nil
        }

        let bytePointer = UnsafeRawPointer(textPointer).assumingMemoryBound(to: UInt8.self)
        let buffer = UnsafeBufferPointer(start: bytePointer, count: Int(textPayload.text_len))
        return String(decoding: buffer, as: UTF8.self)
        #else
        return nil
        #endif
    }

    func canAcceptImageFileDrop() -> Bool {
        #if TOASTTY_HAS_GHOSTTY_KIT
        return ghosttySurface != nil
        #else
        return false
        #endif
    }

    func handleImageFileDrop(_ imageFileURLs: [URL]) -> Bool {
        #if TOASTTY_HAS_GHOSTTY_KIT
        guard let ghosttySurface else {
            return false
        }
        let filePaths = imageFileURLs.map { $0.path(percentEncoded: false) }
        guard let payload = TerminalDropPayloadBuilder.shellEscapedPathPayload(
            forFilePaths: filePaths
        ) else {
            ToasttyLog.warning(
                "Rejected image file drop due to invalid file path payload",
                category: .input,
                metadata: [
                    "panel_id": panelID.uuidString,
                    "image_count": String(imageFileURLs.count),
                ]
            )
            return false
        }
        sendSurfaceText(payload, to: ghosttySurface)
        return true
        #else
        _ = imageFileURLs
        return false
        #endif
    }

    #if TOASTTY_HAS_GHOSTTY_KIT
    private func sendSurfaceText(_ text: String, to surface: ghostty_surface_t) {
        let cString = text.utf8CString
        cString.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            let byteCount = max(buffer.count - 1, 0) // drop C-string null terminator
            guard byteCount > 0 else { return }
            ghostty_surface_text(surface, baseAddress, uintptr_t(byteCount))
        }
    }

    func applyGhosttyGlobalFontChange(from previousPoints: Double, to nextPoints: Double) {
        guard let ghosttySurface else { return }

        if nextPoints == AppState.defaultTerminalFontPoints {
            _ = invokeGhosttyBindingAction("reset_font_size", on: ghosttySurface)
            return
        }

        let pointDelta = nextPoints - previousPoints
        guard pointDelta != 0 else { return }
        let stepMagnitude = max(
            Int(round(abs(pointDelta) / AppState.terminalFontStepPoints)),
            1
        )
        let action = pointDelta > 0
            ? "increase_font_size:\(stepMagnitude)"
            : "decrease_font_size:\(stepMagnitude)"
        _ = invokeGhosttyBindingAction(action, on: ghosttySurface)
    }

    func currentGhosttySurface() -> ghostty_surface_t? {
        ghosttySurface
    }

    private static func currentWorkingDirectory(for surface: ghostty_surface_t) -> String? {
        let inheritedConfig = ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_SPLIT)
        guard let rawPointer = inheritedConfig.working_directory else {
            return nil
        }
        let candidate = String(cString: rawPointer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.isEmpty == false else {
            return nil
        }
        return candidate
    }

    @discardableResult
    private func invokeGhosttyBindingAction(_ action: String, on surface: ghostty_surface_t) -> Bool {
        let cString = action.utf8CString
        let handled = cString.withUnsafeBufferPointer { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return false }
            let byteCount = max(buffer.count - 1, 0)
            guard byteCount > 0 else { return false }
            return ghostty_surface_binding_action(surface, baseAddress, uintptr_t(byteCount))
        }
        if handled == false {
            ToasttyLog.warning(
                "Ghostty binding action not handled",
                category: .ghostty,
                metadata: [
                    "action": action,
                    "panel_id": panelID.uuidString,
                ]
            )
        }
        return handled
    }
    #endif

    #if TOASTTY_HAS_GHOSTTY_KIT
    private func ensureGhosttySurface(terminalState: TerminalPanelState, fontPoints: Double) {
        guard ghosttySurface == nil else { return }

        let hostView = terminalHostView

        switch evaluateSurfaceCreationReadiness(for: hostView) {
        case .ready:
            break

        case .deferred(let reason, let width, let height):
            diagnostics.surfaceDeferredCount += 1
            let reasonChanged = lastSurfaceDeferralReason != reason
            lastSurfaceDeferralReason = reason
            if reasonChanged || diagnostics.surfaceDeferredCount <= 2 || diagnostics.surfaceDeferredCount.isMultiple(of: 60) {
                logSurfaceDiagnostics(
                    message: "Deferring Ghostty surface creation until host is stable",
                    extra: [
                        "reason": reason.rawValue,
                        "host_width": String(width),
                        "host_height": String(height),
                        "stability_passes": String(surfaceCreationStabilityPasses),
                    ]
                )
            }
            return
        }

        let inheritedSourceSurface: ghostty_surface_t?
        var splitSourcePanelID: UUID?
        switch registry.splitSourceSurfaceState(for: panelID) {
        case .none:
            inheritedSourceSurface = nil
        case .pending:
            diagnostics.surfaceDeferredCount += 1
            if diagnostics.surfaceDeferredCount <= 2 || diagnostics.surfaceDeferredCount.isMultiple(of: 60) {
                logSurfaceDiagnostics(
                    message: "Deferring split surface creation until source surface is available",
                    extra: ["reason": "pending_split_source_surface"]
                )
            }
            return
        case .ready(let sourcePanelID, let sourceSurface):
            inheritedSourceSurface = sourceSurface
            splitSourcePanelID = sourcePanelID
            ToasttyLog.debug(
                "Using source Ghostty surface for split inheritance",
                category: .terminal,
                metadata: [
                    "source_panel_id": sourcePanelID.uuidString,
                    "new_panel_id": panelID.uuidString,
                ]
            )
        }

        let requestedWorkingDirectory: String
        if let splitSourcePanelID,
           let sourceWorkingDirectory = registry.resolvedWorkingDirectoryFromProcess(panelID: splitSourcePanelID) {
            requestedWorkingDirectory = sourceWorkingDirectory
            if sourceWorkingDirectory != terminalState.cwd {
                ToasttyLog.debug(
                    "Using process-resolved split source cwd for new terminal surface",
                    category: .terminal,
                    metadata: [
                        "source_panel_id": splitSourcePanelID.uuidString,
                        "new_panel_id": panelID.uuidString,
                        "source_cwd_sample": String(sourceWorkingDirectory.prefix(120)),
                    ]
                )
            }
        } else {
            requestedWorkingDirectory = terminalState.cwd
        }

        diagnostics.surfaceAttemptCount += 1
        guard let createdSurface = ghosttyManager.makeSurface(
            hostView: hostView,
            panelID: panelID,
            workingDirectory: requestedWorkingDirectory,
            fontPoints: fontPoints,
            inheritFrom: inheritedSourceSurface
        ) else {
            diagnostics.surfaceFailureCount += 1
            if diagnostics.surfaceFailureCount <= 5 || diagnostics.surfaceFailureCount.isMultiple(of: 20) {
                logSurfaceDiagnostics(
                    message: "Ghostty surface creation attempt failed",
                    extra: [
                        "host_has_window": hostView.window == nil ? "false" : "true",
                        "host_hidden": hostView.isHidden ? "true" : "false",
                        "host_hidden_ancestor": hostView.hasHiddenAncestor ? "true" : "false",
                        "host_width": String(format: "%.1f", hostView.bounds.width),
                        "host_height": String(format: "%.1f", hostView.bounds.height),
                    ]
                )
            }
            return
        }
        let surface = createdSurface.surface
        diagnostics.surfaceSuccessCount += 1
        if inheritedSourceSurface != nil {
            registry.consumeSplitSource(for: panelID)
        }
        lastSurfaceDeferralReason = nil
        lastViewportDeferralReason = nil
        surfaceCreationStabilityPasses = 0
        lastSurfaceCreationSignature = nil
        logSurfaceDiagnostics(message: "Ghostty surface creation succeeded")
        usesBackingPixelSurfaceSizing = false
        hasDeterminedSurfaceSizingMode = false
        lastRenderMetrics = nil
        lastDisplayID = nil
        ghosttySurface = surface
        registry.register(surface: surface, for: panelID)
        registry.reconcileSurfaceWorkingDirectory(
            panelID: panelID,
            workingDirectory: Self.currentWorkingDirectory(for: surface) ?? createdSurface.workingDirectory,
            source: "surface_create"
        )
    }

    private enum SurfaceCreationReadiness {
        case ready
        case deferred(reason: SurfaceCreationDeferralReason, width: Int, height: Int)
    }

    private func evaluateSurfaceCreationReadiness(for hostView: NSView) -> SurfaceCreationReadiness {
        let width = max(Int(hostView.bounds.width.rounded(.down)), 0)
        let height = max(Int(hostView.bounds.height.rounded(.down)), 0)

        guard let window = hostView.window else {
            surfaceCreationStabilityPasses = 0
            lastSurfaceCreationSignature = nil
            return .deferred(reason: .noWindow, width: width, height: height)
        }

        guard hostView.isHidden == false, hostView.hasHiddenAncestor == false else {
            surfaceCreationStabilityPasses = 0
            lastSurfaceCreationSignature = nil
            return .deferred(reason: .hiddenHost, width: width, height: height)
        }

        guard width >= minimumSurfaceHostDimension,
              height >= minimumSurfaceHostDimension else {
            surfaceCreationStabilityPasses = 0
            lastSurfaceCreationSignature = nil
            return .deferred(reason: .tinyBounds, width: width, height: height)
        }

        let signature = SurfaceCreationSignature(
            windowID: ObjectIdentifier(window),
            width: width,
            height: height
        )
        if lastSurfaceCreationSignature == signature {
            surfaceCreationStabilityPasses += 1
        } else {
            lastSurfaceCreationSignature = signature
            surfaceCreationStabilityPasses = 1
        }

        guard surfaceCreationStabilityPasses >= requiredStableSurfaceCreationPasses else {
            return .deferred(reason: .unstableBounds, width: width, height: height)
        }

        return .ready
    }

    private func evaluateViewportUpdateReadiness(
        for hostView: NSView,
        width: Int,
        height: Int
    ) -> SurfaceCreationDeferralReason? {
        guard hostView.window != nil else {
            return .noWindow
        }

        guard hostView.isHidden == false, hostView.hasHiddenAncestor == false else {
            return .hiddenHost
        }

        guard width >= minimumSurfaceHostDimension,
              height >= minimumSurfaceHostDimension else {
            return .tinyBounds
        }

        return nil
    }

    private func logSurfaceDiagnostics(message: String, extra: [String: String] = [:]) {
        var metadata: [String: String] = [
            "panel_id": panelID.uuidString,
            "attach_count": String(diagnostics.attachCount),
            "update_count": String(diagnostics.updateCount),
            "surface_attempt_count": String(diagnostics.surfaceAttemptCount),
            "surface_success_count": String(diagnostics.surfaceSuccessCount),
            "surface_failure_count": String(diagnostics.surfaceFailureCount),
            "surface_deferred_count": String(diagnostics.surfaceDeferredCount),
            "viewport_deferred_count": String(diagnostics.viewportDeferredCount),
        ]
        for (key, value) in extra {
            metadata[key] = value
        }
        ToasttyLog.debug(message, category: .ghostty, metadata: metadata)
    }

    #endif
}

private extension NSView {
    var hasHiddenAncestor: Bool {
        var ancestor = superview
        while let current = ancestor {
            if current.isHidden {
                return true
            }
            ancestor = current.superview
        }
        return false
    }

}

@MainActor
extension TerminalSurfaceController {
    #if TOASTTY_HAS_GHOSTTY_KIT
    private func shouldIgnoreAttach(to candidate: NSView) -> Bool {
        guard let activeSourceContainer else { return false }
        guard activeSourceContainer !== candidate else { return false }
        guard hostedView.superview != nil else { return false }
        let activeAttached = containerIsAttachedAndVisible(activeSourceContainer)
        let candidateClearlyDetached = candidate.window == nil || candidate.superview == nil
        return activeAttached && candidateClearlyDetached
    }

    private func shouldPromoteSourceContainer(to candidate: NSView) -> Bool {
        guard containerIsAttachedAndVisible(candidate) else {
            return false
        }
        if hostedView.superview === candidate {
            return true
        }
        guard let activeSourceContainer else {
            return true
        }
        if activeSourceContainer === candidate {
            return true
        }
        return !containerIsAttachedAndVisible(activeSourceContainer)
    }

    private func containerIsAttachedAndVisible(_ container: NSView?) -> Bool {
        guard let container else { return false }
        guard container.window != nil else { return false }
        guard container.superview != nil else { return false }
        guard !container.isHidden else { return false }
        guard container.bounds.width > 1, container.bounds.height > 1 else { return false }

        var ancestor = container.superview
        while let view = ancestor {
            if view.isHidden {
                return false
            }
            ancestor = view.superview
        }
        return true
    }

    private func refreshSurfaceAfterContainerMove(sourceContainer: NSView) {
        guard let ghosttySurface else { return }
        updateDisplayIDIfNeeded(surface: ghosttySurface, sourceContainer: sourceContainer)
        ghosttyManager.requestImmediateTick()
        ghostty_surface_refresh(ghosttySurface)
    }

    private func updateDisplayIDIfNeeded(surface: ghostty_surface_t, sourceContainer: NSView) {
        guard let displayID = resolvedDisplayID(sourceContainer: sourceContainer) else {
            return
        }
        guard lastDisplayID != displayID else {
            return
        }
        ghostty_surface_set_display_id(surface, displayID)
        lastDisplayID = displayID
    }

    private func resolvedDisplayID(sourceContainer: NSView) -> UInt32? {
        sourceContainer.window?.screen?.ghosttyDisplayID
    }

    private func shouldUseBackingPixelSurfaceSizing(
        measuredSize: ghostty_surface_size_s,
        logicalWidth: Int,
        logicalHeight: Int,
        expectedPixelWidth: Int,
        expectedPixelHeight: Int,
        scale: Double
    ) -> Bool {
        guard scale > 1.05 else { return false }
        let measuredWidth = Int(measuredSize.width_px)
        let measuredHeight = Int(measuredSize.height_px)
        guard logicalWidth > 0, logicalHeight > 0 else { return false }

        let measuredWidthRatio = Double(measuredWidth) / Double(logicalWidth)
        let measuredHeightRatio = Double(measuredHeight) / Double(logicalHeight)
        let expectedRatio = scale
        let thresholdRatio = expectedRatio * 0.98
        let looksLogicalScale = measuredWidthRatio <= 1.02 && measuredHeightRatio <= 1.02
        let significantlyBelowExpected = measuredWidthRatio < thresholdRatio || measuredHeightRatio < thresholdRatio
        let belowExpectedPixels = measuredWidth < expectedPixelWidth || measuredHeight < expectedPixelHeight
        return looksLogicalScale && significantlyBelowExpected && belowExpectedPixels
    }

    private func logRenderMetricsIfNeeded(
        viewportWidth: Int,
        viewportHeight: Int,
        scale: Double,
        measuredSize: ghostty_surface_size_s?
    ) {
        guard let ghosttySurface else { return }
        let measuredSize = measuredSize ?? ghostty_surface_size(ghosttySurface)
        let metrics = GhosttyRenderMetrics(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            scaleThousandths: Int((scale * 1000).rounded()),
            widthPx: Int(measuredSize.width_px),
            heightPx: Int(measuredSize.height_px),
            columns: Int(measuredSize.columns),
            rows: Int(measuredSize.rows),
            cellWidthPx: Int(measuredSize.cell_width_px),
            cellHeightPx: Int(measuredSize.cell_height_px),
            pixelSizingEnabled: usesBackingPixelSurfaceSizing
        )
        guard metrics != lastRenderMetrics else { return }
        lastRenderMetrics = metrics

        ToasttyLog.debug(
            "Ghostty surface render metrics",
            category: .ghostty,
            metadata: [
                "panel_id": panelID.uuidString,
                "viewport_width": String(metrics.viewportWidth),
                "viewport_height": String(metrics.viewportHeight),
                "scale_thousandths": String(metrics.scaleThousandths),
                "width_px": String(metrics.widthPx),
                "height_px": String(metrics.heightPx),
                "columns": String(metrics.columns),
                "rows": String(metrics.rows),
                "cell_width_px": String(metrics.cellWidthPx),
                "cell_height_px": String(metrics.cellHeightPx),
                "pixel_sizing": metrics.pixelSizingEnabled ? "true" : "false",
            ]
        )
    }

    private func swapToFallbackIfNeeded() {
        guard let container = hostedView.superview else { return }
        if fallbackView.superview !== container {
            fallbackView.removeFromSuperview()
            container.addSubview(fallbackView)
            fallbackView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                fallbackView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                fallbackView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                fallbackView.topAnchor.constraint(equalTo: container.topAnchor),
                fallbackView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
    }

    private func ensureFirstResponderIfNeeded(focused: Bool) {
        guard focused else { return }
        guard let window = hostedView.window else { return }
        guard window.isKeyWindow else { return }
        guard window.firstResponder !== hostedView else { return }
        window.makeFirstResponder(hostedView)
    }

    func pulseVisibilityRefresh() {
        guard let ghosttySurface else { return }
        ghosttyManager.requestImmediateTick()
        ghostty_surface_refresh(ghosttySurface)
    }
    #endif
}

final class TerminalHostView: NSView {
    var resolveImageFileDrop: (([URL]) -> PreparedImageFileDrop?)?
    var performImageFileDrop: ((PreparedImageFileDrop) -> Bool)?
    private var pendingImageFileDrop: PreparedImageFileDrop?

    private static let imageFileURLReadOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]

    #if TOASTTY_HAS_GHOSTTY_KIT
    private var ghosttySurface: ghostty_surface_t?
    private var rightMousePressWasForwarded = false
    #endif

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        syncLayerContentsScale()
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        syncLayerContentsScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncLayerContentsScale()
    }

    #if TOASTTY_HAS_GHOSTTY_KIT
    func setGhosttySurface(_ surface: ghostty_surface_t?) {
        ghosttySurface = surface
        rightMousePressWasForwarded = false
        pendingImageFileDrop = nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let imageFileURLs = Self.imageFileURLs(from: sender.draggingPasteboard)
        guard imageFileURLs.isEmpty == false else {
            pendingImageFileDrop = nil
            return []
        }
        guard let preparedDrop = resolveImageFileDrop?(imageFileURLs) else {
            pendingImageFileDrop = nil
            return []
        }
        pendingImageFileDrop = preparedDrop
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        pendingImageFileDrop != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let pendingImageFileDrop else {
            return false
        }
        self.pendingImageFileDrop = nil

        focusHostViewIfNeeded()
        return performImageFileDrop?(pendingImageFileDrop) ?? false
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        pendingImageFileDrop = nil
        super.draggingExited(sender)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        pendingImageFileDrop = nil
        super.concludeDragOperation(sender)
    }

    override func mouseDown(with event: NSEvent) {
        focusHostViewIfNeeded()
        guard forwardMouseButton(
            event,
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_LEFT
        ) else {
            super.mouseDown(with: event)
            return
        }
    }

    override func mouseUp(with event: NSEvent) {
        let handled = forwardMouseButton(
            event,
            state: GHOSTTY_MOUSE_RELEASE,
            button: GHOSTTY_MOUSE_LEFT
        )
        if let ghosttySurface {
            ghostty_surface_mouse_pressure(ghosttySurface, 0, 0)
        }
        guard handled else {
            super.mouseUp(with: event)
            return
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let ghosttySurface else {
            rightMousePressWasForwarded = false
            super.rightMouseDown(with: event)
            return
        }
        focusHostViewIfNeeded()
        guard shouldForwardRawRightMouseEvents(surface: ghosttySurface) else {
            rightMousePressWasForwarded = false
            super.rightMouseDown(with: event)
            return
        }
        let handled = forwardMouseButton(
            event,
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_RIGHT
        )
        rightMousePressWasForwarded = handled
        guard handled else {
            super.rightMouseDown(with: event)
            return
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let ghosttySurface else {
            rightMousePressWasForwarded = false
            super.rightMouseUp(with: event)
            return
        }
        let shouldForward = rightMousePressWasForwarded
            || shouldForwardRawRightMouseEvents(surface: ghosttySurface)
        rightMousePressWasForwarded = false
        guard shouldForward else {
            super.rightMouseUp(with: event)
            return
        }
        guard forwardMouseButton(
            event,
            state: GHOSTTY_MOUSE_RELEASE,
            button: GHOSTTY_MOUSE_RIGHT
        ) else {
            super.rightMouseUp(with: event)
            return
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        focusHostViewIfNeeded()
        let button = Self.ghosttyMouseButton(for: event.buttonNumber)
        guard forwardMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: button) else {
            super.otherMouseDown(with: event)
            return
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        let button = Self.ghosttyMouseButton(for: event.buttonNumber)
        guard forwardMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: button) else {
            super.otherMouseUp(with: event)
            return
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard forwardMousePosition(event) else {
            super.mouseMoved(with: event)
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard forwardMousePosition(event) else {
            super.mouseDragged(with: event)
            return
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard forwardMousePosition(event) else {
            super.rightMouseDragged(with: event)
            return
        }
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard forwardMousePosition(event) else {
            super.otherMouseDragged(with: event)
            return
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let ghosttySurface else {
            super.scrollWheel(with: event)
            return
        }
        var deltaX = event.scrollingDeltaX
        var deltaY = event.scrollingDeltaY
        let hasPrecision = event.hasPreciseScrollingDeltas

        if hasPrecision {
            // Match Ghostty's native host behavior to preserve trackpad scroll feel.
            deltaX *= 2
            deltaY *= 2
        }

        let mods = Self.ghosttyScrollModifierFlags(
            precision: hasPrecision,
            momentumPhase: event.momentumPhase
        )
        ghostty_surface_mouse_scroll(
            ghosttySurface,
            Double(deltaX),
            Double(deltaY),
            mods
        )
    }

    override func pressureChange(with event: NSEvent) {
        guard let ghosttySurface else {
            super.pressureChange(with: event)
            return
        }
        ghostty_surface_mouse_pressure(
            ghosttySurface,
            UInt32(max(event.stage, 0)),
            Double(event.pressure)
        )
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let ghosttySurface else {
            return super.menu(for: event)
        }
        guard !shouldForwardRawRightMouseEvents(surface: ghosttySurface) else {
            return nil
        }

        focusHostViewIfNeeded()

        let menu = NSMenu(title: "Terminal")
        menu.autoenablesItems = false

        let copyItem = NSMenuItem(
            title: "Copy",
            action: #selector(copy(_:)),
            keyEquivalent: ""
        )
        copyItem.target = self
        copyItem.isEnabled = hasCopyableSelection(on: ghosttySurface)
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(
            title: "Paste",
            action: #selector(paste(_:)),
            keyEquivalent: ""
        )
        pasteItem.target = self
        pasteItem.isEnabled = Self.hasStringContentInPasteboard()
        menu.addItem(pasteItem)

        return menu
    }

    @objc func copy(_ sender: Any?) {
        guard let ghosttySurface,
              hasCopyableSelection(on: ghosttySurface) else {
            return
        }
        if invokeGhosttyBindingAction("copy_to_clipboard", on: ghosttySurface) {
            return
        }
        _ = copySelectionToPasteboard()
    }

    @objc func paste(_ sender: Any?) {
        guard let ghosttySurface else { return }
        _ = invokeGhosttyBindingAction("paste_from_clipboard", on: ghosttySurface)
    }

    override func keyDown(with event: NSEvent) {
        guard handleKeyEvent(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS) else {
            super.keyDown(with: event)
            return
        }
    }

    override func keyUp(with event: NSEvent) {
        guard handleKeyEvent(event, action: GHOSTTY_ACTION_RELEASE) else {
            super.keyUp(with: event)
            return
        }
    }

    private func handleKeyEvent(_ event: NSEvent, action: ghostty_input_action_e) -> Bool {
        guard let ghosttySurface else {
            ToasttyLog.debug(
                "Dropped key event because Ghostty surface is unavailable",
                category: .input,
                metadata: [
                    "key_code": String(event.keyCode),
                    "action": Self.ghosttyInputActionName(action),
                ]
            )
            return false
        }

        let mods = Self.ghosttyModifierFlags(for: event.modifierFlags)
        // Translation mods are only for keyboard-layout text translation (for example
        // option-as-alt) and should not strip control/command from the actual key event.
        let translationMods = ghostty_surface_key_translation_mods(ghosttySurface, mods)
        var keyEvent = ghostty_input_key_s(
            action: action,
            mods: mods,
            consumed_mods: Self.ghosttyConsumedModifierFlags(forTranslationMods: translationMods),
            keycode: UInt32(event.keyCode),
            text: nil,
            unshifted_codepoint: 0,
            composing: false
        )

        if let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
            keyEvent.unshifted_codepoint = scalar.value
        }

        let text = Self.ghosttyText(for: event)
        let handled: Bool
        if let text, !text.isEmpty {
            handled = text.withCString { pointer in
                keyEvent.text = pointer
                return ghostty_surface_key(ghosttySurface, keyEvent)
            }
        } else {
            handled = ghostty_surface_key(ghosttySurface, keyEvent)
        }

        ToasttyLog.debug(
            "Forwarded key event to Ghostty surface",
            category: .input,
            metadata: [
                "handled": handled ? "true" : "false",
                "key_code": String(event.keyCode),
                "action": Self.ghosttyInputActionName(action),
                "modifiers": Self.modifierDescription(event.modifierFlags),
                "text_length": String(text?.count ?? 0),
            ]
        )

        return handled
    }

    private func focusHostViewIfNeeded() {
        guard let window else { return }
        guard window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    private func shouldForwardRawRightMouseEvents(surface: ghostty_surface_t) -> Bool {
        ghostty_surface_mouse_captured(surface)
    }

    @discardableResult
    private func forwardMouseButton(
        _ event: NSEvent,
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e
    ) -> Bool {
        guard let ghosttySurface else { return false }
        forwardMousePosition(event, surface: ghosttySurface)
        let mods = Self.ghosttyModifierFlags(for: event.modifierFlags)
        return ghostty_surface_mouse_button(ghosttySurface, state, button, mods)
    }

    @discardableResult
    private func forwardMousePosition(_ event: NSEvent) -> Bool {
        guard let ghosttySurface else { return false }
        forwardMousePosition(event, surface: ghosttySurface)
        return true
    }

    private func forwardMousePosition(_ event: NSEvent, surface: ghostty_surface_t) {
        let point = convert(event.locationInWindow, from: nil)
        let y = bounds.height - point.y
        let mods = Self.ghosttyModifierFlags(for: event.modifierFlags)
        ghostty_surface_mouse_pos(surface, point.x, y, mods)
    }

    @discardableResult
    private func copySelectionToPasteboard() -> Bool {
        guard let ghosttySurface,
              hasCopyableSelection(on: ghosttySurface),
              let selectedText = selectedText(from: ghosttySurface),
              selectedText.isEmpty == false else {
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedText, forType: .string)
        return true
    }

    private func selectedText(from surface: ghostty_surface_t) -> String? {
        var textPayload = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &textPayload) else {
            return nil
        }
        defer {
            ghostty_surface_free_text(surface, &textPayload)
        }
        guard let textPointer = textPayload.text else {
            return nil
        }

        let bytePointer = UnsafeRawPointer(textPointer).assumingMemoryBound(to: UInt8.self)
        let buffer = UnsafeBufferPointer(start: bytePointer, count: Int(textPayload.text_len))
        return String(decoding: buffer, as: UTF8.self)
    }

    private func hasCopyableSelection(on surface: ghostty_surface_t) -> Bool {
        guard ghostty_surface_has_selection(surface),
              let selectedText = selectedText(from: surface),
              selectedText.isEmpty == false else {
            return false
        }
        return true
    }

    @discardableResult
    private func invokeGhosttyBindingAction(_ action: String, on surface: ghostty_surface_t) -> Bool {
        let cString = action.utf8CString
        let handled = cString.withUnsafeBufferPointer { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return false }
            let byteCount = max(buffer.count - 1, 0) // drop C-string null terminator
            guard byteCount > 0 else { return false }
            return ghostty_surface_binding_action(surface, baseAddress, uintptr_t(byteCount))
        }
        if handled == false {
            ToasttyLog.warning(
                "Ghostty context-menu action not handled",
                category: .ghostty,
                metadata: ["action": action]
            )
        }
        return handled
    }

    private static func imageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        guard let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: imageFileURLReadOptions
        ) as? [URL] else {
            return []
        }
        return objects.map(\.standardizedFileURL)
    }

    private static func hasStringContentInPasteboard() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            return false
        }
        return text.isEmpty == false
    }

    private static func ghosttyModifierFlags(for flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        if flags.contains(.numericPad) { raw |= GHOSTTY_MODS_NUM.rawValue }
        let rawFlags = flags.rawValue
        if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { raw |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { raw |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { raw |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { raw |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    private static func ghosttyConsumedModifierFlags(
        forTranslationMods translationMods: ghostty_input_mods_e
    ) -> ghostty_input_mods_e {
        var raw = translationMods.rawValue
        // These never participate in text translation, so keep them active on the
        // key event instead of marking them consumed.
        raw &= ~GHOSTTY_MODS_CTRL.rawValue
        raw &= ~GHOSTTY_MODS_CTRL_RIGHT.rawValue
        raw &= ~GHOSTTY_MODS_SUPER.rawValue
        raw &= ~GHOSTTY_MODS_SUPER_RIGHT.rawValue
        return ghostty_input_mods_e(rawValue: raw)
    }

    private static func ghosttyMouseButton(for buttonNumber: Int) -> ghostty_input_mouse_button_e {
        switch buttonNumber {
        case 0:
            return GHOSTTY_MOUSE_LEFT
        case 1:
            return GHOSTTY_MOUSE_RIGHT
        case 2:
            return GHOSTTY_MOUSE_MIDDLE
        case 3:
            return GHOSTTY_MOUSE_EIGHT
        case 4:
            return GHOSTTY_MOUSE_NINE
        case 5:
            return GHOSTTY_MOUSE_SIX
        case 6:
            return GHOSTTY_MOUSE_SEVEN
        case 7:
            return GHOSTTY_MOUSE_FOUR
        case 8:
            return GHOSTTY_MOUSE_FIVE
        case 9:
            return GHOSTTY_MOUSE_TEN
        case 10:
            return GHOSTTY_MOUSE_ELEVEN
        default:
            return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    private static func ghosttyScrollModifierFlags(
        precision: Bool,
        momentumPhase: NSEvent.Phase
    ) -> ghostty_input_scroll_mods_t {
        var rawValue: Int32 = 0
        if precision {
            rawValue |= 0b0000_0001
        }
        rawValue |= ghosttyMouseMomentumRawValue(for: momentumPhase) << 1
        return ghostty_input_scroll_mods_t(rawValue)
    }

    private static func ghosttyMouseMomentumRawValue(for phase: NSEvent.Phase) -> Int32 {
        switch phase {
        case .began:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
        case .stationary:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue)
        case .changed:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
        case .ended:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
        case .cancelled:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
        case .mayBegin:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
        default:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
        }
    }

    private static func ghosttyText(for event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }

        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }

            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }

    private static func modifierDescription(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.command) { parts.append("command") }
        if flags.contains(.option) { parts.append("option") }
        if flags.contains(.control) { parts.append("control") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.capsLock) { parts.append("capsLock") }
        if flags.contains(.numericPad) { parts.append("numericPad") }
        return parts.joined(separator: ",")
    }

    private static func ghosttyInputActionName(_ action: ghostty_input_action_e) -> String {
        switch action {
        case GHOSTTY_ACTION_PRESS:
            return "press"
        case GHOSTTY_ACTION_RELEASE:
            return "release"
        case GHOSTTY_ACTION_REPEAT:
            return "repeat"
        default:
            return "unknown(\(action.rawValue))"
        }
    }
    #endif

    private func syncLayerContentsScale() {
        let scale = window?.screen?.backingScaleFactor
            ?? window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        layer?.contentsScale = max(scale, 1)
    }
}

private extension NSScreen {
    var ghosttyDisplayID: UInt32? {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return screenNumber.uint32Value
    }
}

private final class TerminalFallbackView: NSView {
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let reasonLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
        layer?.borderWidth = 0
        layer?.borderColor = NSColor.clear.cgColor

        subtitleLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = NSColor(calibratedWhite: 0.75, alpha: 1)

        reasonLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        reasonLabel.textColor = NSColor(calibratedWhite: 0.65, alpha: 1)

        let stack = NSStackView(views: [subtitleLabel, reasonLabel])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(terminalState: TerminalPanelState, unavailableReason: String) {
        subtitleLabel.stringValue = terminalState.cwd
        reasonLabel.stringValue = unavailableReason
    }
}
