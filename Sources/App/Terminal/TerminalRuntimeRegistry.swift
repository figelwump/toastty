import AppKit
import CoreState
import Foundation

@MainActor
final class TerminalRuntimeRegistry: ObservableObject {
    private var controllers: [UUID: TerminalSurfaceController] = [:]

    func controller(for panelID: UUID) -> TerminalSurfaceController {
        if let existing = controllers[panelID] {
            return existing
        }

        let created = TerminalSurfaceController(panelID: panelID)
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
}

@MainActor
final class TerminalSurfaceController {
    private let panelID: UUID
    private let hostedView: NSView

    #if TOASTTY_HAS_GHOSTTY_KIT
    private var ghosttySurface: ghostty_surface_t?
    private let ghosttyManager = GhosttyRuntimeManager.shared
    #endif

    private let fallbackView = TerminalFallbackView()

    init(panelID: UUID) {
        self.panelID = panelID
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
            fallbackView.update(terminalState: terminalState, focused: focused, unavailableReason: "Ghostty surface unavailable")
            swapToFallbackIfNeeded()
            return
        }

        hostedView.isHidden = false
        if fallbackView.superview != nil {
            fallbackView.removeFromSuperview()
        }

        let xScale = max(Double(backingScaleFactor), 1)
        let yScale = max(Double(backingScaleFactor), 1)
        ghostty_surface_set_content_scale(ghosttySurface, xScale, yScale)

        let width = UInt32(max(Int(viewportSize.width * backingScaleFactor), 1))
        let height = UInt32(max(Int(viewportSize.height * backingScaleFactor), 1))
        ghostty_surface_set_size(ghosttySurface, width, height)
        ghostty_surface_set_focus(ghosttySurface, focused)
        #else
        fallbackView.update(terminalState: terminalState, focused: focused, unavailableReason: "GhosttyKit not linked")
        #endif
    }

    func invalidate() {
        #if TOASTTY_HAS_GHOSTTY_KIT
        if let ghosttySurface {
            ghostty_surface_free(ghosttySurface)
            self.ghosttySurface = nil
        }
        #endif
        fallbackView.removeFromSuperview()
        hostedView.removeFromSuperview()
    }

    #if TOASTTY_HAS_GHOSTTY_KIT
    private func ensureGhosttySurface(terminalState: TerminalPanelState, fontPoints: Double) {
        guard ghosttySurface == nil else { return }

        guard let hostView = hostedView as? TerminalHostView else { return }
        ghosttySurface = ghosttyManager.makeSurface(
            panelID: panelID,
            hostView: hostView,
            workingDirectory: terminalState.cwd,
            fontPoints: fontPoints
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
    #endif
}

final class TerminalHostView: NSView {
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
