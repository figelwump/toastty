import AppKit
import CoreState
import SwiftUI

/// The switch in the header of the coordinator's panel: the chat, or the
/// terminal the agent runs in.
struct CoordinatorPanelModeToggle: View {
    /// Observed: it publishes which one shows.
    @ObservedObject var store: AppStore
    let controller: CoordinatorController

    var body: some View {
        let showsTerminal = store.coordinatorShowsTerminal
        Button {
            if showsTerminal {
                // The chat's field takes the keyboard when the chat shows.
                controller.showsTerminal = false
            } else {
                controller.showTerminal()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: showsTerminal ? "bubble.left.and.text.bubble.right" : "terminal")
                    .font(.system(size: 9, weight: .semibold))
                Text(showsTerminal ? "Chat" : "Terminal")
                    .font(ToastyTheme.fontWorkspaceMergeButton)
            }
            .foregroundStyle(ToastyTheme.sidebarDisclosureText)
            .padding(.horizontal, 7)
            .frame(height: 16)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(ToastyTheme.sidebarDisclosureBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(showsTerminal
            ? "Show the coordinator's conversation as a chat"
            : "Show the coordinator's terminal, for a login, a folder-trust or a permission prompt")
        .accessibilityLabel(showsTerminal ? "Show Chat" : "Show Terminal")
        .accessibilityIdentifier("coordinator.panel.mode-toggle")
    }
}

/// "…" in the header of the coordinator's panel: a menu that shows the
/// coordinator's policy, ledger or friction notes in the right panel, or
/// restarts the coordinator. The chip matches Dock and Terminal; the menu
/// is an `NSMenu`, as on the Scratchpad's and the browser's "…" buttons.
struct CoordinatorPanelActionsButton: View {
    let controller: CoordinatorController

    var body: some View {
        CoordinatorActionsMenuButton(
            openDocument: { document in
                do {
                    try controller.openDocument(document)
                } catch {
                    TaskActions.presentFailure(document.openFailureTitle, error.localizedDescription)
                }
            },
            restart: { controller.perform(.restart) }
        )
        .frame(width: 22, height: 16)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(ToastyTheme.sidebarDisclosureBackground)
        )
        .fixedSize()
        .help("Open the coordinator's policy, ledger or friction notes beside the chat, or restart the coordinator")
    }
}

/// The "…" button itself. Internal so that a test can press each item.
struct CoordinatorActionsMenuButton: NSViewRepresentable {
    let openDocument: (CoordinatorDocument) -> Void
    let restart: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.focusRingType = .none
        button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Coordinator Actions")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        button.contentTintColor = NSColor(ToastyTheme.sidebarDisclosureText)
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.setAccessibilityRole(.menuButton)
        button.setAccessibilityLabel("Coordinator Actions")
        button.setAccessibilityIdentifier("coordinator.panel.actions")
        button.setAccessibilityHelp("Opens the coordinator's policy, ledger or friction notes, or restarts the coordinator")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.openDocument = openDocument
        context.coordinator.restart = restart
    }

    @MainActor
    final class Coordinator: NSObject {
        var openDocument: ((CoordinatorDocument) -> Void)?
        var restart: (() -> Void)?

        @objc func showMenu(_ sender: NSButton) {
            menu().popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.height + 2),
                in: sender
            )
        }

        /// One item for each of the coordinator's files, then Restart
        /// Coordinator.
        func menu() -> NSMenu {
            let menu = NSMenu()
            for document in CoordinatorDocument.allCases {
                let item = NSMenuItem(
                    title: document.openTitle,
                    action: #selector(openCoordinatorDocument(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = CoordinatorDocumentMenuPayload(document: document)
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let restart = NSMenuItem(title: "Restart Coordinator", action: #selector(restartCoordinator(_:)), keyEquivalent: "")
            restart.target = self
            menu.addItem(restart)
            return menu
        }

        @objc private func openCoordinatorDocument(_ sender: NSMenuItem) {
            guard let payload = sender.representedObject as? CoordinatorDocumentMenuPayload else { return }
            openDocument?(payload.document)
        }

        @objc private func restartCoordinator(_ sender: NSMenuItem) {
            restart?()
        }
    }
}

final class CoordinatorDocumentMenuPayload: NSObject {
    let document: CoordinatorDocument

    init(document: CoordinatorDocument) {
        self.document = document
    }
}

/// "Dock" in the header of the coordinator's panel: leaves the full view
/// for the workspace the user came from, with the chat in the dock.
struct CoordinatorPanelDockButton: View {
    let controller: CoordinatorController

    var body: some View {
        Button {
            controller.showDock(focusComposer: true)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 9, weight: .semibold))
                Text("Dock")
                    .font(ToastyTheme.fontWorkspaceMergeButton)
            }
            .foregroundStyle(ToastyTheme.sidebarDisclosureText)
            .padding(.horizontal, 7)
            .frame(height: 16)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(ToastyTheme.sidebarDisclosureBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(ToasttyKeyboardShortcuts.toggleCoordinatorDock.helpText(
            "Go back to your last workspace, with the coordinator's chat in the dock"
        ))
        .accessibilityLabel("Show in Dock")
        .accessibilityIdentifier("coordinator.panel.dock")
    }
}
