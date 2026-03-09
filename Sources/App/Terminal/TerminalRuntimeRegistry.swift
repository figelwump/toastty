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

struct TerminalPanelRenderAttachmentSnapshot {
    let panelID: UUID
    let controllerExists: Bool
    let hostHasSuperview: Bool
    let hostAttachedToWindow: Bool
    let sourceContainerExists: Bool
    let sourceContainerAttachedToWindow: Bool
    let hostSuperviewMatchesSourceContainer: Bool
    let lifecycleState: PanelHostLifecycleState
    let ghosttySurfaceAvailable: Bool

    var isRenderable: Bool {
        controllerExists &&
        hostHasSuperview &&
        hostAttachedToWindow &&
        sourceContainerExists &&
        sourceContainerAttachedToWindow &&
        hostSuperviewMatchesSourceContainer
    }

    static func missingController(panelID: UUID) -> Self {
        Self(
            panelID: panelID,
            controllerExists: false,
            hostHasSuperview: false,
            hostAttachedToWindow: false,
            sourceContainerExists: false,
            sourceContainerAttachedToWindow: false,
            hostSuperviewMatchesSourceContainer: false,
            lifecycleState: .detached,
            ghosttySurfaceAvailable: false
        )
    }
}

@MainActor
final class TerminalRuntimeRegistry: ObservableObject {
    private let focusCoordinator = TerminalFocusCoordinator()
    private weak var store: AppStore?
    private var workspaceRuntimesByID: [UUID: TerminalWorkspaceRuntime] = [:]
    private var terminalWorkspaceIDByPanelID: [UUID: UUID] = [:]
    @Published private(set) var workspaceActivitySubtextByID: [UUID: String] = [:]
    #if TOASTTY_HAS_GHOSTTY_KIT
    private var actionRouter: TerminalActionRouter?
    private var metadataService: TerminalMetadataService?
    private var activityInferenceService: TerminalActivityInferenceService?
    private var storeActionCoordinator: TerminalStoreActionCoordinator?
    private var workspaceMaintenanceService: TerminalWorkspaceMaintenanceService?
    #endif

    deinit {
        #if TOASTTY_HAS_GHOSTTY_KIT
        let storeActionCoordinator = self.storeActionCoordinator
        Task { @MainActor in
            storeActionCoordinator?.unbind()
        }
        #endif
    }

    func bind(store: AppStore) {
        let previousStore = self.store
        if let existingStore = previousStore {
            precondition(existingStore === store, "TerminalRuntimeRegistry cannot be rebound to a different AppStore.")
        }
        self.store = store
        #if TOASTTY_HAS_GHOSTTY_KIT
        storeActionCoordinator?.unbind()
        let metadataService = TerminalMetadataService(store: store, registry: self)
        let activityInferenceService = TerminalActivityInferenceService(
            store: store,
            readVisibleText: { [weak self] panelID in
                self?.automationReadVisibleText(panelID: panelID)
            }
        )
        self.metadataService = metadataService
        self.activityInferenceService = activityInferenceService
        actionRouter = TerminalActionRouter(store: store, registry: self)
        let storeActionCoordinator = TerminalStoreActionCoordinator(
            metadataService: metadataService,
            registerPendingSplitSourceIfNeeded: { [weak self] workspaceID, previousState, nextState in
                self?.runtime(for: workspaceID).registerPendingSplitSourceIfNeeded(
                    previousState: previousState,
                    nextState: nextState
                )
            },
            requestSelectedWorkspaceSlotFocusRestore: { [weak self] in
                self?.scheduleSelectedWorkspaceSlotFocusRestore()
            }
        )
        storeActionCoordinator.bind(store: store)
        self.storeActionCoordinator = storeActionCoordinator
        workspaceMaintenanceService = TerminalWorkspaceMaintenanceService(
            store: store,
            metadataService: metadataService,
            activityInferenceService: activityInferenceService,
            containsController: { [weak self] panelID in
                self?.containsController(for: panelID) ?? false
            },
            controllerForPanelID: { [weak self] panelID in
                self?.existingController(for: panelID)
            },
            updateWorkspaceActivitySubtext: { [weak self] nextSubtextByWorkspaceID in
                self?.setWorkspaceActivitySubtext(nextSubtextByWorkspaceID)
            }
        )
        workspaceMaintenanceService?.publishWorkspaceActivitySubtext()
        workspaceMaintenanceService?.startProcessWorkingDirectoryRefreshLoopIfNeeded()
        #endif
        configureGhosttyActionHandler()
    }

    @discardableResult
    func splitFocusedSlot(workspaceID: UUID, orientation: SplitOrientation) -> Bool {
        sendSplitAction(
            workspaceID: workspaceID,
            action: .splitFocusedSlot(workspaceID: workspaceID, orientation: orientation)
        )
    }

    @discardableResult
    func splitFocusedSlotInDirection(workspaceID: UUID, direction: SlotSplitDirection) -> Bool {
        sendSplitAction(
            workspaceID: workspaceID,
            action: .splitFocusedSlotInDirection(workspaceID: workspaceID, direction: direction)
        )
    }

    func controller(for panelID: UUID, workspaceID: UUID) -> TerminalSurfaceController {
        terminalWorkspaceIDByPanelID[panelID] = workspaceID
        let workspaceRuntime = runtime(for: workspaceID)
        if let existingController = workspaceRuntime.existingController(for: panelID) {
            return existingController
        }
        if let migratedController = migrateController(for: panelID, to: workspaceID) {
            return migratedController
        }
        return workspaceRuntime.controller(for: panelID, delegate: self)
    }

    func synchronizeGhosttySurfaceFocusFromApplicationState() {
        for runtime in workspaceRuntimesByID.values {
            runtime.synchronizeGhosttySurfaceFocusFromApplicationState()
        }
    }

    func synchronize(with state: AppState) {
        let previousTerminalWorkspaceIDByPanelID = terminalWorkspaceIDByPanelID
        let livePanelIDsByWorkspaceID = liveTerminalPanelIDsByWorkspaceID(in: state)
        terminalWorkspaceIDByPanelID = livePanelIDsByWorkspaceID.reduce(into: [:]) { result, entry in
            let (workspaceID, panelIDs) = entry
            for panelID in panelIDs {
                result[panelID] = workspaceID
            }
        }
        let migratedPanelIDsBySourceWorkspaceID = migratedPanelIDsBySourceWorkspace(
            previousPanelWorkspaceIDs: previousTerminalWorkspaceIDByPanelID,
            nextPanelWorkspaceIDs: terminalWorkspaceIDByPanelID
        )

        var removedPanelIDs: Set<UUID> = []
        let liveWorkspaceIDs = Set(state.workspacesByID.keys)
        for workspaceID in Array(workspaceRuntimesByID.keys) {
            guard let runtime = workspaceRuntimesByID[workspaceID] else { continue }
            let migratedPanelIDs = migratedPanelIDsBySourceWorkspaceID[workspaceID] ?? []
            var livePanelIDs = livePanelIDsByWorkspaceID[workspaceID] ?? []
            // Keep moved panels alive in their previous runtime until the
            // destination host view asks for the controller and re-homes it.
            livePanelIDs.formUnion(migratedPanelIDs)
            removedPanelIDs.formUnion(runtime.synchronizeLivePanels(livePanelIDs))
            if liveWorkspaceIDs.contains(workspaceID) == false && migratedPanelIDs.isEmpty {
                workspaceRuntimesByID.removeValue(forKey: workspaceID)
            }
        }

        #if TOASTTY_HAS_GHOSTTY_KIT
        workspaceMaintenanceService?.synchronize(
            state: state,
            livePanelIDs: Set(terminalWorkspaceIDByPanelID.keys),
            removedPanelIDs: removedPanelIDs
        )
        #endif
    }

    func applyGlobalFontChange(from previousPoints: Double, to nextPoints: Double) {
        applyGhosttyGlobalFontChangeIfNeeded(from: previousPoints, to: nextPoints)
    }

    func automationSendText(_ text: String, submit: Bool, panelID: UUID) -> Bool {
        guard let controller = existingController(for: panelID) else {
            return false
        }
        return controller.automationSendText(
            text,
            submit: submit
        )
    }

    func automationReadVisibleText(panelID: UUID) -> String? {
        guard let controller = existingController(for: panelID) else {
            return nil
        }
        return controller.automationReadVisibleText()
    }

    func terminalCloseConfirmationAssessment(panelID: UUID) -> TerminalCloseConfirmationAssessment? {
        guard let controller = existingController(for: panelID) else {
            ToasttyLog.warning(
                "Skipping terminal close confirmation because the surface controller is unavailable",
                category: .terminal,
                metadata: ["panel_id": panelID.uuidString]
            )
            return nil
        }
        guard let visibleText = controller.automationReadVisibleText() else {
            ToasttyLog.warning(
                "Skipping terminal close confirmation because visible terminal text is unavailable",
                category: .terminal,
                metadata: ["panel_id": panelID.uuidString]
            )
            return nil
        }
        return TerminalVisibleTextInspector.assessCloseConfirmation(for: visibleText)
    }

    func automationRenderSnapshot(panelID: UUID) -> TerminalPanelRenderAttachmentSnapshot {
        guard let controller = existingController(for: panelID) else {
            return .missingController(panelID: panelID)
        }
        return controller.renderAttachmentSnapshot()
    }

    func automationDropImageFiles(_ filePaths: [String], panelID: UUID) -> AutomationImageFileDropResult {
        guard let controller = existingController(for: panelID) else {
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

    /// Attempts to return keyboard focus to the currently selected workspace's
    /// focused terminal slot host view. Returns `false` when there is no active
    /// focused terminal slot or no attached host view.
    @discardableResult
    func focusSelectedWorkspaceSlotIfPossible() -> Bool {
        focusCoordinator.focusSelectedWorkspaceSlotIfPossible { [weak self] in
            guard let self,
                  let panelID = self.store?.selectedWorkspace?.focusedPanelID,
                  let controller = self.existingController(for: panelID) else {
                return nil
            }
            return TerminalFocusCoordinator.FocusTarget(
                isReadyForFocus: controller.lifecycleState.isReadyForFocus,
                focusHostViewIfNeeded: { controller.focusHostViewIfNeeded() }
            )
        }
    }

    /// Retries first-responder restoration for the selected workspace's focused
    /// slot. This covers launch/layout races where the host view exists in state
    /// but is not yet attached when focus should be applied.
    func scheduleSelectedWorkspaceSlotFocusRestore(avoidStealingKeyboardFocus: Bool = true) {
        focusCoordinator.scheduleSelectedWorkspaceSlotFocusRestore(
            avoidStealingKeyboardFocus: avoidStealingKeyboardFocus
        ) { [weak self] in
            self?.focusSelectedWorkspaceSlotIfPossible() ?? false
        }
    }

    func workspaceActivitySubtext(for workspaceID: UUID) -> String? {
        workspaceActivitySubtextByID[workspaceID]
    }

    func prepareImageFileDrop(from urls: [URL], targetPanelID: UUID) -> PreparedImageFileDrop? {
        #if TOASTTY_HAS_GHOSTTY_KIT
        guard let store else { return nil }
        let imageFileURLs = Self.normalizedImageFileURLs(from: urls)
        guard imageFileURLs.isEmpty == false else { return nil }
        let state = store.state
        guard isValidDropTargetPanel(targetPanelID, state: state) else {
            return nil
        }
        guard let targetController = existingController(for: targetPanelID) else {
            return nil
        }
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
        guard let store else { return false }
        let state = store.state
        guard isValidDropTargetPanel(drop.targetPanelID, state: state) else {
            ToasttyLog.warning(
                "Rejected image file drop because drop-target panel is invalid",
                category: .input,
                metadata: [
                    "panel_id": drop.targetPanelID.uuidString,
                    "image_count": String(drop.imageFileURLs.count),
                ]
            )
            return false
        }
        guard let targetController = existingController(for: drop.targetPanelID) else {
            ToasttyLog.warning(
                "Rejected image file drop because drop-target controller is unavailable",
                category: .input,
                metadata: [
                    "panel_id": drop.targetPanelID.uuidString,
                    "image_count": String(drop.imageFileURLs.count),
                ]
            )
            return false
        }
        guard targetController.canAcceptImageFileDrop() else {
            ToasttyLog.warning(
                "Rejected image file drop because drop-target surface is unavailable",
                category: .input,
                metadata: [
                    "panel_id": drop.targetPanelID.uuidString,
                    "image_count": String(drop.imageFileURLs.count),
                ]
            )
            return false
        }

        let handled = targetController.handleImageFileDrop(drop.imageFileURLs)
        let focusActionApplied = handled
            ? focusPanelForImageDropIfPossible(drop.targetPanelID)
            : false
        if handled {
            if !focusActionApplied {
                ToasttyLog.warning(
                    "Image file drop succeeded but drop-target panel focus action was rejected",
                    category: .input,
                    metadata: [
                        "panel_id": drop.targetPanelID.uuidString,
                        "image_count": String(drop.imageFileURLs.count),
                    ]
                )
            }
            ToasttyLog.debug(
                "Forwarded image file drop to drop-target terminal",
                category: .input,
                metadata: [
                    "panel_id": drop.targetPanelID.uuidString,
                    "image_count": String(drop.imageFileURLs.count),
                    "focus_action_applied": focusActionApplied ? "true" : "false",
                ]
            )
        } else {
            ToasttyLog.warning(
                "Failed to forward image file drop to drop-target terminal",
                category: .input,
                metadata: [
                    "panel_id": drop.targetPanelID.uuidString,
                    "image_count": String(drop.imageFileURLs.count),
                    "focus_action_applied": focusActionApplied ? "true" : "false",
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
    func sendSplitAction(workspaceID: UUID, action: AppAction) -> Bool {
        #if TOASTTY_HAS_GHOSTTY_KIT
        return storeActionCoordinator?.sendSplitAction(workspaceID: workspaceID, action: action) ?? false
        #else
        guard let store else { return false }
        return store.send(action)
        #endif
    }

    func runtime(for workspaceID: UUID) -> TerminalWorkspaceRuntime {
        if let existing = workspaceRuntimesByID[workspaceID] {
            return existing
        }

        let created = TerminalWorkspaceRuntime(workspaceID: workspaceID)
        workspaceRuntimesByID[workspaceID] = created
        return created
    }

    func existingRuntime(containing panelID: UUID) -> TerminalWorkspaceRuntime? {
        if let workspaceID = terminalWorkspaceIDByPanelID[panelID],
           let runtime = workspaceRuntimesByID[workspaceID] {
            return runtime
        }

        for (workspaceID, runtime) in workspaceRuntimesByID where runtime.containsController(for: panelID) {
            terminalWorkspaceIDByPanelID[panelID] = workspaceID
            return runtime
        }

        return nil
    }

    func existingController(for panelID: UUID) -> TerminalSurfaceController? {
        existingRuntime(containing: panelID)?.existingController(for: panelID)
    }

    func containsController(for panelID: UUID) -> Bool {
        existingController(for: panelID) != nil
    }

    func liveTerminalPanelIDsByWorkspaceID(in state: AppState) -> [UUID: Set<UUID>] {
        state.workspacesByID.reduce(into: [:]) { result, entry in
            let (workspaceID, workspace) = entry
            let panelIDs = workspace.panels.reduce(into: Set<UUID>()) { ids, panelEntry in
                let (panelID, panelState) = panelEntry
                if case .terminal = panelState {
                    ids.insert(panelID)
                }
            }
            result[workspaceID] = panelIDs
        }
    }

    func migratedPanelIDsBySourceWorkspace(
        previousPanelWorkspaceIDs: [UUID: UUID],
        nextPanelWorkspaceIDs: [UUID: UUID]
    ) -> [UUID: Set<UUID>] {
        nextPanelWorkspaceIDs.reduce(into: [:]) { result, entry in
            let (panelID, nextWorkspaceID) = entry
            guard let previousWorkspaceID = previousPanelWorkspaceIDs[panelID],
                  previousWorkspaceID != nextWorkspaceID else {
                return
            }
            result[previousWorkspaceID, default: []].insert(panelID)
        }
    }

    func migrateController(for panelID: UUID, to workspaceID: UUID) -> TerminalSurfaceController? {
        guard let targetRuntime = workspaceRuntimesByID[workspaceID] else {
            return nil
        }

        for (sourceWorkspaceID, sourceRuntime) in workspaceRuntimesByID where sourceWorkspaceID != workspaceID {
            guard let transferredController = sourceRuntime.takeController(for: panelID) else {
                continue
            }
            return targetRuntime.adoptController(transferredController, for: panelID)
        }

        return nil
    }
}

#if TOASTTY_HAS_GHOSTTY_KIT
private extension TerminalRuntimeRegistry {
    func configureGhosttyActionHandler() {
        GhosttyRuntimeManager.shared.actionHandler = self
    }

    func applyGhosttyGlobalFontChangeIfNeeded(from previousPoints: Double, to nextPoints: Double) {
        for runtime in workspaceRuntimesByID.values {
            runtime.applyGhosttyGlobalFontChange(from: previousPoints, to: nextPoints)
        }
    }

    func splitSourceSurfaceState(for newPanelID: UUID) -> TerminalSplitSourceSurfaceState {
        existingRuntime(containing: newPanelID)?.splitSourceSurfaceState(for: newPanelID) ?? .none
    }

    func consumeSplitSource(for newPanelID: UUID) {
        existingRuntime(containing: newPanelID)?.consumeSplitSource(for: newPanelID)
    }
}
#else
private extension TerminalRuntimeRegistry {
    func configureGhosttyActionHandler() {}

    func applyGhosttyGlobalFontChangeIfNeeded(from _: Double, to _: Double) {}
}
#endif

#if TOASTTY_HAS_GHOSTTY_KIT
extension TerminalRuntimeRegistry {
    func panelID(forSurfaceHandle surfaceHandle: UInt) -> UUID? {
        for runtime in workspaceRuntimesByID.values {
            if let panelID = runtime.panelID(forSurfaceHandle: surfaceHandle) {
                return panelID
            }
        }
        return nil
    }

    func workspaceID(containing panelID: UUID, state: AppState) -> UUID? {
        for window in state.windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = state.workspacesByID[workspaceID] else { continue }
                guard workspace.panels[panelID] != nil else { continue }
                if workspace.layoutTree.slotContaining(panelID: panelID) != nil {
                    return workspaceID
                }
            }
        }
        return nil
    }
}
#endif

extension TerminalRuntimeRegistry: TerminalSurfaceControllerDelegate {
    #if TOASTTY_HAS_GHOSTTY_KIT
    func splitSourceSurfaceState(forNewPanelID panelID: UUID) -> TerminalSplitSourceSurfaceState {
        splitSourceSurfaceState(for: panelID)
    }

    func consumeSplitSource(forNewPanelID panelID: UUID) {
        consumeSplitSource(for: panelID)
    }

    func registerSurfaceHandle(_ surface: ghostty_surface_t, for panelID: UUID) {
        register(surface: surface, for: panelID)
    }

    func unregisterSurfaceHandle(_ surface: ghostty_surface_t, for panelID: UUID) {
        unregister(surface: surface, for: panelID)
    }

    func surfaceCreationChildPIDSnapshot() -> Set<pid_t> {
        snapshotChildPIDsForSurfaceCreation()
    }

    func registerSurfaceChildPIDAfterCreation(
        panelID: UUID,
        previousChildren: Set<pid_t>,
        expectedWorkingDirectory: String
    ) {
        registerChildPIDAfterSurfaceCreation(
            panelID: panelID,
            previousChildren: previousChildren,
            expectedWorkingDirectory: expectedWorkingDirectory
        )
    }

    func reconcileSurfaceWorkingDirectoryFromSurface(
        panelID: UUID,
        workingDirectory: String?,
        source: String
    ) {
        reconcileSurfaceWorkingDirectory(
            panelID: panelID,
            workingDirectory: workingDirectory,
            source: source
        )
    }
    #endif
}

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
           workspace.layoutTree.slotContaining(panelID: focusedPanelID) != nil {
            return focusedPanelID
        }

        for leaf in workspace.layoutTree.allSlotInfos {
            let panelID = leaf.panelID
            if workspace.panels[panelID] != nil {
                return panelID
            }
        }

        return nil
    }

    func isValidDropTargetPanel(_ panelID: UUID, state: AppState) -> Bool {
        guard let workspaceID = workspaceID(containing: panelID, state: state),
              let workspace = state.workspacesByID[workspaceID],
              let panelState = workspace.panels[panelID],
              case .terminal = panelState,
              workspace.layoutTree.slotContaining(panelID: panelID) != nil else {
            return false
        }
        return true
    }

    @discardableResult
    func focusPanelForImageDropIfPossible(_ panelID: UUID) -> Bool {
        guard let store else { return false }
        let state = store.state
        guard let workspaceID = workspaceID(containing: panelID, state: state) else {
            return false
        }
        return store.send(.focusPanel(workspaceID: workspaceID, panelID: panelID))
    }

    func register(surface: ghostty_surface_t, for panelID: UUID) {
        existingRuntime(containing: panelID)?.register(surface: surface, for: panelID)
    }

    func unregister(surface: ghostty_surface_t, for panelID: UUID) {
        existingRuntime(containing: panelID)?.unregister(surface: surface, for: panelID)
        workspaceMaintenanceService?.handleSurfaceUnregister(panelID: panelID)
    }

    func prefersNativeCWDSignal(panelID: UUID, now: Date = Date()) -> Bool {
        metadataService?.prefersNativeCWDSignal(panelID: panelID, now: now) ?? false
    }

    func shouldRunProcessCWDFallbackPoll(panelID: UUID, now: Date = Date()) -> Bool {
        metadataService?.shouldRunProcessCWDFallbackPoll(panelID: panelID, now: now) ?? true
    }

    func recordProcessCWDFallbackPoll(panelID: UUID, now: Date = Date()) {
        metadataService?.recordProcessCWDFallbackPoll(panelID: panelID, now: now)
    }

    func snapshotChildPIDsForSurfaceCreation() -> Set<pid_t> {
        metadataService?.snapshotChildPIDsForSurfaceCreation() ?? []
    }

    func registerChildPIDAfterSurfaceCreation(
        panelID: UUID,
        previousChildren: Set<pid_t>,
        expectedWorkingDirectory: String
    ) {
        metadataService?.registerChildPIDAfterSurfaceCreation(
            panelID: panelID,
            previousChildren: previousChildren,
            expectedWorkingDirectory: expectedWorkingDirectory
        )
    }

    func reconcileSurfaceWorkingDirectory(panelID: UUID, workingDirectory: String?, source: String) {
        metadataService?.reconcileSurfaceWorkingDirectory(
            panelID: panelID,
            workingDirectory: workingDirectory,
            source: source
        )
    }

    @discardableResult
    func refreshWorkingDirectoryFromProcessIfNeeded(panelID: UUID, source: String) -> String? {
        metadataService?.refreshWorkingDirectoryFromProcessIfNeeded(panelID: panelID, source: source)
    }

    func setWorkspaceActivitySubtext(_ nextSubtextByWorkspaceID: [UUID: String]) {
        if workspaceActivitySubtextByID != nextSubtextByWorkspaceID {
            workspaceActivitySubtextByID = nextSubtextByWorkspaceID
        }
    }
}
#endif

#if TOASTTY_HAS_GHOSTTY_KIT
extension TerminalRuntimeRegistry: GhosttyRuntimeActionHandling {
    func handleGhosttyRuntimeAction(_ action: GhosttyRuntimeAction) -> Bool {
        actionRouter?.handle(action) ?? false
    }

    func resolveActionTarget(
        for action: GhosttyRuntimeAction,
        state: AppState
    ) -> (panelID: UUID, workspaceID: UUID)? {
        if let surfaceHandle = action.surfaceHandle {
            guard let resolvedPanelID = panelID(forSurfaceHandle: surfaceHandle),
                  let workspaceIDForSurface = workspaceID(containing: resolvedPanelID, state: state) else {
                ToasttyLog.debug(
                    "Ghostty surface action could not resolve panel/workspace",
                    category: .terminal,
                    metadata: [
                        "intent": action.logIntentName,
                        "surface_handle": String(surfaceHandle),
                    ]
                )
                return nil
            }
            return (resolvedPanelID, workspaceIDForSurface)
        }

        guard let selectedWorkspaceID = selectedWorkspaceID(state: state),
              let workspace = state.workspacesByID[selectedWorkspaceID],
              let resolvedPanelID = resolvedActionPanelID(in: workspace) else {
            ToasttyLog.debug(
                "Ghostty app action could not resolve active panel",
                category: .terminal,
                metadata: ["intent": action.logIntentName]
            )
            return nil
        }

        return (resolvedPanelID, selectedWorkspaceID)
    }

    func handleDesktopNotificationAction(
        action: GhosttyRuntimeAction,
        title: String,
        body: String,
        state: AppState,
        store: AppStore
    ) -> Bool {
        _ = store
        return metadataService?.handleDesktopNotificationAction(
            action: action,
            title: title,
            body: body,
            state: state
        ) ?? false
    }

    func handleRuntimeMetadataAction(
        _ intent: GhosttyRuntimeAction.Intent,
        workspaceID: UUID,
        panelID: UUID,
        state: AppState,
        store: AppStore
    ) -> Bool {
        _ = store
        return metadataService?.handleRuntimeMetadataAction(
            intent,
            workspaceID: workspaceID,
            panelID: panelID,
            state: state
        ) ?? false
    }

    static func normalizedMetadataValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return trimmed
    }

    static func normalizedCWDValue(_ value: String?) -> String? {
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

    static func cwdValuesDiffer(_ lhs: String, _ rhs: String) -> Bool {
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

    static func inferredCWDFromTitle(_ title: String, currentCWD: String) -> String? {
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

    static func inferredCWDFromVisibleTerminalText(_ visibleText: String, currentCWD: String) -> String? {
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
