import RemoteProtocol
import Foundation
import Testing
@testable import CoreState

struct RemoteDeviceStoreTests {
    static let now = Date(timeIntervalSince1970: 1_786_100_000)

    @Test func pairingFlowIssuesSendEnabledDeviceAndCredential() throws {
        let store = RemoteDeviceStore(fileURL: nil)
        let code = store.issuePairingCode(at: Self.now)
        #expect(code.isValid(at: Self.now))
        #expect(code.code.count == 9)

        guard case .paired(let device, let token) = try store.redeemPairingCode(
            code.code,
            deviceName: "Vishal's phone",
            at: Self.now.addingTimeInterval(10)
        ) else {
            Issue.record("Expected pairing to succeed")
            return
        }
        #expect(device.scopes == [.read, .send])
        #expect(device.name == "Vishal's phone")
        #expect(token.count >= 40)

        let authenticated = store.authenticate(credentialToken: token, at: Self.now.addingTimeInterval(20))
        #expect(authenticated?.id == device.id)
        #expect(authenticated?.lastSeenAt == Self.now.addingTimeInterval(20))
    }

    @Test func pairingCodeIsSingleUseAndExpires() throws {
        let store = RemoteDeviceStore(fileURL: nil)
        let code = store.issuePairingCode(at: Self.now)

        // Sloppy formatting (lowercase, no dash) still redeems.
        let sloppy = code.code.replacingOccurrences(of: "-", with: "").lowercased()
        guard case .paired = try store.redeemPairingCode(sloppy, deviceName: "One", at: Self.now.addingTimeInterval(5)) else {
            Issue.record("Expected normalized code to redeem")
            return
        }
        // Second use fails.
        #expect(try store.redeemPairingCode(code.code, deviceName: "Two", at: Self.now.addingTimeInterval(6)) == .invalidCode)

        // Expired code fails.
        let expired = store.issuePairingCode(at: Self.now)
        #expect(try store.redeemPairingCode(
            expired.code,
            deviceName: "Three",
            at: Self.now.addingTimeInterval(RemotePairingCode.timeToLive + 1)
        ) == .invalidCode)
    }

    @Test func issuingANewCodeReplacesTheOldOne() throws {
        let store = RemoteDeviceStore(fileURL: nil)
        let first = store.issuePairingCode(at: Self.now)
        _ = store.issuePairingCode(at: Self.now.addingTimeInterval(1))
        #expect(try store.redeemPairingCode(first.code, deviceName: "Old", at: Self.now.addingTimeInterval(2)) == .invalidCode)
    }

    @Test func revocationInvalidatesCredentialsImmediately() throws {
        let store = RemoteDeviceStore(fileURL: nil)
        let code = store.issuePairingCode(at: Self.now)
        guard case .paired(let device, let token) = try store.redeemPairingCode(code.code, deviceName: "Phone", at: Self.now) else {
            Issue.record("Expected pairing to succeed")
            return
        }

        #expect(try store.revokeDevice(device.id, at: Self.now.addingTimeInterval(60)))
        #expect(store.authenticate(credentialToken: token, at: Self.now.addingTimeInterval(61)) == nil)
        #expect(store.devices.first?.isRevoked == true)
        // Revoking again is a no-op.
        #expect(try store.revokeDevice(device.id, at: Self.now.addingTimeInterval(62)) == false)
    }

    @Test func revokeAllClearsCredentialsAndPairing() throws {
        let store = RemoteDeviceStore(fileURL: nil)
        let firstCode = store.issuePairingCode(at: Self.now)
        guard case .paired(_, let firstToken) = try store.redeemPairingCode(firstCode.code, deviceName: "A", at: Self.now) else {
            Issue.record("Expected pairing to succeed")
            return
        }
        _ = store.issuePairingCode(at: Self.now)

        try store.revokeAllDevices(at: Self.now.addingTimeInterval(5))
        #expect(store.authenticate(credentialToken: firstToken, at: Self.now.addingTimeInterval(6)) == nil)
        #expect(store.hasActivePairingCode == false)
        let allRevoked = store.devices.allSatisfy(\.isRevoked)
        #expect(allRevoked)
    }

    @Test func scopeChangesAlwaysKeepRead() throws {
        let store = RemoteDeviceStore(fileURL: nil)
        let code = store.issuePairingCode(at: Self.now)
        guard case .paired(let device, _) = try store.redeemPairingCode(code.code, deviceName: "Phone", at: Self.now) else {
            Issue.record("Expected pairing to succeed")
            return
        }

        try store.setScopes([.send], forDevice: device.id)
        #expect(store.devices.first?.scopes == [.read, .send])
    }

    @Test func statePersistsAcrossReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-device-store-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("remote-devices.json")

        let store = RemoteDeviceStore(fileURL: fileURL)
        let code = store.issuePairingCode(at: Self.now)
        guard case .paired(let device, let token) = try store.redeemPairingCode(code.code, deviceName: "Phone", at: Self.now) else {
            Issue.record("Expected pairing to succeed")
            return
        }

        let reloaded = RemoteDeviceStore(fileURL: fileURL)
        #expect(reloaded.devices.map(\.id) == [device.id])
        #expect(reloaded.authenticate(credentialToken: token, at: Self.now.addingTimeInterval(30))?.id == device.id)

        let permissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        // The raw token never touches disk.
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(raw.contains(token) == false)
    }

    @Test func explicitReadOnlyScopePersistsAcrossReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-device-store-read-only-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("remote-devices.json")

        let store = RemoteDeviceStore(fileURL: fileURL)
        let code = store.issuePairingCode(at: Self.now)
        guard case .paired(let device, _) = try store.redeemPairingCode(
            code.code,
            deviceName: "Phone",
            at: Self.now
        ) else {
            Issue.record("Expected pairing to succeed")
            return
        }

        #expect(try store.setScopes([.read], forDevice: device.id))

        let reloaded = RemoteDeviceStore(fileURL: fileURL)
        #expect(reloaded.devices.first?.scopes == [.read])
    }

    @Test func failedRevocationPersistenceDoesNotMutateMemoryOrDisk() throws {
        enum ExpectedFailure: Error { case write }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-device-store-failure-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("remote-devices.json")

        let initialStore = RemoteDeviceStore(fileURL: fileURL)
        let code = initialStore.issuePairingCode(at: Self.now)
        guard case .paired(let device, let token) = try initialStore.redeemPairingCode(
            code.code,
            deviceName: "Phone",
            at: Self.now
        ) else {
            Issue.record("Expected pairing to succeed")
            return
        }

        let failingStore = RemoteDeviceStore(fileURL: fileURL) { _, _ in
            throw ExpectedFailure.write
        }
        #expect(throws: ExpectedFailure.self) {
            try failingStore.revokeDevice(device.id, at: Self.now.addingTimeInterval(1))
        }
        #expect(failingStore.devices.first?.isRevoked == false)
        #expect(failingStore.authenticate(credentialToken: token, at: Self.now.addingTimeInterval(2)) != nil)

        _ = failingStore.issuePairingCode(at: Self.now.addingTimeInterval(3))
        #expect(throws: ExpectedFailure.self) {
            try failingStore.revokeAllDevices(at: Self.now.addingTimeInterval(4))
        }
        #expect(failingStore.hasActivePairingCode)
        #expect(failingStore.authenticate(credentialToken: token, at: Self.now.addingTimeInterval(5)) != nil)

        let reloaded = RemoteDeviceStore(fileURL: fileURL)
        #expect(reloaded.authenticate(credentialToken: token, at: Self.now.addingTimeInterval(6)) != nil)
    }

    @Test func corruptStoreFileStartsEmpty() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-device-store-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("remote-devices.json")
        try Data("not json".utf8).write(to: fileURL)

        let store = RemoteDeviceStore(fileURL: fileURL)
        #expect(store.devices.isEmpty)
    }

    @Test func missingOrInvalidPersistedScopesNeverGrantSend() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-device-store-scope-fixtures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fixtures: [(json: String, expectedDeviceCount: Int)] = [
            (#"{"devices":[{"id":"00000000-0000-0000-0000-000000000001","name":"Missing","createdAt":807947048}],"credentials":[]}"#, 0),
            (#"{"devices":[{"id":"00000000-0000-0000-0000-000000000002","name":"Empty","scopes":[],"createdAt":807947048}],"credentials":[]}"#, 1),
            (#"{"devices":[{"id":"00000000-0000-0000-0000-000000000003","name":"Unknown","scopes":["read","bogus"],"createdAt":807947048}],"credentials":[]}"#, 0),
        ]

        for (index, fixture) in fixtures.enumerated() {
            let fileURL = directory.appendingPathComponent("remote-devices-\(index).json")
            try Data(fixture.json.utf8).write(to: fileURL)

            let store = RemoteDeviceStore(fileURL: fileURL)
            #expect(store.devices.count == fixture.expectedDeviceCount)
            #expect(store.devices.allSatisfy { $0.scopes.contains(.send) == false })
        }
    }
}

struct RemoteAccessRateLimiterTests {
    static let now = Date(timeIntervalSince1970: 1_786_100_000)

    @Test func locksOutAfterTooManyFailuresInWindow() {
        var limiter = RemoteAccessRateLimiter(maximumFailures: 3, windowDuration: 60, lockoutDuration: 300)
        #expect(limiter.isLockedOut(at: Self.now) == false)

        for offset in 0..<3 {
            #expect(limiter.recordFailure(at: Self.now.addingTimeInterval(Double(offset))) == false)
        }
        let lockedOnFourth = limiter.recordFailure(at: Self.now.addingTimeInterval(3))
        #expect(lockedOnFourth)
        #expect(limiter.isLockedOut(at: Self.now.addingTimeInterval(4)))
        #expect(limiter.isLockedOut(at: Self.now.addingTimeInterval(302)))
        #expect(limiter.isLockedOut(at: Self.now.addingTimeInterval(304)) == false)
    }

    @Test func oldFailuresFallOutOfTheWindow() {
        var limiter = RemoteAccessRateLimiter(maximumFailures: 3, windowDuration: 60, lockoutDuration: 300)
        for offset in [0.0, 1.0, 2.0] {
            limiter.recordFailure(at: Self.now.addingTimeInterval(offset))
        }
        // 61 seconds later the earlier failures have aged out.
        #expect(limiter.recordFailure(at: Self.now.addingTimeInterval(63)) == false)
        #expect(limiter.isLockedOut(at: Self.now.addingTimeInterval(64)) == false)
    }
}

struct RemoteAccessAuditLogTests {
    static let now = Date(timeIntervalSince1970: 1_786_100_000)

    @Test func recordsAndCapsEntries() {
        let log = RemoteAccessAuditLog(fileURL: nil, capacity: 3)
        for index in 0..<5 {
            log.record(RemoteAccessAuditEntry(
                at: Self.now.addingTimeInterval(Double(index)),
                action: .authenticationFailed,
                detail: "attempt \(index)"
            ))
        }
        let recent = log.recentEntries()
        #expect(recent.count == 3)
        #expect(recent.last?.detail == "attempt 4")
        #expect(recent.first?.detail == "attempt 2")
    }

    @Test func persistsAcrossReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-audit-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("remote-audit.json")

        let log = RemoteAccessAuditLog(fileURL: fileURL)
        let deviceID = UUID()
        log.record(RemoteAccessAuditEntry(at: Self.now, action: .devicePaired, deviceID: deviceID, detail: "Phone"))

        let reloaded = RemoteAccessAuditLog(fileURL: fileURL)
        #expect(reloaded.recentEntries().count == 1)
        #expect(reloaded.recentEntries().first?.deviceID == deviceID)
    }
}

struct RemoteGatewayProtocolTests {
    @Test func streamMessageRoundTripsWithVersionAndType() throws {
        let snapshot = RemoteSessionListSnapshot(
            projectionRunID: RemoteProjectionRunID(),
            conversations: [],
            generatedAt: Date(timeIntervalSince1970: 1_786_100_000)
        )
        let encoder = ConversationEventCoding.makeEncoder()
        let data = try encoder.encode(RemoteGatewayStreamMessage.sessionList(snapshot))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""type":"session_list""#))
        #expect(json.contains(#""protocolVersion":"1.0""#))

        let decoded = try ConversationEventCoding.makeDecoder().decode(RemoteGatewayStreamMessage.self, from: data)
        #expect(decoded == .sessionList(snapshot))
    }
}
