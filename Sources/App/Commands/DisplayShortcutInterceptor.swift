import AppKit
import Carbon.HIToolbox
import CoreState

@MainActor
final class DisplayShortcutInterceptor {
    private weak var store: AppStore?
    private let terminalRuntimeRegistry: TerminalRuntimeRegistry
    private let webPanelRuntimeRegistry: WebPanelRuntimeRegistry
    private let sessionRuntimeStore: SessionRuntimeStore
    private let focusedPanelCommandController: FocusedPanelCommandController
    private let processWatchCommandController: ProcessWatchCommandController
    private let isCommandPalettePresented: @MainActor () -> Bool
    private let toggleCommandPalette: @MainActor (UUID?) -> Bool
    nonisolated(unsafe) private var eventMonitor: Any?

    enum ShortcutAction: Equatable {
        case commandPalette
        case closePanel
        case consumeShortcut
        case createWindow
        case createBrowser
        case createBrowserTab
        case createScratchpad
        case createWorkspaceTab
        case increaseTextSize
        case decreaseTextSize
        case resetTextSize
        case split(SlotSplitDirection)
        case watchRunningCommand
        case startLocalDocumentSearch
        case findNextLocalDocumentSearch
        case findPreviousLocalDocumentSearch
        case enterLocalDocumentEdit
        case cancelLocalDocumentEdit
        case saveLocalDocument
        case focusNextUnreadOrActivePanel
        case toggleLaterFlag
        case toggleRightPanel
        case toggleFocusedPanelMode
        case renameSelectedTab
        case selectWorkspaceTab(Int)
        case selectAdjacentTab(TabNavigationDirection)
        case selectAdjacentRightPanelTab(PanelTabNavigationDirection)
        case switchWorkspace(Int)
        case focusPanel(Int)
        case focusSplit(SlotFocusDirection)
        case resizeSplit(SplitResizeDirection)
        case equalizeSplits
        case browserOpenLocation
        case browserReload
        case cycleWorkspaceNext
        case cycleWorkspacePrevious
    }

    init(
        store: AppStore,
        terminalRuntimeRegistry: TerminalRuntimeRegistry,
        webPanelRuntimeRegistry: WebPanelRuntimeRegistry,
        sessionRuntimeStore: SessionRuntimeStore,
        focusedPanelCommandController: FocusedPanelCommandController,
        processWatchCommandController: ProcessWatchCommandController? = nil,
        isCommandPalettePresented: @escaping @MainActor () -> Bool = { false },
        toggleCommandPalette: @escaping @MainActor (UUID?) -> Bool = { _ in false },
        installEventMonitor: Bool = true
    ) {
        self.store = store
        self.terminalRuntimeRegistry = terminalRuntimeRegistry
        self.webPanelRuntimeRegistry = webPanelRuntimeRegistry
        self.sessionRuntimeStore = sessionRuntimeStore
        self.focusedPanelCommandController = focusedPanelCommandController
        self.processWatchCommandController = processWatchCommandController ?? ProcessWatchCommandController(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore
        )
        self.isCommandPalettePresented = isCommandPalettePresented
        self.toggleCommandPalette = toggleCommandPalette
        if installEventMonitor {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard let action = self.shortcutAction(for: event) else { return event }
                // Keep workspace switching in the local monitor so the embedded
                // terminal's key handling cannot swallow Option+digit before the
                // menu-based workspace switch path can run reliably.
                let didHandleShortcut = self.handle(action)
                // If no workspace or panel is mapped to this shortcut, keep default key behavior.
                return didHandleShortcut ? nil : event
            }
        }
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    private func shortcutAction(for event: NSEvent) -> ShortcutAction? {
        shortcutAction(for: event, appOwnedWindowID: appOwnedShortcutWindowID())
    }

    func shortcutAction(for event: NSEvent, appOwnedWindowID: UUID?) -> ShortcutAction? {
        if Self.isCommandPaletteShortcut(event),
           isCommandPalettePresented() {
            return .commandPalette
        }

        if Self.isCommandPaletteShortcut(event),
           appOwnedWindowID != nil {
            return .commandPalette
        }
        if Self.isRepeatedNewWindowShortcut(event),
           canConsumeRepeatedWindowShortcut() {
            return .consumeShortcut
        }
        if Self.isNewWindowShortcut(event),
           canCreateWindowFromShortcut(appOwnedWindowID: appOwnedWindowID) {
            return .createWindow
        }
        if Self.isRepeatedNewTabShortcut(event),
           canConsumeRepeatedWindowShortcut() {
            return .consumeShortcut
        }
        if let shortcutNumber = Self.tabSelectionShortcutNumber(for: event),
           appOwnedWindowID != nil {
            return .selectWorkspaceTab(shortcutNumber)
        }

        if let direction = Self.tabNavigationDirection(for: event),
           appOwnedWindowID != nil {
            return .selectAdjacentTab(direction)
        }

        if let direction = Self.rightPanelTabNavigationDirection(for: event),
           appOwnedWindowID != nil {
            return .selectAdjacentRightPanelTab(direction)
        }

        if Self.isNewTabShortcut(event),
           appOwnedWindowID != nil {
            return .createWorkspaceTab
        }

        if Self.isNewBrowserShortcut(event),
           appOwnedWindowID != nil {
            return .createBrowser
        }

        if Self.isNewBrowserTabShortcut(event),
           appOwnedWindowID != nil {
            return .createBrowserTab
        }

        if Self.isNewScratchpadShortcut(event),
           appOwnedWindowID != nil {
            return .createScratchpad
        }

        if Self.isToggleRightPanelShortcut(event),
           appOwnedWindowID != nil {
            return .toggleRightPanel
        }

        if let textSizeShortcutAction = textSizeShortcutAction(
            for: event,
            appOwnedWindowID: appOwnedWindowID
        ) {
            return textSizeShortcutAction
        }

        if let direction = Self.splitDirection(for: event),
           appOwnedWindowID != nil {
            return .split(direction)
        }

        if Self.isWatchRunningCommandShortcut(event),
           appOwnedWindowID != nil {
            return .watchRunningCommand
        }

        if Self.isClosePanelShortcut(event),
           appOwnedWindowID != nil {
            return .closePanel
        }

        if Self.isFindShortcut(event),
           appOwnedFocusedLocalDocumentSelection(preferredWindowID: appOwnedWindowID) != nil {
            return .startLocalDocumentSearch
        }

        if Self.isFindNextShortcut(event),
           isFocusedLocalDocumentSearchActive(preferredWindowID: appOwnedWindowID) {
            return .findNextLocalDocumentSearch
        }

        if Self.isFindPreviousShortcut(event),
           isFocusedLocalDocumentSearchActive(preferredWindowID: appOwnedWindowID) {
            return .findPreviousLocalDocumentSearch
        }

        if Self.isEnterEditShortcut(event),
           canEnterFocusedLocalDocumentEdit(preferredWindowID: appOwnedWindowID) {
            return .enterLocalDocumentEdit
        }

        if Self.isCancelEditShortcut(event),
           canCancelFocusedLocalDocumentEdit(preferredWindowID: appOwnedWindowID) {
            return .cancelLocalDocumentEdit
        }

        if Self.isSaveShortcut(event),
           appOwnedFocusedLocalDocumentSelection(preferredWindowID: appOwnedWindowID) != nil {
            return .saveLocalDocument
        }

        if Self.isFocusNextUnreadOrActiveShortcut(event),
           appOwnedWindowID != nil {
            return .focusNextUnreadOrActivePanel
        }

        if Self.isToggleLaterFlagShortcut(event),
           appOwnedWindowID != nil {
            return .toggleLaterFlag
        }

        if Self.isToggleFocusedPanelShortcut(event),
           appOwnedWindowID != nil {
            return .toggleFocusedPanelMode
        }

        if Self.isRenameTabShortcut(event),
           appOwnedWindowID != nil {
            return .renameSelectedTab
        }

        if let direction = Self.focusSplitDirection(for: event),
           appOwnedWindowID != nil {
            return .focusSplit(direction)
        }

        if let direction = Self.directionalFocusSplitDirection(for: event),
           appOwnedWindowID != nil {
            return .focusSplit(direction)
        }

        if let direction = Self.resizeSplitDirection(for: event),
           appOwnedWindowID != nil {
            return .resizeSplit(direction)
        }

        if Self.isEqualizeSplitsShortcut(event),
           appOwnedWindowID != nil {
            return .equalizeSplits
        }

        if Self.isBrowserOpenLocationShortcut(event),
           appOwnedFocusedBrowserSelection(preferredWindowID: appOwnedWindowID) != nil {
            return .browserOpenLocation
        }

        if Self.isBrowserReloadShortcut(event),
           appOwnedFocusedBrowserSelection(preferredWindowID: appOwnedWindowID) != nil {
            return .browserReload
        }

        switch DisplayShortcutConfig.action(for: event) {
        case .workspaceSwitch(let shortcutNumber):
            return .switchWorkspace(shortcutNumber)
        case .panelFocus(let shortcutNumber):
            return .focusPanel(shortcutNumber)
        case .cycleWorkspaceNext:
            return .cycleWorkspaceNext
        case .cycleWorkspacePrevious:
            return .cycleWorkspacePrevious
        case nil:
            return nil
        }
    }

    private func handle(_ action: ShortcutAction) -> Bool {
        handle(action, appOwnedWindowID: appOwnedShortcutWindowID())
    }

    func handle(_ action: ShortcutAction, appOwnedWindowID: UUID?) -> Bool {
        switch action {
        case .commandPalette:
            toggleCommandPalette(appOwnedWindowID)
        case .closePanel:
            closeFocusedPanel(preferredWindowID: appOwnedWindowID)
        case .consumeShortcut:
            true
        case .createWindow:
            createWindow(preferredWindowID: appOwnedWindowID)
        case .createBrowser:
            createBrowser(preferredWindowID: appOwnedWindowID, placement: .rightPanel)
        case .createBrowserTab:
            createBrowser(preferredWindowID: appOwnedWindowID, placement: .newTab)
        case .createScratchpad:
            createScratchpad(preferredWindowID: appOwnedWindowID)
        case .createWorkspaceTab:
            createWorkspaceTab(preferredWindowID: appOwnedWindowID)
        case .increaseTextSize:
            adjustTextSize(direction: .increase, preferredWindowID: appOwnedWindowID)
        case .decreaseTextSize:
            adjustTextSize(direction: .decrease, preferredWindowID: appOwnedWindowID)
        case .resetTextSize:
            adjustTextSize(direction: .reset, preferredWindowID: appOwnedWindowID)
        case .split(let direction):
            split(direction: direction, preferredWindowID: appOwnedWindowID)
        case .watchRunningCommand:
            watchRunningCommand()
        case .startLocalDocumentSearch:
            handleStartLocalDocumentSearchShortcut(preferredWindowID: appOwnedWindowID)
        case .findNextLocalDocumentSearch:
            handleFindNextLocalDocumentSearchShortcut(preferredWindowID: appOwnedWindowID)
        case .findPreviousLocalDocumentSearch:
            handleFindPreviousLocalDocumentSearchShortcut(preferredWindowID: appOwnedWindowID)
        case .enterLocalDocumentEdit:
            handleEnterLocalDocumentEditShortcut(preferredWindowID: appOwnedWindowID)
        case .cancelLocalDocumentEdit:
            handleCancelLocalDocumentEditShortcut(preferredWindowID: appOwnedWindowID)
        case .saveLocalDocument:
            handleSaveLocalDocumentShortcut(preferredWindowID: appOwnedWindowID)
        case .focusNextUnreadOrActivePanel:
            focusNextUnreadOrActivePanel(preferredWindowID: appOwnedWindowID)
        case .toggleLaterFlag:
            toggleLaterFlag(preferredWindowID: appOwnedWindowID)
        case .toggleRightPanel:
            toggleRightPanel(preferredWindowID: appOwnedWindowID)
        case .toggleFocusedPanelMode:
            toggleFocusedPanelMode()
        case .renameSelectedTab:
            renameSelectedTab()
        case .selectWorkspaceTab(let shortcutNumber):
            selectWorkspaceTab(shortcutNumber: shortcutNumber)
        case .selectAdjacentTab(let direction):
            selectAdjacentTab(direction: direction)
        case .selectAdjacentRightPanelTab(let direction):
            selectAdjacentRightPanelTab(direction: direction, preferredWindowID: appOwnedWindowID)
        case .switchWorkspace(let shortcutNumber):
            switchWorkspace(shortcutNumber: shortcutNumber)
        case .focusPanel(let shortcutNumber):
            focusTerminalPanel(shortcutNumber: shortcutNumber)
        case .focusSplit(let direction):
            focusSplit(direction: direction, preferredWindowID: appOwnedWindowID)
        case .resizeSplit(let direction):
            resizeSplit(direction: direction, preferredWindowID: appOwnedWindowID)
        case .equalizeSplits:
            equalizeSplits(preferredWindowID: appOwnedWindowID)
        case .browserOpenLocation:
            openFocusedBrowserLocation(preferredWindowID: appOwnedWindowID)
        case .browserReload:
            reloadFocusedBrowser(preferredWindowID: appOwnedWindowID)
        case .cycleWorkspaceNext:
            cycleWorkspace(direction: 1)
        case .cycleWorkspacePrevious:
            cycleWorkspace(direction: -1)
        }
    }

    static func isCommandPaletteShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "p" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command, .shift]
    }

    static func isNewTabShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "t" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command]
    }

    static func isRepeatedNewTabShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat,
              event.charactersIgnoringModifiers?.lowercased() == "t" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command]
    }

    static func isNewWindowShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "n" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command]
    }

    static func isRepeatedNewWindowShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat,
              event.charactersIgnoringModifiers?.lowercased() == "n" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command]
    }

    static func isNewBrowserShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "b" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command, .control]
    }

    static func isNewBrowserTabShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "b" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command, .control, .shift]
    }

    static func isNewScratchpadShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "s" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command, .control]
    }

    static func isToggleRightPanelShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "b" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command, .shift]
    }

    static func isSaveShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "s" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command]
    }

    static func isCancelEditShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              Int(event.keyCode) == Int(kVK_Escape) else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers.isEmpty
    }

    enum TextSizeShortcutDirection: Equatable {
        case increase
        case decrease
        case reset
    }

    static func textSizeShortcutDirection(for event: NSEvent) -> TextSizeShortcutDirection? {
        guard event.type == .keyDown,
              event.isARepeat == false else {
            return nil
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case Int(kVK_ANSI_Equal), Int(kVK_ANSI_KeypadPlus):
            guard modifiers == [.command] || modifiers == [.command, .shift] else {
                return nil
            }
            return .increase
        case Int(kVK_ANSI_Minus), Int(kVK_ANSI_KeypadMinus):
            guard modifiers == [.command] else {
                return nil
            }
            return .decrease
        case Int(kVK_ANSI_0), Int(kVK_ANSI_Keypad0):
            guard modifiers == [.command] else {
                return nil
            }
            return .reset
        default:
            return nil
        }
    }

    static func splitDirection(for event: NSEvent) -> SlotSplitDirection? {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "d" else {
            return nil
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch modifiers {
        case [.command]:
            return .right
        case [.command, .shift]:
            return .down
        default:
            return nil
        }
    }

    static func tabSelectionShortcutNumber(for event: NSEvent) -> Int? {
        guard event.type == .keyDown, event.isARepeat == false else { return nil }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == [.command] else { return nil }

        let shortcutNumber: Int?
        switch Int(event.keyCode) {
        case Int(kVK_ANSI_1), Int(kVK_ANSI_Keypad1):
            shortcutNumber = 1
        case Int(kVK_ANSI_2), Int(kVK_ANSI_Keypad2):
            shortcutNumber = 2
        case Int(kVK_ANSI_3), Int(kVK_ANSI_Keypad3):
            shortcutNumber = 3
        case Int(kVK_ANSI_4), Int(kVK_ANSI_Keypad4):
            shortcutNumber = 4
        case Int(kVK_ANSI_5), Int(kVK_ANSI_Keypad5):
            shortcutNumber = 5
        case Int(kVK_ANSI_6), Int(kVK_ANSI_Keypad6):
            shortcutNumber = 6
        case Int(kVK_ANSI_7), Int(kVK_ANSI_Keypad7):
            shortcutNumber = 7
        case Int(kVK_ANSI_8), Int(kVK_ANSI_Keypad8):
            shortcutNumber = 8
        case Int(kVK_ANSI_9), Int(kVK_ANSI_Keypad9):
            shortcutNumber = 9
        default:
            shortcutNumber = nil
        }

        guard let shortcutNumber,
              shortcutNumber <= DisplayShortcutConfig.maxWorkspaceTabSelectionShortcutCount else {
            return nil
        }
        return shortcutNumber
    }

    /// Detects Cmd+Shift+[ (previous tab) and Cmd+Shift+] (next tab).
    static func tabNavigationDirection(for event: NSEvent) -> TabNavigationDirection? {
        guard event.type == .keyDown, event.isARepeat == false else { return nil }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == [.command, .shift] else { return nil }

        switch Int(event.keyCode) {
        case Int(kVK_ANSI_LeftBracket):
            return .previous
        case Int(kVK_ANSI_RightBracket):
            return .next
        default:
            return nil
        }
    }

    /// Detects Cmd+Ctrl+[ (previous right-panel tab) and Cmd+Ctrl+] (next right-panel tab).
    static func rightPanelTabNavigationDirection(for event: NSEvent) -> PanelTabNavigationDirection? {
        guard event.type == .keyDown, event.isARepeat == false else { return nil }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == [.command, .control] else { return nil }

        switch Int(event.keyCode) {
        case Int(kVK_ANSI_LeftBracket):
            return .previous
        case Int(kVK_ANSI_RightBracket):
            return .next
        default:
            return nil
        }
    }

    static func isClosePanelShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "w" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command]
    }

    static func isFindShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "f" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command]
    }

    static func isFindNextShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "g" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command]
    }

    static func isFindPreviousShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "g" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command, .shift]
    }

    static func isEnterEditShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              Int(event.keyCode) == Int(kVK_ANSI_E) else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command]
    }

    static func isFocusNextUnreadOrActiveShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "a" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command, .shift]
    }

    static func isWatchRunningCommandShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "m" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command, .shift]
    }

    static func isToggleLaterFlagShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "l" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command, .shift]
    }

    static func isToggleFocusedPanelShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "f" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command, .shift]
    }

    static func isRenameTabShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.isARepeat == false else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == [.option, .shift] else { return false }
        return Int(event.keyCode) == Int(kVK_ANSI_E)
    }

    static func focusSplitDirection(for event: NSEvent) -> SlotFocusDirection? {
        guard event.type == .keyDown, event.isARepeat == false else { return nil }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == [.command] else { return nil }

        switch Int(event.keyCode) {
        case Int(kVK_ANSI_LeftBracket):
            return .previous
        case Int(kVK_ANSI_RightBracket):
            return .next
        default:
            return nil
        }
    }

    static func directionalFocusSplitDirection(for event: NSEvent) -> SlotFocusDirection? {
        guard event.type == .keyDown, event.isARepeat == false else { return nil }
        // AppKit marks arrow-key events with .numericPad even on the main
        // keyboard, so strip that flag before matching the app-owned chord.
        let modifiers = event
            .modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.numericPad)
        guard modifiers == [.command, .option] else { return nil }

        switch Int(event.keyCode) {
        case Int(kVK_LeftArrow):
            return .left
        case Int(kVK_RightArrow):
            return .right
        case Int(kVK_UpArrow):
            return .up
        case Int(kVK_DownArrow):
            return .down
        default:
            return nil
        }
    }

    static func resizeSplitDirection(for event: NSEvent) -> SplitResizeDirection? {
        guard event.type == .keyDown, event.isARepeat == false else { return nil }
        // AppKit marks arrow-key events with .numericPad even on the main
        // keyboard, so strip that flag before matching the app-owned chord.
        let modifiers = event
            .modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.numericPad)
        guard modifiers == [.command, .control] else { return nil }

        switch Int(event.keyCode) {
        case Int(kVK_LeftArrow):
            return .left
        case Int(kVK_RightArrow):
            return .right
        case Int(kVK_UpArrow):
            return .up
        case Int(kVK_DownArrow):
            return .down
        default:
            return nil
        }
    }

    static func isEqualizeSplitsShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.isARepeat == false else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == [.command, .control] else {
            return false
        }
        return Int(event.keyCode) == Int(kVK_ANSI_Equal)
    }

    static func isBrowserOpenLocationShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "l" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command]
    }

    static func isBrowserReloadShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "r" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command]
    }

    static func closePanelShortcutWindowID(keyWindow: NSWindow?, modalWindow: NSWindow?) -> UUID? {
        guard modalWindow == nil else { return nil }
        guard let keyWindow else { return nil }
        guard keyWindow.sheetParent == nil else { return nil }
        // Be conservative around active text input so Cmd+W stays with the
        // field editor or text control rather than being reclaimed by Toastty.
        if toasttyResponderUsesReservedClosePanelShortcut(keyWindow.firstResponder) {
            return nil
        }
        guard let rawWindowID = keyWindow.identifier?.rawValue else { return nil }
        return UUID(uuidString: rawWindowID)
    }

    private func appOwnedShortcutWindowID() -> UUID? {
        guard let store else { return nil }
        return currentToasttyAppOwnedWindowID(in: store)
    }

    private func canConsumeRepeatedWindowShortcut() -> Bool {
        guard store != nil else { return false }
        return NSApp.modalWindow == nil
    }

    private func canCreateWindowFromShortcut(appOwnedWindowID: UUID?) -> Bool {
        guard let store else { return false }
        guard NSApp.modalWindow == nil else {
            return false
        }
        if appOwnedWindowID != nil {
            return true
        }
        return store.state.windows.isEmpty
    }

    private func closeFocusedPanel(preferredWindowID: UUID? = nil) -> Bool {
        guard let store else { return false }
        guard let preferredWindowID = preferredWindowID ?? appOwnedShortcutWindowID() else { return false }
        let preferredWorkspaceID = store.commandSelection(preferredWindowID: preferredWindowID)?.workspace.id
        guard focusedPanelCommandController.closeFocusedPanel(
            in: preferredWorkspaceID,
            confirmationPolicy: .interactive
        ).consumesShortcut else {
            if let window = store.window(id: preferredWindowID),
               window.workspaceIDs.isEmpty {
                return closeEmptyWindow(windowID: preferredWindowID)
            }
            // Cmd+W is app-owned for normal workspace windows. If there is no
            // panel to close in that context, swallow the shortcut rather than
            // falling back to AppKit's native window-close path.
            return preferredWorkspaceID != nil
        }
        return true
    }

    private func closeEmptyWindow(windowID: UUID) -> Bool {
        guard let store else { return false }
        let window = NSApp.windows.first { $0.identifier?.rawValue == windowID.uuidString }
        guard store.send(.closeWindow(windowID: windowID), source: .command("close_empty_window")) else {
            return false
        }
        ToasttyLog.info(
            "Closed empty window from app-owned shortcut",
            category: .store,
            metadata: ["window_id": windowID.uuidString]
        )
        window?.close()
        return true
    }

    private func createWindow(preferredWindowID: UUID?) -> Bool {
        guard let store else { return false }
        let commandWindowID = preferredWindowID ?? currentToasttyWorkspaceCommandWindowID(in: store)
        return store.createWindowFromCommand(preferredWindowID: commandWindowID)
    }

    private func createWorkspaceTab(preferredWindowID: UUID?) -> Bool {
        guard let store else { return false }
        guard let preferredWindowID else { return false }
        return store.createWorkspaceTabFromCommand(preferredWindowID: preferredWindowID)
    }

    private func toggleRightPanel(preferredWindowID: UUID?) -> Bool {
        guard let store,
              let workspaceID = store.commandSelection(preferredWindowID: preferredWindowID)?.workspace.id else {
            return false
        }
        return store.sendNavigation(.toggleRightAuxPanel(workspaceID: workspaceID))
    }

    private func textSizeShortcutAction(
        for event: NSEvent,
        appOwnedWindowID: UUID?
    ) -> ShortcutAction? {
        guard appOwnedFocusedScaleTarget(preferredWindowID: appOwnedWindowID) != nil else {
            return nil
        }

        switch Self.textSizeShortcutDirection(for: event) {
        case .increase:
            return .increaseTextSize
        case .decrease:
            return .decreaseTextSize
        case .reset:
            return .resetTextSize
        case nil:
            return nil
        }
    }

    private func split(direction: SlotSplitDirection, preferredWindowID: UUID?) -> Bool {
        guard let store else { return false }
        guard let preferredWindowID else { return false }
        guard let workspaceID = store.commandSelection(preferredWindowID: preferredWindowID)?.workspace.id else {
            return false
        }

        _ = terminalRuntimeRegistry.splitFocusedSlotInDirection(
            workspaceID: workspaceID,
            direction: direction
        )
        // Cmd+D / Cmd+Shift+D should remain app-owned for resolved Toastty
        // workspace windows so embedded web views cannot reject the shortcut.
        return true
    }

    private func watchRunningCommand() -> Bool {
        guard let store else { return false }
        guard let preferredWindowID = appOwnedShortcutWindowID() else { return false }
        guard store.commandSelection(preferredWindowID: preferredWindowID) != nil else {
            return false
        }

        _ = processWatchCommandController.watchFocusedProcess(preferredWindowID: preferredWindowID)
        // Keep the shortcut app-owned for resolved Toastty workspace windows so
        // embedded terminals do not reinterpret it as raw input.
        return true
    }

    private func createBrowser(preferredWindowID: UUID?, placement: WebPanelPlacement) -> Bool {
        guard let store else { return false }
        guard let preferredWindowID else { return false }
        return store.createBrowserPanelFromCommand(
            preferredWindowID: preferredWindowID,
            request: BrowserPanelCreateRequest(
                placementOverride: placement
            )
        )
    }

    private func createScratchpad(preferredWindowID: UUID?) -> Bool {
        guard let store,
              let preferredWindowID,
              let workspaceID = store.commandSelection(preferredWindowID: preferredWindowID)?.workspace.id else {
            return false
        }

        do {
            _ = try store.createBlankScratchpadPanel(
                workspaceID: workspaceID,
                documentStore: webPanelRuntimeRegistry.scratchpadDocumentStore
            )
            return true
        } catch {
            NSLog("Blank Scratchpad creation failed: \(error.localizedDescription)")
            return false
        }
    }

    private func adjustTextSize(
        direction: TextSizeShortcutDirection,
        preferredWindowID: UUID?
    ) -> Bool {
        guard let store else { return false }
        guard let target = appOwnedFocusedScaleTarget(preferredWindowID: preferredWindowID) else {
            return false
        }

        switch (target, direction) {
        case (.terminal(let windowID), .increase):
            _ = store.send(.increaseWindowTerminalFont(windowID: windowID))
        case (.terminal(let windowID), .decrease):
            _ = store.send(.decreaseWindowTerminalFont(windowID: windowID))
        case (.terminal(let windowID), .reset):
            _ = store.send(.resetWindowTerminalFont(windowID: windowID))
        case (.markdown(let windowID), .increase):
            _ = store.send(.increaseWindowMarkdownTextScale(windowID: windowID))
        case (.markdown(let windowID), .decrease):
            _ = store.send(.decreaseWindowMarkdownTextScale(windowID: windowID))
        case (.markdown(let windowID), .reset):
            _ = store.send(.resetWindowMarkdownTextScale(windowID: windowID))
        case (.browser(_, let panelID), .increase):
            _ = store.send(.increaseBrowserPanelPageZoom(panelID: panelID))
        case (.browser(_, let panelID), .decrease):
            _ = store.send(.decreaseBrowserPanelPageZoom(panelID: panelID))
        case (.browser(_, let panelID), .reset):
            _ = store.send(.resetBrowserPanelPageZoom(panelID: panelID))
        }
        return true
    }

    private func focusNextUnreadOrActivePanel(preferredWindowID: UUID? = nil) -> Bool {
        guard let store else { return false }
        guard let preferredWindowID = preferredWindowID ?? appOwnedShortcutWindowID() else { return false }
        guard store.commandSelection(preferredWindowID: preferredWindowID) != nil else {
            return false
        }

        _ = store.focusNextUnreadOrActivePanelFromCommand(
            preferredWindowID: preferredWindowID,
            sessionRuntimeStore: sessionRuntimeStore
        )
        // Cmd+Shift+A is app-owned for normal workspace windows. If there is no
        // next unread or active target, swallow the shortcut rather than
        // passing it to the embedded terminal or default responder.
        return true
    }

    private func toggleLaterFlag(preferredWindowID: UUID? = nil) -> Bool {
        guard let store else { return false }
        guard let preferredWindowID = preferredWindowID ?? appOwnedShortcutWindowID() else { return false }
        guard let focusedPanelID = store.commandSelection(preferredWindowID: preferredWindowID)?.workspace.focusedPanelID else {
            return false
        }

        _ = sessionRuntimeStore.toggleLaterFlagForPanel(panelID: focusedPanelID)
        // Cmd+Shift+L is app-owned for normal workspace windows. If the
        // focused panel does not currently host a managed session, keep the
        // shortcut as a no-op rather than forwarding raw input.
        return true
    }

    private func toggleFocusedPanelMode() -> Bool {
        guard let store else { return false }
        guard let preferredWindowID = appOwnedShortcutWindowID() else { return false }
        guard let workspaceID = store.commandSelection(preferredWindowID: preferredWindowID)?.workspace.id else {
            return false
        }

        _ = terminalRuntimeRegistry.toggleFocusedPanelMode(workspaceID: workspaceID)
        // Cmd+Shift+F is app-owned for normal workspace windows. If the
        // selection does not produce a valid focus root, still swallow the
        // shortcut so the terminal does not interpret it as raw input.
        return true
    }

    private func renameSelectedTab() -> Bool {
        guard let store else { return false }
        guard let preferredWindowID = appOwnedShortcutWindowID() else { return false }
        return store.renameSelectedWorkspaceTabFromCommand(preferredWindowID: preferredWindowID)
    }

    private func switchWorkspace(shortcutNumber: Int) -> Bool {
        guard let store else { return false }
        guard shortcutNumber > 0, shortcutNumber <= DisplayShortcutConfig.maxWorkspaceShortcutCount else {
            return false
        }
        let preferredWindowID = currentToasttyKeyWindowID(in: store)
        guard let window = store.commandSelection(preferredWindowID: preferredWindowID)?.window else {
            return false
        }
        let index = shortcutNumber - 1
        guard window.workspaceIDs.indices.contains(index) else { return false }
        let workspaceID = window.workspaceIDs[index]
        guard store.state.workspacesByID[workspaceID] != nil else { return false }
        return store.sendNavigation(.selectWorkspace(windowID: window.id, workspaceID: workspaceID))
    }

    private func selectWorkspaceTab(shortcutNumber: Int) -> Bool {
        guard let store else { return false }
        guard let preferredWindowID = appOwnedShortcutWindowID() else { return false }
        return store.selectWorkspaceTabFromCommand(
            preferredWindowID: preferredWindowID,
            shortcutNumber: shortcutNumber
        )
    }

    private func selectAdjacentTab(direction: TabNavigationDirection) -> Bool {
        guard let store else { return false }
        guard let preferredWindowID = appOwnedShortcutWindowID() else { return false }
        return store.selectAdjacentWorkspaceTab(
            preferredWindowID: preferredWindowID,
            direction: direction
        )
    }

    private func selectAdjacentRightPanelTab(
        direction: PanelTabNavigationDirection,
        preferredWindowID: UUID?
    ) -> Bool {
        guard let store else { return false }
        guard let preferredWindowID else { return false }
        guard store.canSelectAdjacentRightAuxPanelTab(preferredWindowID: preferredWindowID) else {
            return false
        }
        return store.selectAdjacentRightAuxPanelTab(
            preferredWindowID: preferredWindowID,
            direction: direction
        )
    }

    private func cycleWorkspace(direction: Int) -> Bool {
        guard let store else { return false }
        guard let window = store.selectedWindow else { return false }
        let workspaceIDs = window.workspaceIDs
        guard workspaceIDs.count > 1 else { return false }
        guard let currentID = store.selectedWorkspaceID(in: window.id),
              let currentIndex = workspaceIDs.firstIndex(of: currentID) else {
            return false
        }
        let nextIndex = (currentIndex + direction + workspaceIDs.count) % workspaceIDs.count
        return store.sendNavigation(.selectWorkspace(windowID: window.id, workspaceID: workspaceIDs[nextIndex]))
    }

    private func focusTerminalPanel(shortcutNumber: Int) -> Bool {
        guard let store else { return false }
        let preferredWindowID = currentToasttyKeyWindowID(in: store)
        guard let workspace = store.commandSelection(preferredWindowID: preferredWindowID)?.workspace else {
            return false
        }
        guard let panelID = workspace.terminalPanelID(forDisplayShortcutNumber: shortcutNumber) else {
            return false
        }
        return store.sendNavigation(.focusPanel(workspaceID: workspace.id, panelID: panelID))
    }

    private func focusSplit(direction: SlotFocusDirection, preferredWindowID: UUID?) -> Bool {
        guard let store else { return false }
        guard let preferredWindowID else { return false }
        guard let workspaceID = store.commandSelection(preferredWindowID: preferredWindowID)?.workspace.id else {
            return false
        }
        _ = store.sendNavigation(.focusSlot(workspaceID: workspaceID, direction: direction))
        // Toastty-owned pane-focus shortcuts should not fall through to
        // embedded views once the current workspace window resolves, even if
        // there is no adjacent split target in that direction.
        return true
    }

    private func resizeSplit(direction: SplitResizeDirection, preferredWindowID: UUID?) -> Bool {
        guard let store else { return false }
        guard let preferredWindowID else { return false }
        guard let workspaceID = store.commandSelection(preferredWindowID: preferredWindowID)?.workspace.id else {
            return false
        }

        _ = store.send(
            .resizeFocusedSlotSplit(
                workspaceID: workspaceID,
                direction: direction,
                amount: SplitLayoutCommandController.appOwnedResizeAmount
            )
        )
        // Cmd+Ctrl+Arrow is a Toastty-owned layout shortcut. Once the current
        // workspace window resolves, keep it out of Ghostty even if the
        // focused slot cannot resize further in that direction.
        return true
    }

    private func equalizeSplits(preferredWindowID: UUID?) -> Bool {
        guard let store else { return false }
        guard let preferredWindowID else { return false }
        guard let workspaceID = store.commandSelection(preferredWindowID: preferredWindowID)?.workspace.id else {
            return false
        }

        _ = store.send(.equalizeLayoutSplits(workspaceID: workspaceID))
        // Cmd+Ctrl+= is likewise app-owned once a Toastty workspace window is
        // resolved so embedded terminals never reinterpret it as raw input.
        return true
    }

    private func openFocusedBrowserLocation(preferredWindowID: UUID?) -> Bool {
        guard let runtime = focusedBrowserRuntime(preferredWindowID: preferredWindowID) else { return false }
        runtime.requestLocationFieldFocus()
        return true
    }

    private func reloadFocusedBrowser(preferredWindowID: UUID?) -> Bool {
        guard let runtime = focusedBrowserRuntime(preferredWindowID: preferredWindowID) else { return false }
        _ = runtime.reloadOrStop()
        return true
    }

    private func saveFocusedLocalDocument(preferredWindowID: UUID?) -> Bool {
        guard let selection = focusedLocalDocumentSelection(preferredWindowID: preferredWindowID) else {
            return false
        }
        return webPanelRuntimeRegistry.saveLocalDocumentPanel(panelID: selection.panelID)
    }

    private func startFocusedLocalDocumentSearch(preferredWindowID: UUID?) -> Bool {
        guard let selection = focusedLocalDocumentSelection(preferredWindowID: preferredWindowID) else {
            return false
        }
        return webPanelRuntimeRegistry.startSearchLocalDocumentPanel(panelID: selection.panelID)
    }

    private func findNextFocusedLocalDocumentSearch(preferredWindowID: UUID?) -> Bool {
        guard let selection = focusedLocalDocumentSelection(preferredWindowID: preferredWindowID) else {
            return false
        }
        return webPanelRuntimeRegistry.findNextLocalDocumentPanel(panelID: selection.panelID)
    }

    private func findPreviousFocusedLocalDocumentSearch(preferredWindowID: UUID?) -> Bool {
        guard let selection = focusedLocalDocumentSelection(preferredWindowID: preferredWindowID) else {
            return false
        }
        return webPanelRuntimeRegistry.findPreviousLocalDocumentPanel(panelID: selection.panelID)
    }

    private func canEnterFocusedLocalDocumentEdit(preferredWindowID: UUID?) -> Bool {
        guard let selection = focusedLocalDocumentSelection(preferredWindowID: preferredWindowID) else {
            return false
        }
        return webPanelRuntimeRegistry.canEnterEditingLocalDocumentPanel(panelID: selection.panelID)
    }

    private func isFocusedLocalDocumentSearchActive(preferredWindowID: UUID?) -> Bool {
        guard let selection = focusedLocalDocumentSelection(preferredWindowID: preferredWindowID) else {
            return false
        }
        guard let searchState = webPanelRuntimeRegistry.localDocumentSearchState(panelID: selection.panelID) else {
            return false
        }
        return searchState.isPresented && searchState.query.isEmpty == false
    }

    private func enterFocusedLocalDocumentEdit(preferredWindowID: UUID?) -> Bool {
        guard let selection = focusedLocalDocumentSelection(preferredWindowID: preferredWindowID) else {
            return false
        }
        return webPanelRuntimeRegistry.enterEditingLocalDocumentPanel(panelID: selection.panelID)
    }

    private func canCancelFocusedLocalDocumentEdit(preferredWindowID: UUID?) -> Bool {
        guard let selection = focusedLocalDocumentSelection(preferredWindowID: preferredWindowID) else {
            return false
        }
        return webPanelRuntimeRegistry.canCancelEditingLocalDocumentPanel(panelID: selection.panelID)
    }

    private func cancelFocusedLocalDocumentEdit(preferredWindowID: UUID?) -> Bool {
        guard let selection = focusedLocalDocumentSelection(preferredWindowID: preferredWindowID) else {
            return false
        }
        return webPanelRuntimeRegistry.cancelEditingLocalDocumentPanel(panelID: selection.panelID)
    }

    private func handleCancelLocalDocumentEditShortcut(preferredWindowID: UUID?) -> Bool {
        guard canCancelFocusedLocalDocumentEdit(preferredWindowID: preferredWindowID) else {
            return false
        }
        // Keep bare Escape with the active local-document editor only while it
        // has a cancelable edit session; otherwise let the embedded view or the
        // default responder handle Escape normally.
        _ = cancelFocusedLocalDocumentEdit(preferredWindowID: preferredWindowID)
        return true
    }

    private func handleEnterLocalDocumentEditShortcut(preferredWindowID: UUID?) -> Bool {
        enterFocusedLocalDocumentEdit(preferredWindowID: preferredWindowID)
    }

    private func handleStartLocalDocumentSearchShortcut(preferredWindowID: UUID?) -> Bool {
        startFocusedLocalDocumentSearch(preferredWindowID: preferredWindowID)
    }

    private func handleFindNextLocalDocumentSearchShortcut(preferredWindowID: UUID?) -> Bool {
        findNextFocusedLocalDocumentSearch(preferredWindowID: preferredWindowID)
    }

    private func handleFindPreviousLocalDocumentSearchShortcut(preferredWindowID: UUID?) -> Bool {
        findPreviousFocusedLocalDocumentSearch(preferredWindowID: preferredWindowID)
    }

    private func handleSaveLocalDocumentShortcut(preferredWindowID: UUID?) -> Bool {
        guard focusedLocalDocumentSelection(preferredWindowID: preferredWindowID) != nil else {
            return false
        }
        _ = saveFocusedLocalDocument(preferredWindowID: preferredWindowID)
        // Cmd+S is app-owned for focused local-document panels, even when save is
        // currently disabled in preview mode or conflict state.
        return true
    }

    private func focusedBrowserRuntime(preferredWindowID: UUID?) -> BrowserPanelRuntime? {
        guard let selection = appOwnedFocusedBrowserSelection(preferredWindowID: preferredWindowID) else {
            return nil
        }
        return webPanelRuntimeRegistry.browserRuntime(for: selection.panelID)
    }

    private func appOwnedFocusedBrowserSelection(
        preferredWindowID: UUID?
    ) -> FocusedBrowserPanelCommandSelection? {
        guard let preferredWindowID else { return nil }
        return focusedBrowserSelection(preferredWindowID: preferredWindowID)
    }

    private func appOwnedFocusedLocalDocumentSelection(
        preferredWindowID: UUID?
    ) -> FocusedLocalDocumentPanelCommandSelection? {
        guard let preferredWindowID else { return nil }
        return focusedLocalDocumentSelection(preferredWindowID: preferredWindowID)
    }

    private func appOwnedFocusedScaleTarget(
        preferredWindowID: UUID?
    ) -> FocusedScaleCommandTarget? {
        guard let preferredWindowID,
              let store else {
            return nil
        }
        return store.focusedScaleCommandTarget(preferredWindowID: preferredWindowID)
    }

    private func focusedBrowserSelection(preferredWindowID: UUID?) -> FocusedBrowserPanelCommandSelection? {
        guard let store else { return nil }
        return store.focusedBrowserPanelSelection(preferredWindowID: preferredWindowID)
    }

    private func focusedLocalDocumentSelection(preferredWindowID: UUID?) -> FocusedLocalDocumentPanelCommandSelection? {
        guard let store else { return nil }
        return store.focusedLocalDocumentPanelSelection(preferredWindowID: preferredWindowID)
    }
}
