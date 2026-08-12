import Foundation

public struct MobileCredentialGeneration: Equatable, Sendable {
    fileprivate let rawValue: UInt64
}

public actor MobileCredentialVault: GatewayCredentialProvider {
    private let store: any MobileCredentialStoring
    private var storedCredential: StoredMobileCredential?
    private var generationValue: UInt64 = 0

    public init(store: any MobileCredentialStoring = KeychainMobileCredentialStore()) {
        self.store = store
    }

    @discardableResult
    public func restore() -> MobileCredentialLoadResult {
        let result = store.load()
        switch result {
        case .available(let credential):
            storedCredential = credential
        case .missing, .locked, .corrupt, .incompatible, .failed:
            storedCredential = nil
        }
        advanceGeneration()
        return result
    }

    @discardableResult
    public func install(_ credential: StoredMobileCredential) throws -> MobileCredentialGeneration {
        try store.save(credential)
        storedCredential = credential
        advanceGeneration()
        return currentGeneration()
    }

    public func currentCredential() -> StoredMobileCredential? { storedCredential }

    public func currentGeneration() -> MobileCredentialGeneration {
        MobileCredentialGeneration(rawValue: generationValue)
    }

    public func credential() async throws -> GatewayCredential? {
        storedCredential.map { .bearer(token: $0.bearerToken) }
    }

    public func delete() throws {
        try store.delete()
        storedCredential = nil
        advanceGeneration()
    }

    /// Invalidates only the credential generation that originated a failed
    /// request. A delayed 401 from an older request cannot erase a re-pair.
    @discardableResult
    public func delete(ifCurrent expectedGeneration: MobileCredentialGeneration) throws -> Bool {
        guard expectedGeneration.rawValue == generationValue else { return false }
        try delete()
        return true
    }

    private func advanceGeneration() {
        generationValue &+= 1
    }
}
