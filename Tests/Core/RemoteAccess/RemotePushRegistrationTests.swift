import Foundation
import RemoteProtocol
import Testing
@testable import CoreState

struct RemotePushRegistrationTests {
    static let now = RemoteDeviceStoreTests.now
    static let configuration = RemotePushConfiguration(relayURL: URL(string: "https://push.example.com")!)!
    static let token = Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")

    static func pair(_ store: RemoteDeviceStore) throws -> (UUID, String) {
        let offer = try store.issueNativePairingOffer(gatewayURL: RemoteDeviceStoreTests.gatewayURL, at: now)
        guard case .paired(let device, let token) = try store.redeemNativePairingOffer(
            using: .qr(offerID: offer.id, secret: offer.qrPayload.secret), deviceName: "Phone",
            tailscaleLogin: RemoteDeviceStoreTests.tailscaleLogin, at: now
        ) else { throw CocoaError(.coderInvalidValue) }
        return (device.id, token)
    }

    static func registration(_ id: UUID = UUID()) -> RemoteGatewayPushRegistration {
        .init(registrationID: id, sendToken: token, relayID: configuration.relayID)
    }

    @Test func replacementAndRevocationRetainCleanupAcrossReload() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "push-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "devices.json")
        let store = RemoteDeviceStore(fileURL: url)
        let (deviceID, _) = try Self.pair(store)
        let first = Self.registration()
        let second = Self.registration()
        try store.setPushRegistration(first, forDevice: deviceID, configuration: Self.configuration)
        try store.setPushRegistration(first, forDevice: deviceID, configuration: Self.configuration)
        #expect(store.pendingPushCleanup.isEmpty)
        try store.setPushRegistration(second, forDevice: deviceID, configuration: Self.configuration)
        #expect(store.pendingPushCleanup.map(\.registrationID) == [first.registrationID])
        try store.revokeDevice(deviceID, at: Self.now)
        let reloaded = RemoteDeviceStore(fileURL: url)
        #expect(reloaded.pushRegistration(forDevice: deviceID) == nil)
        #expect(reloaded.pendingPushCleanup.map(\.registrationID) == [first.registrationID, second.registrationID])
        #expect(reloaded.eligiblePushRegistrations(configuration: Self.configuration).isEmpty)
        let old = try #require(reloaded.pendingPushCleanup.first)
        try reloaded.completePushCleanup(old)
        #expect(RemoteDeviceStore(fileURL: url).pendingPushCleanup.map(\.registrationID) == [second.registrationID])
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func failedReplacementAndCleanupPersistencePreserveCredentials() throws {
        enum Failure: Error { case write }
        let directory = FileManager.default.temporaryDirectory.appending(path: "push-store-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "devices.json")
        let store = RemoteDeviceStore(fileURL: url)
        let (deviceID, _) = try Self.pair(store)
        let first = Self.registration()
        try store.setPushRegistration(first, forDevice: deviceID, configuration: Self.configuration)
        let failing = RemoteDeviceStore(fileURL: url) { _, _ in throw Failure.write }
        #expect(throws: Failure.self) { try failing.setPushRegistration(Self.registration(), forDevice: deviceID, configuration: Self.configuration) }
        #expect(failing.pushRegistration(forDevice: deviceID)?.registrationID == first.registrationID)
        #expect(failing.pendingPushCleanup.isEmpty)
        try store.setPushRegistration(nil, forDevice: deviceID, configuration: nil)
        let cleanupFailure = RemoteDeviceStore(fileURL: url) { _, _ in throw Failure.write }
        let cleanup = try #require(cleanupFailure.pendingPushCleanup.first)
        #expect(throws: Failure.self) { try cleanupFailure.completePushCleanup(cleanup) }
        #expect(cleanupFailure.pendingPushCleanup == [cleanup])
    }

    @Test func lateFailedSendCannotClearNewGrantAndCleanupCannotBeReinstalled() throws {
        let store = RemoteDeviceStore(fileURL: nil)
        let (deviceID, _) = try Self.pair(store)
        let first = Self.registration()
        try store.setPushRegistration(first, forDevice: deviceID, configuration: Self.configuration)
        let old = try #require(store.pushRegistration(forDevice: deviceID))
        var alteredCapability = first
        alteredCapability.sendToken = String(repeating: "A", count: 43)
        #expect(throws: RemoteDevicePushRegistrationError.invalidRegistration) {
            try store.setPushRegistration(alteredCapability, forDevice: deviceID, configuration: Self.configuration)
        }
        #expect(store.pendingPushCleanup.isEmpty)
        let second = Self.registration()
        try store.setPushRegistration(second, forDevice: deviceID, configuration: Self.configuration)
        #expect(try !store.clearPushRegistration(matching: old))
        #expect(store.pushRegistration(forDevice: deviceID)?.registrationID == second.registrationID)
        #expect(throws: RemoteDevicePushRegistrationError.cleanupPending) {
            try store.setPushRegistration(first, forDevice: deviceID, configuration: Self.configuration)
        }
        let other = RemotePushConfiguration(relayURL: URL(string: "https://other.example.com")!)!
        #expect(store.eligiblePushRegistrations(configuration: other).isEmpty)
        #expect(store.pendingPushCleanup.first?.relayURL == Self.configuration.relayURL)
    }

    @Test func nativeRoutesRequireBearerIdentityAndValidateExactRegistrationShape() throws {
        let (handler, store, _) = RemoteGatewayRequestHandlerTests.makeHandler()
        let (deviceID, credential) = try Self.pair(store)
        let headers = [("authorization", "Bearer \(credential)"), ("tailscale-user-login", RemoteDeviceStoreTests.tailscaleLogin)]
        func response(_ method: String, _ path: String, _ fields: [(String, String)], _ body: Data = Data()) throws -> RemoteGatewayHTTPResponse {
            guard case .respond(let response) = handler.handle(RemoteGatewayRequestHandlerTests.request(method, path, headerFields: fields, body: body), at: Self.now) else { throw CocoaError(.coderInvalidValue) }
            return response
        }
        let hello = try response("GET", "/api/hello", [])
        #expect(try !JSONDecoder().decode(RemoteGatewayHelloResponse.self, from: hello.body).capabilities.contains(.pushNotifications))
        let disabled = try JSONDecoder().decode(RemoteGatewayPushConfigurationResponse.self, from: response("GET", RemotePushPolicy.configurationPath, headers).body)
        #expect(disabled.relayID == nil && disabled.apnsEnvironment == nil)
        let registration = Self.registration()
        let body = try JSONEncoder().encode(RemoteGatewayPushRegistrationRequest(registration: registration))
        #expect(try response("POST", RemotePushPolicy.registrationPath, headers, body).status == 409)
        handler.updateConfiguration(.init(allowedOrigins: [RemoteGatewayRequestHandlerTests.origin], pushConfiguration: Self.configuration))
        let configuredHello = try response("GET", "/api/hello", [])
        #expect(try JSONDecoder().decode(RemoteGatewayHelloResponse.self, from: configuredHello.body).capabilities.contains(.pushNotifications))
        var wrongRelay = registration
        wrongRelay.relayID = "other-relay"
        #expect(try response("POST", RemotePushPolicy.registrationPath, headers, JSONEncoder().encode(RemoteGatewayPushRegistrationRequest(registration: wrongRelay))).status == 409)
        var wrongToken = registration
        wrongToken.sendToken = String(repeating: "_", count: 43)
        #expect(try response("POST", RemotePushPolicy.registrationPath, headers, JSONEncoder().encode(RemoteGatewayPushRegistrationRequest(registration: wrongToken))).status == 400)
        for path in [RemotePushPolicy.configurationPath, RemotePushPolicy.registrationPath] {
            let method = path == RemotePushPolicy.configurationPath ? "GET" : "POST"
            #expect(try response(method, path, [], body).status == 401)
            #expect(try response(method, path, [headers[0]], body).status == 401)
            #expect(try response(method, path, [("cookie", RemoteGatewayRequestHandlerTests.pairedDeviceCookie(store))], body).status == 401)
            #expect(try response(method, path, headers + [("origin", "https://hostile.example")], body).status == 403)
        }
        var object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        object["deviceID"] = UUID().uuidString
        #expect(try response("POST", RemotePushPolicy.registrationPath, headers, JSONSerialization.data(withJSONObject: object)).status == 400)
        object.removeValue(forKey: "deviceID")
        var grant = try #require(object["registration"] as? [String: Any])
        grant["relayURL"] = "https://attacker.example"
        object["registration"] = grant
        #expect(try response("POST", RemotePushPolicy.registrationPath, headers, JSONSerialization.data(withJSONObject: object)).status == 400)
        #expect(try response("POST", RemotePushPolicy.registrationPath, headers, Data(repeating: 65, count: 4097)).status == 400)
        #expect(try response("POST", RemotePushPolicy.registrationPath, headers, body).status == 200)
        #expect(store.pushRegistration(forDevice: deviceID)?.registrationID == registration.registrationID)
        let configuration = try response("GET", RemotePushPolicy.configurationPath, headers)
        let text = try #require(String(data: configuration.body, encoding: .utf8))
        #expect(!text.contains(Self.token) && !text.contains(Self.configuration.relayURL.absoluteString))
        #expect(try JSONDecoder().decode(RemoteGatewayPushConfigurationResponse.self, from: configuration.body).registrationID == registration.registrationID)
        #expect(try response("POST", RemotePushPolicy.registrationPath, headers, JSONEncoder().encode(RemoteGatewayPushRegistrationRequest(registration: nil))).status == 200)
        #expect(store.pushRegistration(forDevice: deviceID) == nil)
        #expect(store.pendingPushCleanup.count == 1)
    }

    @Test func registrationAndSendEligibilityRequireNativeReadPermission() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "push-read-scope-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "devices.json")
        let device = RemoteDeviceRecord(name: "Phone", scopes: [], authKind: .native, tailscaleLogin: RemoteDeviceStoreTests.tailscaleLogin, createdAt: Self.now)
        let registration = RemoteDevicePushRegistration(deviceID: device.id, registration: Self.registration(), configuration: Self.configuration)
        let state = RemoteDeviceStore.State(devices: [device], credentials: [.init(credentialHash: RemoteDeviceStore.hashToken(Self.token), deviceID: device.id, issuedAt: Self.now)], pushRegistrations: [registration])
        try JSONEncoder().encode(state).write(to: url)
        let store = RemoteDeviceStore(fileURL: url)
        #expect(store.eligiblePushRegistrations(configuration: Self.configuration).isEmpty)
        let (handler, _, _) = RemoteGatewayRequestHandlerTests.makeHandler(deviceStore: store)
        handler.updateConfiguration(.init(allowedOrigins: [], pushConfiguration: Self.configuration))
        let body = try JSONEncoder().encode(RemoteGatewayPushRegistrationRequest(registration: Self.registration()))
        guard case .respond(let response) = handler.handle(RemoteGatewayRequestHandlerTests.request("POST", RemotePushPolicy.registrationPath,
            headerFields: [("authorization", "Bearer \(Self.token)"), ("tailscale-user-login", RemoteDeviceStoreTests.tailscaleLogin)], body: body), at: Self.now) else { throw CocoaError(.coderInvalidValue) }
        #expect(response.status == 403)
        try store.setPushRegistration(nil, forDevice: device.id, configuration: nil)
        #expect(store.pendingPushCleanup == [registration])
    }
}
