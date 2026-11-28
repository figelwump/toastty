import AppKit
import ConversationUI
import Foundation

/// The macOS composer fields and drop targets of `CoordinatorChatModel`:
/// each view's AppKit text view, held weakly, and the drop targets of the
/// chat and the dock. The Linux frontend has its own
/// (linux/Sources/ToasttyAppLogic/Coordinator).
@MainActor
final class CoordinatorChatPlatform {
    /// Each view's composer text view, held weakly.
    fileprivate var composerTextViews: [CoordinatorChatModel.Host: WeakTextView] = [:]
    /// Take files dropped on each view's chat or composer's field. A drop
    /// gives that view's field the keyboard.
    fileprivate let panelDropTarget: AttachmentDropTarget
    fileprivate let dockDropTarget: AttachmentDropTarget

    init(attachmentDraft: DraftAttachments) {
        panelDropTarget = AttachmentDropTarget(attachments: attachmentDraft)
        dockDropTarget = AttachmentDropTarget(attachments: attachmentDraft)
    }

    func connect(to model: CoordinatorChatModel) {
        panelDropTarget.onDrop = { [weak model] in model?.takeKeyboardAfterDrop(host: .panel) }
        dockDropTarget.onDrop = { [weak model] in model?.takeKeyboardAfterDrop(host: .dock) }
    }
}

extension CoordinatorChatModel {
    /// The composer's text view of the view that showed last, so that
    /// keyboard focus meant for the terminal under the chat can go to it.
    var composerTextView: NSTextView? {
        get {
            if let activeHost, let view = platform.composerTextViews[activeHost]?.view { return view }
            return platform.composerTextViews.values.lazy.compactMap(\.view).first
        }
        set { setComposerTextView(newValue, host: .panel) }
    }

    /// The composer's text view of the view at `host`.
    func setComposerTextView(_ textView: NSTextView?, host: Host) {
        platform.composerTextViews[host] = textView.map(WeakTextView.init)
    }

    /// Whether the composer of the view at `host` has the keyboard in its
    /// window.
    func composerHasKeyboard(host: Host) -> Bool {
        guard let view = platform.composerTextViews[host]?.view, let window = view.window else { return false }
        return window.firstResponder === view
    }

    /// **Files…** in the composer's ＋ menu.
    func chooseFiles() {
        guard attachmentDraft.canEdit, attachmentDraft.canAttachMore else { return }
        let openPanel = DraftAttachments.makeOpenPanel()
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                if response == .OK {
                    self.attachmentDraft.attachFiles(openPanel.urls)
                }
                self.requestComposerFocus()
            }
        }
        if let window = composerTextView?.window {
            openPanel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            openPanel.begin(completionHandler: finish)
        }
    }

    /// Takes files dropped on the chat or on the composer's field of the
    /// view at `host`.
    func attachmentDropTarget(host: Host) -> AttachmentDropTarget {
        switch host {
        case .panel: platform.panelDropTarget
        case .dock: platform.dockDropTarget
        }
    }

    /// Files were dropped on the view at `host`, perhaps from another app:
    /// Toastty becomes the active app, the view's window comes to the
    /// front, and the view's field takes the keyboard, so that the user can
    /// type the message that goes with the files.
    func takeKeyboardAfterDrop(host: Host) {
        if host == .panel {
            // Another panel in the coordinator's workspace, such as
            // policy.md's, can have the focus.
            controller?.focusPanelForDrop()
        }
        platform.composerTextViews[host]?.view?.window?.makeKeyAndOrderFront(nil)
        activateApp()
        requestComposerFocus(host: host)
    }

    // MARK: - The keyboard

    /// Gives the composer the keyboard, in place of the terminal under the
    /// chat. Returns whether the chat has the keyboard now. A reader who
    /// selects text in the transcript keeps the keyboard there, so that
    /// Copy still copies the selection.
    @discardableResult
    func focusComposer() -> Bool {
        guard let composerTextView, let window = composerTextView.window else { return false }
        if window.firstResponder === composerTextView || window.firstResponder is ToasttyTranscriptTextView {
            return true
        }
        return window.makeFirstResponder(composerTextView)
    }
}

/// A text view held weakly, so a view that goes away takes its composer
/// with it.
fileprivate struct WeakTextView {
    weak var view: NSTextView?
}

