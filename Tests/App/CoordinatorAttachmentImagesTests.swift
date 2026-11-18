@testable import ToasttyApp
import CoreGraphics
import CoreState
import Foundation
import ImageIO
import RemoteProtocol
import Testing
import UniformTypeIdentifiers

/// The app's side of the route that serves a paired device the images
/// attached to the messages of the coordinator's chat: it installs the
/// route with the coordinator and answers only for the coordinator's own
/// conversation. The route's checks of the message and the file are in
/// `RemoteCoordinatorAttachmentImageGatewayTests`.
@MainActor
struct CoordinatorAttachmentImagesTests {
    @Test func aPairedDeviceGetsTheImagesOfTheCoordinatorsChatOnly() async throws {
        let fixture = try CoordinatorChatFixture(pairsNativeDevice: true)
        defer { fixture.tearDown() }
        let conversations = fixture.conversations
        conversations.enableGateway()
        #expect(conversations.gatewayCapabilities().contains(.coordinatorAttachmentImages) == false)
        conversations.service.installCoordinatorAttachmentImages()
        #expect(conversations.gatewayCapabilities().contains(.coordinatorAttachmentImages))
        fixture.chat.show(panelID: fixture.panelID)
        try await fixture.waitUntil("the open prompt") {
            fixture.chat.summary?.inputAvailability.allowsRemoteSend == true
        }

        // One image attached on the Mac, from anywhere on it, and one that
        // a phone sent, in the gateway's own store.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("coordinator-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let onTheMac = folder.appendingPathComponent("crash screen.png")
        try Self.png(width: 1_600, height: 900).write(to: onTheMac)
        let store = RemoteMessageAttachmentStore(
            root: URL(filePath: conversations.runtimeHome).appendingPathComponent("remote-attachments", isDirectory: true))
        let staged = try await store.stage([RemoteMessageAttachment(filename: "Photo.png", data: Self.png(width: 300, height: 500))])
        let message = RemoteAttachmentDeliveryText.text("Here is the crash screen.", paths: [onTheMac.path] + staged.files.map(\.path))
        try fixture.runTurn(1, userText: message)

        let conversationID = try #require(conversations.conversationID(ofPanel: fixture.panelID))
        var eventID: String?
        try await fixture.waitUntil("the message in the conversation") {
            let events = (try? conversations.gatewayLatestEvents(of: conversationID, credential: conversations.nativeCredential)) ?? []
            eventID = events.last { event in
                if case .userMessage(let payload) = event.payload { return payload.text == message }
                return false
            }?.eventID
            return eventID != nil
        }
        let messageID = try #require(eventID)

        let macImage = try await Self.image(conversations, conversationID, messageID, index: 0)
        #expect(macImage.error == nil)
        #expect(macImage.pixelWidth == 600)
        #expect((337...338).contains(macImage.pixelHeight ?? 0))
        let phoneImage = try await Self.image(conversations, conversationID, messageID, index: 1, size: .full)
        #expect(phoneImage.error == nil)
        #expect(phoneImage.pixelWidth == 300)
        #expect(phoneImage.pixelHeight == 500)

        // Any other conversation is refused, also with the same message.
        let other = try await Self.image(conversations, RemoteConversationID(rawValue: UUID()), messageID, index: 0)
        #expect(other.error == .denied)
        #expect(other.data == nil)
    }

    private static func image(
        _ conversations: LocalConversationFixture,
        _ conversationID: RemoteConversationID,
        _ eventID: String,
        index: Int,
        size: RemoteCoordinatorAttachmentImageRequest.Size = .thumbnail
    ) async throws -> RemoteCoordinatorAttachmentImageResponse {
        let credential = try #require(conversations.nativeCredential)
        let http = RemoteGatewayHTTPRequest(
            method: "POST",
            path: RemoteCoordinatorAttachmentImagePolicy.path,
            headers: ["tailscale-user-login": "owner@example.com", "authorization": "Bearer \(credential)"],
            body: try ConversationEventCoding.makeEncoder().encode(RemoteCoordinatorAttachmentImageRequest(
                conversationID: conversationID, eventID: eventID, attachmentIndex: index, size: size))
        )
        guard case .deferredCoordinatorAttachmentImage(let deviceID, let request) = conversations.gatewayHandler.handle(http, at: .now)
        else { throw LocalConversationFixtureError.unexpectedGatewayOutcome }
        let response = await conversations.gatewayHandler.resolveCoordinatorAttachmentImage(deviceID: deviceID, request: request)
        return try ConversationEventCoding.makeDecoder().decode(RemoteCoordinatorAttachmentImageResponse.self, from: response.body)
    }

    private static func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
