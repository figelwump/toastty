import RemoteProtocol
import SwiftUI

struct ToasttySettingsView: View {
    let presentation: ToasttySettingsPresentation
    let onUnpair: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmsUnpair = false
    @State private var isUnpairing = false

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                deviceSection
                diagnosticsSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(ToasttyDesignTokens.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("toastty-mobile-settings-done")
                }
            }
        }
        .tint(ToasttyDesignTokens.amber)
        .preferredColorScheme(.dark)
        .presentationBackground(ToasttyDesignTokens.background)
        .alert("Unpair this iPhone?", isPresented: $confirmsUnpair) {
            Button("Cancel", role: .cancel) {}
            Button("Unpair", role: .destructive) {
                Task { @MainActor in
                    isUnpairing = true
                    await onUnpair()
                    isUnpairing = false
                }
            }
            .accessibilityIdentifier("toastty-mobile-confirm-unpair")
        } message: {
            Text("Toastty will try to revoke this device on your Mac, then remove its local credential. Pair again to reconnect.")
        }
        .accessibilityIdentifier("toastty-mobile-settings")
    }

    private var connectionSection: some View {
        Section("Connection") {
            settingsRow("Host", value: presentation.host, identifier: "host")
            settingsRow(
                "Tailnet reachability",
                value: presentation.reachability.accessibilityLabel,
                identifier: "reachability"
            )
            settingsRow("Protocol", value: presentation.protocolVersion, identifier: "protocol")
            settingsRow(
                "Projection run",
                value: presentation.projectionRunID ?? "Waiting for snapshot",
                identifier: "projection-run"
            )
            settingsRow(
                "Latest projection generation",
                value: presentation.projectionGeneration.map(String.init) ?? "—",
                identifier: "projection-generation"
            )
            settingsRow(
                "Active cursor",
                value: presentation.activeConversationCursor.map(String.init) ?? "No conversation open",
                identifier: "active-cursor"
            )
        }
    }

    private var deviceSection: some View {
        Section("This device") {
            settingsRow(
                "Name",
                value: presentation.device?.name ?? "Unavailable",
                identifier: "device-name"
            )
            settingsRow(
                "Scopes",
                value: scopeSummary,
                identifier: "device-scopes"
            )
            settingsRow(
                "Credential created",
                value: credentialCreatedSummary,
                identifier: "credential-created"
            )

            Text("Device scopes and per-session remote input are managed on your Mac.")
                .font(.footnote)
                .foregroundStyle(ToasttyDesignTokens.mutedText)
                .fixedSize(horizontal: false, vertical: true)

            Button(role: .destructive) {
                confirmsUnpair = true
            } label: {
                HStack {
                    if isUnpairing { ProgressView() }
                    Text(isUnpairing ? "Unpairing…" : "Unpair this iPhone")
                    Spacer(minLength: 0)
                }
            }
            .disabled(isUnpairing)
            .accessibilityIdentifier("toastty-mobile-unpair")
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            Label("Connection diagnostics are redacted", systemImage: "hand.raised")
                .font(.subheadline)
            Text("Toastty never includes credentials, pairing secrets, transcript content, workspace paths, or conversation titles in connection diagnostics.")
                .font(.footnote)
                .foregroundStyle(ToasttyDesignTokens.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            settingsRow("Client", value: "Toastty for iPhone", identifier: "client")
            Text("Native remote access over your Tailscale tailnet.")
                .font(.footnote)
                .foregroundStyle(ToasttyDesignTokens.mutedText)
        }
    }

    private var scopeSummary: String {
        guard let scopes = presentation.device?.scopes, !scopes.isEmpty else { return "None" }
        return scopes.map(\.rawValue).sorted().joined(separator: ", ")
    }

    private var credentialCreatedSummary: String {
        guard let date = presentation.credentialCreatedAt else { return "Unavailable" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func settingsRow(_ title: String, value: String, identifier: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                Spacer(minLength: 12)
                Text(value)
                    .foregroundStyle(ToasttyDesignTokens.secondaryText)
                    .multilineTextAlignment(.trailing)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(ToasttyDesignTokens.secondaryText)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value)")
        .accessibilityIdentifier("toastty-mobile-settings-\(identifier)")
    }
}
