import AppKit
import SwiftUI

@MainActor
final class CommandPaletteController: NSObject, NSWindowDelegate {
    private final class ObserverTokenBox: @unchecked Sendable {
        let token: NSObjectProtocol

        init(token: NSObjectProtocol) {
            self.token = token
        }
    }

    enum DismissReason {
        case cancelled
        case executed
        case toggled
        case clickAway
        case originWindowClosed
        case appDeactivated
    }

    private weak var store: AppStore?
    private let actions: CommandPaletteActionHandling
    private let panelFactory: () -> CommandPalettePanel
    private let scheduleWorkspaceFocusRestore: @MainActor (UUID, Bool) -> Void

    private var panel: CommandPalettePanel?
    private(set) var viewModel: CommandPaletteViewModel?
    private var originWindowID: UUID?
    private weak var originWindow: NSWindow?
    private weak var previousFirstResponder: NSResponder?
    private var originWorkspaceID: UUID?
    private var appDidResignActiveObserver: ObserverTokenBox?
    private var originWindowWillCloseObserver: ObserverTokenBox?
    private var isDismissing = false

    private(set) var isPresented = false

    init(
        store: AppStore,
        terminalRuntimeRegistry: TerminalRuntimeRegistry,
        actions: CommandPaletteActionHandling,
        panelFactory: @escaping () -> CommandPalettePanel = { CommandPalettePanel() },
        scheduleWorkspaceFocusRestore: (@MainActor (UUID, Bool) -> Void)? = nil
    ) {
        self.store = store
        self.actions = actions
        self.panelFactory = panelFactory
        self.scheduleWorkspaceFocusRestore = scheduleWorkspaceFocusRestore ?? { [weak terminalRuntimeRegistry] workspaceID, avoidStealingKeyboardFocus in
            terminalRuntimeRegistry?.scheduleWorkspaceFocusRestore(
                workspaceID: workspaceID,
                avoidStealingKeyboardFocus: avoidStealingKeyboardFocus
            )
        }
    }

    deinit {
        let notificationCenter = NotificationCenter.default

        if let appDidResignActiveObserver {
            notificationCenter.removeObserver(appDidResignActiveObserver.token)
        }

        if let originWindowWillCloseObserver {
            notificationCenter.removeObserver(originWindowWillCloseObserver.token)
        }
    }

    @discardableResult
    func toggle(originWindowID: UUID?) -> Bool {
        if isPresented {
            dismiss(reason: .toggled)
            return true
        }

        guard let originWindowID,
              let store,
              store.window(id: originWindowID) != nil,
              let originWindow = resolveWindow(id: originWindowID) else {
            return false
        }

        show(originWindowID: originWindowID, originWindow: originWindow)
        return true
    }

    func dismiss(reason: DismissReason) {
        guard isPresented, isDismissing == false else { return }

        // Clear presentation state before ordering the panel out so delegate
        // callbacks triggered by `orderOut` cannot re-enter dismissal as a
        // synthetic click-away.
        isDismissing = true
        isPresented = false

        let originWindowID = self.originWindowID
        let originWindow = self.originWindow
        let previousFirstResponder = self.previousFirstResponder
        let originWorkspaceID = self.originWorkspaceID
        let panel = self.panel

        removeObservers()

        self.originWindowID = nil
        self.originWindow = nil
        self.previousFirstResponder = nil
        self.originWorkspaceID = nil
        self.panel = nil
        self.viewModel = nil

        panel?.delegate = nil
        panel?.contentViewController = nil
        panel?.orderOut(nil)

        if shouldRestoreFocus(for: reason),
           let originWindowID {
            restoreFocus(
                reason: reason,
                originWindowID: originWindowID,
                originWindow: originWindow,
                previousFirstResponder: previousFirstResponder,
                originWorkspaceID: originWorkspaceID
            )
        }

        isDismissing = false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isPresented, isDismissing == false else { return }
        _ = notification
        if NSApp.isActive {
            dismiss(reason: .clickAway)
        }
    }

    private func show(originWindowID: UUID, originWindow: NSWindow) {
        self.originWindowID = originWindowID
        self.originWindow = originWindow
        previousFirstResponder = originWindow.firstResponder
        originWorkspaceID = actions.commandSelection(originWindowID: originWindowID)?.workspace.id

        let viewModel = CommandPaletteViewModel(
            originWindowID: originWindowID,
            commands: Self.commands(),
            actions: actions,
            onCancel: { [weak self] in
                self?.dismiss(reason: .cancelled)
            },
            onExecuted: { [weak self] in
                self?.dismiss(reason: .executed)
            }
        )
        self.viewModel = viewModel

        let hostingController = NSHostingController(rootView: CommandPaletteView(viewModel: viewModel))
        let panel = panelFactory()
        panel.delegate = self
        panel.contentViewController = hostingController
        panel.position(relativeTo: originWindow)

        isPresented = true
        self.panel = panel

        installObservers(originWindow: originWindow)
        panel.makeKeyAndOrderFront(nil)
    }

    private func shouldRestoreFocus(for reason: DismissReason) -> Bool {
        switch reason {
        case .cancelled, .executed, .toggled:
            return true
        case .clickAway, .originWindowClosed, .appDeactivated:
            return false
        }
    }

    private func restoreFocus(
        reason: DismissReason,
        originWindowID: UUID,
        originWindow: NSWindow?,
        previousFirstResponder: NSResponder?,
        originWorkspaceID: UUID?
    ) {
        let resolvedOriginWindow = originWindow ?? resolveWindow(id: originWindowID)
        let currentWorkspaceID = actions.commandSelection(originWindowID: originWindowID)?.workspace.id
        let workspaceIDForRestore = currentWorkspaceID ?? originWorkspaceID
        resolvedOriginWindow?.makeKeyAndOrderFront(nil)

        let shouldRestorePreviousResponder = reason != .executed || currentWorkspaceID == originWorkspaceID

        if shouldRestorePreviousResponder,
           let resolvedOriginWindow,
           let previousFirstResponder,
           resolvedOriginWindow.makeFirstResponder(previousFirstResponder) {
            return
        }

        if let workspaceIDForRestore {
            scheduleWorkspaceFocusRestore(workspaceIDForRestore, false)
        }
    }

    private func installObservers(originWindow: NSWindow) {
        let notificationCenter = NotificationCenter.default
        appDidResignActiveObserver = ObserverTokenBox(
            token: notificationCenter.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.dismiss(reason: .appDeactivated)
                }
            }
        )

        originWindowWillCloseObserver = ObserverTokenBox(
            token: notificationCenter.addObserver(
                forName: NSWindow.willCloseNotification,
                object: originWindow,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.dismiss(reason: .originWindowClosed)
                }
            }
        )
    }

    private func removeObservers() {
        let notificationCenter = NotificationCenter.default

        if let appDidResignActiveObserver {
            notificationCenter.removeObserver(appDidResignActiveObserver.token)
            self.appDidResignActiveObserver = nil
        }

        if let originWindowWillCloseObserver {
            notificationCenter.removeObserver(originWindowWillCloseObserver.token)
            self.originWindowWillCloseObserver = nil
        }
    }

    private func resolveWindow(id windowID: UUID) -> NSWindow? {
        NSApp.windows.first(where: { $0.identifier?.rawValue == windowID.uuidString })
    }

    private static func commands() -> [PaletteCommand] {
        [
            PaletteCommand(
                id: "layout.split.horizontal",
                keywords: ["split", "horizontal", "right", "panel"],
                shortcut: ToasttyKeyboardShortcuts.splitHorizontal,
                title: { _ in "Split Horizontally" },
                isAvailable: { context in
                    context.actions.canSplitHorizontal(originWindowID: context.originWindowID)
                },
                execute: { context in
                    context.actions.splitHorizontal(originWindowID: context.originWindowID)
                }
            ),
            PaletteCommand(
                id: "workspace.create",
                keywords: ["workspace", "new", "create"],
                shortcut: ToasttyKeyboardShortcuts.newWorkspace,
                title: { _ in "New Workspace" },
                isAvailable: { context in
                    context.actions.canCreateWorkspace(originWindowID: context.originWindowID)
                },
                execute: { context in
                    context.actions.createWorkspace(originWindowID: context.originWindowID)
                }
            ),
            PaletteCommand(
                id: "window.toggle-sidebar",
                keywords: ["sidebar", "toggle", "show", "hide"],
                shortcut: ToasttyKeyboardShortcuts.toggleSidebar,
                title: { context in
                    context.actions.sidebarTitle(originWindowID: context.originWindowID)
                },
                isAvailable: { context in
                    context.actions.canToggleSidebar(originWindowID: context.originWindowID)
                },
                execute: { context in
                    context.actions.toggleSidebar(originWindowID: context.originWindowID)
                }
            ),
        ]
    }
}
