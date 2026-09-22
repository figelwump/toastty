import Foundation
import Testing
import RemoteProtocol
@testable import CoreState

struct RemoteMessageAttachmentTests {
    private func request(attachments: [RemoteMessageAttachment] = []) -> RemoteMessageSendRequest {
        .init(conversationID: RemoteConversationID(), clientRequestID: "attachment-test",
              expectedInputEpoch: .init(bindingID: UUID(), counter: 1), text: "Read this", attachments: attachments)
    }

    @Test func legacyCodecOmitsAttachmentsAndDecodesOldRequests() throws {
        let original = request()
        let encoded = try JSONEncoder().encode(original)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("attachments"))
        #expect(try JSONDecoder().decode(RemoteMessageSendRequest.self, from: encoded) == original)
        let attachment = RemoteMessageAttachment(filename: "note.txt", data: Data("Hello".utf8))
        let enriched = request(attachments: [attachment])
        #expect(try JSONDecoder().decode(RemoteMessageSendRequest.self, from: JSONEncoder().encode(enriched)) == enriched)
    }

    @Test func validatesTypeContentsCountAndDecodedLimits() {
        let valid = RemoteMessageAttachment(filename: "note.swift", data: Data("let answer = 42".utf8))
        #expect(RemoteAttachmentPolicy.validationError(for: [valid]) == nil)
        #expect(RemoteAttachmentPolicy.validationError(for: [valid, valid]) != nil)
        #expect(RemoteAttachmentPolicy.validationError(for: (0..<5).map { _ in .init(filename: "x.txt", data: valid.data) }) != nil)
        #expect(RemoteAttachmentPolicy.validationError(for: [.init(filename: "fake.jpg", data: valid.data)]) != nil)
        #expect(RemoteAttachmentPolicy.validationError(for: [.init(filename: "code.exe", data: valid.data)]) != nil)
        #expect(RemoteAttachmentPolicy.validationError(for: [.init(filename: "nul.txt", data: Data([0]))]) != nil)
        #expect(RemoteAttachmentPolicy.validationError(for: [.init(filename: "x.txt", data: Data(repeating: 65, count: RemoteAttachmentPolicy.maximumFileBytes + 1))]) != nil)
        let maximum = Data(repeating: 65, count: RemoteAttachmentPolicy.maximumFileBytes)
        #expect(RemoteAttachmentPolicy.validationError(for: [.init(filename: "a.txt", data: maximum), .init(filename: "b.txt", data: maximum)]) == nil)
        #expect(RemoteAttachmentPolicy.validationError(for: [.init(filename: "a.txt", data: maximum), .init(filename: "b.txt", data: maximum), valid]) != nil)
    }

    @Test func encodedMaximumFitsTransportAndDisplayNamesStripTerminalControls() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var value = request(attachments: (0..<2).map { _ in .init(filename: "photo.jpg", data: Data(repeating: 255, count: RemoteAttachmentPolicy.maximumFileBytes)) })
        value.text = String(repeating: "x", count: RemoteGatewayProtocol.maximumRequestBodyBytes)
        #expect(try encoder.encode(value).count < RemoteAttachmentPolicy.maximumEncodedBodyBytes)
        value.attachments = [.init(filename: "../../bad\u{1B}\r\n\u{202E}.txt", data: Data("ok".utf8))]
        #expect(value.displayText == value.text + "\n[Attachment: bad.txt]")
    }

    @Test func headerOnlyParsingUsesCanonicalAttachmentRouteAndStrictFraming() {
        let route = RemoteAttachmentPolicy.sendPath
        let length = RemoteAttachmentPolicy.maximumEncodedBodyBytes
        let head = "POST \(route)?x=1 HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n"
        guard case .request(let request, _) = RemoteGatewayHTTPRequest.parse(Data(head.utf8), headersOnly: true) else {
            Issue.record("Expected bounded attachment header without body")
            return
        }
        #expect(request.path == route)
        #expect(request.body.isEmpty)
        #expect(RemoteGatewayHTTPRequest.parse(Data(head.utf8)) == .needMoreData)
        for path in [route + "/", "/api/conversation.message.send", "/api/hello", "/api/../api/conversation.message.send-with-attachments"] {
            let raw = "POST \(path) HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n"
            #expect(RemoteGatewayHTTPRequest.parse(Data(raw.utf8), headersOnly: true) == .invalid)
        }
        for headers in ["", "Transfer-Encoding: chunked\r\n", "Content-Length: \(length + 1)\r\n", "Content-Length: 1\r\nContent-Length: 1\r\n"] {
            #expect(RemoteGatewayHTTPRequest.parse(Data("POST \(route) HTTP/1.1\r\n\(headers)\r\n".utf8), headersOnly: true) == .invalid)
        }
    }

    @Test func privateStagingPreservesBytesUsesRandomNamesAndCleansOnlyOwnedChildren() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("attachments")
        let store = RemoteMessageAttachmentStore(root: root)
        let data = Data("private upload bytes".utf8)
        let request = request(attachments: [.init(filename: "../../bad\u{1B}\n.txt", data: data)])
        let staged = try await store.stage(request.attachments)
        #expect(try Data(contentsOf: staged.files[0]) == data)
        #expect(!staged.files[0].lastPathComponent.contains("bad"))
        #expect(staged.files[0].pathExtension == "txt")
        #expect(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int == 0o700)
        #expect(try FileManager.default.attributesOfItem(atPath: staged.files[0].path)[.posixPermissions] as? Int == 0o600)
        let prompt = staged.deliveryText(for: request)
        #expect(prompt.contains(TerminalDropPayloadBuilder.shellEscapedPath(staged.files[0].path)))
        #expect(!prompt.contains("\u{1B}"))
        let protected = base.appendingPathComponent("protected")
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        let sentinel = protected.appendingPathComponent("sentinel.txt")
        try data.write(to: sentinel)
        let symlink = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: protected)
        try await store.cleanup(at: Date().addingTimeInterval(RemoteMessageAttachmentStore.retention + 60))
        #expect(!FileManager.default.fileExists(atPath: staged.directory.path))
        #expect(try Data(contentsOf: sentinel) == data)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path) == protected.path)
    }

    @Test func stagingBudgetFailsClosedAndRootSymlinkIsRejected() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("attachments")
        let store = RemoteMessageAttachmentStore(root: root, maximumBytes: 3)
        let staged = try await store.stage([.init(filename: "a.txt", data: Data("abc".utf8))])
        await #expect(throws: RemoteMessageAttachmentStore.StorageError.self) {
            try await store.stage([.init(filename: "b.txt", data: Data("d".utf8))])
        }
        await store.discard(staged)
        #expect(!FileManager.default.fileExists(atPath: staged.directory.path))
        let linked = base.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: root)
        let unsafe = RemoteMessageAttachmentStore(root: linked)
        await #expect(throws: RemoteMessageAttachmentStore.StorageError.self) {
            try await unsafe.stage([.init(filename: "b.txt", data: Data("d".utf8))])
        }
    }
}
