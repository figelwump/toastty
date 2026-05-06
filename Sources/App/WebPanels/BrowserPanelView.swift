import AppKit
import CoreState
import SwiftUI
import UniformTypeIdentifiers

struct BrowserPanelView: View {
    let panelID: UUID
    let webState: WebPanelState
    @ObservedObject var runtime: BrowserPanelRuntime
    let isEffectivelyVisible: Bool
    let isActivePanel: Bool
    let activatePanel: () -> Void

    @State private var addressDraft = ""
    @State private var isEditingAddressField = false

    private static let toolbarHeight: CGFloat = 34

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            BrowserPanelHostView(
                runtime: runtime,
                webState: webState,
                isEffectivelyVisible: isEffectivelyVisible,
                shouldFocusWebView: isActivePanel && isEditingAddressField == false
            )
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .onAppear {
            syncAddressDraft()
        }
        .onChange(of: runtime.navigationState.displayedURLString) { _, _ in
            guard isEditingAddressField == false else {
                return
            }
            syncAddressDraft()
        }
        .onChange(of: webState.restorableURL) { _, _ in
            guard isEditingAddressField == false else {
                return
            }
            syncAddressDraft()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            browserToolbarButton(
                systemImage: "chevron.left",
                helpText: "Back",
                isDisabled: runtime.navigationState.canGoBack == false
            ) {
                activatePanel()
                _ = runtime.goBack()
            }

            browserToolbarButton(
                systemImage: "chevron.right",
                helpText: "Forward",
                isDisabled: runtime.navigationState.canGoForward == false
            ) {
                activatePanel()
                _ = runtime.goForward()
            }

            browserToolbarButton(
                systemImage: runtime.navigationState.isLoading ? "xmark" : "arrow.clockwise",
                helpText: runtime.navigationState.isLoading ? "Stop" : "Reload",
                isDisabled: runtime.navigationState.canReloadOrStop == false
            ) {
                activatePanel()
                _ = runtime.reloadOrStop()
            }

            BrowserAddressTextField(
                text: $addressDraft,
                placeholder: "Enter URL",
                focusRequestID: isActivePanel ? runtime.locationFieldFocusRequestID : nil,
                accessibilityID: "browser.address.\(panelID.uuidString)",
                onSubmit: submitAddressDraft,
                onCancel: cancelAddressEditing,
                onEditingChanged: handleAddressEditingChanged
            )
            .frame(
                maxWidth: .infinity,
                minHeight: PanelHeaderSearchLayout.searchFieldHeight,
                maxHeight: PanelHeaderSearchLayout.searchFieldHeight
            )
            .layoutPriority(1)
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(ToastyTheme.surfaceBackground.opacity(0.96))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(ToastyTheme.subtleBorder, lineWidth: 1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(
            maxWidth: .infinity,
            minHeight: Self.toolbarHeight,
            maxHeight: Self.toolbarHeight,
            alignment: .leading
        )
        .background(ToastyTheme.elevatedBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ToastyTheme.hairline)
                .frame(height: 1)
        }
    }

    private func browserToolbarButton(
        systemImage: String,
        helpText: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            browserToolbarIcon(systemImage: systemImage, isDisabled: isDisabled)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(helpText)
    }

    private func browserToolbarIcon(systemImage: String, isDisabled: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isDisabled ? ToastyTheme.inactiveText : ToastyTheme.primaryText)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(ToastyTheme.surfaceBackground.opacity(isDisabled ? 0.45 : 0.96))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(ToastyTheme.subtleBorder, lineWidth: 1)
            }
    }

    private func handleAddressEditingChanged(_ isEditing: Bool) {
        if Self.shouldActivatePanelWhenAddressEditingChanges(
            isEditing: isEditing,
            isActivePanel: isActivePanel
        ) {
            activatePanel()
        }

        if isEditing {
            addressDraft = displayedAddressString
        }
        isEditingAddressField = isEditing
        if isEditing == false {
            syncAddressDraft()
        }
    }

    nonisolated static func shouldActivatePanelWhenAddressEditingChanges(
        isEditing: Bool,
        isActivePanel: Bool
    ) -> Bool {
        isEditing && isActivePanel == false
    }

    private func submitAddressDraft() {
        activatePanel()
        if runtime.loadUserEnteredURL(addressDraft) {
            addressDraft = displayedAddressString
            _ = runtime.focusWebView()
            return
        }

        syncAddressDraft()
    }

    private func cancelAddressEditing() {
        syncAddressDraft()
        _ = runtime.focusWebView()
    }

    private func syncAddressDraft() {
        addressDraft = displayedAddressString
    }

    private var displayedAddressString: String {
        runtime.navigationState.displayedURLString ?? webState.restorableURL ?? ""
    }
}

struct BrowserPanelHeaderAccessory: View {
    let panelID: UUID
    let webState: WebPanelState
    @ObservedObject var runtime: BrowserPanelRuntime
    let screenshotInsertCandidates: [BrowserScreenshotSendCandidate]
    let activatePanel: () -> Void
    let insertScreenshotPathForAgent: (URL, BrowserScreenshotSendCandidate) -> Bool

    @State private var screenshotInFlight = false

    var body: some View {
        BrowserPanelActionsMenuButton(
            canOpenCurrentURL: currentBrowserURL != nil,
            screenshotInFlight: screenshotInFlight,
            screenshotInsertCandidates: screenshotInsertCandidates,
            openCurrentURL: {
                activatePanel()
                openCurrentURLInDefaultBrowser()
            },
            copyScreenshot: copyVisibleScreenshot,
            saveScreenshot: saveVisibleScreenshotAs,
            insertScreenshotPath: insertVisibleScreenshotPath(for:)
        )
        .frame(width: 18, height: 18)
        .fixedSize()
        .disabled(screenshotInFlight)
        .help(screenshotInFlight ? "Capturing Screenshot" : "Browser Actions")
    }

    private func openCurrentURLInDefaultBrowser() {
        guard let currentBrowserURL else { return }
        NSWorkspace.shared.open(currentBrowserURL)
    }

    private func copyVisibleScreenshot() {
        performScreenshotAction { screenshot in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(screenshot.pngData, forType: .png)
        }
    }

    private func saveVisibleScreenshotAs() {
        performScreenshotAction { screenshot in
            let savePanel = NSSavePanel()
            savePanel.title = "Save Browser Screenshot"
            savePanel.nameFieldStringValue = screenshot.suggestedFileName
            savePanel.allowedContentTypes = [.png]
            savePanel.canCreateDirectories = true

            guard savePanel.runModal() == .OK,
                  let targetURL = savePanel.url else {
                return
            }
            try screenshot.pngData.write(to: targetURL, options: [.atomic])
        }
    }

    private func insertVisibleScreenshotPath(for candidate: BrowserScreenshotSendCandidate) {
        performScreenshotAction { screenshot in
            let fileURL = try BrowserPanelScreenshotWriter.writeQuickScreenshot(
                pngData: screenshot.pngData
            )
            let inserted = insertScreenshotPathForAgent(fileURL, candidate)
            if inserted == false {
                try? FileManager.default.removeItem(at: fileURL)
                NSLog(
                    "Browser screenshot path insert failed: sessionID=%@ panelID=%@ path=%@",
                    candidate.sessionID,
                    candidate.panelID.uuidString,
                    fileURL.path
                )
            }
        }
    }

    private func performScreenshotAction(
        _ operation: @escaping @MainActor (BrowserPanelScreenshot) throws -> Void
    ) {
        guard screenshotInFlight == false else { return }
        activatePanel()
        screenshotInFlight = true

        Task { @MainActor in
            defer {
                screenshotInFlight = false
            }
            do {
                let screenshot = try await captureVisibleScreenshot()
                try operation(screenshot)
            } catch {
                NSLog("Browser screenshot action failed: %@", error.localizedDescription)
            }
        }
    }

    private func captureVisibleScreenshot() async throws -> BrowserPanelScreenshot {
        let image = try await runtime.captureVisibleScreenshot()
        let pngData = try BrowserPanelScreenshotWriter.pngData(from: image)
        return BrowserPanelScreenshot(
            pngData: pngData,
            suggestedFileName: BrowserPanelScreenshotWriter.suggestedFileName(
                title: webState.title,
                urlString: displayedAddressString
            )
        )
    }

    private var currentBrowserURL: URL? {
        let address = displayedAddressString
        guard address.isEmpty == false else { return nil }
        return URL(string: address)
    }

    private var displayedAddressString: String {
        runtime.navigationState.displayedURLString ?? webState.restorableURL ?? ""
    }
}

private struct BrowserPanelActionsMenuButton: NSViewRepresentable {
    let canOpenCurrentURL: Bool
    let screenshotInFlight: Bool
    let screenshotInsertCandidates: [BrowserScreenshotSendCandidate]
    let openCurrentURL: () -> Void
    let copyScreenshot: () -> Void
    let saveScreenshot: () -> Void
    let insertScreenshotPath: (BrowserScreenshotSendCandidate) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.focusRingType = .none
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.setAccessibilityRole(.menuButton)
        button.setAccessibilityLabel("Browser Actions")
        button.setAccessibilityIdentifier("panel.header.browser.actions")
        button.setAccessibilityHelp("Opens browser actions")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.canOpenCurrentURL = canOpenCurrentURL
        context.coordinator.screenshotInFlight = screenshotInFlight
        context.coordinator.screenshotInsertCandidates = screenshotInsertCandidates
        context.coordinator.openCurrentURL = openCurrentURL
        context.coordinator.copyScreenshot = copyScreenshot
        context.coordinator.saveScreenshot = saveScreenshot
        context.coordinator.insertScreenshotPath = insertScreenshotPath

        button.image = NSImage(
            systemSymbolName: "ellipsis",
            accessibilityDescription: "Browser Actions"
        )
        button.contentTintColor = .secondaryLabelColor
        button.isEnabled = screenshotInFlight == false
    }

    @MainActor
    final class Coordinator: NSObject {
        var canOpenCurrentURL = false
        var screenshotInFlight = false
        var screenshotInsertCandidates: [BrowserScreenshotSendCandidate] = []
        var openCurrentURL: (() -> Void)?
        var copyScreenshot: (() -> Void)?
        var saveScreenshot: (() -> Void)?
        var insertScreenshotPath: ((BrowserScreenshotSendCandidate) -> Void)?

        @objc func showMenu(_ sender: NSButton) {
            let menu = BrowserPanelActionsMenuBuilder.menu(
                canOpenCurrentURL: canOpenCurrentURL,
                screenshotInFlight: screenshotInFlight,
                screenshotInsertCandidates: screenshotInsertCandidates,
                target: self,
                openCurrentURLAction: #selector(openCurrentURL(_:)),
                copyScreenshotAction: #selector(copyScreenshot(_:)),
                saveScreenshotAction: #selector(saveScreenshot(_:)),
                insertScreenshotPathAction: #selector(insertScreenshotPath(_:))
            )

            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.height + 2),
                in: sender
            )
        }

        @objc private func openCurrentURL(_ sender: NSMenuItem) {
            openCurrentURL?()
        }

        @objc private func copyScreenshot(_ sender: NSMenuItem) {
            copyScreenshot?()
        }

        @objc private func saveScreenshot(_ sender: NSMenuItem) {
            saveScreenshot?()
        }

        @objc private func insertScreenshotPath(_ sender: NSMenuItem) {
            guard let payload = sender.representedObject as? BrowserScreenshotCandidateMenuPayload else {
                return
            }
            insertScreenshotPath?(payload.candidate)
        }
    }
}

private final class BrowserScreenshotCandidateMenuPayload: NSObject {
    let candidate: BrowserScreenshotSendCandidate

    init(candidate: BrowserScreenshotSendCandidate) {
        self.candidate = candidate
    }
}

enum BrowserPanelActionsMenuBuilder {
    static func menu(
        canOpenCurrentURL: Bool,
        screenshotInFlight: Bool,
        screenshotInsertCandidates: [BrowserScreenshotSendCandidate],
        target: AnyObject?,
        openCurrentURLAction: Selector?,
        copyScreenshotAction: Selector?,
        saveScreenshotAction: Selector?,
        insertScreenshotPathAction: Selector?
    ) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(actionItem(
            title: "Open in Default Browser",
            isEnabled: canOpenCurrentURL,
            target: target,
            action: openCurrentURLAction
        ))
        menu.addItem(.separator())
        menu.addItem(actionItem(
            title: "Copy Screenshot",
            isEnabled: screenshotInFlight == false,
            target: target,
            action: copyScreenshotAction
        ))
        menu.addItem(actionItem(
            title: "Save Screenshot As...",
            isEnabled: screenshotInFlight == false,
            target: target,
            action: saveScreenshotAction
        ))
        menu.addItem(.separator())

        if screenshotInsertCandidates.isEmpty {
            let item = NSMenuItem(title: "No active sessions in this tab", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for candidate in screenshotInsertCandidates {
                let item = NSMenuItem(
                    title: "Insert Path in \(candidate.label)",
                    action: screenshotInFlight ? nil : insertScreenshotPathAction,
                    keyEquivalent: ""
                )
                item.target = target
                item.representedObject = BrowserScreenshotCandidateMenuPayload(candidate: candidate)
                item.isEnabled = screenshotInFlight == false
                menu.addItem(item)
            }
        }

        return menu
    }

    private static func actionItem(
        title: String,
        isEnabled: Bool,
        target: AnyObject?,
        action: Selector?
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: isEnabled ? action : nil,
            keyEquivalent: ""
        )
        item.target = target
        item.isEnabled = isEnabled
        return item
    }
}
