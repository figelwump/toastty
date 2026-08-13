import CoreState
import Foundation
import SwiftUI

/// Management window for the remote-access gateway: kill switch, pairing,
/// paired devices with revocation, tailnet origin, and the local audit trail.
struct RemoteAccessSettingsView: View {
    @ObservedObject var service: RemoteAccessService
    @State private var showsAudit = false
    @State private var originDetectionRequestID = 0
    @State private var originDetectionState: TailnetOriginDetectionState = .idle
    @State private var copiedNativeFallbackCode: String?
    private let tailnetOriginDetector: TailscaleTailnetOriginDetector

    init(
        service: RemoteAccessService,
        tailnetOriginDetector: TailscaleTailnetOriginDetector = TailscaleTailnetOriginDetector()
    ) {
        _service = ObservedObject(wrappedValue: service)
        self.tailnetOriginDetector = tailnetOriginDetector
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                gatewaySection
                if service.isEnabled {
                    pairingSection
                }
                devicesSection
                writeControlsSection
                if showsAudit {
                    auditSection
                }
            }
            .padding(20)
        }
        .frame(minWidth: 460, minHeight: 420)
        .onAppear {
            service.refreshDevices()
            service.refreshNativePairingOffer()
        }
        .task(id: originDetectionRequestID) {
            await detectTailnetOrigin(allowsReplacingExistingOrigin: originDetectionRequestID > 0)
        }
        .onChange(of: service.tailnetOrigin) {
            if case .failed = originDetectionState {
                originDetectionState = .idle
            }
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
                HStack(spacing: 8) {
                    TextField("https://your-mac.tailnet.ts.net", text: $service.tailnetOrigin)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)

                    Button {
                        originDetectionRequestID += 1
                    } label: {
                        if originDetectionState == .detecting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Detect")
                        }
                    }
                    .disabled(originDetectionState == .detecting)
                    .accessibilityLabel("Detect Tailnet origin")
                    .accessibilityIdentifier("toastty-remote-access-detect-origin")
                }
            }
            if case .failed(let message) = originDetectionState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Toastty detects this Mac’s Tailnet origin when possible. Tailscale Serve must still proxy the local gateway; only that exact origin may pair or subscribe.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func detectTailnetOrigin(allowsReplacingExistingOrigin: Bool) async {
        let originAtStart = service.tailnetOrigin
        guard allowsReplacingExistingOrigin
                || originAtStart.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        guard originDetectionState != .detecting else { return }

        originDetectionState = .detecting
        do {
            let detectedOrigin = try await tailnetOriginDetector.detectOrigin()
            try Task.checkCancellation()
            guard TailnetOriginDetectionPolicy.shouldApply(
                originAtStart: originAtStart,
                currentOrigin: service.tailnetOrigin,
                allowsReplacingExistingOrigin: allowsReplacingExistingOrigin
            ) else {
                originDetectionState = .idle
                return
            }
            service.tailnetOrigin = detectedOrigin
            originDetectionState = .idle
        } catch is CancellationError {
            originDetectionState = .idle
        } catch let error as TailscaleTailnetOriginDetectionError {
            originDetectionState = .failed(error.recoveryMessage)
        } catch {
            originDetectionState = .failed(
                TailscaleTailnetOriginDetectionError.unavailable.recoveryMessage
            )
        }
    }

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pair a phone").font(.headline)
            browserPairingSection
            Divider()
            nativePairingSection
        }
    }

    private var browserPairingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Browser")
                .font(.subheadline.weight(.semibold))
            if let code = service.currentPairingCode {
                HStack(spacing: 12) {
                    Text(code.code)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Cancel") {
                        service.invalidatePairingCode()
                    }
                }
                Text("Single use, expires after 5 minutes. New devices can read and send by default; you can disable Send below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Show Pairing Code") {
                    service.issuePairingCode()
                }
            }
        }
    }

    private var nativePairingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Native app")
                .font(.subheadline.weight(.semibold))
            Text("Scan the QR code in Toastty Mobile. The fallback code is for manual pairing and expires with the QR code.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let offer = service.currentNativePairingOffer {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    nativeOfferContent(offer, at: context.date)
                }
            } else {
                Button("Show Native Pairing QR") {
                    service.issueNativePairingOffer()
                }
            }

            if let nativePairingError = service.nativePairingError {
                Text(nativePairingError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func nativeOfferContent(_ offer: RemoteNativePairingOffer, at date: Date) -> some View {
        let isExpired = date >= offer.expiresAt
        if isExpired {
            HStack(spacing: 12) {
                Text("Pairing offer expired")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Button("Issue New QR") {
                    service.issueNativePairingOffer()
                }
                Button("Cancel") {
                    service.cancelNativePairingOffer()
                }
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                if let image = service.currentNativePairingQRCode {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 176, height: 176)
                        .accessibilityLabel("Native pairing QR code")
                        .accessibilityHint("Scan with Toastty Mobile")
                        .privacySensitive()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 36))
                        Text("QR unavailable")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: 176, height: 176)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Fallback code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(offer.fallbackCode)
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .textSelection(.enabled)
                            .privacySensitive()
                        Button(copiedNativeFallbackCode == offer.fallbackCode ? "Copied" : "Copy Code") {
                            if RemoteAccessPairingClipboard.copy(offer.fallbackCode) {
                                copiedNativeFallbackCode = offer.fallbackCode
                            }
                        }
                        .accessibilityLabel("Copy fallback code")
                        .accessibilityIdentifier("toastty-remote-access-copy-fallback-code")
                    }
                    Text(nativeOfferExpiryLabel(offer, at: date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("Issue New QR") {
                        service.issueNativePairingOffer()
                    }
                    Button("Cancel") {
                        service.cancelNativePairingOffer()
                    }
                }
            }
        }
    }

    private func nativeOfferExpiryLabel(_ offer: RemoteNativePairingOffer, at date: Date) -> String {
        RemoteAccessPairingPresentation.expiryLabel(expiresAt: offer.expiresAt, at: date)
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
            if let deviceManagementError = service.deviceManagementError {
                Text(deviceManagementError)
                    .font(.callout)
                    .foregroundStyle(.red)
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
                        Toggle("Send", isOn: Binding(
                            get: { device.scopes.contains(.send) },
                            set: { service.setDeviceSendScope($0, for: device.id) }
                        ))
                        .toggleStyle(.checkbox)
                        .help("Allow this device to send messages to sessions where remote replies are enabled.")
                        Button("Revoke", role: .destructive) {
                            service.revokeDevice(device.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var writeControlsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remote replies").font(.headline)
            Text("On by default for each active session. Turn off a session for every device until Toastty restarts, or turn off Send on a device for a persistent block. Local typing always wins.")
                .font(.caption)
                .foregroundStyle(.secondary)
            let conversations = service.writeControllableSessions
            if conversations.isEmpty {
                Text("No agent sessions available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(conversations, id: \.conversationID) { conversation in
                Toggle(isOn: Binding(
                    get: { service.isSessionWriteEnabled(conversation.conversationID) },
                    set: { service.setSessionWriteEnabled($0, for: conversation.conversationID) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(conversation.title)
                        Text("\(conversation.provider.displayName)\(conversation.placement.workspaceTitle.map { " · \($0)" } ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
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
        let kind = device.authKind == .native ? "Native app" : "Browser"
        let paired = "paired \(device.createdAt.formatted(date: .abbreviated, time: .shortened))"
        if let lastSeenAt = device.lastSeenAt {
            return "\(kind) · \(scopes) · \(paired) · last seen \(lastSeenAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return "\(kind) · \(scopes) · \(paired)"
    }

    private func auditLabel(_ entry: RemoteAccessAuditEntry) -> String {
        var label = entry.action.rawValue.replacingOccurrences(of: "_", with: " ")
        if let detail = entry.detail {
            label += " — \(detail)"
        }
        return label
    }
}

private enum TailnetOriginDetectionState: Equatable {
    case idle
    case detecting
    case failed(String)
}
