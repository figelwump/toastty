import Foundation
import RemoteProtocol
import Security
@testable import ToasttyMobileDomain
import XCTest

final class MobileCredentialStoreTests: XCTestCase {
    func testLoadDistinguishesMissingLockedFailureCorruptAndIncompatible() throws {
        let security = RecordingSecurityClient()
        let store = KeychainMobileCredentialStore(securityClient: security)

        security.copyResult = .status(errSecItemNotFound)
        XCTAssertEqual(store.load(), .missing)

        security.copyResult = .status(errSecInteractionNotAllowed)
        XCTAssertEqual(store.load(), .locked)

        security.copyResult = .status(errSecNotAvailable)
        XCTAssertEqual(store.load(), .failed(.keychainStatus(errSecNotAvailable)))

        security.copyResult = .data(Data("not-json".utf8))
        XCTAssertEqual(store.load(), .corrupt)

        security.copyResult = .data(Data(#"{"schemaVersion":99}"#.utf8))
        XCTAssertEqual(store.load(), .incompatible(storedVersion: 99))
    }

    func testSaveAndLoadRoundTripUsesNonSynchronizableLocator() throws {
        let security = RecordingSecurityClient()
        security.copyResult = .status(errSecItemNotFound)
        let store = KeychainMobileCredentialStore(
            service: "test.service",
            account: "test.account",
            securityClient: security
        )

        let credential = try Self.makeCredential()
        try store.save(credential)

        let added = try XCTUnwrap(security.addedItems.last)
        XCTAssertEqual(added.locator.service, "test.service")
        XCTAssertEqual(added.locator.account, "test.account")
        XCTAssertEqual(added.locator.synchronizable, .nonSynchronizable)
        security.copyResult = .data(added.data)
        XCTAssertEqual(store.load(), .available(credential))
    }

    func testDuplicateAddFallsBackToUpdate() throws {
        let security = RecordingSecurityClient()
        security.copyResult = .status(errSecItemNotFound)
        security.addStatus = errSecDuplicateItem
        let store = KeychainMobileCredentialStore(securityClient: security)

        try store.save(Self.makeCredential())

        XCTAssertEqual(security.updatedItems.count, 1)
    }

    func testDeleteUsesSynchronizableAnyAndToleratesMissing() throws {
        let security = RecordingSecurityClient()
        security.deleteStatus = errSecItemNotFound
        let store = KeychainMobileCredentialStore(securityClient: security)

        try store.delete()

        XCTAssertEqual(security.deletedLocators.last?.synchronizable, .any)
    }

    func testStoredCredentialDescriptionAndDebugDescriptionAreFullyRedacted() throws {
        let credential = try Self.makeCredential(
            host: "sentinel-private-host.private-tailnet.ts.net",
            deviceName: "Sentinel Vishal Phone",
            token: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
        )

        for output in [String(describing: credential), String(reflecting: credential)] {
            XCTAssertEqual(output, "<redacted mobile credential>")
            XCTAssertFalse(output.contains("sentinel"))
            XCTAssertFalse(output.contains("Vishal"))
            XCTAssertFalse(output.contains("BBBB"))
            XCTAssertFalse(output.contains(credential.device.id.uuidString))
        }
    }

    static func makeCredential(
        host: String = "mac.example-tailnet.ts.net",
        deviceName: String = "Native phone",
        token: String = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    ) throws -> StoredMobileCredential {
        try StoredMobileCredential(
            gatewayURL: XCTUnwrap(URL(string: "https://\(host)")),
            device: RemoteGatewayDeviceSummary(
                id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
                name: deviceName,
                scopes: [.read, .send]
            ),
            credentialCreatedAt: Date(timeIntervalSince1970: 1_786_200_000),
            bearerToken: token
        )
    }
}

final class RecordingSecurityClient: MobileCredentialSecurityClient, @unchecked Sendable {
    private let lock = NSLock()
    var copyResult: KeychainCopyResult = .status(errSecItemNotFound)
    var addStatus: OSStatus = errSecSuccess
    var updateStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess
    private(set) var addedItems: [KeychainItemToAdd] = []
    private(set) var updatedItems: [(KeychainItemLocator, Data)] = []
    private(set) var deletedLocators: [KeychainItemLocator] = []

    func copy(_ locator: KeychainItemLocator) -> KeychainCopyResult {
        lock.withLock { copyResult }
    }

    func add(_ item: KeychainItemToAdd) -> OSStatus {
        lock.withLock {
            addedItems.append(item)
            return addStatus
        }
    }

    func update(_ locator: KeychainItemLocator, data: Data) -> OSStatus {
        lock.withLock {
            updatedItems.append((locator, data))
            return updateStatus
        }
    }

    func delete(_ locator: KeychainItemLocator) -> OSStatus {
        lock.withLock {
            deletedLocators.append(locator)
            return deleteStatus
        }
    }
}
