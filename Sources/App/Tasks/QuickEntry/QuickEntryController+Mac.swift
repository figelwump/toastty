import AppKit
import CoreState
import Foundation
import SwiftUI

/// The app that was in front when the panel opened.
typealias QuickEntryFrontmostApplication = NSRunningApplication

/// The macOS windows of quick entry: the floating panel, its picker panel,
/// the toast, the Carbon hot key, and the focus handoff back to the app the
/// user was in. `QuickEntryController` (the shared core) drives it. The
/// Linux frontend has its own (linux/Sources/ToasttyAppLogic/Tasks).
@MainActor
final class QuickEntryPresentation {
    static let frontmostApplication: @MainActor () -> NSRunningApplication? = {
        NSWorkspace.shared.frontmostApplication
    }

    private let frontmostApplication: @MainActor () -> NSRunningApplication?
    private var hotKey: QuickEntryHotKey?

    fileprivate(set) var panel: QuickEntryPanel?
    fileprivate(set) var pickerPanel: QuickEntryPickerPanel?
    /// The pill whose mouse-down just closed its picker, and that click's
    /// event number, so its mouse-up does not open the picker again.
    private var pickerClosedByPillClick: (kind: QuickEntryPickerKind, eventNumber: Int)?
    /// The app in front when the panel opened, if not Toastty.
    private var previousApplication: NSRunningApplication?
    private weak var previousKeyWindow: NSWindow?
    private weak var previousFirstResponder: NSResponder?
    /// Where the last panel was, so the next one opens there when it opens
    /// on the same screen. The top stays put because the height follows the
    /// text.
    private var lastPanelPlacement: QuickEntryPlacement.Remembered?
    /// The frame of the panel that just closed, where its toast shows.
    private var closedPanelFrame: NSRect?
    fileprivate(set) var toastPanel: QuickEntryToastPanel?
    private var toastTask: Task<Void, Never>?

    init(frontmostApplication: @escaping @MainActor () -> NSRunningApplication?) {
        self.frontmostApplication = frontmostApplication
    }

    // MARK: - The hot key

    func registerHotKey(
        _ shortcut: QuickEntryShortcut?,
        handler: @escaping @MainActor () -> Void
    ) -> QuickEntryShortcutRegistration {
        let hotKey = self.hotKey ?? QuickEntryHotKey(onPress: handler)
        self.hotKey = hotKey
        switch hotKey.register(shortcut) {
        case .registered(let shortcut): return .registered(shortcut)
        case .off: return .off
        case .failed(let shortcut, let status): return .failed(shortcut, status)
        }
    }

    // MARK: - The panel

    /// Before a new panel: who has the keyboard, to give it back.
    func rememberFocusBeforePresenting() {
        let frontmost = frontmostApplication()
        previousApplication = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        // The main window rather than the key window: opened from the
        // command palette, the key window is the palette, which is closing.
        previousKeyWindow = NSApp.isActive ? (NSApp.mainWindow ?? NSApp.keyWindow) : nil
        previousFirstResponder = previousKeyWindow?.firstResponder
    }

    func showPanel(for model: QuickEntryModel, controller: QuickEntryController) {
        let dropTarget = AttachmentDropTarget(attachments: model.attachmentDraft)
        let panel = QuickEntryPanel()
        panel.onSubmit = { [weak model] in model?.submit() }
        panel.onCreateTask = { [weak model] in model?.createTask() }
        panel.onCancel = { [weak model] in model?.cancel() }
        panel.onPicker = { [weak controller] kind in controller?.togglePicker(kind) }
        panel.contentView = QuickEntryContentView(
            rootView: QuickEntryView(
                model: model,
                dropTarget: dropTarget,
                attachFiles: { [weak controller] in controller?.chooseFiles() },
                togglePicker: { [weak controller] kind in controller?.togglePicker(kind) },
                onHeightChange: { [weak self, weak panel] height in
                    // Called during SwiftUI layout; resizing the window there
                    // would start a layout pass inside the current one.
                    DispatchQueue.main.async { [weak self, weak panel] in
                        guard let self, let panel, self.panel === panel else { return }
                        panel.fitContentHeight(height)
                    }
                }
            ),
            dropTarget: dropTarget
        )
        var size = QuickEntryPanel.defaultSize
        if let fittingHeight = panel.contentView?.fittingSize.height, fittingHeight > 0 {
            size.height = fittingHeight.rounded(.up)
        }
        // The screen of the window the user is working in, not the one with
        // Toastty's window or the last panel.
        let frame: NSRect
        if let screen = QuickEntryPanel.focusedScreen() ?? NSScreen.main {
            frame = QuickEntryPlacement.frame(
                size: size,
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                remembered: lastPanelPlacement
            )
        } else {
            frame = NSRect(origin: .zero, size: size)
        }
        panel.setFrame(frame, display: false)
        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func bringPanelForward() {
        guard let panel else { return }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func focusPanel() {
        panel?.makeKey()
    }

    var logMetadata: [String: String] {
        [
            "from_app": previousApplication?.bundleIdentifier ?? "toastty",
            "window_number": panel.map { String($0.windowNumber) } ?? "none",
            "is_key_window": String(panel?.isKeyWindow ?? false),
        ]
    }

    func closePanel() {
        guard let panel else { return }
        lastPanelPlacement = panel.screen.map {
            QuickEntryPlacement.Remembered(
                topLeft: NSPoint(x: panel.frame.minX, y: panel.frame.maxY),
                screenFrame: $0.frame
            )
        }
        closedPanelFrame = panel.frame
        let windowNumber = panel.windowNumber
        // Clear presentation before AppKit sends window-close callbacks.
        self.panel = nil
        panel.close()
        panel.contentView = nil
        ToasttyLog.info("Closed the quick entry panel", category: .tasks, metadata: [
            "window_number": String(windowNumber),
            "is_visible": String(panel.isVisible),
        ])
    }

    /// Gives focus back: to the app that was in front, or to the Toastty
    /// window and field that had it.
    func restoreFocus() {
        let previousApplication = self.previousApplication
        let previousKeyWindow = self.previousKeyWindow
        let previousFirstResponder = self.previousFirstResponder
        self.previousApplication = nil
        self.previousKeyWindow = nil
        self.previousFirstResponder = nil

        if let previousApplication {
            // Toastty became active only if the user chose files to attach.
            if NSApp.isActive {
                previousApplication.activate(options: [])
            }
            return
        }
        if let previousKeyWindow, previousKeyWindow.isVisible {
            previousKeyWindow.makeKey()
            if let previousFirstResponder {
                previousKeyWindow.makeFirstResponder(previousFirstResponder)
            }
        }
    }

    func chooseFiles(completion: @MainActor ([URL]) -> Void) {
        let openPanel = DraftAttachments.makeOpenPanel()
        // Above the floating quick entry panel. A modal panel needs Toastty
        // to be the active app; focus goes back when the quick entry closes.
        openPanel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        NSApp.activate()
        let response = openPanel.runModal()
        completion(response == .OK ? openPanel.urls : [])
    }

    // MARK: - The toast

    func showToast(_ message: String, duration: Duration) {
        toastTask?.cancel()
        toastPanel?.orderOut(nil)
        let toast = QuickEntryToastPanel(message: message)
        let anchor = closedPanelFrame ?? QuickEntryPanel.defaultFrame(screen: QuickEntryPanel.focusedScreen())
        closedPanelFrame = nil
        toast.setFrameOrigin(NSPoint(
            x: (anchor.midX - toast.frame.width / 2).rounded(),
            y: (anchor.midY - toast.frame.height / 2).rounded()
        ))
        toast.orderFrontRegardless()
        toastPanel = toast
        toastTask = Task { @MainActor [weak self, weak toast] in
            try? await Task.sleep(for: duration)
            guard Task.isCancelled == false, let toast else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                toast.animator().alphaValue = 0
            }
            toast.orderOut(nil)
            if self?.toastPanel === toast {
                self?.toastPanel = nil
            }
        }
    }

    // MARK: - Pickers

    /// Whether this is the mouse-up of the click on the pill whose
    /// mouse-down just closed this picker.
    func consumePillClickThatClosedPicker(_ kind: QuickEntryPickerKind) -> Bool {
        guard let closed = pickerClosedByPillClick else { return false }
        pickerClosedByPillClick = nil
        // The mouse-down on the pill took focus from the picker and closed
        // it; this is the same click's mouse-up, which shares its event
        // number.
        guard closed.kind == kind, let event = NSApp.currentEvent, event.type == .leftMouseUp else { return false }
        return event.eventNumber == closed.eventNumber
    }

    func showPicker(_ picker: QuickEntryPicker, for model: QuickEntryModel, controller: QuickEntryController) {
        guard let panel else { return }
        let kind = picker.kind
        let pickerPanel = QuickEntryPickerPanel()
        pickerPanel.onPickerShortcut = { [weak controller] kind in controller?.togglePicker(kind) }
        pickerPanel.onClose = { [weak picker] in picker?.cancel() }
        pickerPanel.onSubmitTask = { [weak controller] in controller?.submitFromPicker(createsTask: false) }
        pickerPanel.onCreateTask = { [weak controller] in controller?.submitFromPicker(createsTask: true) }
        pickerPanel.onCommandRight = { [weak picker] in
            guard let picker, picker.kind == .agent, picker.columns == nil else { return false }
            picker.openColumns()
            return true
        }
        pickerPanel.onRetryCodexModels = { [weak picker] in
            guard let picker, picker.showsCodexCatalogStatus, picker.codexCatalogStatus == .unavailable else { return false }
            picker.onRetryCodexModels()
            return true
        }
        pickerPanel.currentQuery = { [weak picker] in picker?.query ?? "" }
        pickerPanel.onNumberKey = { [weak picker] number in
            guard let picker, picker.query.isEmpty else { return false }
            return picker.chooseFrequent(number: number)
        }
        pickerPanel.onResignKey = { [weak self, weak pickerPanel, weak controller, weak model] in
            guard let self, let pickerPanel, self.pickerPanel === pickerPanel else { return }
            self.pickerResignedKey(kind: kind, model: model)
            controller?.closePicker(refocusText: false)
        }
        let hostingView = NSHostingView(rootView: QuickEntryPickerView(picker: picker) { [weak pickerPanel] size in
            // Called during SwiftUI layout; see the quick entry panel.
            DispatchQueue.main.async { pickerPanel?.fit(size) }
        })
        pickerPanel.contentView = hostingView
        let pill = model.pillFrames[kind].map {
            QuickEntryPickerPlacement.screenFrame(of: $0, inPanelFrame: panel.frame)
        } ?? NSRect(x: panel.frame.minX + 14, y: panel.frame.minY + 10, width: 1, height: 26)
        pickerPanel.place(
            size: hostingView.fittingSize,
            pill: pill,
            visibleFrame: (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        )
        self.pickerPanel = pickerPanel
        panel.addChildWindow(pickerPanel, ordered: .above)
        pickerPanel.makeKey()
    }

    func hidePicker() {
        guard let pickerPanel else { return }
        self.pickerPanel = nil
        pickerPanel.parent?.removeChildWindow(pickerPanel)
        pickerPanel.orderOut(nil)
        pickerPanel.contentView = nil
    }

    /// A click outside the picker, or another app in front, closes it. A
    /// click on its own pill is remembered, so that click does not open the
    /// picker again.
    private func pickerResignedKey(kind: QuickEntryPickerKind, model: QuickEntryModel?) {
        if let event = NSApp.currentEvent, event.type == .leftMouseDown, let panel, event.window === panel,
           let pill = model?.pillFrames[kind] {
            let point = event.locationInWindow
            let flipped = NSPoint(x: point.x, y: panel.frame.height - point.y)
            if pill.contains(flipped) {
                pickerClosedByPillClick = (kind, event.eventNumber)
            }
        }
    }
}

extension QuickEntryController {
    var panel: QuickEntryPanel? { presentation.panel }
    var pickerPanel: QuickEntryPickerPanel? { presentation.pickerPanel }
    var toastPanel: QuickEntryToastPanel? { presentation.toastPanel }
}
