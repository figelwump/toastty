import Foundation

/// A composer's text field in the GTK chat
/// (linux/Sources/ToasttyLinux/UI/Coordinator). The model holds each view's
/// field weakly, as the macOS model holds each view's text view.
@MainActor
protocol CoordinatorComposerField: AnyObject {
    /// The field has the keyboard in its window.
    var hasKeyboard: Bool { get }
    /// The reader selects text in the transcript, which keeps the keyboard
    /// so that Copy copies the selection.
    var transcriptHasKeyboard: Bool { get }
    /// Gives the field the keyboard. Returns whether it has it after.
    func takeKeyboard() -> Bool
    /// Brings the field's window to the front.
    func presentWindow()
    /// A file chooser over the field's window; `completion` gets the chosen
    /// files, or none.
    func chooseFiles(completion: @escaping @MainActor ([URL]) -> Void)
}

/// The Linux composer fields of `CoordinatorChatModel` (macOS:
/// `CoordinatorChatModel+Mac.swift`). Drops reach the model through
/// `DraftAttachments` directly: the GTK drop target reads the files and
/// calls `attachFiles`, then `takeKeyboardAfterDrop(host:)`.
@MainActor
final class CoordinatorChatPlatform {
    fileprivate var fields: [CoordinatorChatModel.Host: WeakField] = [:]

    init(attachmentDraft: DraftAttachments) {
        _ = attachmentDraft
    }

    func connect(to model: CoordinatorChatModel) {
        _ = model
    }
}

private struct WeakField {
    weak var field: (any CoordinatorComposerField)?
}

extension CoordinatorChatModel {
    /// The composer's field of the view that showed last.
    var composerField: (any CoordinatorComposerField)? {
        if let activeHost, let field = platform.fields[activeHost]?.field { return field }
        return platform.fields.values.lazy.compactMap(\.field).first
    }

    /// The composer's field of the view at `host`.
    func setComposerField(_ field: (any CoordinatorComposerField)?, host: Host) {
        platform.fields[host] = field.map(WeakField.init)
    }

    /// Whether the composer of the view at `host` has the keyboard in its
    /// window.
    func composerHasKeyboard(host: Host) -> Bool {
        platform.fields[host]?.field?.hasKeyboard == true
    }

    /// **Files…** in the composer's ＋ menu.
    func chooseFiles() {
        guard attachmentDraft.canEdit, attachmentDraft.canAttachMore, let field = composerField else { return }
        field.chooseFiles { [weak self] urls in
            guard let self else { return }
            if urls.isEmpty == false {
                attachmentDraft.attachFiles(urls)
            }
            requestComposerFocus()
        }
    }

    /// Files were dropped on the view at `host`: its window comes to the
    /// front and its field takes the keyboard, so that the user can type the
    /// message that goes with the files.
    func takeKeyboardAfterDrop(host: Host) {
        if host == .panel {
            // Another panel in the coordinator's workspace, such as
            // policy.md's, can have the focus.
            controller?.focusPanelForDrop()
        }
        platform.fields[host]?.field?.presentWindow()
        activateApp()
        requestComposerFocus(host: host)
    }

    /// Gives the composer the keyboard, in place of the terminal under the
    /// chat. Returns whether the chat has the keyboard now. A reader who
    /// selects text in the transcript keeps the keyboard there.
    @discardableResult
    func focusComposer() -> Bool {
        guard let field = composerField else { return false }
        if field.hasKeyboard || field.transcriptHasKeyboard { return true }
        return field.takeKeyboard()
    }
}
