import AppKit
import SwiftUI

/// The floating quick entry window.
///
/// A non-activating panel: it takes typing without making Toastty the
/// active app, so the app you were in stays in front and gets focus back
/// when the panel closes. It floats over other apps and full-screen spaces,
/// stays open when you click into another app to take a screenshot, and
/// moves when you drag its background.
@MainActor
final class QuickEntryPanel: NSPanel {
    nonisolated static let width: CGFloat = 600
    /// Where the panel starts before its content sets the height.
    nonisolated static let defaultSize = NSSize(width: width, height: 210)
    nonisolated static let cornerRadius: CGFloat = 14

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
        // The window server draws the shadow around the rounded content.
        // A SwiftUI shadow would need a transparent margin, which would take
        // clicks and drops meant for the apps around the panel.
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        setAccessibilityIdentifier("quick-entry.panel")
    }

    /// Command shortcuts stay inside the panel. Toastty's menus would
    /// otherwise act on the Toastty window behind it: ⌘W would close a
    /// terminal there, and ⌘T would open a tab. While Toastty is not the
    /// active app its menu bar does not handle ⌘C or ⌘V either, so the
    /// panel sends the editing shortcuts to the text field itself.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else {
            // Typing and Control keys go to the text field as key events.
            return super.performKeyEquivalent(with: event)
        }
        switch Self.commandAction(key: key, keyCode: event.keyCode, modifiers: modifiers) {
        case .edit(let selector):
            _ = firstResponder?.tryToPerform(selector, with: nil)
        case .submit:
            onSubmit()
        case .close:
            onCancel()
        case .application:
            return super.performKeyEquivalent(with: event)
        case .ignore:
            break
        }
        return true
    }

    enum CommandAction: Equatable {
        case edit(Selector)
        case submit
        case close
        /// ⌘Q and ⌘H, which act on the app rather than a window.
        case application
        case ignore
    }

    static func commandAction(key: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> CommandAction {
        if keyCode == 36 || keyCode == 76 {
            return .submit
        }
        if modifiers == .command, key == "w" || key == "." {
            return .close
        }
        if modifiers == .command, key == "q" || key == "h" {
            return .application
        }
        if let selector = editingSelector(key: key, modifiers: modifiers) {
            return .edit(selector)
        }
        return .ignore
    }

    static func editingSelector(key: String, modifiers: NSEvent.ModifierFlags) -> Selector? {
        switch (key, modifiers) {
        case ("x", .command): #selector(NSText.cut(_:))
        case ("c", .command): #selector(NSText.copy(_:))
        case ("v", .command): #selector(NSText.paste(_:))
        case ("v", [.command, .option, .shift]): #selector(NSTextView.pasteAsPlainText(_:))
        case ("a", .command): #selector(NSText.selectAll(_:))
        case ("z", .command): Selector(("undo:"))
        case ("z", [.command, .shift]): Selector(("redo:"))
        default: nil
        }
    }

    /// Sets the height to the content's, keeping the top edge in place
    /// unless the taller panel would then run off the bottom of the screen.
    func fitContentHeight(_ height: CGFloat) {
        let height = height.rounded(.up)
        guard height > 0, abs(frame.height - height) >= 0.5 else { return }
        var resized = frame
        resized.origin.y = frame.maxY - height
        resized.size.height = height
        if let visible = screen?.visibleFrame, resized.minY < visible.minY {
            resized.origin.y = min(visible.minY, visible.maxY - height)
        }
        setFrame(resized, display: false)
        invalidateShadow()
    }

    /// The top third of the screen, centred.
    static func defaultFrame(size: NSSize = defaultSize, screen: NSScreen?) -> NSRect {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else {
            return NSRect(origin: .zero, size: size)
        }
        return defaultFrame(size: size, visibleFrame: visible)
    }

    nonisolated static func defaultFrame(size: NSSize, visibleFrame visible: NSRect) -> NSRect {
        let centerY = visible.maxY - visible.height / 3
        return NSRect(
            x: (visible.midX - size.width / 2).rounded(),
            y: (centerY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }

    /// The screen the user is working on: the one holding most of the
    /// focused window, else the one with the pointer.
    static func focusedScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let index = QuickEntryPlacement.screenIndex(
            focusedWindowFrame: focusedWindowFrame(screens: screens),
            pointer: NSEvent.mouseLocation,
            screenFrames: screens.map(\.frame)
        )
        return index.map { screens[$0] }
    }

    /// Toastty's own key or main window while it is active. For another app,
    /// its frontmost normal window from the window server, whose bounds need
    /// no Accessibility or screen recording permission.
    private static func focusedWindowFrame(screens: [NSScreen]) -> NSRect? {
        if NSApp.isActive {
            let window = [NSApp.keyWindow, NSApp.mainWindow]
                .compactMap { $0 }
                .first { $0.isVisible && ($0 is QuickEntryPanel) == false }
            return window?.frame
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let primaryHeight = screens.first?.frame.height,
              let windows = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]] else {
            return nil
        }
        // Front to back: the first normal-layer window of the app in front.
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width > 1, bounds.height > 1 else {
                continue
            }
            return QuickEntryPlacement.cocoaFrame(fromWindowServerBounds: bounds, primaryScreenHeight: primaryHeight)
        }
        return nil
    }
}

/// Where the quick entry panel opens.
enum QuickEntryPlacement {
    /// Where the user last left the panel, and on which screen.
    struct Remembered: Equatable {
        var topLeft: NSPoint
        var screenFrame: NSRect
    }

    /// The screen holding most of `focusedWindowFrame`, else the one with
    /// the pointer.
    static func screenIndex(focusedWindowFrame: NSRect?, pointer: NSPoint, screenFrames: [NSRect]) -> Int? {
        if let focusedWindowFrame {
            let overlaps = screenFrames.enumerated().map { index, frame -> (Int, CGFloat) in
                let overlap = frame.intersection(focusedWindowFrame)
                return (index, overlap.isNull ? 0 : overlap.width * overlap.height)
            }
            if let best = overlaps.max(by: { $0.1 < $1.1 }), best.1 > 0 {
                return best.0
            }
        }
        return screenFrames.firstIndex { NSMouseInRect(pointer, $0, false) }
    }

    /// The panel frame on the target screen: the remembered spot when it was
    /// on that same screen, kept inside its visible area; otherwise the
    /// default spot there.
    static func frame(
        size: NSSize,
        screenFrame: NSRect,
        visibleFrame: NSRect,
        remembered: Remembered?
    ) -> NSRect {
        guard let remembered, remembered.screenFrame == screenFrame else {
            return QuickEntryPanel.defaultFrame(size: size, visibleFrame: visibleFrame)
        }
        var frame = NSRect(
            x: remembered.topLeft.x,
            y: remembered.topLeft.y - size.height,
            width: size.width,
            height: size.height
        )
        frame.origin.x = min(max(frame.minX, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - size.width))
        frame.origin.y = min(max(frame.minY, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - size.height))
        return frame
    }

    /// Window server bounds have their origin at the top left of the primary
    /// screen, with y growing down; AppKit's start at its bottom left.
    static func cocoaFrame(fromWindowServerBounds bounds: CGRect, primaryScreenHeight: CGFloat) -> NSRect {
        NSRect(x: bounds.minX, y: primaryScreenHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }
}

/// Accepts drops anywhere on the panel and hands them to the model.
@MainActor
final class QuickEntryDropTarget {
    weak var model: QuickEntryModel?

    init(model: QuickEntryModel?) {
        self.model = model
    }

    /// Files, promised files and images become attachments.
    static func carriesAttachments(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: QuickEntryModel.droppableTypes.filter { $0 != .URL }) != nil
    }

    static func carriesLink(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.URL]) != nil
    }

    func dropEntered(_ pasteboard: NSPasteboard, acceptsLinks: Bool = false) -> Bool {
        guard Self.carriesAttachments(pasteboard) || (acceptsLinks && Self.carriesLink(pasteboard)) else {
            return false
        }
        model?.isDropTargeted = true
        return true
    }

    func dropExited() {
        model?.isDropTargeted = false
    }

    func performDrop(_ pasteboard: NSPasteboard) -> Bool {
        model?.isDropTargeted = false
        return model?.handleDrop(from: pasteboard) ?? false
    }
}

/// The panel's content: SwiftUI inside a view that takes drops, so a file
/// dropped on the footer or the border attaches too.
@MainActor
final class QuickEntryContentView: NSView {
    private let dropTarget: QuickEntryDropTarget

    init<Content: View>(rootView: Content, dropTarget: QuickEntryDropTarget) {
        self.dropTarget = dropTarget
        super.init(frame: NSRect(origin: .zero, size: QuickEntryPanel.defaultSize))
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        registerForDraggedTypes(QuickEntryModel.droppableTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropTarget.dropEntered(sender.draggingPasteboard, acceptsLinks: true) ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        return QuickEntryDropTarget.carriesAttachments(pasteboard) || QuickEntryDropTarget.carriesLink(pasteboard) ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropTarget.dropExited()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropTarget.performDrop(sender.draggingPasteboard)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dropTarget.dropExited()
    }
}

/// "Task created" after the panel closes. It ignores the mouse and fades
/// out on its own.
@MainActor
final class QuickEntryToastPanel: NSPanel {
    nonisolated static let size = NSSize(width: 260, height: 40)

    init(message: String) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: QuickEntryToastView(message: message))
        setAccessibilityIdentifier("quick-entry.toast")
    }

    override var canBecomeKey: Bool { false }
}

private struct QuickEntryToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ToastyTheme.sidebarSubspaceDoneMark)
            Text(message)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(ToastyTheme.primaryText)
        }
        .padding(.horizontal, 14)
        .frame(width: QuickEntryToastPanel.size.width, height: QuickEntryToastPanel.size.height)
        .background(
            Capsule(style: .continuous).fill(Color(red: 0.10, green: 0.10, blue: 0.11).opacity(0.96))
        )
        .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}
