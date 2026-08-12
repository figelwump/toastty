import Foundation
@testable import ToasttyMobileDomain
import XCTest

final class MobileCredentialVaultTests: XCTestCase {
    func testRestoreCachesCredentialForGatewayProvider() async throws {
        let credential = try MobileCredentialStoreTests.makeCredential()
        let store = InMemoryMobileCredentialStore(credential: credential)
        let vault = MobileCredentialVault(store: store)

        let restored = await vault.restore()
        let gatewayCredential = try await vault.credential()
        let current = await vault.currentCredential()
        XCTAssertEqual(restored, .available(credential))
        XCTAssertEqual(gatewayCredential, .bearer(token: credential.bearerToken))
        XCTAssertEqual(current, credential)
    }

    func testStaleUnauthorizedGenerationCannotDeleteReplacement() async throws {
        let oldCredential = try MobileCredentialStoreTests.makeCredential()
        let replacement = try MobileCredentialStoreTests.makeCredential(
            host: "replacement.tail.ts.net",
            token: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
        )
        let vault = MobileCredentialVault(store: InMemoryMobileCredentialStore())
        let oldGeneration = try await vault.install(oldCredential)
        let newGeneration = try await vault.install(replacement)

        let deleted = try await vault.delete(ifCurrent: oldGeneration)
        let current = await vault.currentCredential()
        let generation = await vault.currentGeneration()
        XCTAssertFalse(deleted)
        XCTAssertEqual(current, replacement)
        XCTAssertEqual(generation, newGeneration)
    }

    func testCurrentUnauthorizedGenerationDeletesCredential() async throws {
        let vault = MobileCredentialVault(store: InMemoryMobileCredentialStore())
        let generation = try await vault.install(MobileCredentialStoreTests.makeCredential())

        let deleted = try await vault.delete(ifCurrent: generation)
        let current = await vault.currentCredential()
        let gatewayCredential = try await vault.credential()
        XCTAssertTrue(deleted)
        XCTAssertNil(current)
        XCTAssertNil(gatewayCredential)
    }
}

private final class InMemoryMobileCredentialStore: MobileCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: StoredMobileCredential?

    init(credential: StoredMobileCredential? = nil) {
        self.credential = credential
    }

    func load() -> MobileCredentialLoadResult {
        lock.withLock { credential.map(MobileCredentialLoadResult.available) ?? .missing }
    }

    func save(_ credential: StoredMobileCredential) {
        lock.withLock { self.credential = credential }
    }

    func delete() {
        lock.withLock { credential = nil }
    }
}
