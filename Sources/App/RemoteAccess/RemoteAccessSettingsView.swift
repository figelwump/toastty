import AppKit
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
        Form {
            gatewaySection
            if service.isReady {
                pairingSection
            }
            devicesSection
            if showsAudit {
                auditSection
            }
        }
        .formStyle(.grouped)
        .background(WindowInitialFocusClearer())
        .frame(minWidth: 480, minHeight: 460)
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
        Section {
            Toggle(isOn: Binding(
                get: { service.isEnabled },
                set: { service.setEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Enable Remote Access")
                        if case .starting = service.activationState {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                    Text(gatewayStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if let startupError = service.startupError {
                Text(startupError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            LabeledContent("Tailnet origin") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        TextField("Tailnet origin", text: $service.tailnetOrigin)
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)

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
                    if originDetectionState == .detecting {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Detecting Tailnet origin…")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: "Example: https://your-mac.tailnet.ts.net")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if case .failed(let message) = originDetectionState {
                    Text(message)
                }
                Text("Toastty detects this Mac’s Tailnet origin when possible. Tailscale Serve must still proxy the local gateway; only that exact origin may pair or subscribe.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var gatewayStatusText: String {
        switch service.activationState {
        case .off, .failed:
            return "Off — phones cannot connect and all remote reads stop immediately."
        case .starting:
            return "Starting — preparing conversations before phones can connect."
        case .ready(let port):
            return "Listening on 127.0.0.1:\(String(port)) · \(service.connectedClientCount) connected"
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
        Section {
            if let offer = service.currentNativePairingOffer {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    nativeOfferContent(offer, at: context.date)
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Toastty Mobile")
                        Text("Pair a phone by scanning a QR code.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show Pairing QR") {
                        service.issueNativePairingOffer()
                    }
                }
            }

            if let nativePairingError = service.nativePairingError {
                Text(nativePairingError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Pair a Phone")
        } footer: {
            Text("The QR code is single use. If the phone can’t scan it, enter the fallback code manually; it expires with the QR code.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func nativeOfferContent(_ offer: RemoteNativePairingOffer, at date: Date) -> some View {
        let isExpired = date >= offer.expiresAt
        if isExpired {
            HStack {
                Label("Pairing offer expired", systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Issue New QR") {
                    service.issueNativePairingOffer()
                }
                Button("Cancel") {
                    service.cancelNativePairingOffer()
                }
            }
        } else {
            VStack(spacing: 12) {
                if let image = service.currentNativePairingQRCode {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 180, height: 180)
                        .padding(8)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10))
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
                    .frame(width: 180, height: 180)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }

                HStack(spacing: 8) {
                    Text(offer.fallbackCode)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                        .privacySensitive()
                    Button(copiedNativeFallbackCode == offer.fallbackCode ? "Copied" : "Copy") {
                        if RemoteAccessPairingClipboard.copy(offer.fallbackCode) {
                            copiedNativeFallbackCode = offer.fallbackCode
                        }
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Copy fallback code")
                    .accessibilityIdentifier("toastty-remote-access-copy-fallback-code")
                }

                Text(nativeOfferExpiryLabel(offer, at: date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button("Issue New QR") {
                        service.issueNativePairingOffer()
                    }
                    Button("Cancel") {
                        service.cancelNativePairingOffer()
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private func nativeOfferExpiryLabel(_ offer: RemoteNativePairingOffer, at date: Date) -> String {
        RemoteAccessPairingPresentation.expiryLabel(expiresAt: offer.expiresAt, at: date)
    }

    private var devicesSection: some View {
        Section {
            if service.devices.isEmpty {
                Text("No devices paired yet.")
                    .foregroundStyle(.secondary)
            }
            if let deviceManagementError = service.deviceManagementError {
                Text(deviceManagementError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            ForEach(service.devices) { device in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .strikethrough(device.isRevoked)
                        Text(deviceDetail(device))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let lastSeenAt = device.lastSeenAt {
                            Text("Last seen \(lastSeenAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
            }
        } header: {
            HStack {
                Text("Paired Devices")
                Spacer()
                Button(showsAudit ? "Hide Audit Log" : "Show Audit Log") {
                    showsAudit.toggle()
                }
                .buttonStyle(.link)
                .font(.caption)
                if service.devices.contains(where: { $0.isRevoked == false }) {
                    Button("Revoke All", role: .destructive) {
                        service.revokeAllDevices()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var auditSection: some View {
        Section("Recent Activity") {
            let entries = service.recentAuditEntries(limit: 30).reversed()
            if entries.isEmpty {
                Text("No remote-access activity recorded.")
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
        let kind = device.authKind == .native ? "Native app" : "Browser"
        return "\(kind) · paired \(device.createdAt.formatted(date: .abbreviated, time: .shortened))"
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

/// AppKit focuses the window's first text field when it opens, which selects the
/// tailnet origin field's contents. Clear the initial first responder so the
/// window opens with nothing focused; clicking the field still edits normally.
private struct WindowInitialFocusClearer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ClearingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ClearingView: NSView {
        private var hasCleared = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !hasCleared, let window else { return }
            hasCleared = true
            window.initialFirstResponder = nil
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                if window.firstResponder is NSTextView {
                    window.makeFirstResponder(nil)
                }
            }
        }
    }
}
