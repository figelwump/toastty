import RemoteProtocol
import Foundation
import Testing
@testable import CoreState

struct RemoteDeviceStoreTests {
    static let now = Date(timeIntervalSince1970: 1_786_100_000)
    static let gatewayURL = URL(string: "https://toastty.example-tailnet.ts.net")!
    static let tailscaleLogin = "phone-owner@example.com"

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

        let original = try Data(contentsOf: fileURL)
        let code = store.issuePairingCode(at: Self.now)
        #expect(throws: RemoteDeviceStorePersistenceError.self) {
            try store.redeemPairingCode(code.code, deviceName: "Must not overwrite", at: Self.now)
        }
        #expect(try Data(contentsOf: fileURL) == original)
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

    @Test func nativeOfferContainsBoundedIndependentProofsAndReplacesOrCancelsAtomically() throws {
        let store = RemoteDeviceStore(fileURL: nil)
        let first = try store.issueNativePairingOffer(gatewayURL: Self.gatewayURL, at: Self.now)
        #expect(first.expiresAt == Self.now.addingTimeInterval(120))
        #expect(first.qrPayload.secret.count == 43)
        #expect(Data(base64URLTestString: first.qrPayload.secret)?.count == 32)
        #expect(first.fallbackCode.count == 14)
        #expect(first.fallbackCode.allSatisfy { "23456789ABCDEFGHJKMNPQRSTVWXYZ-".contains($0) })

        let encoded = try first.qrPayload.encodedString()
        #expect(encoded.hasPrefix("toastty-pairing:v1:"))
        #expect(encoded.utf8.count <= RemoteNativePairingQRPayload.maximumEncodedByteCount)
        #expect(try RemoteNativePairingQRPayload(encodedString: encoded) == first.qrPayload)

        let replacement = try store.issueNativePairingOffer(
            gatewayURL: Self.gatewayURL,
            at: Self.now.addingTimeInterval(1)
        )
        #expect(replacement.id != first.id)
        #expect(try store.redeemNativePairingOffer(
            using: .qr(offerID: first.id, secret: first.qrPayload.secret),
            deviceName: "Phone",
            tailscaleLogin: Self.tailscaleLogin,
            at: Self.now.addingTimeInterval(2)
        ) == .invalidOffer)
        store.cancelNativePairingOffer()
        #expect(store.activeNativePairingOffer(at: Self.now.addingTimeInterval(3)) == nil)
    }

    @Test func nativeOfferRejectsNonTailnetGatewayOrigins() {
        let store = RemoteDeviceStore(fileURL: nil)
        for value in [
            "http://toastty.example-tailnet.ts.net",
            "https://toastty.example-tailnet.ts.net.evil.example",
            "https://user@toastty.example-tailnet.ts.net",
            "https://toastty.example-tailnet.ts.net/path",
            "https://toastty.example-tailnet.ts.net?secret=value",
            "https://toastty.example-tailnet.ts.net:8443",
        ] {
            #expect(throws: RemoteNativePairingOfferError.self) {
                try store.issueNativePairingOffer(gatewayURL: URL(string: value)!, at: Self.now)
            }
        }
    }

    @Test func nativeQRAndFallbackShareOneAtomicRedemption() throws {
        let store = RemoteDeviceStore(fileURL: nil)
        let offer = try store.issueNativePairingOffer(gatewayURL: Self.gatewayURL, at: Self.now)
        let outcomes = NativePairingOutcomes()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            let proof: RemoteNativePairingProof = index == 0
                ? .qr(offerID: offer.id, secret: offer.qrPayload.secret)
                : .fallbackCode(offer.fallbackCode.lowercased().replacingOccurrences(of: "-", with: ""))
            let outcome = try! store.redeemNativePairingOffer(
                using: proof,
                deviceName: "Phone \(index)",
                tailscaleLogin: Self.tailscaleLogin,
                at: Self.now.addingTimeInterval(1)
            )
            outcomes.append(outcome)
        }

        let pairedCount = outcomes.values.filter {
            if case .paired = $0 { return true }
            return false
        }.count
        let invalidCount = outcomes.values.filter { $0 == .invalidOffer }.count
        #expect(pairedCount == 1)
        #expect(invalidCount == 1)
        #expect(store.devices.count == 1)
    }

    @Test func failedNativePairingWriteLeavesOfferRedeemable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-native-offer-write-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("remote-devices.json")
        let writer = OneShotWriter()
        let store = RemoteDeviceStore(fileURL: fileURL, persistenceWriter: writer.write)
        let offer = try store.issueNativePairingOffer(gatewayURL: Self.gatewayURL, at: Self.now)

        #expect(throws: NativePairingTestFailure.self) {
            try store.redeemNativePairingOffer(
                using: .fallbackCode(offer.fallbackCode),
                deviceName: "Phone",
                tailscaleLogin: Self.tailscaleLogin,
                at: Self.now.addingTimeInterval(1)
            )
        }
        #expect(store.activeNativePairingOffer(at: Self.now.addingTimeInterval(2))?.id == offer.id)

        guard case .paired(let device, _) = try store.redeemNativePairingOffer(
            using: .fallbackCode(offer.fallbackCode),
            deviceName: "Phone",
            tailscaleLogin: Self.tailscaleLogin,
            at: Self.now.addingTimeInterval(2)
        ) else {
            Issue.record("Expected retry to redeem the still-active offer")
            return
        }
        #expect(device.authKind == .native)
    }

    @Test func nativeCredentialIsReturnedOnceHashOnlyAndIdentityBoundAcrossReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-native-credential-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("remote-devices.json")
        let store = RemoteDeviceStore(fileURL: fileURL)
        let offer = try store.issueNativePairingOffer(gatewayURL: Self.gatewayURL, at: Self.now)

        guard case .paired(let device, let token) = try store.redeemNativePairingOffer(
            using: .qr(offerID: offer.id, secret: offer.qrPayload.secret),
            deviceName: "Native phone",
            tailscaleLogin: Self.tailscaleLogin,
            at: Self.now.addingTimeInterval(1)
        ) else {
            Issue.record("Expected native pairing")
            return
        }
        #expect(device.authKind == .native)
        #expect(device.tailscaleLogin == Self.tailscaleLogin)
        #expect(token.count == 43)
        #expect(Data(base64URLTestString: token)?.count == 32)
        #expect(store.authenticateBrowserCredential(token, at: Self.now.addingTimeInterval(2)) == nil)
        #expect(store.authenticateNativeBearer(
            token,
            tailscaleLogin: Self.tailscaleLogin.uppercased(),
            at: Self.now.addingTimeInterval(2)
        ) == .identityMismatch)

        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(raw.contains(token) == false)
        #expect(raw.contains(offer.qrPayload.secret) == false)
        #expect(raw.contains(offer.fallbackCode) == false)

        let reloaded = RemoteDeviceStore(fileURL: fileURL)
        guard case .authenticated(let authenticated) = reloaded.authenticateNativeBearer(
            token,
            tailscaleLogin: Self.tailscaleLogin,
            at: Self.now.addingTimeInterval(3)
        ) else {
            Issue.record("Expected exact identity to authenticate after reload")
            return
        }
        #expect(authenticated.id == device.id)
        #expect(reloaded.authenticate(credentialToken: token, at: Self.now.addingTimeInterval(4)) == nil)
    }

    @Test func nativeIdentityComparisonDoesNotUnicodeNormalize() throws {
        let precomposedLogin = "caf\u{00E9}@example.com"
        let decomposedLogin = "cafe\u{0301}@example.com"
        let store = RemoteDeviceStore(fileURL: nil)
        let offer = try store.issueNativePairingOffer(gatewayURL: Self.gatewayURL, at: Self.now)
        guard case .paired(_, let token) = try store.redeemNativePairingOffer(
            using: .qr(offerID: offer.id, secret: offer.qrPayload.secret),
            deviceName: "Native phone",
            tailscaleLogin: precomposedLogin,
            at: Self.now.addingTimeInterval(1)
        ) else {
            Issue.record("Expected native pairing")
            return
        }

        #expect(store.authenticateNativeBearer(
            token,
            tailscaleLogin: decomposedLogin,
            at: Self.now.addingTimeInterval(2)
        ) == .identityMismatch)
        guard case .authenticated = store.authenticateNativeBearer(
            token,
            tailscaleLogin: precomposedLogin,
            at: Self.now.addingTimeInterval(3)
        ) else {
            Issue.record("Expected byte-exact identity to authenticate")
            return
        }
    }

    @Test func nativeFailuresAndLockoutPersistByExactIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-native-lockout-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("remote-devices.json")
        let store = RemoteDeviceStore(fileURL: fileURL)
        _ = try store.issueNativePairingOffer(gatewayURL: Self.gatewayURL, at: Self.now)

        for offset in 0..<4 {
            #expect(try store.redeemNativePairingOffer(
                using: .fallbackCode("2222-2222-2222"),
                deviceName: "Phone",
                tailscaleLogin: Self.tailscaleLogin,
                at: Self.now.addingTimeInterval(Double(offset))
            ) == .invalidOffer)
        }
        let lockedUntil = Self.now.addingTimeInterval(304)
        #expect(try store.redeemNativePairingOffer(
            using: .fallbackCode("2222-2222-2222"),
            deviceName: "Phone",
            tailscaleLogin: Self.tailscaleLogin,
            at: Self.now.addingTimeInterval(4)
        ) == .lockedOut(until: lockedUntil))

        let reloaded = RemoteDeviceStore(fileURL: fileURL)
        #expect(try reloaded.redeemNativePairingOffer(
            using: .fallbackCode("3333-3333-3333"),
            deviceName: "Phone",
            tailscaleLogin: Self.tailscaleLogin,
            at: Self.now.addingTimeInterval(5)
        ) == .lockedOut(until: lockedUntil))
        #expect(try reloaded.redeemNativePairingOffer(
            using: .fallbackCode("3333-3333-3333"),
            deviceName: "Phone",
            tailscaleLogin: Self.tailscaleLogin.uppercased(),
            at: Self.now.addingTimeInterval(5)
        ) == .invalidOffer)
    }

    @Test func oversizedEncodedStateRefusesMutationWithoutOverwritingSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-state-output-bound-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("remote-devices.json")
        let deviceID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let prefix = #"{"devices":[{"id":"\#(deviceID.uuidString)","name":"Browser","scopes":["read"],"createdAt":807947048}],"credentials":[],"padding":""#
        let suffix = #""}"#
        let paddingCount = RemoteDeviceStore.maximumPersistedStateByteCount
            - prefix.utf8.count
            - suffix.utf8.count
        let original = Data((prefix + String(repeating: "x", count: paddingCount) + suffix).utf8)
        #expect(original.count == RemoteDeviceStore.maximumPersistedStateByteCount)
        try original.write(to: fileURL)

        let store = RemoteDeviceStore(fileURL: fileURL)
        #expect(store.devices.map(\.id) == [deviceID])
        do {
            _ = try store.setScopes([.read, .send], forDevice: deviceID)
            Issue.record("Expected oversized encoded output to fail")
        } catch let error as RemoteDeviceStorePersistenceError {
            #expect(error == .encodedStateTooLarge)
        }
        #expect(store.devices.first?.scopes == [.read])
        #expect(try Data(contentsOf: fileURL) == original)
    }

    @Test func secureWriterRepairsDirectoryAndFilePermissionsForFirstAndReplacementWrites() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-secure-writer-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let fileURL = directory.appendingPathComponent("remote-devices.json")
        let store = RemoteDeviceStore(fileURL: fileURL)
        let code = store.issuePairingCode(at: Self.now)
        guard case .paired(let device, _) = try store.redeemPairingCode(
            code.code,
            deviceName: "Browser",
            at: Self.now
        ) else {
            Issue.record("Expected first secure write")
            return
        }

        #expect(try permissions(of: directory) == 0o700)
        #expect(try permissions(of: fileURL) == 0o600)

        // Simulate broadened existing metadata; replacement must use the
        // newly-created 0600 inode rather than carrying this mode forward.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        #expect(try store.setScopes([.read], forDevice: device.id))
        #expect(try permissions(of: directory) == 0o700)
        #expect(try permissions(of: fileURL) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [fileURL.lastPathComponent])
    }

    @Test func activeLockoutFloodCannotEvictAnotherActiveIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-native-active-lock-flood-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("remote-devices.json")
        let failures = (0..<RemoteDeviceStore.maximumNativeFailureIdentityCount).map { index in
            RemoteNativePairingFailureRecord(
                tailscaleLogin: "locked-\(index)@example.com",
                failureTimes: [Self.now],
                lockedOutUntil: Self.now.addingTimeInterval(600 + Double(index)),
                updatedAt: Self.now.addingTimeInterval(Double(index))
            )
        }
        let initialState = RemoteDeviceStore.State(nativePairingFailures: failures)
        let original = try JSONEncoder().encode(initialState)
        try original.write(to: fileURL)

        let store = RemoteDeviceStore(fileURL: fileURL)
        _ = try store.issueNativePairingOffer(gatewayURL: Self.gatewayURL, at: Self.now)
        #expect(try store.redeemNativePairingOffer(
            using: .fallbackCode("2222-2222-2222"),
            deviceName: "Flooding phone",
            tailscaleLogin: "new-attacker@example.com",
            at: Self.now.addingTimeInterval(1)
        ) == .lockedOut(until: Self.now.addingTimeInterval(600)))
        #expect(store.state.nativePairingFailures == failures)
        #expect(try Data(contentsOf: fileURL) == original)
        #expect(try store.redeemNativePairingOffer(
            using: .fallbackCode("3333-3333-3333"),
            deviceName: "Locked phone",
            tailscaleLogin: failures[0].tailscaleLogin,
            at: Self.now.addingTimeInterval(2)
        ) == .lockedOut(until: failures[0].lockedOutUntil!))
    }

    @Test func expiredNativeOfferIsClearedWhenQueriedOrRedeemed() throws {
        let queryStore = RemoteDeviceStore(fileURL: nil)
        let queriedOffer = try queryStore.issueNativePairingOffer(gatewayURL: Self.gatewayURL, at: Self.now)
        #expect(queryStore.activeNativePairingOffer(at: queriedOffer.expiresAt) == nil)
        #expect(queryStore.activeNativePairingOffer(at: Self.now) == nil)

        let redemptionStore = RemoteDeviceStore(fileURL: nil)
        let redeemedOffer = try redemptionStore.issueNativePairingOffer(gatewayURL: Self.gatewayURL, at: Self.now)
        #expect(try redemptionStore.redeemNativePairingOffer(
            using: .fallbackCode(redeemedOffer.fallbackCode),
            deviceName: "Expired phone",
            tailscaleLogin: Self.tailscaleLogin,
            at: redeemedOffer.expiresAt
        ) == .invalidOffer)
        #expect(redemptionStore.activeNativePairingOffer(at: Self.now) == nil)
    }

    @Test func legacyMixedStateMigratesWithoutDiscardingValidNeighborsOrRewritingOnLoad() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-native-migration-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("remote-devices.json")
        let legacyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let nativeID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let brokenID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let legacyToken = String(repeating: "A", count: 43)
        let nativeToken = String(repeating: "C", count: 42) + "A"
        let json = #"{"devices":[{"id":"\#(legacyID.uuidString)","name":"Legacy browser","scopes":["read"],"createdAt":807947048},{"id":"\#(nativeID.uuidString)","name":"Native phone","scopes":["read","send"],"authKind":"native","tailscaleLogin":"\#(Self.tailscaleLogin)","createdAt":807947049},{"id":"\#(brokenID.uuidString)","name":"Broken native","scopes":["read"],"authKind":"native","createdAt":807947050}],"credentials":[{"credentialHash":"\#(RemoteDeviceStore.hashToken(legacyToken))","deviceID":"\#(legacyID.uuidString)","issuedAt":807947048},{"credentialHash":"\#(RemoteDeviceStore.hashToken(nativeToken))","deviceID":"\#(nativeID.uuidString)","issuedAt":807947049}],"futureTopLevelField":{"keptByOlderBuilds":true}}"#
        let original = Data(json.utf8)
        try original.write(to: fileURL)

        let store = RemoteDeviceStore(fileURL: fileURL)
        #expect(try Data(contentsOf: fileURL) == original)
        #expect(store.devices.map(\.id) == [legacyID, nativeID])
        #expect(store.devices.first?.authKind == .browser)
        #expect(store.authenticateBrowserCredential(legacyToken, at: Self.now)?.id == legacyID)
        #expect(store.authenticateNativeBearer(
            nativeToken,
            tailscaleLogin: Self.tailscaleLogin,
            at: Self.now
        ) == .authenticated(store.devices[1]))

        #expect(try store.setScopes([.read, .send], forDevice: legacyID))
        let rewritten = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(rewritten.contains("Broken native"))
        #expect(rewritten.contains(#""authKind" : "native""#))
        #expect(rewritten.contains("futureTopLevelField"))
        let restarted = RemoteDeviceStore(fileURL: fileURL)
        #expect(restarted.authenticateBrowserCredential(
            legacyToken,
            at: Self.now.addingTimeInterval(61)
        )?.id == legacyID)
    }

    @Test func nativeInputBoundsFailClosed() throws {
        let store = RemoteDeviceStore(fileURL: nil)
        let offer = try store.issueNativePairingOffer(gatewayURL: Self.gatewayURL, at: Self.now)
        #expect(try store.redeemNativePairingOffer(
            using: .fallbackCode(offer.fallbackCode),
            deviceName: " bad ",
            tailscaleLogin: Self.tailscaleLogin,
            at: Self.now
        ) == .invalidDeviceName)
        #expect(try store.redeemNativePairingOffer(
            using: .fallbackCode(offer.fallbackCode),
            deviceName: String(repeating: "a", count: 81),
            tailscaleLogin: Self.tailscaleLogin,
            at: Self.now
        ) == .invalidDeviceName)
        #expect(store.authenticateBrowserCredential(
            String(repeating: "x", count: RemoteDeviceStore.maximumCredentialTokenByteCount + 1),
            at: Self.now
        ) == nil)
    }
}

private func permissions(of url: URL) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
}

private extension Data {
    init?(base64URLTestString: String) {
        var value = base64URLTestString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = value.utf8.count % 4
        if remainder != 0 { value.append(String(repeating: "=", count: 4 - remainder)) }
        self.init(base64Encoded: value)
    }
}

private enum NativePairingTestFailure: Error {
    case write
}

private final class NativePairingOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RemoteDeviceStore.NativePairingOutcome] = []

    var values: [RemoteDeviceStore.NativePairingOutcome] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: RemoteDeviceStore.NativePairingOutcome) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class OneShotWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    func write(_ state: RemoteDeviceStore.State, to fileURL: URL) throws {
        lock.lock()
        let fail = shouldFail
        shouldFail = false
        lock.unlock()
        if fail { throw NativePairingTestFailure.write }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
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
