import AppKit
import SwiftUI

/// A message's text field that takes files: a pasted file or image, and
/// files or images dropped on the text, become the draft's attachments.
/// Pasted text stays plain text, and dropped text or a link goes into the
/// text as usual.
class AttachmentTextView: NSTextView {
    /// Returns true when it took the pasteboard as attachments.
    var onPasteAttachments: (NSPasteboard) -> Bool = { _ in false }
    weak var dropTarget: AttachmentDropTarget?

    /// A field that does not take drops of text still takes files.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        let types = super.acceptableDragTypes
        return types + DraftAttachments.attachmentTypes.filter { types.contains($0) == false }
    }

    // Files and images attach; anything else pastes as plain text. Do not
    // narrow readablePasteboardTypes to get plain text: pasteAsPlainText(_:)
    // then inserts nothing.
    override func paste(_ sender: Any?) {
        if onPasteAttachments(.general) {
            return
        }
        pasteAsPlainText(sender)
    }

    // Files and images dropped on the text attach, as they do anywhere else
    // around the field; dropped text and links still go into the text.

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if let dropTarget, dropTarget.dropEntered(sender.draggingPasteboard) {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if AttachmentDropTarget.carriesAttachments(sender.draggingPasteboard) {
            return .copy
        }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropTarget?.dropExited()
        super.draggingExited(sender)
    }

    // NSTextView agrees to a drop only for types it reads as text, so a
    // promised file or image data would end here, before
    // performDragOperation(_:), and attach nothing.
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if AttachmentDropTarget.carriesAttachments(sender.draggingPasteboard) {
            return true
        }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let dropTarget, AttachmentDropTarget.carriesAttachments(sender.draggingPasteboard) {
            return dropTarget.performDrop(sender.draggingPasteboard)
        }
        dropTarget?.dropExited()
        return super.performDragOperation(sender)
    }

    // A drag can end without an exit or a drop, for example when it is
    // cancelled over the field; the highlight must not stay on.
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dropTarget?.dropExited()
        super.draggingEnded(sender)
    }
}

/// Takes drops of files and images anywhere over a SwiftUI area, such as
/// the coordinator's chat, while clicks and scrolling go to the views under
/// it. AppKit looks for a drop's destination among the views registered for
/// the dragged types, not by `hitTest(_:)`: this view is found for files
/// and images, and a view under it, such as a covered terminal, is not.
final class AttachmentDropView: NSView {
    var dropTarget: AttachmentDropTarget?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Links too, for a `file:` link; any other link is refused here.
        registerForDraggedTypes(DraftAttachments.droppableTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropTarget?.dropEntered(sender.draggingPasteboard) == true ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        AttachmentDropTarget.carriesAttachments(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropTarget?.dropExited()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropTarget?.performDrop(sender.draggingPasteboard) ?? false
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dropTarget?.dropExited()
    }
}

/// An area of a SwiftUI view that takes drops of files and images for a
/// draft. Put it behind the area's content: it takes no clicks.
struct AttachmentDropArea: NSViewRepresentable {
    let dropTarget: AttachmentDropTarget

    func makeNSView(context: Context) -> AttachmentDropView {
        let view = AttachmentDropView()
        view.dropTarget = dropTarget
        return view
    }

    func updateNSView(_ view: AttachmentDropView, context: Context) {
        view.dropTarget = dropTarget
    }
}
