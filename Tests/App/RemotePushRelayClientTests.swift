import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

@Suite(.serialized)
struct RemotePushRelayClientTests {
    @Test func statusHandlingDropsAmbiguousEventsWithoutRetryAndKeepsCleanupUntilConfirmed() async throws {
        let session = RemotePushRelayClient.makeSession(protocolClasses: [PushRelayTestURLProtocol.self])
        defer { session.invalidateAndCancel() }
        let client = RemotePushRelayClient(session: session)
        let relay = try #require(RemotePushConfiguration(relayURL: URL(string: "https://push.example.com")!))
        let token = String(repeating: "A", count: 43)
        let grant = RemoteDevicePushRegistration(deviceID: UUID(), registration: .init(registrationID: UUID(), sendToken: token, relayID: relay.relayID), configuration: relay)
        let notification = RemotePushSessionNotification(eventID: UUID(), conversationID: RemoteConversationID(), sessionTitle: "Fix checkout\n", status: .needsApproval)
        for (status, expected) in [(202, RemotePushSendOutcome.accepted), (401, .registrationUnavailable), (404, .registrationUnavailable), (410, .registrationUnavailable), (429, .dropped), (503, .dropped)] {
            PushRelayTestURLProtocol.state.reset(status: status)
            #expect(await client.send(notification, to: grant) == expected)
            let requests = PushRelayTestURLProtocol.state.requests
            #expect(requests.count == 1)
            let request = try #require(requests.first)
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/v1/registrations/\(grant.registrationID.uuidString.lowercased())/notifications")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        }
        for (status, expected) in [(204, true), (404, true), (410, true), (401, false), (429, false), (503, false)] {
            PushRelayTestURLProtocol.state.reset(status: status)
            #expect(await client.revoke(grant) == expected)
            #expect(PushRelayTestURLProtocol.state.requests.count == 1)
            #expect(PushRelayTestURLProtocol.state.requests.first?.httpMethod == "DELETE")
        }
        PushRelayTestURLProtocol.state.reset(status: 202, responseBody: Data(repeating: 65, count: 4097))
        #expect(await client.send(notification, to: grant) == .accepted)
        #expect(PushRelayTestURLProtocol.state.requests.count == 1)
        PushRelayTestURLProtocol.state.reset(status: 202, fails: true)
        #expect(await client.send(notification, to: grant) == .dropped)
        #expect(PushRelayTestURLProtocol.state.requests.count == 1)
    }

    @Test func productionSessionRefusesRedirectsAndDisablesCookiesAndCache() async throws {
        let session = RemotePushRelayClient.makeSession(protocolClasses: [PushRelayTestURLProtocol.self])
        defer { session.invalidateAndCancel() }
        #expect(session.configuration.timeoutIntervalForRequest == 10)
        #expect(session.configuration.timeoutIntervalForResource == 15)
        #expect(session.configuration.urlCache == nil)
        #expect(session.configuration.httpCookieStorage == nil)
        let relay = try #require(RemotePushConfiguration(relayURL: URL(string: "https://push.example.com/")!))
        let grant = RemoteDevicePushRegistration(deviceID: UUID(), registration: .init(registrationID: UUID(), sendToken: String(repeating: "A", count: 43), relayID: relay.relayID), configuration: relay)
        let notification = RemotePushSessionNotification(eventID: UUID(), conversationID: RemoteConversationID(), sessionTitle: String(repeating: "\"\\/", count: 170), status: .ready)
        #expect(try JSONEncoder().encode(notification).count <= RemotePushPolicy.maximumBodyBytes)
        PushRelayTestURLProtocol.state.reset(status: 307, redirectURL: URL(string: "https://other.example.com/leak"))
        #expect(await RemotePushRelayClient(session: session).send(notification, to: grant) == .dropped)
        #expect(PushRelayTestURLProtocol.state.requests.count == 1)
        #expect(PushRelayTestURLProtocol.state.requests.first?.url?.host == "push.example.com")
        #expect(PushRelayTestURLProtocol.state.requests.first?.url?.path == "/v1/registrations/\(grant.registrationID.uuidString.lowercased())/notifications")
    }
}

private final class PushRelayTestURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = PushRelayTestResponseState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = Self.state.record(request)
        if response.fails {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        if let redirectURL = response.redirectURL {
            var redirected = request
            redirected.url = redirectURL
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: http)
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class PushRelayTestResponseState: @unchecked Sendable {
    struct Response { var status: Int; var body: Data; var fails: Bool; var redirectURL: URL? }
    private let lock = NSLock()
    private var response = Response(status: 202, body: Data("{}".utf8), fails: false, redirectURL: nil)
    private var storedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    func reset(status: Int, responseBody: Data = Data("{}".utf8), fails: Bool = false, redirectURL: URL? = nil) {
        lock.lock()
        defer { lock.unlock() }
        response = .init(status: status, body: responseBody, fails: fails, redirectURL: redirectURL)
        storedRequests = []
    }

    func record(_ request: URLRequest) -> Response {
        lock.lock()
        defer { lock.unlock() }
        storedRequests.append(request)
        return response
    }
}
