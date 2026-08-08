import CoreState
import SwiftUI

/// Management window for the remote-access gateway: kill switch, pairing,
/// paired devices with revocation, tailnet origin, and the local audit trail.
struct RemoteAccessSettingsView: View {
    @ObservedObject var service: RemoteAccessService
    @State private var showsAudit = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                gatewaySection
                if service.isEnabled {
                    pairingSection
                }
                devicesSection
                if showsAudit {
                    auditSection
                }
            }
            .padding(20)
        }
        .frame(minWidth: 460, minHeight: 420)
        .onAppear {
            service.refreshDevices()
        }
    }

    private var gatewaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { service.isEnabled },
                set: { service.setEnabled($0) }
            )) {
                Text("Enable Remote Access").font(.headline)
            }
            .toggleStyle(.switch)

            if let port = service.listeningPort {
                Text("Listening on 127.0.0.1:\(String(port)) · \(service.connectedClientCount) connected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Off. Phones cannot connect and all remote reads stop immediately.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let startupError = service.startupError {
                Text(startupError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            LabeledContent("Tailnet origin") {
                TextField("https://your-mac.tailnet.ts.net", text: $service.tailnetOrigin)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
            }
            Text("Serve the gateway over Tailscale with `tailscale serve` and enter the resulting HTTPS origin here. Only allowlisted origins may pair or subscribe.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pair a phone").font(.headline)
            if let code = service.currentPairingCode {
                HStack(spacing: 12) {
                    Text(code.code)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Cancel") {
                        service.invalidatePairingCode()
                    }
                }
                Text("Single use, expires after 5 minutes. Enter it on the phone's pairing screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Show Pairing Code") {
                    service.issuePairingCode()
                }
            }
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Paired devices").font(.headline)
                Spacer()
                Button(showsAudit ? "Hide Audit Log" : "Show Audit Log") {
                    showsAudit.toggle()
                }
                .buttonStyle(.link)
                if service.devices.contains(where: { $0.isRevoked == false }) {
                    Button("Revoke All", role: .destructive) {
                        service.revokeAllDevices()
                    }
                }
            }
            if service.devices.isEmpty {
                Text("No devices paired yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(service.devices) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .strikethrough(device.isRevoked)
                        Text(deviceDetail(device))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if device.isRevoked {
                        Text("Revoked")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Revoke", role: .destructive) {
                            service.revokeDevice(device.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var auditSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent activity").font(.headline)
            let entries = service.recentAuditEntries(limit: 30).reversed()
            if entries.isEmpty {
                Text("No remote-access activity recorded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.at.formatted(date: .abbreviated, time: .standard))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(auditLabel(entry))
                        .font(.caption)
                }
            }
        }
    }

    private func deviceDetail(_ device: RemoteDeviceRecord) -> String {
        let scopes = device.scopes.map(\.rawValue).sorted().joined(separator: ", ")
        if let lastSeenAt = device.lastSeenAt {
            return "\(scopes) · last seen \(lastSeenAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return scopes
    }

    private func auditLabel(_ entry: RemoteAccessAuditEntry) -> String {
        var label = entry.action.rawValue.replacingOccurrences(of: "_", with: " ")
        if let detail = entry.detail {
            label += " — \(detail)"
        }
        return label
    }
}
