import CoreState
import SwiftUI

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
                isEffectivelyVisible: isEffectivelyVisible
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
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(helpText)
    }

    private func handleAddressEditingChanged(_ isEditing: Bool) {
        if isEditing {
            activatePanel()
            addressDraft = displayedAddressString
        }
        isEditingAddressField = isEditing
        if isEditing == false {
            syncAddressDraft()
        }
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
