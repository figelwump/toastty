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
    private var controllers: [UUID: TerminalSurfaceController] = [:]
    private weak var store: AppStore?
    private var storeActionObserverToken: UUID?
    @Published private(set) var workspaceActivitySubtextByID: [UUID: String] = [:]
    private var selectedSlotFocusRestoreTask: Task<Void, Never>?
    #if TOASTTY_HAS_GHOSTTY_KIT
    private var panelIDBySurfaceHandle: [UInt: UUID] = [:]
    private var pendingSplitSourcePanelByNewPanelID: [UUID: UUID] = [:]
    private var titleBeforeAgentInferenceByPanelID: [UUID: String] = [:]
    private var suppressedAgentTitleInferencePanelIDs: Set<UUID> = []
    private var nativeCWDLastSignalAtByPanelID: [UUID: Date] = [:]
    private var nativeCWDLastProcessFallbackPollAtByPanelID: [UUID: Date] = [:]
    private var panelActivityByPanelID: [UUID: PanelActivityState] = [:]
    private var previousSelectedWorkspaceID: UUID?
    private var visibilityPulseTask: Task<Void, Never>?
    private var processWorkingDirectoryRefreshTask: Task<Void, Never>?
    private let processWorkingDirectoryResolver = TerminalProcessWorkingDirectoryResolver()
    #endif

    deinit {
        selectedSlotFocusRestoreTask?.cancel()
        #if TOASTTY_HAS_GHOSTTY_KIT
        visibilityPulseTask?.cancel()
        processWorkingDirectoryRefreshTask?.cancel()
        #endif
    }

    func bind(store: AppStore) {
        let previousStore = self.store
        if let existingStore = previousStore {
            precondition(existingStore === store, "TerminalRuntimeRegistry cannot be rebound to a different AppStore.")
        }
        if let storeActionObserverToken,
           let previousStore {
            previousStore.removeActionAppliedObserver(storeActionObserverToken)
        }
        self.store = store
        storeActionObserverToken = store.addActionAppliedObserver { [weak self] action, previousState, nextState in
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
            titleBeforeAgentInferenceByPanelID.removeValue(forKey: panelID)
            suppressedAgentTitleInferencePanelIDs.remove(panelID)
            nativeCWDLastSignalAtByPanelID.removeValue(forKey: panelID)
            nativeCWDLastProcessFallbackPollAtByPanelID.removeValue(forKey: panelID)
            panelActivityByPanelID.removeValue(forKey: panelID)
            #endif
        }
        #if TOASTTY_HAS_GHOSTTY_KIT
        pendingSplitSourcePanelByNewPanelID = pendingSplitSourcePanelByNewPanelID.filter {
            livePanelIDs.contains($0.key) && livePanelIDs.contains($0.value)
        }
        panelActivityByPanelID = panelActivityByPanelID.filter { panelID, _ in
            livePanelIDs.contains(panelID)
        }
        #endif

        if workspaceActivitySubtextByID.isEmpty == false {
            let liveWorkspaceIDs = Set(state.workspacesByID.keys)
            workspaceActivitySubtextByID = workspaceActivitySubtextByID.filter { workspaceID, _ in
                liveWorkspaceIDs.contains(workspaceID)
            }
        }

        handleGhosttyWorkspaceSelectionPulseIfNeeded(state: state)
    }

    func applyGlobalFontChange(from previousPoints: Double, to nextPoints: Double) {
        applyGhosttyGlobalFontChangeIfNeeded(from: previousPoints, to: nextPoints)
    }

    func automationSendText(_ text: String, submit: Bool, panelID: UUID) -> Bool {
        guard let controller = controllers[panelID] else {
            return false
        }
        #if TOASTTY_HAS_GHOSTTY_KIT
        let hasResolvedShell = processWorkingDirectoryResolver.resolveWorkingDirectory(for: panelID) != nil
        let hasNativeCWDSignal = panelHasNativeCWDSignal(panelID: panelID)
        let readyForInput = hasResolvedShell || hasNativeCWDSignal
        #else
        let readyForInput = false
        #endif
        return controller.automationSendText(
            text,
            submit: submit,
            readyForInput: readyForInput
        )
    }

    func automationReadVisibleText(panelID: UUID) -> String? {
        guard let controller = controllers[panelID] else {
            return nil
        }
        return controller.automationReadVisibleText()
    }

    func automationRenderSnapshot(panelID: UUID) -> TerminalPanelRenderAttachmentSnapshot {
        guard let controller = controllers[panelID] else {
            return .missingController(panelID: panelID)
        }
        return controller.renderAttachmentSnapshot()
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

    /// Attempts to return keyboard focus to the currently selected workspace's
    /// focused terminal slot host view. Returns `false` when there is no active
    /// focused terminal slot or no attached host view.
    @discardableResult
    func focusSelectedWorkspaceSlotIfPossible() -> Bool {
        guard let workspace = store?.selectedWorkspace,
              let panelID = workspace.focusedPanelID else {
            return false
        }
        guard let controller = controllers[panelID] else {
            return false
        }
        guard controller.lifecycleState.isReadyForFocus else {
            return false
        }
        return controller.focusHostViewIfNeeded()
    }

    /// Retries first-responder restoration for the selected workspace's focused
    /// slot. This covers launch/layout races where the host view exists in state
    /// but is not yet attached when focus should be applied.
    func scheduleSelectedWorkspaceSlotFocusRestore() {
        selectedSlotFocusRestoreTask?.cancel()
        selectedSlotFocusRestoreTask = Task { @MainActor [weak self] in
            let maxAttempts = 12
            let retryDelayNanoseconds: UInt64 = 16_000_000
            for attempt in 0..<maxAttempts {
                guard Task.isCancelled == false else { return }
                guard let self else { return }
                if NSApp.isActive, self.shouldAvoidStealingKeyboardFocus() {
                    return
                }
                if NSApp.isActive, self.focusSelectedWorkspaceSlotIfPossible() {
                    return
                }
                guard attempt < maxAttempts - 1 else { return }
                try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
                guard Task.isCancelled == false else { return }
            }
        }
    }

    private func shouldAvoidStealingKeyboardFocus() -> Bool {
        guard let keyWindow = NSApp.keyWindow,
              let textView = keyWindow.firstResponder as? NSTextView else {
            return false
        }
        return textView.isFieldEditor
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
        guard let targetController = controllers[targetPanelID] else {
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
        guard let targetController = controllers[drop.targetPanelID] else {
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
        guard let store else { return false }
        #if TOASTTY_HAS_GHOSTTY_KIT
        refreshSplitSourcePanelCWDBeforeSplit(
            workspaceID: workspaceID,
            store: store
        )
        #endif
        return store.send(action)
    }

    #if TOASTTY_HAS_GHOSTTY_KIT
    /// Refreshes the split source panel CWD from its tracked process PID so the
    /// reducer reads a fresh value when creating the new split panel.
    func refreshSplitSourcePanelCWDBeforeSplit(workspaceID: UUID, store: AppStore) {
        let state = store.state
        guard let workspace = state.workspacesByID[workspaceID],
              let sourcePanelID = resolvedActionPanelID(in: workspace),
              let panelState = workspace.panels[sourcePanelID],
              case .terminal = panelState else {
            return
        }
        let now = Date()
        guard shouldRunProcessCWDFallbackPoll(panelID: sourcePanelID, now: now) else {
            return
        }
        recordProcessCWDFallbackPoll(panelID: sourcePanelID, now: now)

        refreshWorkingDirectoryFromProcessIfNeeded(
            panelID: sourcePanelID,
            source: "pre_split_refresh"
        )
    }
    #endif
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
        switch action {
        case .splitFocusedSlot(workspaceID: let workspaceID, orientation: _):
            registerPendingSplitSourceIfNeeded(
                workspaceID: workspaceID,
                previousState: previousState,
                nextState: nextState
            )
        case .splitFocusedSlotInDirection(workspaceID: let workspaceID, direction: _):
            registerPendingSplitSourceIfNeeded(
                workspaceID: workspaceID,
                previousState: previousState,
                nextState: nextState
            )
        case .toggleFocusedPanelMode(workspaceID: let workspaceID):
            scheduleFocusedPanelFocusRestoreIfNeeded(
                workspaceID: workspaceID,
                previousState: previousState,
                nextState: nextState
            )
        default:
            break
        }
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

    func scheduleFocusedPanelFocusRestoreIfNeeded(
        workspaceID: UUID,
        previousState: AppState,
        nextState: AppState
    ) {
        guard selectedWorkspaceID(state: nextState) == workspaceID,
              let previousWorkspace = previousState.workspacesByID[workspaceID],
              let nextWorkspace = nextState.workspacesByID[workspaceID],
              previousWorkspace.focusedPanelModeActive != nextWorkspace.focusedPanelModeActive else {
            return
        }

        scheduleSelectedWorkspaceSlotFocusRestore()
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
           workspace.layoutTree.slotContaining(panelID: focusedPanelID) != nil,
           let focusedPanelState = workspace.panels[focusedPanelID],
           focusedPanelState.kind == .terminal {
            return focusedPanelID
        }

        for leaf in workspace.layoutTree.allSlotInfos {
            let panelID = leaf.panelID
            guard workspace.layoutTree.slotContaining(panelID: panelID) != nil,
                  let panelState = workspace.panels[panelID] else {
                continue
            }
            if panelState.kind == .terminal {
                return panelID
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
        panelIDBySurfaceHandle[UInt(bitPattern: surface)] = panelID
    }

    func unregister(surface: ghostty_surface_t, for panelID: UUID) {
        let key = UInt(bitPattern: surface)
        if panelIDBySurfaceHandle[key] == panelID {
            panelIDBySurfaceHandle.removeValue(forKey: key)
        }
        processWorkingDirectoryResolver.invalidate(panelID: panelID)
        titleBeforeAgentInferenceByPanelID.removeValue(forKey: panelID)
        suppressedAgentTitleInferencePanelIDs.remove(panelID)
        nativeCWDLastSignalAtByPanelID.removeValue(forKey: panelID)
        nativeCWDLastProcessFallbackPollAtByPanelID.removeValue(forKey: panelID)
    }

    func panelHasNativeCWDSignal(panelID: UUID) -> Bool {
        nativeCWDLastSignalAtByPanelID[panelID] != nil
    }

    func prefersNativeCWDSignal(panelID: UUID, now: Date = Date()) -> Bool {
        guard let lastSignalAt = nativeCWDLastSignalAtByPanelID[panelID] else {
            return false
        }
        return now.timeIntervalSince(lastSignalAt) <= Self.nativeCWDSignalFreshnessInterval
    }

    func shouldRunProcessCWDFallbackPoll(panelID: UUID, now: Date = Date()) -> Bool {
        guard panelHasNativeCWDSignal(panelID: panelID) else {
            return true
        }
        guard let lastPollAt = nativeCWDLastProcessFallbackPollAtByPanelID[panelID] else {
            return true
        }
        return now.timeIntervalSince(lastPollAt) >= Self.nativeCWDProcessFallbackPollInterval
    }

    func recordProcessCWDFallbackPoll(panelID: UUID, now: Date = Date()) {
        nativeCWDLastProcessFallbackPollAtByPanelID[panelID] = now
    }

    func recordNativeCWDSignal(panelID: UUID, now: Date = Date()) {
        let isFirstSignal = nativeCWDLastSignalAtByPanelID[panelID] == nil
        nativeCWDLastSignalAtByPanelID[panelID] = now
        // Seed fallback polling from the native signal timestamp so we do not
        // immediately overwrite a fresh callback with a process poll.
        nativeCWDLastProcessFallbackPollAtByPanelID[panelID] = now
        if isFirstSignal {
            ToasttyLog.info(
                "Detected native Ghostty cwd callback for terminal panel; process cwd polling will be treated as fallback",
                category: .terminal,
                metadata: ["panel_id": panelID.uuidString]
            )
        }
    }

    func snapshotChildPIDsForSurfaceCreation() -> Set<pid_t> {
        processWorkingDirectoryResolver.snapshotChildPIDs()
    }

    func registerChildPIDAfterSurfaceCreation(
        panelID: UUID,
        previousChildren: Set<pid_t>,
        expectedWorkingDirectory: String
    ) {
        processWorkingDirectoryResolver.registerNewChild(
            panelID: panelID,
            previousChildren: previousChildren,
            expectedWorkingDirectory: expectedWorkingDirectory
        )
    }

    func panelID(for surface: ghostty_surface_t) -> UUID? {
        panelIDBySurfaceHandle[UInt(bitPattern: surface)]
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
        let now = Date()
        refreshSelectedWorkspaceTerminalMetadataFromProcess(state: state)

        let selectedPanelWorkspaceIDs = trackedSelectedWorkspaceVisibleTerminalPanelIDs(state: state)
        for (panelID, workspaceID) in selectedPanelWorkspaceIDs {
            refreshPanelActivityFromVisibleTextIfNeeded(
                panelID: panelID,
                workspaceID: workspaceID,
                state: state,
                now: now
            )
        }

        let backgroundPanelWorkspaceIDs = trackedBackgroundTerminalPanelIDs(state: state)
        for (panelID, workspaceID) in backgroundPanelWorkspaceIDs {
            refreshPanelActivityFromVisibleTextIfNeeded(
                panelID: panelID,
                workspaceID: workspaceID,
                state: state,
                now: now
            )
        }

        pruneStalePanelActivity(now: now)
        updateWorkspaceActivitySubtext(state: state, now: now)
    }

    func refreshSelectedWorkspaceTerminalMetadataFromProcess(state: AppState) {
        guard let selectedWorkspaceID = selectedWorkspaceID(state: state),
              let workspace = state.workspacesByID[selectedWorkspaceID] else {
            return
        }

        let panelIDs = visibleTerminalPanelIDs(in: workspace)
        guard panelIDs.isEmpty == false else { return }
        let now = Date()
        for panelID in panelIDs {
            if shouldRunProcessCWDFallbackPoll(panelID: panelID, now: now) {
                recordProcessCWDFallbackPoll(panelID: panelID, now: now)
                _ = refreshWorkingDirectoryFromProcessIfNeeded(
                    panelID: panelID,
                    source: "process_poll"
                )
            }
            refreshAgentTitleFromVisibleTextIfNeeded(panelID: panelID, state: state)
        }
    }

    func trackedSelectedWorkspaceVisibleTerminalPanelIDs(state: AppState) -> [UUID: UUID] {
        guard let selectedWorkspaceID = selectedWorkspaceID(state: state),
              let workspace = state.workspacesByID[selectedWorkspaceID] else {
            return [:]
        }

        var workspaceByPanelID: [UUID: UUID] = [:]
        for panelID in visibleTerminalPanelIDs(in: workspace) {
            guard controllers[panelID] != nil else { continue }
            workspaceByPanelID[panelID] = selectedWorkspaceID
        }
        return workspaceByPanelID
    }

    func trackedBackgroundTerminalPanelIDs(state: AppState) -> [UUID: UUID] {
        let selectedWorkspaceID = selectedWorkspaceID(state: state)
        var workspaceByPanelID: [UUID: UUID] = [:]
        for workspace in state.workspacesByID.values where workspace.id != selectedWorkspaceID {
            for (panelID, panelState) in workspace.panels {
                guard case .terminal = panelState else { continue }
                guard controllers[panelID] != nil else { continue }
                workspaceByPanelID[panelID] = workspace.id
            }
        }
        return workspaceByPanelID
    }

    func refreshAgentTitleFromVisibleTextIfNeeded(panelID: UUID, state: AppState) {
        guard let store,
              let workspaceID = workspaceID(containing: panelID, state: state),
              let workspace = state.workspacesByID[workspaceID],
              let panelState = workspace.panels[panelID],
              case .terminal(let terminalState) = panelState else {
            titleBeforeAgentInferenceByPanelID.removeValue(forKey: panelID)
            suppressedAgentTitleInferencePanelIDs.remove(panelID)
            return
        }

        let currentTitle = terminalState.title
        let currentCanonicalInferredAgentTitle = Self.canonicalInferredAgentTitle(from: currentTitle)
        let titleIsAgentInferred = currentCanonicalInferredAgentTitle != nil
        let titleEligibleForInference = Self.titleIsEligibleForAgentInference(
            terminalTitle: currentTitle,
            terminalCWD: terminalState.cwd
        )
        guard titleIsAgentInferred || titleEligibleForInference else {
            titleBeforeAgentInferenceByPanelID.removeValue(forKey: panelID)
            suppressedAgentTitleInferencePanelIDs.remove(panelID)
            return
        }

        guard let visibleText = automationReadVisibleText(panelID: panelID) else {
            return
        }
        let inferredAgentTitle = Self.inferredAgentTitleFromVisibleTerminalText(visibleText)
        let shellPromptIsActive = Self.visibleTextShowsInteractiveShellPrompt(visibleText)
        let recentAgentLaunchCommandIsVisible = Self.visibleTextShowsRecentAgentLaunchCommand(visibleText)

        if titleIsAgentInferred {
            if shellPromptIsActive {
                restoreTitleBeforeAgentInferenceIfNeeded(
                    panelID: panelID,
                    workspaceID: workspaceID,
                    currentTitle: currentTitle,
                    store: store
                )
                suppressedAgentTitleInferencePanelIDs.insert(panelID)
                return
            }

            if inferredAgentTitle == currentCanonicalInferredAgentTitle {
                return
            }

            if let inferredAgentTitle {
                let handled = store.send(
                    .updateTerminalPanelMetadata(
                        panelID: panelID,
                        title: inferredAgentTitle,
                        cwd: nil
                    )
                )
                if handled {
                    ToasttyLog.debug(
                        "Updated inferred agent title from visible terminal text",
                        category: .terminal,
                        metadata: [
                            "workspace_id": workspaceID.uuidString,
                            "panel_id": panelID.uuidString,
                            "inferred_title": inferredAgentTitle,
                        ]
                    )
                } else {
                    ToasttyLog.warning(
                        "Reducer rejected inferred agent title update",
                        category: .terminal,
                        metadata: [
                            "workspace_id": workspaceID.uuidString,
                            "panel_id": panelID.uuidString,
                            "inferred_title": inferredAgentTitle,
                        ]
                    )
                }
                return
            }

            restoreTitleBeforeAgentInferenceIfNeeded(
                panelID: panelID,
                workspaceID: workspaceID,
                currentTitle: currentTitle,
                store: store
            )
            suppressedAgentTitleInferencePanelIDs.insert(panelID)
            return
        }

        if shellPromptIsActive {
            // Avoid re-inference loops from stale banner text once control has
            // returned to an interactive shell prompt.
            return
        }

        if suppressedAgentTitleInferencePanelIDs.contains(panelID) {
            // Do not re-infer from stale banner text after prompt restore unless
            // a fresh launch command is visible near the current prompt.
            guard recentAgentLaunchCommandIsVisible else {
                return
            }
            suppressedAgentTitleInferencePanelIDs.remove(panelID)
        }

        guard let inferredAgentTitle else {
            return
        }

        let handled = store.send(
            .updateTerminalPanelMetadata(
                panelID: panelID,
                title: inferredAgentTitle,
                cwd: nil
            )
        )
        if handled {
            titleBeforeAgentInferenceByPanelID[panelID] = currentTitle
            suppressedAgentTitleInferencePanelIDs.remove(panelID)
            ToasttyLog.debug(
                "Inferred agent title from visible terminal text",
                category: .terminal,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "panel_id": panelID.uuidString,
                    "inferred_title": inferredAgentTitle,
                ]
            )
        } else {
            ToasttyLog.warning(
                "Reducer rejected inferred agent title update",
                category: .terminal,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "panel_id": panelID.uuidString,
                    "inferred_title": inferredAgentTitle,
                ]
            )
        }
    }

    func refreshPanelActivityFromVisibleTextIfNeeded(
        panelID: UUID,
        workspaceID: UUID,
        state: AppState,
        now: Date
    ) {
        guard let workspace = state.workspacesByID[workspaceID],
              let panelState = workspace.panels[panelID],
              case .terminal(let terminalState) = panelState else {
            panelActivityByPanelID.removeValue(forKey: panelID)
            return
        }

        guard let visibleText = automationReadVisibleText(panelID: panelID) else {
            return
        }
        let visibleLines = Self.sanitizedVisibleTerminalLines(visibleText)

        let inferredAgentKind = Self.inferredAgentKind(
            terminalTitle: terminalState.title,
            visibleText: visibleText
        )
        guard let inferredAgentKind else {
            // Clear stale agent activity after the slot returns to an
            // interactive shell prompt. This avoids lingering sidebar status
            // while also tolerating transient inference misses mid-run.
            if Self.visibleTextShowsInteractiveShellPrompt(visibleText) {
                panelActivityByPanelID.removeValue(forKey: panelID)
            }
            return
        }

        let inferredPhase = Self.inferredAgentPhase(visibleText: visibleText, visibleLines: visibleLines)
        let inferredRunningCommand = Self.inferredRunningCommand(visibleLines: visibleLines)
        panelActivityByPanelID[panelID] = PanelActivityState(
            workspaceID: workspaceID,
            agent: inferredAgentKind,
            phase: inferredPhase,
            runningCommand: inferredRunningCommand,
            updatedAt: now
        )
    }

    func pruneStalePanelActivity(now: Date) {
        panelActivityByPanelID = panelActivityByPanelID.filter { _, activity in
            now.timeIntervalSince(activity.updatedAt) <= Self.activityRetentionInterval
        }
    }

    func updateWorkspaceActivitySubtext(state: AppState, now: Date) {
        var activitiesByWorkspaceID: [UUID: [PanelActivityState]] = [:]
        for activity in panelActivityByPanelID.values {
            guard state.workspacesByID[activity.workspaceID] != nil else { continue }
            guard now.timeIntervalSince(activity.updatedAt) <= Self.activityRetentionInterval else { continue }
            activitiesByWorkspaceID[activity.workspaceID, default: []].append(activity)
        }

        var nextSubtextByWorkspaceID: [UUID: String] = [:]
        for (workspaceID, activities) in activitiesByWorkspaceID {
            guard let subtext = Self.workspaceActivitySubtext(from: activities, now: now) else { continue }
            nextSubtextByWorkspaceID[workspaceID] = subtext
        }

        if workspaceActivitySubtextByID != nextSubtextByWorkspaceID {
            workspaceActivitySubtextByID = nextSubtextByWorkspaceID
        }
    }

    func restoreTitleBeforeAgentInferenceIfNeeded(
        panelID: UUID,
        workspaceID: UUID,
        currentTitle: String,
        store: AppStore
    ) {
        if let previousTitle = titleBeforeAgentInferenceByPanelID[panelID] {
            let handled = store.send(
                .updateTerminalPanelMetadata(
                    panelID: panelID,
                    title: previousTitle,
                    cwd: nil
                )
            )
            if handled {
                titleBeforeAgentInferenceByPanelID.removeValue(forKey: panelID)
                ToasttyLog.debug(
                    "Restored terminal title after inferred agent title became stale",
                    category: .terminal,
                    metadata: [
                        "workspace_id": workspaceID.uuidString,
                        "panel_id": panelID.uuidString,
                        "restored_title": previousTitle,
                    ]
                )
            } else {
                ToasttyLog.warning(
                    "Reducer rejected restoring stale inferred terminal title",
                    category: .terminal,
                    metadata: [
                        "workspace_id": workspaceID.uuidString,
                        "panel_id": panelID.uuidString,
                        "restored_title": previousTitle,
                    ]
                )
            }
            // Fall through to stale-title fallback when restore is rejected.
        }

        guard Self.isInferredAgentTitle(currentTitle) else {
            return
        }

        let resetTitle = Self.defaultTerminalTitleAfterAgentInferenceRestore
        guard currentTitle != resetTitle else {
            return
        }

        let handled = store.send(
            .updateTerminalPanelMetadata(panelID: panelID, title: resetTitle, cwd: nil)
        )
        if handled {
            ToasttyLog.debug(
                "Reset stale inferred terminal title after restart",
                category: .terminal,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "panel_id": panelID.uuidString,
                    "restored_title": resetTitle,
                ]
            )
        } else {
            ToasttyLog.warning(
                "Reducer rejected resetting stale inferred terminal title",
                category: .terminal,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "panel_id": panelID.uuidString,
                    "restored_title": resetTitle,
                ]
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
        for leaf in workspace.layoutTree.allSlotInfos {
            let selectedPanelID = leaf.panelID
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

        // Desktop notifications are handled separately — they should not steal focus.
        if case .desktopNotification(let title, let body) = action.intent {
            let route = resolveDesktopNotificationRoute(
                action: action,
                title: title,
                state: state
            )
            return handleDesktopNotification(
                title: title,
                body: body,
                route: route,
                state: state,
                store: store
            )
        }

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

        // Metadata updates should not steal focus.
        switch action.intent {
        case .setTerminalTitle(let title):
            let now = Date()
            return handleTerminalMetadataUpdate(
                title: title,
                cwd: nil,
                allowLegacyCWDInference: prefersNativeCWDSignal(panelID: panelID, now: now) == false,
                workspaceID: workspaceIDForAction,
                panelID: panelID,
                state: state,
                store: store
            )
        case .setTerminalCWD(let cwd):
            if Self.normalizedCWDValue(cwd) != nil {
                recordNativeCWDSignal(panelID: panelID)
            }
            return handleTerminalMetadataUpdate(
                title: nil,
                cwd: cwd,
                allowLegacyCWDInference: false,
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
            handled = splitFocusedSlotInDirection(workspaceID: workspaceIDForAction, direction: direction)

        case .focus(let direction):
            handled = store.send(.focusSlot(workspaceID: workspaceIDForAction, direction: direction))

        case .resizeSplit(let direction, let amount):
            handled = store.send(
                .resizeFocusedSlotSplit(
                    workspaceID: workspaceIDForAction,
                    direction: direction,
                    amount: amount
                )
            )

        case .equalizeSplits:
            handled = store.send(.equalizeLayoutSplits(workspaceID: workspaceIDForAction))

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

    private struct DesktopNotificationRoute {
        let workspaceID: UUID?
        let panelID: UUID?
        let source: String
    }

    private func resolveDesktopNotificationRoute(
        action: GhosttyRuntimeAction,
        title: String,
        state: AppState
    ) -> DesktopNotificationRoute {
        if let surfaceHandle = action.surfaceHandle {
            if let panelID = panelIDBySurfaceHandle[surfaceHandle],
               let workspaceID = workspaceID(containing: panelID, state: state) {
                return DesktopNotificationRoute(
                    workspaceID: workspaceID,
                    panelID: panelID,
                    source: "surface_handle"
                )
            }

            ToasttyLog.warning(
                "Desktop notification missing panel mapping for Ghostty surface handle",
                category: .notifications,
                metadata: ["surface_handle": String(surfaceHandle)]
            )
        }

        if let selectedWindowID = state.selectedWindowID,
           let selectedWindow = state.windows.first(where: { $0.id == selectedWindowID }) {
            let currentSelectedWorkspaceID = selectedWorkspaceID(state: state)
            let nonSelectedWorkspaceIDs = selectedWindow.workspaceIDs.filter { $0 != currentSelectedWorkspaceID }
            if nonSelectedWorkspaceIDs.count == 1,
               let workspaceID = nonSelectedWorkspaceIDs.first,
               let workspace = state.workspacesByID[workspaceID],
               let panelID = resolvedActionPanelID(in: workspace) {
                return DesktopNotificationRoute(
                    workspaceID: workspaceID,
                    panelID: panelID,
                    source: "single_non_selected_workspace"
                )
            }
        }

        ToasttyLog.warning(
            "Desktop notification route unresolved",
            category: .notifications,
            metadata: [
                "title": title,
                "has_surface_handle": action.surfaceHandle == nil ? "false" : "true",
            ]
        )
        return DesktopNotificationRoute(
            workspaceID: nil,
            panelID: nil,
            source: "unresolved"
        )
    }

    private func handleDesktopNotification(
        title: String,
        body: String,
        route: DesktopNotificationRoute,
        state: AppState,
        store: AppStore
    ) -> Bool {
        let workspaceID = route.workspaceID
        let panelID = route.panelID
        let notificationContext: DesktopNotificationContext
        if let workspaceID {
            notificationContext = desktopNotificationContext(
                workspaceID: workspaceID,
                panelID: panelID,
                state: state
            )
        } else {
            notificationContext = DesktopNotificationContext()
        }

        let appIsActive = NSApplication.shared.isActive
        let currentSelectedWorkspaceID = selectedWorkspaceID(state: state)
        let panelIsFocused: Bool
        if let workspaceID,
           let panelID,
           currentSelectedWorkspaceID == workspaceID,
           let workspace = state.workspacesByID[workspaceID] {
            panelIsFocused = workspace.focusedPanelID == panelID
                && workspace.layoutTree.slotContaining(panelID: panelID) != nil
        } else {
            panelIsFocused = false
        }

        if appIsActive && panelIsFocused {
            var metadata: [String: String] = [
                "title": title,
                "route_source": route.source,
            ]
            if let workspaceID {
                metadata["workspace_id"] = workspaceID.uuidString
            }
            if let panelID {
                metadata["panel_id"] = panelID.uuidString
            }
            ToasttyLog.debug(
                "Suppressed desktop notification for focused panel",
                category: .notifications,
                metadata: metadata
            )
            return true
        }

        if appIsActive,
           workspaceID == nil,
           panelID == nil,
           let selectedWorkspaceID = currentSelectedWorkspaceID,
           let selectedWindowID = state.selectedWindowID,
           let selectedWindow = state.windows.first(where: { $0.id == selectedWindowID }),
           selectedWindow.workspaceIDs.count == 1,
           let workspace = state.workspacesByID[selectedWorkspaceID],
           let resolvedPanelID = resolvedActionPanelID(in: workspace),
           workspace.focusedPanelID == resolvedPanelID,
           workspace.layoutTree.slotContaining(panelID: resolvedPanelID) != nil {
            ToasttyLog.debug(
                "Suppressed unresolved desktop notification for focused panel in single-workspace window",
                category: .notifications,
                metadata: ["title": title]
            )
            return true
        }

        if let workspaceID {
            _ = store.send(.recordDesktopNotification(workspaceID: workspaceID, panelID: panelID))
        } else {
            ToasttyLog.warning(
                "Skipped unread badge update because desktop notification route is unresolved",
                category: .notifications,
                metadata: ["title": title]
            )
        }

        Task {
            await SystemNotificationSender.send(
                title: title,
                body: body,
                workspaceID: workspaceID,
                panelID: panelID,
                context: notificationContext
            )
        }

        var metadata: [String: String] = [
            "title": title,
            "app_active": appIsActive ? "true" : "false",
            "route_source": route.source,
        ]
        if let workspaceID {
            metadata["workspace_id"] = workspaceID.uuidString
        }
        if let panelID {
            metadata["panel_id"] = panelID.uuidString
        }
        ToasttyLog.info(
            "Delivered desktop notification from Ghostty",
            category: .notifications,
            metadata: metadata
        )
        return true
    }

    private func desktopNotificationContext(
        workspaceID: UUID,
        panelID: UUID?,
        state: AppState
    ) -> DesktopNotificationContext {
        guard let workspace = state.workspacesByID[workspaceID] else {
            return DesktopNotificationContext()
        }
        return DesktopNotificationContext(
            workspaceTitle: workspace.title,
            panelLabel: panelID.flatMap { workspace.panels[$0]?.notificationLabel }
        )
    }

    private func handleTerminalMetadataUpdate(
        title: String?,
        cwd: String?,
        allowLegacyCWDInference: Bool,
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
        if allowLegacyCWDInference,
           normalizedCWD == nil,
           let normalizedTitle {
            normalizedCWD = Self.inferredCWDFromTitle(normalizedTitle, currentCWD: terminalState.cwd)
            if normalizedCWD != nil {
                cwdSource = "title_inference"
            }
        }
        if allowLegacyCWDInference,
           normalizedCWD == nil,
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
        guard prefersNativeCWDSignal(panelID: panelID) == false else {
            return true
        }
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
            allowLegacyCWDInference: true,
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

    private static func inferredAgentTitleFromVisibleTerminalText(_ visibleText: String) -> String? {
        let lines = sanitizedVisibleTerminalLines(visibleText)
        guard lines.isEmpty == false else { return nil }
        let candidateLines = Array(lines.suffix(agentTitleDetectionLineWindow))

        for line in candidateLines.reversed() {
            let lowercasedLine = line.lowercased()
            if lowercasedLine.contains("openai codex (v") {
                return "Codex"
            }
            if lowercasedLine.contains("claude code v") {
                return "Claude Code"
            }
        }
        return nil
    }

    private static func visibleTextShowsInteractiveShellPrompt(_ visibleText: String) -> Bool {
        guard let promptContext = recentPromptContext(visibleText) else {
            return false
        }

        switch promptContext {
        case .interactive:
            return true
        case .command(let token):
            return agentLaunchCommandTokens.contains(token) == false
        }
    }

    private static func visibleTextShowsRecentAgentLaunchCommand(_ visibleText: String) -> Bool {
        guard let promptContext = recentPromptContext(visibleText) else {
            return false
        }

        switch promptContext {
        case .interactive:
            return false
        case .command(let token):
            return agentLaunchCommandTokens.contains(token)
        }
    }

    private static func recentPromptContext(_ visibleText: String) -> PromptContext? {
        let lines = sanitizedVisibleTerminalLines(visibleText)
        guard lines.isEmpty == false else { return nil }
        let candidateLines = Array(lines.suffix(agentTitleDetectionLineWindow))

        for (offset, line) in candidateLines.reversed().enumerated() {
            guard offset <= recentPromptLineMaxDistanceFromBottom else {
                break
            }
            guard let promptLine = promptLineDetails(line) else {
                continue
            }

            guard let command = promptLine.command else {
                return .interactive
            }

            let commandToken = command
                .split(whereSeparator: { $0.isWhitespace })
                .first?
                .lowercased() ?? ""
            if commandToken.isEmpty {
                return .interactive
            }
            return .command(token: commandToken)
        }

        return nil
    }

    private static func promptLineDetails(_ line: String) -> PromptLineDetails? {
        if let strictPromptLine = parsedPromptLine(line) {
            let command = normalizedPromptCommand(strictPromptLine.command)
            return PromptLineDetails(command: command)
        }

        if let loosePromptLine = parsedLoosePromptLine(line) {
            return loosePromptLine
        }

        return nil
    }

    private static func parsedLoosePromptLine(_ line: String) -> PromptLineDetails? {
        let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.isEmpty == false else { return nil }
        let lastIndex = min(parts.count - 1, loosePromptMarkerScanTokenLimit)
        guard lastIndex >= 0 else { return nil }

        // Prompts appear at the start of a line; constraining scan depth avoids
        // matching arbitrary markers in agent output text.
        for index in 0...lastIndex {
            let token = parts[index]

            if promptMarkerTokens.contains(token) {
                guard index > 0,
                      normalizedPromptPathCandidate(parts[index - 1]) != nil else {
                    continue
                }
                let command: String?
                if index + 1 < parts.count {
                    command = parts[(index + 1)...].joined(separator: " ")
                } else {
                    command = nil
                }
                return PromptLineDetails(command: normalizedPromptCommand(command))
            }

            guard token.count > 1,
                  let trailingCharacter = token.last else {
                continue
            }
            let markerToken = String(trailingCharacter)
            guard promptMarkerTokens.contains(markerToken) else {
                continue
            }

            let pathToken = String(token.dropLast())
            guard normalizedPromptPathCandidate(pathToken) != nil else {
                continue
            }
            let command: String?
            if index + 1 < parts.count {
                command = parts[(index + 1)...].joined(separator: " ")
            } else {
                command = nil
            }
            return PromptLineDetails(command: normalizedPromptCommand(command))
        }

        return nil
    }

    private static func normalizedPromptCommand(_ command: String?) -> String? {
        guard let command else { return nil }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }

    private static func titleIsEligibleForAgentInference(terminalTitle: String, terminalCWD: String) -> Bool {
        if titleLooksLikeDefaultTerminalTitle(terminalTitle) {
            return true
        }

        // Preserve compact directory titles like "clawdbot", but still allow
        // inference for raw CWD path titles ("/Users/..." or "~/...").
        guard titleLooksLikePathTitle(terminalTitle),
              let normalizedTitlePath = normalizedCWDValue(terminalTitle),
              let normalizedCurrentCWD = normalizedCWDValue(terminalCWD) else {
            return false
        }

        return canonicalCWDForComparison(normalizedTitlePath) == canonicalCWDForComparison(normalizedCurrentCWD)
    }

    private static func isInferredAgentTitle(_ title: String) -> Bool {
        canonicalInferredAgentTitle(from: title) != nil
    }

    private static func canonicalInferredAgentTitle(from title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }

        let normalized = Self.normalizedAgentTitleCandidate(trimmed)
        guard normalized.isEmpty == false else {
            return nil
        }
        let normalizedLowercased = normalized.lowercased()

        for candidate in inferredAgentTitleCandidates {
            let candidateLowercased = candidate.lowercased()
            guard normalizedLowercased.hasPrefix(candidateLowercased) else {
                continue
            }
            let boundaryIndex = normalizedLowercased.index(
                normalizedLowercased.startIndex,
                offsetBy: candidateLowercased.count
            )
            if boundaryIndex == normalizedLowercased.endIndex {
                return candidate
            }

            let boundaryCharacter = normalizedLowercased[boundaryIndex]
            guard boundaryCharacter.isLetter == false,
                  boundaryCharacter.isNumber == false else {
                continue
            }
            return candidate
        }
        return nil
    }

    private static func normalizedAgentTitleCandidate(_ title: String) -> String {
        var candidate = title
        while let first = candidate.first,
              first.isLetter == false,
              first.isNumber == false {
            candidate.removeFirst()
        }
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func titleLooksLikeDefaultTerminalTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "terminal" {
            return true
        }

        let components = normalized.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count == 2, components[0] == "terminal" else {
            return false
        }
        return Int(components[1]) != nil
    }

    private static func titleLooksLikePathTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix("file://")
    }

    private static func inferredAgentKind(terminalTitle: String, visibleText: String) -> AgentKindInference? {
        let inferredTitleFromTerminalTitle = canonicalInferredAgentTitle(from: terminalTitle)
        if inferredTitleFromTerminalTitle == "Codex" {
            return .codex
        }
        if inferredTitleFromTerminalTitle == "Claude Code" {
            return .claudeCode
        }

        if let inferredTitle = inferredAgentTitleFromVisibleTerminalText(visibleText) {
            return inferredTitle == "Codex" ? .codex : .claudeCode
        }

        guard let promptContext = recentPromptContext(visibleText) else {
            return nil
        }
        guard case .command(let token) = promptContext else {
            return nil
        }
        return agentKind(forPromptToken: token)
    }

    private static func inferredAgentPhase(visibleText: String, visibleLines: [String]) -> AgentActivityPhase {
        if visibleTextShowsWaitingForInput(visibleLines) {
            return .waitingInput
        }
        if visibleTextShowsInteractiveShellPrompt(visibleText) {
            return .idle
        }
        return .running
    }

    private static func visibleTextShowsWaitingForInput(_ visibleLines: [String]) -> Bool {
        guard visibleLines.isEmpty == false else { return false }
        let candidateLines = Array(visibleLines.suffix(agentTitleDetectionLineWindow))

        for line in candidateLines.reversed() {
            let lowercased = line.lowercased()
            if lowercased.contains("waiting for input")
                || lowercased.contains("waiting on user input")
                || lowercased.contains("needs your input")
                || lowercased.contains("select an option")
                || lowercased.contains("enter your choice")
                || lowercased.contains("press enter to continue")
                || lowercased.contains("press return to continue")
                || lowercased.contains("approve command")
                || lowercased.contains("approval required") {
                return true
            }

            if lowercased.contains("y/n") || lowercased.contains("[y]") || lowercased.contains("[n]") {
                return true
            }
        }

        return false
    }

    private static func inferredRunningCommand(visibleLines: [String]) -> String? {
        guard visibleLines.isEmpty == false else { return nil }
        let candidateLines = Array(visibleLines.suffix(agentTitleDetectionLineWindow))

        for (offset, line) in candidateLines.reversed().enumerated() {
            guard offset <= recentPromptLineMaxDistanceFromBottom else {
                break
            }
            guard let command = promptLineDetails(line)?.command else {
                continue
            }

            let normalized = collapsedWhitespace(command)
            guard normalized.isEmpty == false else {
                continue
            }
            let commandToken = normalized
                .split(whereSeparator: { $0.isWhitespace })
                .first?
                .lowercased() ?? ""
            guard commandToken.isEmpty == false else {
                continue
            }
            // Keep agent launch commands out of the activity command slot so
            // long-running foreground shell jobs stay visible.
            guard agentLaunchCommandTokens.contains(commandToken) == false else {
                continue
            }
            return String(normalized.prefix(activityCommandCharacterLimit))
        }

        return nil
    }

    private static func collapsedWhitespace(_ line: String) -> String {
        line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func workspaceActivitySubtext(from activities: [PanelActivityState], now: Date) -> String? {
        guard activities.isEmpty == false else { return nil }

        var codexCount = 0
        var claudeCount = 0
        var runningCount = 0
        var waitingInputCount = 0
        var idleCount = 0

        for activity in activities {
            switch activity.agent {
            case .codex:
                codexCount += 1
            case .claudeCode:
                claudeCount += 1
            }

            switch activity.phase {
            case .running:
                runningCount += 1
            case .waitingInput:
                waitingInputCount += 1
            case .idle:
                idleCount += 1
            }
        }

        let totalAgentCount = codexCount + claudeCount
        guard totalAgentCount > 0 else { return nil }

        let statusSegments: [String] = {
            if waitingInputCount > 0 && runningCount > 0 {
                return [
                    "\(waitingInputCount) waiting input",
                    "\(runningCount) running",
                ]
            }
            if waitingInputCount > 0 {
                return ["\(waitingInputCount) waiting input"]
            }
            if runningCount > 0 {
                return ["\(runningCount) running"]
            }
            return ["\(idleCount) idle"]
        }()
        let statusText = statusSegments.joined(separator: ", ")

        var agentSegments: [String] = []
        if claudeCount > 0 {
            agentSegments.append("\(claudeCount) \(claudeCodeActivityLabel)")
        }
        if codexCount > 0 {
            agentSegments.append("\(codexCount) Codex")
        }

        if totalAgentCount == 1,
           let mostRecentActivity = activities.max(by: { $0.updatedAt < $1.updatedAt }),
           now.timeIntervalSince(mostRecentActivity.updatedAt) <= activityCommandFreshnessInterval,
           let runningCommand = mostRecentActivity.runningCommand {
            let singleAgent = agentActivityLabel(for: mostRecentActivity.agent)
            switch mostRecentActivity.phase {
            case .running:
                return "\(runningCommand) · \(singleAgent) running"
            case .waitingInput:
                return "\(runningCommand) · \(singleAgent) waiting input"
            case .idle:
                // Idle state should fall back to aggregate status formatting.
                break
            }
        }

        return "\(agentSegments.joined(separator: ", ")) · \(statusText)"
    }

    private static func agentKind(forPromptToken token: String) -> AgentKindInference? {
        if codexPromptTokens.contains(token) {
            return .codex
        }
        if claudePromptTokens.contains(token) {
            return .claudeCode
        }
        return nil
    }

    private static func agentActivityLabel(for agent: AgentKindInference) -> String {
        switch agent {
        case .codex:
            return "1 Codex"
        case .claudeCode:
            return "1 \(claudeCodeActivityLabel)"
        }
    }

    private static let inferredAgentTitleCandidates: [String] = ["Codex", "Claude Code"]
    private static let defaultTerminalTitleAfterAgentInferenceRestore = "Terminal"
    private static let codexPromptTokens: Set<String> = ["codex", "cdx"]
    private static let claudePromptTokens: Set<String> = ["claude"]
    // Consider native cwd callbacks authoritative for a short grace period.
    private static let nativeCWDSignalFreshnessInterval: TimeInterval = 120
    // Keep process-based cwd sync as a low-frequency fallback once native callbacks are observed.
    private static let nativeCWDProcessFallbackPollInterval: TimeInterval = 30
    private static let activityCommandCharacterLimit = 96
    // Keep command-first summaries short-lived so stale process labels clear quickly.
    private static let activityCommandFreshnessInterval: TimeInterval = 60
    // Compact labels preserve room for status details in the sidebar.
    private static let claudeCodeActivityLabel = "CC"
    // Drop stale activity after a short window to avoid long-lived misleading subtext.
    private static let activityRetentionInterval: TimeInterval = 240
    private struct PromptLineDetails {
        let command: String?
    }

    private struct PanelActivityState {
        var workspaceID: UUID
        var agent: AgentKindInference
        var phase: AgentActivityPhase
        var runningCommand: String?
        var updatedAt: Date
    }

    private enum AgentKindInference {
        case codex
        case claudeCode
    }

    private enum AgentActivityPhase {
        case running
        case waitingInput
        case idle
    }

    private enum PromptContext {
        case interactive
        case command(token: String)
    }

    private static let agentTitleDetectionLineWindow = 16
    private static let recentPromptLineMaxDistanceFromBottom = 5
    private static let loosePromptMarkerScanTokenLimit = 5
    private static let agentLaunchCommandTokens: Set<String> = ["cdx", "codex", "cc", "claude"]
    private static let promptMarkerTokens: Set<String> = ["%", "#", "$", ">"]
    private static let promptPathWrapperCharacters = CharacterSet(charactersIn: "\"'`()[]{}<>")
    private static let promptPathTrailingPunctuationCharacters = CharacterSet(charactersIn: ",;")
}
#endif

@MainActor
final class TerminalSurfaceController: PanelHostLifecycleControlling {
    private let panelID: UUID
    private unowned let registry: TerminalRuntimeRegistry
    private let hostedView: NSView
    private weak var activeSourceContainer: NSView?
    private var activeAttachment: PanelHostAttachmentToken?

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
    private var temporarilyHiddenForViewportDeferral = false
    private var viewportResumeStabilityPasses = 0
    private var lastAttachmentTransitionAt: Date?
    private var lastViewportResumeSignature: SurfaceCreationSignature?
    private var lastPresentationSignature: SurfacePresentationSignature?
    private var diagnostics = SurfaceDiagnostics()

    private let minimumSurfaceHostDimension = 48
    private let requiredStableSurfaceCreationPasses = 2
    private let requiredStableViewportResumePasses = 2
    private let requiredAutomationInputStabilityInterval: TimeInterval = 0.5

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

    private struct SurfacePresentationSignature: Equatable {
        let logicalWidth: Int
        let logicalHeight: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let scaleThousandths: Int
        let focused: Bool
        let pixelSizingEnabled: Bool
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
            return self.registry.prepareImageFileDrop(from: urls, targetPanelID: self.panelID)
        }
        terminalHostView.performImageFileDrop = { [weak self] drop in
            guard let self else { return false }
            return self.registry.handlePreparedImageFileDrop(drop)
        }
        #else
        hostedView = fallbackView
        #endif
    }

    var lifecycleState: PanelHostLifecycleState {
        guard let activeAttachment else {
            return .detached
        }
        let sourceContainer = activeSourceContainer
        let attachedToContainer = sourceContainer != nil && hostedView.superview === sourceContainer
        let attachedToWindow = hostedView.window != nil && sourceContainer?.window != nil
        return attachedToContainer && attachedToWindow ? .ready(activeAttachment) : .attached(activeAttachment)
    }

    func attachHost(to container: NSView, attachment: PanelHostAttachmentToken) {
        if let activeAttachment, attachment.generation < activeAttachment.generation {
            ToasttyLog.debug(
                "Ignoring stale panel host attachment",
                category: .terminal,
                metadata: [
                    "panel_id": panelID.uuidString,
                    "attachment_id": attachment.rawValue.uuidString,
                    "attachment_generation": String(attachment.generation),
                    "active_attachment_id": activeAttachment.rawValue.uuidString,
                    "active_attachment_generation": String(activeAttachment.generation)
                ]
            )
            return
        }
        let sourceContainerChanged = activeSourceContainer !== container
        let hostedViewWillReattach = hostedView.superview !== container
        let attachmentChanged = activeAttachment != attachment
        activeAttachment = attachment
        #if TOASTTY_HAS_GHOSTTY_KIT
        diagnostics.attachCount += 1
        #endif

        activeSourceContainer = container
        if hostedViewWillReattach {
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
        if sourceContainerChanged || attachmentChanged || hostedViewWillReattach {
            lastAttachmentTransitionAt = Date()
            surfaceCreationStabilityPasses = 0
            lastSurfaceCreationSignature = nil
            lastSurfaceDeferralReason = nil
            refreshSurfaceAfterContainerMove(sourceContainer: container)
        }
        #endif
    }

    func detachHost(attachment: PanelHostAttachmentToken) {
        guard let currentAttachment = activeAttachment else { return }
        guard attachment == currentAttachment else {
            if attachment.generation < currentAttachment.generation {
                ToasttyLog.debug(
                    "Ignoring stale panel host detach",
                    category: .terminal,
                    metadata: [
                        "panel_id": panelID.uuidString,
                        "attachment_id": attachment.rawValue.uuidString,
                        "attachment_generation": String(attachment.generation),
                        "active_attachment_id": currentAttachment.rawValue.uuidString,
                        "active_attachment_generation": String(currentAttachment.generation)
                    ]
                )
                return
            }
            ToasttyLog.debug(
                "Ignoring detach for non-current panel host attachment",
                category: .terminal,
                metadata: [
                    "panel_id": panelID.uuidString,
                    "attachment_id": attachment.rawValue.uuidString,
                    "attachment_generation": String(attachment.generation),
                    "active_attachment_id": currentAttachment.rawValue.uuidString,
                    "active_attachment_generation": String(currentAttachment.generation)
                ]
            )
            return
        }
        ToasttyLog.debug(
            "Detaching panel host controller",
            category: .terminal,
            metadata: [
                "panel_id": panelID.uuidString,
                "attachment_id": attachment.rawValue.uuidString
            ]
        )
        activeAttachment = nil
        activeSourceContainer = nil
        hostedView.removeFromSuperview()
        fallbackView.removeFromSuperview()
    }

    func update(
        terminalState: TerminalPanelState,
        focused: Bool,
        fontPoints: Double,
        viewportSize: CGSize,
        backingScaleFactor: CGFloat,
        sourceContainer: NSView,
        attachment: PanelHostAttachmentToken
    ) {
        guard activeAttachment == attachment else {
            ToasttyLog.debug(
                "Skipping terminal update from stale host attachment",
                category: .terminal,
                metadata: ["panel_id": panelID.uuidString]
            )
            return
        }

        #if TOASTTY_HAS_GHOSTTY_KIT
        diagnostics.updateCount += 1
        if activeSourceContainer !== sourceContainer || hostedView.superview !== sourceContainer {
            attachHost(to: sourceContainer, attachment: attachment)
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
            temporarilyHiddenForViewportDeferral = false
            resetViewportResumeStability()
            lastPresentationSignature = nil
            terminalHostView.setGhosttySurface(nil)
            fallbackView.update(terminalState: terminalState, unavailableReason: "Ghostty surface unavailable")
            swapToFallbackIfNeeded()
            return
        }

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
            // Keep the hosted terminal hidden until layout is stable enough for
            // a valid viewport update; otherwise stale tiny geometry can flash.
            hostedView.isHidden = true
            temporarilyHiddenForViewportDeferral = true
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
        let resumedFromViewportDeferral = lastViewportDeferralReason != nil
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
        hostedView.isHidden = false
        temporarilyHiddenForViewportDeferral = false
        resetViewportResumeStability()
        let effectiveFocused = focused && hostView.isEffectivelyVisible
        ghostty_surface_set_focus(ghosttySurface, effectiveFocused)
        ensureFirstResponderIfNeeded(focused: effectiveFocused)

        let presentationSignature = SurfacePresentationSignature(
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            scaleThousandths: Int((xScale * 1000).rounded()),
            focused: effectiveFocused,
            pixelSizingEnabled: usesBackingPixelSurfaceSizing
        )
        let presentationChanged = presentationSignature != lastPresentationSignature
        lastPresentationSignature = presentationSignature

        if hostView.isEffectivelyVisible && (resumedFromViewportDeferral || presentationChanged) {
            requestImmediateSurfaceRefresh(ghosttySurface)
        }
        #else
        fallbackView.update(terminalState: terminalState, unavailableReason: "Ghostty terminal runtime not enabled in this build")
        #endif
    }

    func invalidate() {
        ToasttyLog.debug(
            "Invalidating panel host controller",
            category: .terminal,
            metadata: [
                "panel_id": panelID.uuidString,
                "attachment_id": activeAttachment?.rawValue.uuidString ?? "nil",
                "has_source_container": activeSourceContainer == nil ? "false" : "true"
            ]
        )
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
        temporarilyHiddenForViewportDeferral = false
        lastAttachmentTransitionAt = nil
        resetViewportResumeStability()
        lastPresentationSignature = nil
        diagnostics = SurfaceDiagnostics()
        #endif
        activeSourceContainer = nil
        activeAttachment = nil
        fallbackView.removeFromSuperview()
        hostedView.removeFromSuperview()
    }

    @discardableResult
    func focusHostViewIfNeeded() -> Bool {
        guard let window = hostedView.window else { return false }
        if window.firstResponder === hostedView {
            return true
        }
        return window.makeFirstResponder(hostedView)
    }

    func automationSendText(_ text: String, submit: Bool, readyForInput: Bool) -> Bool {
        #if TOASTTY_HAS_GHOSTTY_KIT
        guard let ghosttySurface, readyForInput, isReadyForAutomationInput(), focusHostViewIfNeeded() else {
            return false
        }

        if text.isEmpty == false {
            sendSurfaceText(text, to: ghosttySurface)
        }

        if submit {
            guard sendSurfaceSubmit(to: ghosttySurface) else {
                return false
            }
        }

        return true
        #else
        return false
        #endif
    }

    private func isReadyForAutomationInput(now: Date = Date()) -> Bool {
        #if TOASTTY_HAS_GHOSTTY_KIT
        guard lifecycleState.isReadyForFocus else {
            return false
        }
        guard ghosttySurface != nil else {
            return false
        }
        guard temporarilyHiddenForViewportDeferral == false else {
            return false
        }
        if let lastAttachmentTransitionAt,
           now.timeIntervalSince(lastAttachmentTransitionAt) < requiredAutomationInputStabilityInterval {
            return false
        }
        return true
        #else
        return lifecycleState.isReadyForFocus
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

    func renderAttachmentSnapshot() -> TerminalPanelRenderAttachmentSnapshot {
        let sourceContainer = activeSourceContainer
        #if TOASTTY_HAS_GHOSTTY_KIT
        let ghosttySurfaceAvailable = ghosttySurface != nil
        #else
        let ghosttySurfaceAvailable = false
        #endif
        return TerminalPanelRenderAttachmentSnapshot(
            panelID: panelID,
            controllerExists: true,
            hostHasSuperview: hostedView.superview != nil,
            hostAttachedToWindow: hostedView.window != nil,
            sourceContainerExists: sourceContainer != nil,
            sourceContainerAttachedToWindow: sourceContainer?.window != nil,
            hostSuperviewMatchesSourceContainer: hostedView.superview === sourceContainer,
            lifecycleState: lifecycleState,
            ghosttySurfaceAvailable: ghosttySurfaceAvailable
        )
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

    private func sendSurfaceSubmit(to surface: ghostty_surface_t) -> Bool {
        // `ghostty_surface_text` is paste-oriented input. Use a real Return key
        // event so automation submit executes the pending command under bracketed
        // paste and matches live keyboard behavior.
        let submitText = "\r"
        return submitText.withCString { pointer in
            let keyEvent = ghostty_input_key_s(
                action: GHOSTTY_ACTION_PRESS,
                mods: ghostty_input_mods_e(0),
                consumed_mods: ghostty_input_mods_e(0),
                keycode: 0x24,
                text: pointer,
                unshifted_codepoint: 13,
                composing: false
            )
            return ghostty_surface_key(surface, keyEvent)
        }
    }

    func applyGhosttyGlobalFontChange(from previousPoints: Double, to nextPoints: Double) {
        guard let ghosttySurface else { return }
        guard abs(nextPoints - previousPoints) >= AppState.terminalFontComparisonEpsilon else { return }

        let baselinePoints = resolvedGhosttyConfiguredFontBaselinePoints()

        if abs(nextPoints - baselinePoints) < AppState.terminalFontComparisonEpsilon {
            _ = invokeGhosttyBindingAction("reset_font_size", on: ghosttySurface)
            return
        }

        let pointDelta = nextPoints - previousPoints
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

    private func resolvedGhosttyConfiguredFontBaselinePoints() -> Double {
        let configuredPoints = ghosttyManager.configuredTerminalFontPoints ?? AppState.defaultTerminalFontPoints
        return AppState.clampedTerminalFontPoints(configuredPoints)
    }

    private func synchronizeGhosttySurfaceFont(to targetPoints: Double, on surface: ghostty_surface_t) {
        let baselinePoints = resolvedGhosttyConfiguredFontBaselinePoints()
        let clampedTargetPoints = AppState.clampedTerminalFontPoints(targetPoints)

        if abs(clampedTargetPoints - baselinePoints) < AppState.terminalFontComparisonEpsilon {
            _ = invokeGhosttyBindingAction("reset_font_size", on: surface)
            return
        }

        // Normalize to Ghostty's configured baseline before applying a delta so
        // newly created panes don't retain stale inherited zoom levels.
        guard invokeGhosttyBindingAction("reset_font_size", on: surface) else {
            return
        }

        let pointDelta = clampedTargetPoints - baselinePoints
        let stepMagnitude = max(
            Int(round(abs(pointDelta) / AppState.terminalFontStepPoints)),
            1
        )
        let action = pointDelta > 0
            ? "increase_font_size:\(stepMagnitude)"
            : "decrease_font_size:\(stepMagnitude)"
        _ = invokeGhosttyBindingAction(action, on: surface)
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
            ToasttyLog.debug(
                "Using source Ghostty surface for split inheritance",
                category: .terminal,
                metadata: [
                    "source_panel_id": sourcePanelID.uuidString,
                    "new_panel_id": panelID.uuidString,
                ]
            )
        }

        // CWD is already up-to-date in terminalState.cwd thanks to the
        // pre-split refresh in sendSplitAction().
        let requestedWorkingDirectory = terminalState.cwd

        // Snapshot child PIDs before surface creation so we can diff after
        // to find the newly spawned login/shell process for CWD tracking.
        let previousChildPIDs = registry.snapshotChildPIDsForSurfaceCreation()

        diagnostics.surfaceAttemptCount += 1
        guard let createdSurface = ghosttyManager.makeSurface(
            hostView: hostView,
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
        lastPresentationSignature = nil
        logSurfaceDiagnostics(message: "Ghostty surface creation succeeded")
        usesBackingPixelSurfaceSizing = false
        hasDeterminedSurfaceSizingMode = false
        lastRenderMetrics = nil
        lastDisplayID = nil
        ghosttySurface = surface
        registry.register(surface: surface, for: panelID)
        synchronizeGhosttySurfaceFont(to: fontPoints, on: surface)

        // Register the new child process (login → shell) for CWD tracking.
        registry.registerChildPIDAfterSurfaceCreation(
            panelID: panelID,
            previousChildren: previousChildPIDs,
            expectedWorkingDirectory: requestedWorkingDirectory
        )

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
        guard let window = hostView.window else {
            resetViewportResumeStability()
            return .noWindow
        }

        guard hostView.hasHiddenAncestor == false else {
            resetViewportResumeStability()
            return .hiddenHost
        }

        if hostView.isHidden, temporarilyHiddenForViewportDeferral == false {
            resetViewportResumeStability()
            return .hiddenHost
        }

        guard width >= minimumSurfaceHostDimension,
              height >= minimumSurfaceHostDimension else {
            resetViewportResumeStability()
            return .tinyBounds
        }

        if temporarilyHiddenForViewportDeferral {
            let signature = SurfaceCreationSignature(
                windowID: ObjectIdentifier(window),
                width: width,
                height: height
            )
            if lastViewportResumeSignature == signature {
                viewportResumeStabilityPasses += 1
            } else {
                lastViewportResumeSignature = signature
                viewportResumeStabilityPasses = 1
            }

            guard viewportResumeStabilityPasses >= requiredStableViewportResumePasses else {
                return .unstableBounds
            }
        } else {
            resetViewportResumeStability()
        }

        return nil
    }

    private func resetViewportResumeStability() {
        viewportResumeStabilityPasses = 0
        lastViewportResumeSignature = nil
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
    private func refreshSurfaceAfterContainerMove(sourceContainer: NSView) {
        guard let ghosttySurface else { return }
        updateDisplayIDIfNeeded(surface: ghosttySurface, sourceContainer: sourceContainer)
        requestImmediateSurfaceRefresh(ghosttySurface)
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
        requestImmediateSurfaceRefresh(ghosttySurface)
    }

    private func requestImmediateSurfaceRefresh(_ surface: ghostty_surface_t) {
        ghosttyManager.requestImmediateTick()
        ghostty_surface_refresh(surface)
    }
    #endif
}

final class TerminalHostView: NSView {
    var resolveImageFileDrop: (([URL]) -> PreparedImageFileDrop?)?
    var performImageFileDrop: ((PreparedImageFileDrop) -> Bool)?
    private var pendingImageFileDrop: PreparedImageFileDrop?
    private weak var observedWindow: NSWindow?
    private var windowOcclusionObserver: NSObjectProtocol?
    private var lastKnownSurfaceVisibility: Bool?
    private(set) var isEffectivelyVisible = false

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

    override var isHidden: Bool {
        didSet {
            #if TOASTTY_HAS_GHOSTTY_KIT
            syncSurfaceVisibility(reason: "hidden_changed")
            #else
            isEffectivelyVisible = window != nil && isHidden == false && hasHiddenAncestor == false
            #endif
        }
    }

    @MainActor deinit {
        #if TOASTTY_HAS_GHOSTTY_KIT
        if let windowOcclusionObserver {
            NotificationCenter.default.removeObserver(windowOcclusionObserver)
        }
        #endif
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        #if TOASTTY_HAS_GHOSTTY_KIT
        syncSurfaceVisibility(reason: "superview_changed")
        #else
        isEffectivelyVisible = window != nil && isHidden == false && hasHiddenAncestor == false
        #endif
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        #if TOASTTY_HAS_GHOSTTY_KIT
        updateWindowOcclusionObservation()
        syncLayerContentsScale()
        syncSurfaceVisibility(reason: "window_changed")
        #else
        syncLayerContentsScale()
        isEffectivelyVisible = window != nil && isHidden == false && hasHiddenAncestor == false
        #endif
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
        lastKnownSurfaceVisibility = nil
        syncSurfaceVisibility(reason: "surface_assignment")
    }

    private func updateWindowOcclusionObservation() {
        guard observedWindow !== window else {
            return
        }

        stopObservingWindowOcclusion()
        observedWindow = window

        guard let window else {
            return
        }

        windowOcclusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncSurfaceVisibility(reason: "window_occlusion_changed")
            }
        }
    }

    private func stopObservingWindowOcclusion() {
        if let windowOcclusionObserver {
            NotificationCenter.default.removeObserver(windowOcclusionObserver)
        }
        windowOcclusionObserver = nil
        observedWindow = nil
    }

    private func resolvedSurfaceVisibility() -> Bool {
        guard let window else {
            return false
        }
        guard isHidden == false, hasHiddenAncestor == false else {
            return false
        }
        return window.occlusionState.contains(.visible)
    }

    private func syncSurfaceVisibility(reason: String) {
        let visible = resolvedSurfaceVisibility()
        isEffectivelyVisible = visible

        guard let ghosttySurface else {
            lastKnownSurfaceVisibility = nil
            return
        }
        guard lastKnownSurfaceVisibility != visible else {
            return
        }

        lastKnownSurfaceVisibility = visible
        ghostty_surface_set_occlusion(ghosttySurface, visible)
        if visible {
            let shouldRestoreFocus = window?.isKeyWindow == true && window?.firstResponder === self
            ghostty_surface_set_focus(ghosttySurface, shouldRestoreFocus)
            GhosttyRuntimeManager.shared.requestImmediateTick()
            ghostty_surface_refresh(ghosttySurface)
        } else {
            ghostty_surface_set_focus(ghosttySurface, false)
        }

        ToasttyLog.debug(
            "Updated Ghostty surface occlusion",
            category: .ghostty,
            metadata: [
                "visible": visible ? "true" : "false",
                "reason": reason,
                "restored_focus": visible && window?.isKeyWindow == true && window?.firstResponder === self ? "true" : "false",
                "has_window": window == nil ? "false" : "true",
                "is_hidden": isHidden ? "true" : "false",
                "has_hidden_ancestor": hasHiddenAncestor ? "true" : "false",
            ]
        )
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
