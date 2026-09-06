import RemoteProtocol
import XCTest
@testable import ToasttyMobileDomain

final class GatewayPreviewClientTests: XCTestCase {
    func testPreviewAndResourceUseTypedPOSTBodiesAndNativeBearer() async throws {
        let target = RemotePreviewTarget.panel(workspaceID: UUID(), panelID: UUID())
        let content = RemotePreviewContent.html(.init(title: "Page", sourcePath: "/project/site/index.html",
                                                    html: "<p>Page</p>", revision: "1"))
        let resourceRequest = RemoteHTMLResourceRequest(target: target, expectedSourcePath: "/project/site/index.html",
                                                       relativePath: "styles/site.css")
        let transport = PreviewRecordingTransport(responses: [
            try response(RemoteGatewayHelloResponse()), try response(RemotePreviewResponse(content: content)),
            try response(RemoteHTMLResourceResponse(mimeType: "text/css", data: Data("body{}".utf8)))
        ])
        let client = try client(transport: transport)
        let loaded = try await client.preview(target)
        let resource = try await client.previewResource(resourceRequest)
        XCTAssertEqual(loaded, content)
        XCTAssertEqual(resource.data, Data("body{}".utf8))
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/hello", "/api/preview.get", "/api/preview.resource.get"])
        for request in requests.dropFirst() {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-preview-credential")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        }
        XCTAssertEqual(try ConversationEventCoding.makeDecoder().decode(RemotePreviewRequest.self,
            from: XCTUnwrap(requests[1].httpBody)).target, target)
        XCTAssertEqual(try ConversationEventCoding.makeDecoder().decode(RemoteHTMLResourceRequest.self,
            from: XCTUnwrap(requests[2].httpBody)), resourceRequest)
    }

    func testOlderHostNeverReceivesUnsupportedPreviewRequest() async throws {
        let transport = PreviewRecordingTransport(responses: [try response(RemoteGatewayHelloResponse(capabilities: []))])
        do {
            _ = try await client(transport: transport).preview(.panel(workspaceID: UUID(), panelID: UUID()))
            XCTFail("Expected unavailable preview")
        } catch let error as GatewayFailure {
            XCTAssertEqual(error, .operationCompatibility(.missingCapability(.workspacePanelPreview)))
        }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testHostResourceErrorRemainsTypedAndCancellationPropagates() async throws {
        let transport = PreviewRecordingTransport(responses: [try response(RemoteHTMLResourceResponse(error: .stale))])
        let request = RemoteHTMLResourceRequest(target: .panel(workspaceID: UUID(), panelID: UUID()),
                                               expectedSourcePath: "/project/index.html", relativePath: "x.js")
        do {
            _ = try await client(transport: transport).previewResource(request)
            XCTFail("Expected stale preview")
        } catch let error as RemotePreviewError { XCTAssertEqual(error, .stale) }
        do {
            _ = try await client(transport: PreviewCancelledTransport()).previewResource(request)
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
    }

    private func client(transport: any HTTPTransport) throws -> GatewayClient {
        GatewayClient(baseURL: try XCTUnwrap(URL(string: "https://mac.example")), transport: transport,
            credentialProvider: StaticGatewayCredentialProvider(.bearer(token: "test-preview-credential")))
    }
    private func response(_ value: some Encodable) throws -> HTTPTransportResponse {
        .init(statusCode: 200, headers: ["content-type": "application/json"],
              body: try ConversationEventCoding.makeEncoder().encode(value))
    }
}

private actor PreviewRecordingTransport: HTTPTransport {
    private var responses: [HTTPTransportResponse]
    private(set) var requests: [URLRequest] = []
    init(responses: [HTTPTransportResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw GatewayFailure.invalidResponse }
        return responses.removeFirst()
    }
}
private struct PreviewCancelledTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPTransportResponse { throw CancellationError() }
}
