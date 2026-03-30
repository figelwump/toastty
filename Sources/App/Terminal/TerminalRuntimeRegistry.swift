import AppKit
import Combine
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
    private let runtimeStore = TerminalWindowRuntimeStore()
    private weak var store: AppStore?
    private var sessionLifecycleTracker: (any TerminalSessionLifecycleTracking)?
    private weak var terminalProfileProvider: (any TerminalProfileProviding)?
    private var stateObservation: AnyCancellable?
    private var observedWindowFontPointsByID: [UUID: Double] = [:]
    private var restoredTerminalPanelIDsAwaitingLaunch: Set<UUID> = []
    private var profiledTerminalPanelIDsAwaitingStartupTitleCleanup: Set<UUID> = []
    private var launchedProfiledPanelIDs: Set<UUID> = []
    private var exitedTerminalPanelIDs: Set<UUID> = []
    private var loggedLaunchEnvironmentPanelIDs: Set<UUID> = []
    private var baseLaunchEnvironmentProvider: (@Sendable (UUID) -> [String: String])?
    @Published private(set) var panelDisplayTitleOverrideByID: [UUID: String] = [:]
    @Published private(set) var workspaceActivitySubtextByID: [UUID: String] = [:]
    @Published private(set) var searchStateByPanelID: [UUID: TerminalSearchState] = [:]
    @Published private(set) var searchFieldFocusedPanelID: UUID?
    private var ghosttyCloseSurfaceHandler: ((UUID, Bool) -> Bool)?
    private var searchDispatchTaskByPanelID: [UUID: Task<Void, Never>] = [:]
    private var searchDispatchTokenByPanelID: [UUID: UUID] = [:]
    #if TOASTTY_HAS_GHOSTTY_KIT
    private var actionRouter: TerminalActionRouter?
    private var metadataService: TerminalMetadataService?
    private var activityInferenceService: TerminalActivityInferenceService?
    private var storeActionCoordinator: TerminalStoreActionCoordinator?
    private var workspaceMaintenanceService: TerminalWorkspaceMaintenanceService?
    #endif

    deinit {
        for task in searchDispatchTaskByPanelID.values {
            task.cancel()
        }
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
        let metadataService = TerminalMetadataService(
            store: store,
            registry: self,
            sessionLifecycleTracker: sessionLifecycleTracker
        )
        let activityInferenceService = TerminalActivityInferenceService(
            readVisibleText: { [weak self] panelID in
                self?.automationReadVisibleText(panelID: panelID)
            },
            sessionLifecycleTracker: sessionLifecycleTracker
        )
        self.metadataService = metadataService
        self.activityInferenceService = activityInferenceService
        actionRouter = TerminalActionRouter(store: store, registry: self)
        let storeActionCoordinator = TerminalStoreActionCoordinator(
            metadataService: metadataService,
            registerPendingSplitSourceIfNeeded: { [weak self] workspaceID, previousState, nextState in
                self?.runtimeStore.registerPendingSplitSourceIfNeeded(
                    workspaceID: workspaceID,
                    previousState: previousState,
                    nextState: nextState
                )
            },
            armCloseTransitionViewportDeferral: { [weak self] workspaceID, panelIDs in
                self?.runtimeStore.armCloseTransitionViewportDeferral(
                    workspaceID: workspaceID,
                    panelIDs: panelIDs
                )
            },
            requestWorkspaceFocusRestore: { [weak self] workspaceID in
                self?.scheduleWorkspaceFocusRestore(workspaceID: workspaceID)
            }
        )
        storeActionCoordinator.bind(store: store)
        self.storeActionCoordinator = storeActionCoordinator
        workspaceMaintenanceService = TerminalWorkspaceMaintenanceService(
            store: store,
            metadataService: metadataService,
            activityInferenceService: activityInferenceService,
            containsController: { [weak self] panelID in
                self?.runtimeStore.containsController(for: panelID) ?? false
            },
            controllerForPanelID: { [weak self] panelID in
                self?.runtimeStore.existingController(for: panelID)
            },
            updatePanelDisplayTitleOverrides: { [weak self] nextOverridesByPanelID in
                self?.setPanelDisplayTitleOverrides(nextOverridesByPanelID)
            },
            updateWorkspaceActivitySubtext: { [weak self] nextSubtextByWorkspaceID in
                self?.setWorkspaceActivitySubtext(nextSubtextByWorkspaceID)
            }
        )
        workspaceMaintenanceService?.publishPanelDisplayTitleOverrides()
        workspaceMaintenanceService?.publishWorkspaceActivitySubtext()
        workspaceMaintenanceService?.startProcessWorkingDirectoryRefreshLoopIfNeeded()
        #endif
        configureGhosttyActionHandler()
        bindStateObservation(to: store)
    }

    func bind(sessionLifecycleTracker: any TerminalSessionLifecycleTracking) {
        self.sessionLifecycleTracker = sessionLifecycleTracker
        #if TOASTTY_HAS_GHOSTTY_KIT
        metadataService?.bind(sessionLifecycleTracker: sessionLifecycleTracker)
        activityInferenceService?.bind(sessionLifecycleTracker: sessionLifecycleTracker)
        #endif
    }

    func setTerminalProfileProvider(
        _ terminalProfileProvider: any TerminalProfileProviding,
        restoredTerminalPanelIDs: Set<UUID>
    ) {
        self.terminalProfileProvider = terminalProfileProvider
        restoredTerminalPanelIDsAwaitingLaunch = restoredTerminalPanelIDs
        profiledTerminalPanelIDsAwaitingStartupTitleCleanup = restoredTerminalPanelIDs
    }

    func setBaseLaunchEnvironmentProvider(
        _ provider: @escaping @Sendable (UUID) -> [String: String]
    ) {
        baseLaunchEnvironmentProvider = provider
    }

    private func logSurfaceLaunchEnvironmentIfNeeded(
        panelID: UUID,
        environment: [String: String]
    ) {
        guard loggedLaunchEnvironmentPanelIDs.insert(panelID).inserted else {
            return
        }

        let shimDirectory = Self.normalizedLaunchContextValue(
            environment[ToasttyLaunchContextEnvironment.agentShimDirectoryKey]
        )
        let path = Self.normalizedLaunchContextValue(environment["PATH"])
        let launchContextPanelID = Self.normalizedLaunchContextValue(
            environment[ToasttyLaunchContextEnvironment.panelIDKey]
        )

        ToasttyLog.info(
            "Prepared terminal surface launch environment",
            category: .terminal,
            metadata: [
                "panel_id": panelID.uuidString,
                "launch_context_panel_id": launchContextPanelID ?? "none",
                "launch_context_panel_matches_surface": launchContextPanelID == panelID.uuidString ? "true" : "false",
                "socket_path": Self.normalizedLaunchContextValue(
                    environment[ToasttyLaunchContextEnvironment.socketPathKey]
                ) ?? "none",
                "cli_path_present": Self.normalizedLaunchContextValue(
                    environment[ToasttyLaunchContextEnvironment.cliPathKey]
                ) == nil ? "false" : "true",
                "session_id_present": Self.normalizedLaunchContextValue(
                    environment[ToasttyLaunchContextEnvironment.sessionIDKey]
                ) == nil ? "false" : "true",
                "agent_shim_directory": shimDirectory ?? "none",
                "path_starts_with_shim_directory": Self.pathStartsWithDirectory(
                    path,
                    directoryPath: shimDirectory
                ) ? "true" : "false",
                "path_contains_shim_directory": Self.pathContainsDirectory(
                    path,
                    directoryPath: shimDirectory
                ) ? "true" : "false",
                "path_sample": Self.pathEntriesSample(path),
            ]
        )
    }

    private static func normalizedLaunchContextValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }

    private static func normalizedPathEntries(_ path: String?) -> [String] {
        guard let path else {
            return []
        }
        return path
            .split(separator: ":")
            .map(String.init)
            .filter { $0.isEmpty == false }
    }

    private static func pathEntriesSample(_ path: String?, limit: Int = 4) -> String {
        let entries = normalizedPathEntries(path)
        guard entries.isEmpty == false else {
            return "none"
        }
        return entries.prefix(limit).joined(separator: " | ")
    }

    private static func pathStartsWithDirectory(_ path: String?, directoryPath: String?) -> Bool {
        guard let directoryPath,
              let firstEntry = normalizedPathEntries(path).first else {
            return false
        }
        return firstEntry == directoryPath
    }

    private static func pathContainsDirectory(_ path: String?, directoryPath: String?) -> Bool {
        guard let directoryPath else {
            return false
        }
        return normalizedPathEntries(path).contains(directoryPath)
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

    @discardableResult
    func splitFocusedSlotInDirectionWithTerminalProfile(
        workspaceID: UUID,
        direction: SlotSplitDirection,
        profileBinding: TerminalProfileBinding
    ) -> Bool {
        sendSplitAction(
            workspaceID: workspaceID,
            action: .splitFocusedSlotInDirectionWithTerminalProfile(
                workspaceID: workspaceID,
                direction: direction,
                profileBinding: profileBinding
            )
        )
    }

    func controller(for panelID: UUID, workspaceID: UUID, windowID: UUID) -> TerminalSurfaceController {
        runtimeStore.controller(
            for: panelID,
            workspaceID: workspaceID,
            windowID: windowID,
            state: store?.state,
            delegate: self
        )
    }

    func synchronizeGhosttySurfaceFocusFromApplicationState() {
        runtimeStore.synchronizeGhosttySurfaceFocusFromApplicationState()
    }

    @discardableResult
    func resetTrackedGhosttyModifiersForApplicationDeactivation() -> Int {
        runtimeStore.resetTrackedGhosttyModifiersForApplicationDeactivation()
    }

    func synchronize(with state: AppState) {
        let removedPanelIDs = runtimeStore.synchronize(with: state)
        let livePanelIDs = liveTerminalPanelIDs(in: state)
        launchedProfiledPanelIDs = launchedProfiledPanelIDs.intersection(livePanelIDs)
        restoredTerminalPanelIDsAwaitingLaunch = restoredTerminalPanelIDsAwaitingLaunch.intersection(livePanelIDs)
        profiledTerminalPanelIDsAwaitingStartupTitleCleanup = profiledTerminalPanelIDsAwaitingStartupTitleCleanup
            .intersection(livePanelIDs)
        exitedTerminalPanelIDs = exitedTerminalPanelIDs.intersection(livePanelIDs)
        pruneSearchState(livePanelIDs: livePanelIDs)
        #if TOASTTY_HAS_GHOSTTY_KIT
        workspaceMaintenanceService?.synchronize(
            state: state,
            livePanelIDs: livePanelIDs,
            removedPanelIDs: removedPanelIDs
        )
        #endif
    }

    func sendText(_ text: String, submit: Bool, panelID: UUID) -> Bool {
        automationSendText(text, submit: submit, panelID: panelID)
    }

    func readVisibleText(panelID: UUID) -> String? {
        automationReadVisibleText(panelID: panelID)
    }

    func automationSendText(_ text: String, submit: Bool, panelID: UUID) -> Bool {
        guard let controller = runtimeStore.existingController(for: panelID) else {
            return false
        }
        return controller.automationSendText(
            text,
            submit: submit
        )
    }

    func automationReadVisibleText(panelID: UUID) -> String? {
        guard let controller = runtimeStore.existingController(for: panelID) else {
            return nil
        }
        return controller.automationReadVisibleText()
    }

    private func performSearchAction(_ action: String, panelID: UUID) -> Bool {
        guard let controller = runtimeStore.existingController(for: panelID) else {
            return false
        }
        return controller.performSearchAction(action)
    }

    private func scheduleSearchDispatch(needle: String, panelID: UUID) {
        cancelPendingSearchDispatch(for: panelID)
        let shouldDelay = needle.isEmpty == false && needle.count < 3
        let dispatchToken = UUID()
        searchDispatchTokenByPanelID[panelID] = dispatchToken
        let task = Task { @MainActor [weak self] in
            if shouldDelay {
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard Task.isCancelled == false else {
                return
            }
            guard let self else {
                return
            }
            guard self.searchDispatchTokenByPanelID[panelID] == dispatchToken else {
                return
            }
            _ = self.performSearchAction("search:\(needle)", panelID: panelID)
            guard self.searchDispatchTokenByPanelID[panelID] == dispatchToken else {
                return
            }
            self.searchDispatchTaskByPanelID.removeValue(forKey: panelID)
            self.searchDispatchTokenByPanelID.removeValue(forKey: panelID)
        }
        searchDispatchTaskByPanelID[panelID] = task
    }

    private func cancelPendingSearchDispatch(for panelID: UUID) {
        searchDispatchTaskByPanelID.removeValue(forKey: panelID)?.cancel()
        searchDispatchTokenByPanelID.removeValue(forKey: panelID)
    }

    private func pruneSearchState(livePanelIDs: Set<UUID>) {
        for panelID in searchDispatchTaskByPanelID.keys where livePanelIDs.contains(panelID) == false {
            cancelPendingSearchDispatch(for: panelID)
        }
        if searchStateByPanelID.isEmpty == false {
            searchStateByPanelID = searchStateByPanelID.filter { livePanelIDs.contains($0.key) }
        }
        if let searchFieldFocusedPanelID,
           livePanelIDs.contains(searchFieldFocusedPanelID) == false {
            self.searchFieldFocusedPanelID = nil
        }
    }

    func terminalCloseConfirmationAssessment(panelID: UUID) -> TerminalCloseConfirmationAssessment? {
        if exitedTerminalPanelIDs.contains(panelID) {
            return TerminalCloseConfirmationAssessment(requiresConfirmation: false)
        }
        guard let controller = runtimeStore.existingController(for: panelID) else {
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
        guard let controller = runtimeStore.existingController(for: panelID) else {
            return .missingController(panelID: panelID)
        }
        return controller.renderAttachmentSnapshot()
    }

    func automationDropImageFiles(_ filePaths: [String], panelID: UUID) -> AutomationImageFileDropResult {
        guard let controller = runtimeStore.existingController(for: panelID) else {
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

    /// Attempts to return keyboard focus to the target terminal slot host view.
    /// Returns `false` when the host view is unavailable or not ready.
    @discardableResult
    func focusPanelIfPossible(panelID: UUID) -> Bool {
        focusCoordinator.focusIfPossible { [weak self] in
            guard let self,
                  let controller = self.runtimeStore.existingController(for: panelID) else {
                return nil
            }
            return TerminalFocusCoordinator.FocusTarget(
                isReadyForFocus: controller.lifecycleState.isReadyForFocus,
                focusHostViewIfNeeded: { controller.focusHostViewIfNeeded() }
            )
        }
    }

    /// Retries first-responder restoration for a specific panel host view. This
    /// covers launch/layout races where the host exists in state but is not yet
    /// attached when focus should be applied.
    func schedulePanelFocusRestore(panelID: UUID, avoidStealingKeyboardFocus: Bool = true) {
        scheduleFocusRestore(
            avoidStealingKeyboardFocus: avoidStealingKeyboardFocus
        ) {
            panelID
        }
    }

    /// Retries focus restoration for whichever panel is currently focused in a
    /// specific workspace. The panel is resolved on each retry so transient
    /// state like delayed focused-panel updates can still recover.
    func scheduleWorkspaceFocusRestore(workspaceID: UUID, avoidStealingKeyboardFocus: Bool = true) {
        scheduleFocusRestore(
            avoidStealingKeyboardFocus: avoidStealingKeyboardFocus
        ) { [weak self] in
            self?.store?.state.workspacesByID[workspaceID]?.focusedPanelID
        }
    }

    func workspaceActivitySubtext(for workspaceID: UUID) -> String? {
        workspaceActivitySubtextByID[workspaceID]
    }

    func panelDisplayTitleOverride(for panelID: UUID) -> String? {
        panelDisplayTitleOverrideByID[panelID]
    }

    func searchState(for panelID: UUID) -> TerminalSearchState? {
        searchStateByPanelID[panelID]
    }

    func isSearchFieldFocused(panelID: UUID) -> Bool {
        searchFieldFocusedPanelID == panelID
    }

    func setSearchFieldFocused(_ focused: Bool, panelID: UUID) {
        if focused {
            searchFieldFocusedPanelID = panelID
        } else if searchFieldFocusedPanelID == panelID {
            searchFieldFocusedPanelID = nil
        }
    }

    @discardableResult
    func releaseInactiveSearchFieldFocus(activePanelID: UUID?) -> Bool {
        guard let searchFieldFocusedPanelID,
              searchFieldFocusedPanelID != activePanelID else {
            return false
        }
        self.searchFieldFocusedPanelID = nil
        return true
    }

    @discardableResult
    func startSearch(panelID: UUID) -> Bool {
        performSearchAction("start_search", panelID: panelID)
    }

    @discardableResult
    func findNext(panelID: UUID) -> Bool {
        performSearchAction("navigate_search:next", panelID: panelID)
    }

    @discardableResult
    func findPrevious(panelID: UUID) -> Bool {
        performSearchAction("navigate_search:previous", panelID: panelID)
    }

    @discardableResult
    func endSearch(panelID: UUID) -> Bool {
        cancelPendingSearchDispatch(for: panelID)
        return performSearchAction("end_search", panelID: panelID)
    }

    func updateSearchNeedle(_ needle: String, panelID: UUID) {
        guard var state = searchStateByPanelID[panelID] else {
            return
        }
        guard state.needle != needle else {
            return
        }
        state.needle = needle
        searchStateByPanelID[panelID] = state
        scheduleSearchDispatch(needle: needle, panelID: panelID)
    }

    func restoreTerminalFocusAfterSearch(panelID: UUID) {
        if focusPanelIfPossible(panelID: panelID) {
            return
        }
        schedulePanelFocusRestore(
            panelID: panelID,
            avoidStealingKeyboardFocus: false
        )
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
        guard let targetController = runtimeStore.existingController(for: targetPanelID) else {
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
        guard let targetController = runtimeStore.existingController(for: drop.targetPanelID) else {
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
    func bindStateObservation(to store: AppStore) {
        stateObservation?.cancel()
        observedWindowFontPointsByID = effectiveWindowFontPointsByID(in: store.state)
        stateObservation = store.$state.sink { [weak self] state in
            self?.handleObservedStoreState(state)
        }
    }

    func handleObservedStoreState(_ state: AppState) {
        synchronize(with: state)
        let nextWindowFontPointsByID = effectiveWindowFontPointsByID(in: state)
        applyGhosttyFontChangesIfNeeded(
            from: observedWindowFontPointsByID,
            to: nextWindowFontPointsByID
        )
        observedWindowFontPointsByID = nextWindowFontPointsByID
    }

    func scheduleFocusRestore(
        avoidStealingKeyboardFocus: Bool,
        resolvePanelID: @escaping @MainActor () -> UUID?
    ) {
        focusCoordinator.scheduleFocusRestore(
            avoidStealingKeyboardFocus: avoidStealingKeyboardFocus
        ) { [weak self] in
            guard let self,
                  let panelID = resolvePanelID() else {
                return false
            }
            return self.focusPanelIfPossible(panelID: panelID)
        }
    }

    @discardableResult
    func sendSplitAction(workspaceID: UUID, action: AppAction) -> Bool {
        #if TOASTTY_HAS_GHOSTTY_KIT
        return storeActionCoordinator?.sendSplitAction(workspaceID: workspaceID, action: action) ?? false
        #else
        guard let store else { return false }
        return store.send(action)
        #endif
    }

    func liveTerminalPanelIDs(in state: AppState) -> Set<UUID> {
        state.workspacesByID.values.reduce(into: Set<UUID>()) { result, workspace in
            result.formUnion(workspace.allTerminalPanelIDs)
        }
    }

    func effectiveWindowFontPointsByID(in state: AppState) -> [UUID: Double] {
        Dictionary(uniqueKeysWithValues: state.windows.map { window in
            (window.id, state.effectiveTerminalFontPoints(for: window.id))
        })
    }

}

extension TerminalRuntimeRegistry {
    func setGhosttyCloseSurfaceHandler(_ handler: @escaping (UUID, Bool) -> Bool) {
        ghosttyCloseSurfaceHandler = handler
    }
}

#if TOASTTY_HAS_GHOSTTY_KIT
private extension TerminalRuntimeRegistry {
    func configureGhosttyActionHandler() {
        GhosttyRuntimeManager.shared.actionHandler = self
    }

    func applyGhosttyFontChangesIfNeeded(from previousPointsByWindowID: [UUID: Double], to nextPointsByWindowID: [UUID: Double]) {
        for windowID in Set(previousPointsByWindowID.keys).union(nextPointsByWindowID.keys) {
            guard let previousPoints = previousPointsByWindowID[windowID],
                  let nextPoints = nextPointsByWindowID[windowID],
                  abs(previousPoints - nextPoints) >= AppState.terminalFontComparisonEpsilon else {
                continue
            }
            runtimeStore.applyGhosttyFontChange(windowID: windowID, from: previousPoints, to: nextPoints)
        }
    }

    func splitSourceSurfaceState(for newPanelID: UUID) -> TerminalSplitSourceSurfaceState {
        runtimeStore.splitSourceSurfaceState(for: newPanelID)
    }

    func consumeSplitSource(for newPanelID: UUID) {
        runtimeStore.consumeSplitSource(for: newPanelID)
    }
}
#else
private extension TerminalRuntimeRegistry {
    func configureGhosttyActionHandler() {}

    func applyGhosttyFontChangesIfNeeded(from _: [UUID: Double], to _: [UUID: Double]) {}
}
#endif

#if TOASTTY_HAS_GHOSTTY_KIT
extension TerminalRuntimeRegistry {
    func panelID(forSurfaceHandle surfaceHandle: UInt) -> UUID? {
        runtimeStore.panelID(forSurfaceHandle: surfaceHandle)
    }

    #if DEBUG
    func registerSurfaceHandleForTesting(
        _ surface: ghostty_surface_t,
        for panelID: UUID,
        workspaceID: UUID,
        windowID: UUID,
        state: AppState
    ) {
        runtimeStore.registerSurfaceHandleForTesting(
            surface,
            for: panelID,
            workspaceID: workspaceID,
            windowID: windowID,
            state: state
        )
    }
    #endif

    func workspaceID(containing panelID: UUID, state: AppState) -> UUID? {
        for window in state.windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = state.workspacesByID[workspaceID] else { continue }
                guard workspace.panelState(for: panelID) != nil else { continue }
                if workspace.slotID(containingPanelID: panelID) != nil {
                    return workspaceID
                }
            }
        }
        return nil
    }
}
#endif

extension TerminalRuntimeRegistry: TerminalSurfaceControllerDelegate {
    func handleLocalInterruptKey(for panelID: UUID, kind: TerminalLocalInterruptKind) {
        _ = sessionLifecycleTracker?.handleLocalInterruptForPanelIfActive(
            panelID: panelID,
            kind: kind,
            at: Date()
        )
    }

    @discardableResult
    func activatePanelIfNeeded(_ panelID: UUID) -> Bool {
        guard let store else { return false }
        let state = store.state
        for window in state.windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = state.workspacesByID[workspaceID] else { continue }
                guard workspace.panelState(for: panelID) != nil else { continue }
                guard workspace.slotID(containingPanelID: panelID) != nil else { continue }
                return store.send(.focusPanel(workspaceID: workspaceID, panelID: panelID))
            }
        }
        return false
    }

    #if TOASTTY_HAS_GHOSTTY_KIT
    func splitSourceSurfaceState(forNewPanelID panelID: UUID) -> TerminalSplitSourceSurfaceState {
        splitSourceSurfaceState(for: panelID)
    }

    func consumeSplitSource(forNewPanelID panelID: UUID) {
        consumeSplitSource(for: panelID)
    }

    func surfaceLaunchConfiguration(for panelID: UUID) -> TerminalSurfaceLaunchConfiguration {
        let baseEnvironmentVariables = baseLaunchEnvironmentProvider?(panelID) ?? [:]
        logSurfaceLaunchEnvironmentIfNeeded(panelID: panelID, environment: baseEnvironmentVariables)

        guard launchedProfiledPanelIDs.contains(panelID) == false else {
            return TerminalSurfaceLaunchConfiguration(environmentVariables: baseEnvironmentVariables)
        }
        guard let store,
              let workspaceID = workspaceID(containing: panelID, state: store.state),
              let workspace = store.state.workspacesByID[workspaceID],
              case .terminal(let terminalState)? = workspace.panelState(for: panelID) else {
            return TerminalSurfaceLaunchConfiguration(environmentVariables: baseEnvironmentVariables)
        }

        let catalog = terminalProfileProvider?.catalog ?? .empty
        switch TerminalProfileLaunchResolver.resolve(
            panelID: panelID,
            terminalState: terminalState,
            catalog: catalog,
            restoredTerminalPanelIDsAwaitingLaunch: restoredTerminalPanelIDsAwaitingLaunch,
            launchedProfiledPanelIDs: launchedProfiledPanelIDs,
            baseEnvironmentVariables: baseEnvironmentVariables
        ) {
        case .none:
            return TerminalSurfaceLaunchConfiguration(environmentVariables: baseEnvironmentVariables)
        case .missingProfile(let profileID, let reason):
            ToasttyLog.warning(
                "Launching profiled pane without startup command because the profile is unavailable",
                category: .terminal,
                metadata: [
                    "panel_id": panelID.uuidString,
                    "profile_id": profileID,
                    "launch_reason": reason.rawValue,
                ]
            )
            return TerminalSurfaceLaunchConfiguration(environmentVariables: baseEnvironmentVariables)
        case .launch(let configuration):
            if Self.shouldSuppressProfileStartupCommandTitle(configuration.initialInput) {
                // Seed cleanup before the surface starts emitting title callbacks so the
                // literal launch wrapper title cannot win the first race on fresh panes.
                profiledTerminalPanelIDsAwaitingStartupTitleCleanup.insert(panelID)
            }
            return configuration
        }
    }

    func profileStartupCommandAwaitingTitleCleanup(
        panelID: UUID,
        terminalState: TerminalPanelState
    ) -> String? {
        guard profiledTerminalPanelIDsAwaitingStartupTitleCleanup.contains(panelID),
              let profileBinding = terminalState.profileBinding,
              let profile = terminalProfileProvider?.catalog.profile(id: profileBinding.profileID),
              Self.shouldSuppressProfileStartupCommandTitle(profile.startupCommand) else {
            return nil
        }
        return profile.startupCommand
    }

    func markProfileLaunchTitleCleanupCompleted(panelID: UUID) {
        profiledTerminalPanelIDsAwaitingStartupTitleCleanup.remove(panelID)
    }

    func markInitialSurfaceLaunchCompleted(for panelID: UUID) {
        restoredTerminalPanelIDsAwaitingLaunch.remove(panelID)
        guard let store,
              let workspaceID = workspaceID(containing: panelID, state: store.state),
              let workspace = store.state.workspacesByID[workspaceID],
              case .terminal(let terminalState)? = workspace.panelState(for: panelID),
              terminalState.profileBinding != nil else {
            return
        }
        launchedProfiledPanelIDs.insert(panelID)
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
        expectedWorkingDirectory: String?,
        isRestoredLaunch: Bool
    ) {
        registerChildPIDAfterSurfaceCreation(
            panelID: panelID,
            previousChildren: previousChildren,
            expectedWorkingDirectory: expectedWorkingDirectory,
            isRestoredLaunch: isRestoredLaunch
        )
    }

    func requestImmediateProcessWorkingDirectoryRefresh(
        panelID: UUID,
        source: String
    ) {
        metadataService?.requestImmediateWorkingDirectoryRefresh(
            panelID: panelID,
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

extension TerminalRuntimeRegistry {
    func setWorkspaceActivitySubtext(_ nextSubtextByWorkspaceID: [UUID: String]) {
        if workspaceActivitySubtextByID != nextSubtextByWorkspaceID {
            workspaceActivitySubtextByID = nextSubtextByWorkspaceID
        }
    }

    func setPanelDisplayTitleOverrides(_ nextOverridesByPanelID: [UUID: String]) {
        if panelDisplayTitleOverrideByID != nextOverridesByPanelID {
            panelDisplayTitleOverrideByID = nextOverridesByPanelID
        }
    }
}

#if TOASTTY_HAS_GHOSTTY_KIT
private extension TerminalRuntimeRegistry {
    func resolvedActionPanelID(in workspace: WorkspaceState) -> UUID? {
        if let focusedPanelID = workspace.focusedPanelID,
           workspace.panelState(for: focusedPanelID) != nil,
           workspace.slotID(containingPanelID: focusedPanelID) != nil {
            return focusedPanelID
        }

        for tab in workspace.orderedTabs {
            for leaf in tab.layoutTree.allSlotInfos {
                let panelID = leaf.panelID
                if tab.panels[panelID] != nil {
                    return panelID
                }
            }
        }

        return nil
    }

    func isValidDropTargetPanel(_ panelID: UUID, state: AppState) -> Bool {
        guard let workspaceID = workspaceID(containing: panelID, state: state),
              let workspace = state.workspacesByID[workspaceID],
              let panelState = workspace.panelState(for: panelID),
              case .terminal = panelState,
              workspace.slotID(containingPanelID: panelID) != nil else {
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
        runtimeStore.register(surface: surface, for: panelID)
    }

    func unregister(surface: ghostty_surface_t, for panelID: UUID) {
        runtimeStore.unregister(surface: surface, for: panelID)
        workspaceMaintenanceService?.handleSurfaceUnregister(panelID: panelID)
    }

    func prefersNativeCWDSignal(panelID: UUID) -> Bool {
        metadataService?.prefersNativeCWDSignal(panelID: panelID) ?? false
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
        expectedWorkingDirectory: String?,
        isRestoredLaunch: Bool
    ) {
        metadataService?.registerChildPIDAfterSurfaceCreation(
            panelID: panelID,
            previousChildren: previousChildren,
            expectedWorkingDirectory: expectedWorkingDirectory,
            isRestoredLaunch: isRestoredLaunch
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
}
#endif

#if TOASTTY_HAS_GHOSTTY_KIT
extension TerminalRuntimeRegistry: GhosttyRuntimeActionHandling {
    func handleGhosttyRuntimeAction(_ action: GhosttyRuntimeAction) -> Bool {
        actionRouter?.handle(action) ?? false
    }

    func handleGhosttyCloseSurfaceRequest(surfaceHandle: UInt?, confirmed: Bool) -> Bool {
        guard let surfaceHandle else {
            ToasttyLog.warning(
                "Ignoring Ghostty close-surface request without a resolved surface handle",
                category: .ghostty
            )
            return false
        }
        guard let panelID = panelID(forSurfaceHandle: surfaceHandle) else {
            ToasttyLog.warning(
                "Ignoring Ghostty close-surface request for an unknown surface handle",
                category: .ghostty,
                metadata: ["surface_handle": String(surfaceHandle)]
            )
            return false
        }
        return ghosttyCloseSurfaceHandler?(panelID, confirmed) ?? false
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

        guard let selection = state.selectedWorkspaceSelection(),
              let resolvedPanelID = resolvedActionPanelID(in: selection.workspace) else {
            ToasttyLog.debug(
                "Ghostty app action could not resolve active panel",
                category: .terminal,
                metadata: ["intent": action.logIntentName]
            )
            return nil
        }

        return (resolvedPanelID, selection.workspaceID)
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
}
#endif

#if TOASTTY_HAS_GHOSTTY_KIT
extension TerminalRuntimeRegistry {
    func handleSearchRuntimeAction(
        _ intent: GhosttyRuntimeAction.Intent,
        panelID: UUID
    ) -> Bool {
        switch intent {
        case .startSearch(let needle):
            var nextState = searchStateByPanelID[panelID] ?? TerminalSearchState(
                isPresented: true,
                needle: needle
            )
            nextState.isPresented = true
            if needle.isEmpty == false {
                nextState.needle = needle
            }
            nextState.focusRequestID = UUID()
            searchStateByPanelID[panelID] = nextState
            if needle.isEmpty == false {
                scheduleSearchDispatch(needle: needle, panelID: panelID)
            }
            return true

        case .endSearch:
            cancelPendingSearchDispatch(for: panelID)
            if searchFieldFocusedPanelID == panelID {
                searchFieldFocusedPanelID = nil
            }
            searchStateByPanelID.removeValue(forKey: panelID)
            return true

        case .searchTotal(let total):
            guard var state = searchStateByPanelID[panelID] else {
                return false
            }
            state.total = total
            searchStateByPanelID[panelID] = state
            return true

        case .searchSelected(let selected):
            guard var state = searchStateByPanelID[panelID] else {
                return false
            }
            state.selected = selected
            searchStateByPanelID[panelID] = state
            return true

        default:
            return false
        }
    }

    func handleRuntimeMetadataAction(
        _ intent: GhosttyRuntimeAction.Intent,
        workspaceID: UUID,
        panelID: UUID,
        state: AppState,
        store: AppStore
    ) -> Bool {
        _ = store
        if case .showChildExited(let exitCode) = intent {
            exitedTerminalPanelIDs.insert(panelID)
            ToasttyLog.debug(
                "Marked terminal panel as exited",
                category: .terminal,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "panel_id": panelID.uuidString,
                    "exit_code": String(exitCode),
                ]
            )
            return true
        }
        let metadataHandled = metadataService?.handleRuntimeMetadataAction(
            intent,
            workspaceID: workspaceID,
            panelID: panelID,
            state: state
        ) ?? false

        switch intent {
        case .commandFinished:
            let activityHandled = handleCommandFinishedActivityUpdate(
                panelID: panelID,
                state: state
            )
            return metadataHandled || activityHandled

        default:
            return metadataHandled
        }
    }

    private func handleCommandFinishedActivityUpdate(
        panelID: UUID,
        state: AppState
    ) -> Bool {
        guard let activityInferenceService else { return false }
        let handled = activityInferenceService.handleCommandFinished(
            panelID: panelID,
            liveWorkspaceIDs: Set(state.workspacesByID.keys)
        )
        guard handled else { return false }

        setPanelDisplayTitleOverrides(activityInferenceService.panelDisplayTitleOverrideByID)
        setWorkspaceActivitySubtext(activityInferenceService.workspaceActivitySubtextByID)
        return true
    }

    static func normalizedMetadataValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return trimmed
    }

    static func shouldSuppressProfileStartupCommandTitle(_ startupCommand: String?) -> Bool {
        guard let normalizedCommand = normalizedMetadataValue(startupCommand) else { return false }
        return normalizedCommand.contains("$TOASTTY_") || normalizedCommand.contains("${TOASTTY_")
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
