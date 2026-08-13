import AppKit
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

@MainActor
struct RemoteAccessPairingPresentationTests {
    @Test func pendingInteractionPreviewUsesFirstPendingPrompt() {
        let resolved = interaction(prompt: "Resolved prompt", state: .resolved)
        let pending = interaction(prompt: "  Allow\n   this operation?  ")
        let later = interaction(prompt: "Later prompt")

        #expect(RemotePendingInteractionPreviewFormatter.make(from: [resolved, pending, later])?.prompt == "Allow this operation?")
    }

    @Test func pendingInteractionPreviewIsGraphemeSafeAndBounded() {
        let preview = RemotePendingInteractionPreviewFormatter.make(
            from: [interaction(prompt: String(repeating: "👨🏽‍💻", count: 8))],
            maximumGraphemeCount: 5
        )

        #expect(preview?.prompt == "👨🏽‍💻👨🏽‍💻👨🏽‍💻👨🏽‍💻…")
        #expect(preview?.prompt.count == 5)
    }

    @Test func pendingInteractionPreviewOmitsMissingOrBlankPrompts() {
        #expect(RemotePendingInteractionPreviewFormatter.make(from: []) == nil)
        #expect(RemotePendingInteractionPreviewFormatter.make(from: [interaction(prompt: " \n ")]) == nil)
    }

    @Test func qrRendererRejectsPayloadsOverWireBudget() {
        let oversized = String(repeating: "x", count: RemoteNativePairingQRPayload.maximumEncodedByteCount + 1)

        #expect(RemoteAccessPairingQRCode.image(payload: oversized) == nil)
    }

    @Test func qrRendererAcceptsBoundedPairingPayload() throws {
        let secret = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        #expect(secret.count == 43)
        let payload = try RemoteNativePairingQRPayload(
            gatewayURL: URL(string: "https://host.tailnet.ts.net")!,
            offerID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            secret: secret,
            expiresAt: Date(timeIntervalSince1970: 1_786_300_120)
        ).encodedString()

        #expect(Data(payload.utf8).count < RemoteNativePairingQRPayload.maximumEncodedByteCount)
        #expect(RemoteAccessPairingQRCode.image(payload: payload) != nil)
    }

    @Test func nativePairingGatewayUsesOnlyConfiguredHTTPSOrigin() {
        #expect(RemoteAccessService.publicGatewayURL(from: "mac.tailnet.ts.net")?.absoluteString == "https://mac.tailnet.ts.net")
        #expect(RemoteAccessService.publicGatewayURL(from: "HTTPS://MAC.TAILNET.TS.NET:443/")?.absoluteString == "https://mac.tailnet.ts.net")
        #expect(RemoteAccessService.publicGatewayURL(from: "https://mac.tailnet.ts.net/")?.absoluteString == "https://mac.tailnet.ts.net")
        #expect(RemoteAccessService.publicGatewayURL(from: "http://127.0.0.1:42871") == nil)
        #expect(RemoteAccessService.publicGatewayURL(from: "https://evil.example") == nil)
        #expect(RemoteAccessService.publicGatewayURL(from: "https://foo.ts.net.evil") == nil)
        #expect(RemoteAccessService.publicGatewayURL(from: "https://ts.net") == nil)
        #expect(RemoteAccessService.publicGatewayURL(from: "https://mac.tailnet.ts.net:8443") == nil)
        #expect(RemoteAccessService.publicGatewayURL(from: "https://user@mac.tailnet.ts.net") == nil)
        #expect(RemoteAccessService.publicGatewayURL(from: "https://mac.tailnet.ts.net/pair?secret=value") == nil)
        #expect(RemoteAccessService.publicGatewayURL(from: "https://mac.tailnet.ts.net/#fragment") == nil)
    }

    @Test func nativePairingExpiryLabelUsesClockStyleFormatting() {
        let now = Date(timeIntervalSince1970: 1_786_300_000)

        #expect(RemoteAccessPairingPresentation.expiryLabel(
            expiresAt: now.addingTimeInterval(119),
            at: now
        ) == "Expires in 1:59")
        #expect(RemoteAccessPairingPresentation.expiryLabel(
            expiresAt: now.addingTimeInterval(-1),
            at: now
        ) == "Expires in 0:00")
    }

    @Test func nativeFallbackCodeCopiesToRequestedPasteboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.clearContents() }

        #expect(RemoteAccessPairingClipboard.copy("2345-6789-ABCD", to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "2345-6789-ABCD")
    }

    @Test func remoteAccessSourcesDoNotLogSensitiveSourceValues() throws {
        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/App/RemoteAccess")
        let files = try FileManager.default.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        let source = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        let forbiddenLogFragments = [
            #"metadata: ["path""#,
            #"metadata: ["host""#,
            #"metadata: ["hostname""#,
            #"metadata: ["title""#,
            #"metadata: ["prompt""#,
            #"metadata: ["error": "\(error)"#,
            #"error.localizedDescription"#,
        ]

        for fragment in forbiddenLogFragments {
            #expect(source.contains(fragment) == false)
        }
    }

    private func interaction(
        prompt: String,
        state: RemotePendingInteraction.State = .pending
    ) -> RemotePendingInteraction {
        RemotePendingInteraction(
            id: .init(rawValue: UUID().uuidString),
            kind: .permission,
            prompt: prompt,
            inputEpoch: RemoteInputEpoch(
                bindingID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                counter: 1
            ),
            presentedAt: Date(timeIntervalSince1970: 1_786_300_000),
            state: state
        )
    }
}
