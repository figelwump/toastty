@testable import CoreState
import CoreGraphics
import Foundation
import ImageIO
import RemoteProtocol
import Testing
import UniformTypeIdentifiers

/// The route that serves a device the images attached to the user messages
/// of the coordinator's chat. It is a boundary of what a paired device can
/// read on the Mac: the device names a message and a place in its list of
/// files, and the Mac serves only an image that its own copy of that user
/// message lists. Which conversation is the coordinator's is in
/// `CoordinatorChatSendPathTests`.
private let coordinatorConversationID = RemoteConversationID(rawValue: UUID())
private let otherConversationID = RemoteConversationID(rawValue: UUID())

@MainActor
struct RemoteCoordinatorAttachmentImageGatewayTests {
    private typealias Support = RemoteGatewayRequestHandlerTests

    private static let identity = "owner@example.com"
    private static let coordinatorID = coordinatorConversationID
    private static let otherID = otherConversationID

    // MARK: - Codec

    @Test func theRequestAndTheAnswerRoundTripAndAnAnswerIsAnImageOrAnError() throws {
        let decoder = ConversationEventCoding.makeDecoder()
        let encoder = ConversationEventCoding.makeEncoder()
        let request = RemoteCoordinatorAttachmentImageRequest(
            conversationID: Self.coordinatorID, eventID: "claude:abc", attachmentIndex: 1, size: .full)
        #expect(try decoder.decode(RemoteCoordinatorAttachmentImageRequest.self, from: encoder.encode(request)) == request)
        #expect(request.isValid)
        var invalid = request
        invalid.attachmentIndex = -1
        #expect(invalid.isValid == false)
        invalid = request
        invalid.eventID = ""
        #expect(invalid.isValid == false)

        let image = RemoteCoordinatorAttachmentImageResponse(mimeType: "image/jpeg", data: Data([1, 2]), pixelWidth: 2, pixelHeight: 1)
        #expect(try decoder.decode(RemoteCoordinatorAttachmentImageResponse.self, from: encoder.encode(image)) == image)
        let refused = RemoteCoordinatorAttachmentImageResponse(error: .denied)
        #expect(try decoder.decode(RemoteCoordinatorAttachmentImageResponse.self, from: encoder.encode(refused)) == refused)
        // Half an image, or an image with an error, is not an answer.
        for json in [
            #"{"protocolVersion":"1.0","mimeType":"image/jpeg","data":"AQI="}"#,
            #"{"protocolVersion":"1.0","mimeType":"image/jpeg","data":"AQI=","pixelWidth":2,"pixelHeight":1,"error":"denied"}"#,
            #"{"protocolVersion":"1.0"}"#,
        ] {
            #expect(throws: DecodingError.self) {
                try decoder.decode(RemoteCoordinatorAttachmentImageResponse.self, from: Data(json.utf8))
            }
        }
        // A refusal that this client does not know reads as unsupported.
        let future = try decoder.decode(
            RemoteCoordinatorAttachmentImageResponse.self, from: Data(#"{"protocolVersion":"1.0","error":"quota"}"#.utf8))
        #expect(future.error == .unsupported)
    }

    // MARK: - Hello and the route

    @Test func helloAdvertisesTheImagesOnlyWithTheCoordinatorsEvents() throws {
        let (handler, _, _) = Support.makeHandler()
        func capabilities() throws -> [RemoteGatewayCapability] {
            guard case .respond(let response) = handler.handle(
                Support.request("GET", "/api/hello", headerFields: [], body: Data()), at: Support.now
            ) else { throw CocoaError(.coderInvalidValue) }
            return try JSONDecoder().decode(RemoteGatewayHelloResponse.self, from: response.body).capabilities
        }
        #expect(try capabilities().contains(.coordinatorAttachmentImages) == false)
        handler.coordinatorConversationEventsHandler = { _ in [] }
        #expect(try capabilities().contains(.coordinatorAttachmentImages))
    }

    @Test func onlyAPairedDeviceWithReadAccessReachesTheRead() throws {
        let (handler, store, _) = Support.makeHandler()
        handler.coordinatorConversationEventsHandler = { _ in [] }
        let native = try Support.nativeCredential(handler: handler, store: store, identity: Self.identity)
        let headers = [("authorization", "Bearer \(native.credential)"), ("tailscale-user-login", Self.identity)]
        let body = try ConversationEventCoding.makeEncoder().encode(RemoteCoordinatorAttachmentImageRequest(
            conversationID: Self.coordinatorID, eventID: "e1", attachmentIndex: 0, size: .thumbnail))
        func outcome(
            _ method: String = "POST", headers override: [(String, String)]? = nil
        ) -> RemoteGatewayRequestHandler.Outcome {
            handler.handle(
                Support.request(method, RemoteCoordinatorAttachmentImagePolicy.path,
                                headerFields: override ?? headers, body: body),
                at: Support.now
            )
        }
        func status(_ outcome: RemoteGatewayRequestHandler.Outcome) -> Int? {
            if case .respond(let response) = outcome { return response.status }
            return nil
        }

        // Showing the chat needs read access only.
        #expect(try store.setScopes([.read], forDevice: native.device.id) == true)
        guard case .deferredCoordinatorAttachmentImage(let deviceID, let deferred) = outcome() else {
            Issue.record("A device with read access reaches the read")
            return
        }
        #expect(deviceID == native.device.id)
        #expect(deferred.eventID == "e1")

        #expect(status(outcome(headers: [("tailscale-user-login", Self.identity)])) == 401)
        #expect(status(outcome(headers: [("authorization", "Bearer unknown"), ("tailscale-user-login", Self.identity)])) == 401)
        #expect((status(outcome("GET")) ?? 0) >= 400)

        // A request that does not name one file of one message.
        for bad in [
            Data("{}".utf8),
            try ConversationEventCoding.makeEncoder().encode(RemoteCoordinatorAttachmentImageRequest(
                conversationID: Self.coordinatorID, eventID: "e1", attachmentIndex: -1, size: .thumbnail)),
            Data(repeating: 32, count: RemoteCoordinatorAttachmentImagePolicy.maximumRequestBodyBytes + 1),
        ] {
            let result = handler.handle(
                Support.request("POST", RemoteCoordinatorAttachmentImagePolicy.path, headerFields: headers, body: bad),
                at: Support.now)
            #expect(status(result) == 400)
        }

        // A revoked device does not reach the read.
        #expect(try store.revokeDevice(native.device.id, at: Support.now))
        #expect(status(outcome()) == 401)
    }

    // MARK: - What the Mac serves

    @Test func anImageOfAUserMessageIsServedNewlyEncodedAtBothSizes() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let wide = try folder.png("wide screenshot.png", width: 3_000, height: 1_000, opaque: true)
        let clear = try folder.png("icon.png", width: 800, height: 800, opaque: false)
        let fixture = try Fixture(paths: [wide, clear, folder.file("notes.txt", Data("hi".utf8))])

        let thumbnail = try await fixture.image(index: 0, size: .thumbnail)
        #expect(thumbnail.mimeType == "image/jpeg")
        #expect(thumbnail.pixelWidth == 600)
        #expect(thumbnail.pixelHeight == 200)
        #expect(try Self.decodedSize(thumbnail.data) == CGSize(width: 600, height: 200))
        // A new file from the decoded pixels, not the file's own bytes.
        #expect(thumbnail.data != (try Data(contentsOf: URL(fileURLWithPath: wide))))

        let full = try await fixture.image(index: 0, size: .full)
        #expect(full.pixelWidth == 3_000)
        #expect(full.pixelHeight == 1_000)

        // An image with transparency keeps it, as a PNG.
        let icon = try await fixture.image(index: 1, size: .thumbnail)
        #expect(icon.mimeType == "image/png")
        #expect(icon.pixelWidth == 600)
    }

    @Test func everyRequestOutsideTheChatsAttachedImagesIsRefused() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let image = try folder.png("shot.png", width: 40, height: 30, opaque: true)
        let outside = try folder.png("outside/secret.png", width: 40, height: 30, opaque: true)
        let link = folder.url("link.png")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outside)
        let linkedFolder = folder.url("linked")
        try FileManager.default.createSymbolicLink(atPath: linkedFolder.path, withDestinationPath: folder.url("outside").path)
        let renamedText = try folder.file("notes.png", Data("not an image at all".utf8))
        let text = try folder.file("notes.txt", Data("plain".utf8))
        let missing = folder.url("gone.png").path
        let huge = folder.url("huge.png")
        #expect(FileManager.default.createFile(atPath: huge.path, contents: nil))
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(RemoteCoordinatorAttachmentImagePolicy.maximumSourceBytes + 1))
        try handle.close()

        let fixture = try Fixture(paths: [
            image, link.path, linkedFolder.appendingPathComponent("secret.png").path,
            renamedText, text, missing, huge.path,
        ])
        // The message's own image is served, so each refusal is about the
        // request.
        #expect(try await fixture.image(index: 0, size: .thumbnail).pixelWidth == 40)

        // An index past the message's files.
        #expect(try await fixture.refusal(index: 7) == .denied)
        // A message that is not the user's, though its text lists a file.
        #expect(try await fixture.refusal(eventID: "assistant", index: 0) == .denied)
        // A message the Mac does not have.
        #expect(try await fixture.refusal(eventID: "unknown", index: 0) == .missing)
        // Another conversation's message.
        #expect(try await fixture.refusal(conversationID: Self.otherID, eventID: "other", index: 0) == .denied)
        // A symbolic link to a file outside, as the file or in its folders.
        #expect(try await fixture.refusal(index: 1) == .denied)
        #expect(try await fixture.refusal(index: 2) == .denied)
        // A text file named as an image, and a file that is not an image.
        #expect(try await fixture.refusal(index: 3) == .unsupported)
        #expect(try await fixture.refusal(index: 4) == .unsupported)
        // A file that is gone, and one too large to read.
        #expect(try await fixture.refusal(index: 5) == .missing)
        #expect(try await fixture.refusal(index: 6) == .tooLarge)

        // A device revoked after its request reached the read is refused,
        // also for the image it could read before.
        #expect(try fixture.store.revokeDevice(fixture.deviceID, at: Support.now))
        #expect(try await fixture.refusal(index: 0) == .denied)
    }

    @Test func anImageThatWouldDecodeToMorePixelsThanTheLimitIsRefused() throws {
        // A small file can decode to a huge image; the Mac reads the size
        // from the header first. Here the limit is lowered to this image.
        let folder = try Folder()
        defer { folder.remove() }
        let data = try Data(contentsOf: URL(fileURLWithPath: folder.png("wide.png", width: 120, height: 100, opaque: true)))
        #expect(throws: RemotePreviewError.tooLarge) {
            try RemoteCoordinatorAttachmentImageReader.encodedImage(
                from: data, maximumPixelSize: 600, maximumSourcePixels: 11_999)
        }
        let atTheLimit = try RemoteCoordinatorAttachmentImageReader.encodedImage(
            from: data, maximumPixelSize: 600, maximumSourcePixels: 12_000)
        #expect(atTheLimit.pixelWidth == 120)
    }

    // MARK: - Support

    private static func decodedSize(_ data: Data?) throws -> CGSize {
        let data = try #require(data)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return CGSize(width: image.width, height: image.height)
    }

    /// The coordinator's conversation with one user message that lists
    /// `paths`, an agent message whose text lists them too, and another
    /// conversation's user message that lists them, from a paired device
    /// with read access.
    private struct Fixture {
        let handler: RemoteGatewayRequestHandler
        let store: RemoteDeviceStore
        let deviceID: UUID

        @MainActor
        init(paths: [String]) throws {
            let message = CoordinatorMessageHeader.quickEntryMessage(
                .init(project: .init(id: UUID(), title: "toastty"), agent: "claude"),
                text: "Here is the crash screen.",
                attachmentPaths: paths
            )
            func event(_ conversationID: RemoteConversationID, _ eventID: String, _ payload: ConversationEventPayload) -> ConversationEvent {
                ConversationEvent(
                    conversationID: conversationID, sequence: 1, eventID: eventID, timestamp: Support.now,
                    provider: .claude, payload: payload)
            }
            let coordinatorEvents = [
                event(coordinatorConversationID, "user", .userMessage(.init(text: message, origin: .remote))),
                event(coordinatorConversationID, "assistant", .assistantMessage(.init(text: message, phase: .final))),
            ]
            let (handler, store, _) = Support.makeHandler()
            // The Mac answers only for the coordinator's conversation; the
            // app's side of this is in `CoordinatorChatSendPathTests`.
            handler.coordinatorConversationEventsHandler = { conversationID in
                conversationID == coordinatorConversationID ? coordinatorEvents : nil
            }
            let native = try Support.nativeCredential(
                handler: handler, store: store, identity: RemoteCoordinatorAttachmentImageGatewayTests.identity)
            #expect(try store.setScopes([.read], forDevice: native.device.id) == true)
            self.handler = handler
            self.store = store
            self.deviceID = native.device.id
        }

        @MainActor
        func response(
            conversationID: RemoteConversationID = coordinatorConversationID,
            eventID: String = "user",
            index: Int,
            size: RemoteCoordinatorAttachmentImageRequest.Size = .thumbnail
        ) async throws -> RemoteCoordinatorAttachmentImageResponse {
            let http = await handler.resolveCoordinatorAttachmentImage(
                deviceID: deviceID,
                request: .init(conversationID: conversationID, eventID: eventID, attachmentIndex: index, size: size)
            )
            #expect(http.status == 200)
            return try ConversationEventCoding.makeDecoder().decode(RemoteCoordinatorAttachmentImageResponse.self, from: http.body)
        }

        @MainActor
        func image(index: Int, size: RemoteCoordinatorAttachmentImageRequest.Size) async throws -> RemoteCoordinatorAttachmentImageResponse {
            let answer = try await response(index: index, size: size)
            #expect(answer.error == nil, "file \(index): \(String(describing: answer.error))")
            return answer
        }

        @MainActor
        func refusal(
            conversationID: RemoteConversationID = coordinatorConversationID,
            eventID: String = "user",
            index: Int
        ) async throws -> RemotePreviewError? {
            let answer = try await response(conversationID: conversationID, eventID: eventID, index: index)
            #expect(answer.data == nil)
            return answer.error
        }
    }

    /// A temporary folder, under `/var/folders`, so the Mac's `/var` alias
    /// is in every path, as for the files a phone sends.
    private struct Folder {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-images-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func url(_ name: String) -> URL { root.appendingPathComponent(name) }

        func file(_ name: String, _ data: Data) throws -> String {
            let url = url(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url.path
        }

        func png(_ name: String, width: Int, height: Int, opaque: Bool) throws -> String {
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: opaque ? 1 : 0.5))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = try #require(context.makeImage())
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            return try file(name, data as Data)
        }
    }
}
