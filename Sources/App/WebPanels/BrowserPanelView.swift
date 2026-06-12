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
    let annotationSendCandidates: [BrowserScreenshotSendCandidate]
    let canSubmitAnnotationsToAgent: (BrowserScreenshotSendCandidate) -> Bool
    let sendAnnotationPayloadToAgent: (String, BrowserScreenshotSendCandidate) -> Bool

    @State private var addressDraft = ""
    @State private var isEditingAddressField = false

    private static let toolbarHeight: CGFloat = 34

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            ZStack {
                BrowserPanelHostView(
                    runtime: runtime,
                    webState: webState,
                    isEffectivelyVisible: isEffectivelyVisible,
                    shouldFocusWebView: isActivePanel && isEditingAddressField == false
                )

                BrowserAnnotationOverlayView(
                    runtime: runtime,
                    activatePanel: activatePanel
                )

                if runtime.annotationState.isAnnotationModeEnabled {
                    Rectangle()
                        .strokeBorder(ToastyTheme.accent.opacity(0.85), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if runtime.annotationState.isAnnotationModeEnabled {
                    BrowserAnnotationModeToolbar(
                        panelID: panelID,
                        runtime: runtime,
                        sendCandidates: annotationSendCandidates,
                        canSubmitToAgent: canSubmitAnnotationsToAgent,
                        sendPayloadToAgent: sendAnnotationPayloadToAgent
                    )
                    .padding(.top, 10)
                }
            }
            .overlay(alignment: .bottom) {
                if let notice = runtime.annotationSendNotice {
                    BrowserAnnotationNoticeToast(notice: notice) {
                        runtime.clearAnnotationSendNotice(id: notice.id)
                    }
                    .padding(.bottom, 14)
                }
            }
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
    let canSubmitAnnotationsToAgent: (BrowserScreenshotSendCandidate) -> Bool
    let sendAnnotationPayloadToAgent: (String, BrowserScreenshotSendCandidate) -> Bool

    @State private var screenshotInFlight = false
    @State private var isClearConfirmationPresented = false

    var body: some View {
        HStack(spacing: 3) {
            browserAnnotationToggle

            if runtime.annotationState.hasDrafts {
                browserAnnotationSendMenu
                browserAnnotationClearButton
            }

            browserScreenshotMenu

            BrowserPanelActionsMenuButton(
                canOpenCurrentURL: currentBrowserURL != nil,
                openCurrentURL: {
                    activatePanel()
                    openCurrentURLInDefaultBrowser()
                }
            )
            .frame(width: 18, height: 18)
            .fixedSize()
            .help("Browser Actions")
        }
        .frame(minWidth: 0)
    }

    private var isAnnotationToggleDisabled: Bool {
        runtime.navigationState.displayedURLString == nil
    }

    private var browserAnnotationToggle: some View {
        Button {
            activatePanel()
            runtime.setAnnotationModeEnabled(runtime.annotationState.isAnnotationModeEnabled == false)
        } label: {
            browserHeaderIcon(
                systemImage: "pencil.and.outline",
                isDisabled: isAnnotationToggleDisabled,
                isActive: runtime.annotationState.isAnnotationModeEnabled
            )
            .overlay(alignment: .topTrailing) {
                if runtime.annotationState.draftCount > 0 {
                    BrowserAnnotationCountBadge(count: runtime.annotationState.draftCount)
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isAnnotationToggleDisabled)
        .help(
            isAnnotationToggleDisabled
                ? "Load a page to annotate it"
                : (runtime.annotationState.isAnnotationModeEnabled
                    ? "Exit Annotation Mode"
                    : "Annotate Browser Page")
        )
        .accessibilityLabel("Annotate Browser Page")
        .accessibilityIdentifier("panel.header.browser.annotations.toggle.\(panelID.uuidString)")
    }

    private var isAnnotationSendDisabled: Bool {
        runtime.isAnnotationSendInFlight || runtime.isAnnotationEditorActive
    }

    private var browserAnnotationSendMenu: some View {
        Menu {
            Section("Send to Agent") {
                BrowserAnnotationSendMenuItems(
                    candidates: screenshotInsertCandidates,
                    canSubmit: canSubmitAnnotationsToAgent,
                    send: sendAnnotations(to:)
                )
            }
        } label: {
            browserHeaderIcon(
                systemImage: "paperplane",
                isDisabled: isAnnotationSendDisabled,
                isActive: false
            )
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .disabled(isAnnotationSendDisabled)
        .help(runtime.isAnnotationSendInFlight ? "Sending Annotations" : "Send Browser Annotations to Agent")
        .accessibilityLabel("Send Browser Annotations to Agent")
        .accessibilityIdentifier("panel.header.browser.annotations.send.\(panelID.uuidString)")
    }

    private var browserAnnotationClearButton: some View {
        Button {
            isClearConfirmationPresented = true
        } label: {
            browserHeaderIcon(systemImage: "xmark.circle", isDisabled: false, isActive: false)
        }
        .buttonStyle(.plain)
        .help("Clear Browser Annotations")
        .accessibilityLabel("Clear Browser Annotations")
        .accessibilityIdentifier("panel.header.browser.annotations.clear.\(panelID.uuidString)")
        .confirmationDialog(
            BrowserAnnotationCopy.clearConfirmationTitle(
                draftCount: runtime.annotationState.draftCount
            ),
            isPresented: $isClearConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                runtime.clearAnnotations(exitAnnotationMode: false)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var browserScreenshotMenu: some View {
        Menu {
            Button {
                copyVisibleScreenshot()
            } label: {
                Label("Copy Screenshot", systemImage: "doc.on.doc")
            }

            Button {
                saveVisibleScreenshotAs()
            } label: {
                Label("Save Screenshot As...", systemImage: "square.and.arrow.down")
            }

            Divider()

            Section("Insert Path in Agent") {
                if screenshotInsertCandidates.isEmpty {
                    Button("No active sessions in this tab") {}
                        .disabled(true)
                } else {
                    ForEach(screenshotInsertCandidates) { candidate in
                        Button {
                            insertVisibleScreenshotPath(for: candidate)
                        } label: {
                            Label(candidate.label, systemImage: "paperclip")
                        }
                    }
                }
            }
        } label: {
            browserHeaderIcon(systemImage: "camera", isDisabled: screenshotInFlight, isActive: false)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .disabled(screenshotInFlight)
        .help(screenshotInFlight ? "Capturing Screenshot" : "Browser Screenshot")
        .accessibilityLabel("Browser Screenshot")
        .accessibilityIdentifier("panel.header.browser.screenshot.\(panelID.uuidString)")
    }

    private func browserHeaderIcon(
        systemImage: String,
        isDisabled: Bool,
        isActive: Bool
    ) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(
                isDisabled
                    ? ToastyTheme.inactiveText
                    : (isActive ? ToastyTheme.accent : ToastyTheme.primaryText)
            )
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
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

    private func sendAnnotations(to candidate: BrowserScreenshotSendCandidate) {
        activatePanel()
        BrowserAnnotationSendFlow.send(
            runtime: runtime,
            candidate: candidate,
            canSubmit: canSubmitAnnotationsToAgent,
            sendPayload: sendAnnotationPayloadToAgent
        )
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
    let openCurrentURL: () -> Void

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
        context.coordinator.openCurrentURL = openCurrentURL

        button.image = NSImage(
            systemSymbolName: "ellipsis",
            accessibilityDescription: "Browser Actions"
        )
        button.contentTintColor = .secondaryLabelColor
    }

    @MainActor
    final class Coordinator: NSObject {
        var canOpenCurrentURL = false
        var openCurrentURL: (() -> Void)?

        @objc func showMenu(_ sender: NSButton) {
            let menu = BrowserPanelActionsMenuBuilder.menu(
                canOpenCurrentURL: canOpenCurrentURL,
                target: self,
                openCurrentURLAction: #selector(openCurrentURL(_:))
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
    }
}

enum BrowserPanelActionsMenuBuilder {
    static func menu(
        canOpenCurrentURL: Bool,
        target: AnyObject?,
        openCurrentURLAction: Selector?
    ) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(actionItem(
            title: "Open in Default Browser",
            isEnabled: canOpenCurrentURL,
            target: target,
            action: openCurrentURLAction
        ))
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
