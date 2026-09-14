import SwiftUI

struct WebPanelAnnotationHeaderAccessory<Runtime: WebPanelAnnotationRuntime>: View {
    let panelID: UUID
    @ObservedObject var runtime: Runtime
    let canAnnotate: Bool
    let sendCandidates: [BrowserScreenshotSendCandidate]
    let activatePanel: () -> Void
    let sendAvailability: (BrowserScreenshotSendCandidate) -> BrowserAnnotationSendAvailability
    let sendPayloadToAgent: (String, BrowserScreenshotSendCandidate) -> Bool

    @State private var isClearConfirmationPresented = false

    var body: some View {
        HStack(spacing: 3) {
            annotationToggle
            if runtime.annotationState.hasDrafts {
                annotationSendMenu
                annotationClearButton
            }
        }
    }

    private var annotationToggle: some View {
        Button {
            activatePanel()
            runtime.setAnnotationModeEnabled(runtime.annotationState.isAnnotationModeEnabled == false)
        } label: {
            headerIcon(
                systemImage: "pencil.tip.crop.circle",
                isDisabled: canAnnotate == false,
                isActive: runtime.annotationState.isAnnotationModeEnabled,
                fontSize: 12
            )
            .overlay(alignment: .topTrailing) {
                if runtime.annotationState.draftCount > 0 {
                    BrowserAnnotationCountBadge(count: runtime.annotationState.draftCount)
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(canAnnotate == false)
        .help(
            canAnnotate == false
                ? runtime.annotationSource.unavailableHelp
                : (runtime.annotationState.isAnnotationModeEnabled
                    ? "Exit Annotation Mode"
                    : runtime.annotationSource.annotateLabel)
        )
        .accessibilityLabel(runtime.annotationSource.annotateLabel)
        .accessibilityIdentifier(accessibilityID(action: "toggle"))
    }

    private var isSendDisabled: Bool {
        runtime.isAnnotationSendInFlight || runtime.isAnnotationEditorActive
    }

    private var annotationSendMenu: some View {
        Menu {
            Section("Send to Agent") {
                BrowserAnnotationSendMenuItems(
                    candidates: sendCandidates,
                    availability: sendAvailability,
                    send: sendAnnotations(to:)
                )
            }
        } label: {
            headerIcon(systemImage: "paperplane", isDisabled: isSendDisabled)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .disabled(isSendDisabled)
        .help(runtime.isAnnotationSendInFlight ? "Sending Annotations" : sendLabel)
        .accessibilityLabel(sendLabel)
        .accessibilityIdentifier(accessibilityID(action: "send"))
    }

    private var annotationClearButton: some View {
        Button {
            isClearConfirmationPresented = true
        } label: {
            headerIcon(systemImage: "xmark.circle", isDisabled: runtime.isAnnotationSendInFlight)
        }
        .buttonStyle(.plain)
        .disabled(runtime.isAnnotationSendInFlight)
        .help("Clear \(runtime.annotationSource.label) Annotations")
        .accessibilityLabel("Clear \(runtime.annotationSource.label) Annotations")
        .accessibilityIdentifier(accessibilityID(action: "clear"))
        .confirmationDialog(
            BrowserAnnotationCopy.clearConfirmationTitle(draftCount: runtime.annotationState.draftCount),
            isPresented: $isClearConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                runtime.clearAnnotations(exitAnnotationMode: false)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var sendLabel: String {
        "Send \(runtime.annotationSource.label) Annotations to Agent"
    }

    private func accessibilityID(action: String) -> String {
        "panel.header.\(runtime.annotationSource.rawValue).annotations.\(action).\(panelID.uuidString)"
    }

    private func headerIcon(
        systemImage: String,
        isDisabled: Bool,
        isActive: Bool = false,
        fontSize: CGFloat = 10
    ) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(
                isDisabled
                    ? ToastyTheme.inactiveText
                    : (isActive ? ToastyTheme.accent : ToastyTheme.primaryText)
            )
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
    }

    private func sendAnnotations(to candidate: BrowserScreenshotSendCandidate) {
        activatePanel()
        BrowserAnnotationSendFlow.send(
            runtime: runtime,
            candidate: candidate,
            availability: sendAvailability,
            sendPayload: sendPayloadToAgent
        )
    }
}
