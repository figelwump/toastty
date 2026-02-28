import AppKit
import CoreState
import Foundation
#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit
#endif

@MainActor
final class TerminalRuntimeRegistry: ObservableObject {
    private var controllers: [UUID: TerminalSurfaceController] = [:]
    private weak var store: AppStore?
    #if TOASTTY_HAS_GHOSTTY_KIT
    private var panelIDBySurfaceHandle: [UInt: UUID] = [:]
    #endif

    func bind(store: AppStore) {
        self.store = store
        #if TOASTTY_HAS_GHOSTTY_KIT
        GhosttyRuntimeManager.shared.actionHandler = self
        #endif
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
        }
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

    #if TOASTTY_HAS_GHOSTTY_KIT
    fileprivate func register(surface: ghostty_surface_t, for panelID: UUID) {
        panelIDBySurfaceHandle[UInt(bitPattern: surface)] = panelID
    }

    fileprivate func unregister(surface: ghostty_surface_t, for panelID: UUID) {
        let key = UInt(bitPattern: surface)
        if panelIDBySurfaceHandle[key] == panelID {
            panelIDBySurfaceHandle.removeValue(forKey: key)
        }
    }

    private func panelID(for surface: ghostty_surface_t) -> UUID? {
        panelIDBySurfaceHandle[UInt(bitPattern: surface)]
    }

    private func workspaceID(containing panelID: UUID, state: AppState) -> UUID? {
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
    #endif
}

#if TOASTTY_HAS_GHOSTTY_KIT
extension TerminalRuntimeRegistry: GhosttyRuntimeActionHandling {
    private enum RoutedGhosttyAction {
        case split(PaneSplitDirection)
        case focusPane(PaneFocusDirection)
        case toggleFocusedPanelMode
    }

    func handleGhosttyRuntimeAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE else {
            return false
        }

        let routedAction: RoutedGhosttyAction
        switch action.tag {
        case GHOSTTY_ACTION_NEW_SPLIT:
            guard let direction = PaneSplitDirection(ghosttyDirection: action.action.new_split) else {
                return false
            }
            routedAction = .split(direction)

        case GHOSTTY_ACTION_GOTO_SPLIT:
            guard let direction = PaneFocusDirection(ghosttyDirection: action.action.goto_split) else {
                return false
            }
            routedAction = .focusPane(direction)

        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            routedAction = .toggleFocusedPanelMode

        default:
            return false
        }

        guard let sourceSurface = target.target.surface else {
            return false
        }
        guard let panelID = panelID(for: sourceSurface) else {
            return false
        }
        guard let store else {
            return false
        }
        guard let workspaceID = workspaceID(containing: panelID, state: store.state) else {
            return false
        }
        guard store.send(.focusPanel(workspaceID: workspaceID, panelID: panelID)) else {
            return false
        }

        switch routedAction {
        case .split(let direction):
            return store.send(.splitFocusedPaneInDirection(workspaceID: workspaceID, direction: direction))

        case .focusPane(let direction):
            return store.send(.focusPane(workspaceID: workspaceID, direction: direction))

        case .toggleFocusedPanelMode:
            return store.send(.toggleFocusedPanelMode(workspaceID: workspaceID))
        }
    }
}

private extension PaneSplitDirection {
    init?(ghosttyDirection: ghostty_action_split_direction_e) {
        switch ghosttyDirection {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT:
            self = .right
        case GHOSTTY_SPLIT_DIRECTION_DOWN:
            self = .down
        case GHOSTTY_SPLIT_DIRECTION_LEFT:
            self = .left
        case GHOSTTY_SPLIT_DIRECTION_UP:
            self = .up
        default:
            return nil
        }
    }
}

private extension PaneFocusDirection {
    init?(ghosttyDirection: ghostty_action_goto_split_e) {
        switch ghosttyDirection {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS:
            self = .previous
        case GHOSTTY_GOTO_SPLIT_NEXT:
            self = .next
        case GHOSTTY_GOTO_SPLIT_UP:
            self = .up
        case GHOSTTY_GOTO_SPLIT_DOWN:
            self = .down
        case GHOSTTY_GOTO_SPLIT_LEFT:
            self = .left
        case GHOSTTY_GOTO_SPLIT_RIGHT:
            self = .right
        default:
            return nil
        }
    }
}
#endif

@MainActor
final class TerminalSurfaceController {
    private let panelID: UUID
    private unowned let registry: TerminalRuntimeRegistry
    private let hostedView: NSView

    #if TOASTTY_HAS_GHOSTTY_KIT
    private var ghosttySurface: ghostty_surface_t?
    private let ghosttyManager = GhosttyRuntimeManager.shared
    #endif

    private let fallbackView = TerminalFallbackView()

    init(panelID: UUID, registry: TerminalRuntimeRegistry) {
        self.panelID = panelID
        self.registry = registry
        #if TOASTTY_HAS_GHOSTTY_KIT
        hostedView = TerminalHostView()
        #else
        hostedView = fallbackView
        #endif
    }

    func attach(into container: NSView) {
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
    }

    func update(
        terminalState: TerminalPanelState,
        focused: Bool,
        fontPoints: Double,
        viewportSize: CGSize,
        backingScaleFactor: CGFloat
    ) {
        #if TOASTTY_HAS_GHOSTTY_KIT
        ensureGhosttySurface(terminalState: terminalState, fontPoints: fontPoints)
        guard let ghosttySurface else {
            hostedView.isHidden = true
            if let hostView = hostedView as? TerminalHostView {
                hostView.setGhosttySurface(nil)
            }
            fallbackView.update(terminalState: terminalState, focused: focused, unavailableReason: "Ghostty surface unavailable")
            swapToFallbackIfNeeded()
            return
        }

        hostedView.isHidden = false
        if let hostView = hostedView as? TerminalHostView {
            hostView.setGhosttySurface(ghosttySurface)
        }
        if fallbackView.superview != nil {
            fallbackView.removeFromSuperview()
        }

        let xScale = max(Double(backingScaleFactor), 1)
        let yScale = max(Double(backingScaleFactor), 1)
        ghostty_surface_set_content_scale(ghosttySurface, xScale, yScale)

        // The embedded API accepts logical surface dimensions; content scale is provided separately.
        let width = UInt32(max(Int(viewportSize.width), 1))
        let height = UInt32(max(Int(viewportSize.height), 1))
        ghostty_surface_set_size(ghosttySurface, width, height)
        ghostty_surface_set_focus(ghosttySurface, focused)
        ensureFirstResponderIfNeeded(focused: focused)
        #else
        fallbackView.update(terminalState: terminalState, focused: focused, unavailableReason: "Ghostty terminal runtime not enabled in this build")
        #endif
    }

    func invalidate() {
        #if TOASTTY_HAS_GHOSTTY_KIT
        if let hostView = hostedView as? TerminalHostView {
            hostView.setGhosttySurface(nil)
        }
        if let ghosttySurface {
            registry.unregister(surface: ghosttySurface, for: panelID)
            ghostty_surface_free(ghosttySurface)
            self.ghosttySurface = nil
        }
        #endif
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
    #endif

    #if TOASTTY_HAS_GHOSTTY_KIT
    private func ensureGhosttySurface(terminalState: TerminalPanelState, fontPoints: Double) {
        guard ghosttySurface == nil else { return }

        guard let hostView = hostedView as? TerminalHostView else { return }
        guard let surface = ghosttyManager.makeSurface(
            hostView: hostView,
            workingDirectory: terminalState.cwd,
            fontPoints: fontPoints
        ) else {
            return
        }
        ghosttySurface = surface
        registry.register(surface: surface, for: panelID)
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
    #endif
}

final class TerminalHostView: NSView {
    #if TOASTTY_HAS_GHOSTTY_KIT
    private var ghosttySurface: ghostty_surface_t?
    #endif

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    #if TOASTTY_HAS_GHOSTTY_KIT
    func setGhosttySurface(_ surface: ghostty_surface_t?) {
        ghosttySurface = surface
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
        guard let ghosttySurface else { return false }

        let mods = Self.ghosttyModifierFlags(for: event.modifierFlags)
        var keyEvent = ghostty_input_key_s(
            action: action,
            mods: mods,
            consumed_mods: ghostty_surface_key_translation_mods(ghosttySurface, mods),
            keycode: UInt32(event.keyCode),
            text: nil,
            unshifted_codepoint: 0,
            composing: false
        )

        if let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
            keyEvent.unshifted_codepoint = scalar.value
        }

        if let text = Self.ghosttyText(for: event), !text.isEmpty {
            return text.withCString { pointer in
                keyEvent.text = pointer
                return ghostty_surface_key(ghosttySurface, keyEvent)
            }
        }

        return ghostty_surface_key(ghosttySurface, keyEvent)
    }

    private static func ghosttyModifierFlags(for flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        if flags.contains(.numericPad) { raw |= GHOSTTY_MODS_NUM.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
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
    #endif
}

private final class TerminalFallbackView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let reasonLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
        layer?.cornerRadius = 8

        titleLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white

        subtitleLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = NSColor(calibratedWhite: 0.75, alpha: 1)

        reasonLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        reasonLabel.textColor = NSColor(calibratedWhite: 0.65, alpha: 1)

        let stack = NSStackView(views: [titleLabel, subtitleLabel, reasonLabel])
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

    func update(terminalState: TerminalPanelState, focused: Bool, unavailableReason: String) {
        titleLabel.stringValue = "\(terminalState.title) · \(terminalState.shell)"
        subtitleLabel.stringValue = terminalState.cwd
        reasonLabel.stringValue = unavailableReason
        layer?.borderWidth = focused ? 1.5 : 1
        layer?.borderColor = (focused ? NSColor.systemBlue : NSColor(calibratedWhite: 0.4, alpha: 1)).cgColor
    }
}
