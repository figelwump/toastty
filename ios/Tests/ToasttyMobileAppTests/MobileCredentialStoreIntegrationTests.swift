import Foundation
import RemoteProtocol
import Security
@testable import ToasttyMobileDomain
import XCTest

final class MobileCredentialStoreIntegrationTests: XCTestCase {
    func testHostedAppKeychainRoundTripUsesThisDeviceOnlyDataProtectionItem() throws {
        let service = "com.giantthings.toastty.mobile.tests.\(UUID().uuidString)"
        let store = KeychainMobileCredentialStore(service: service, account: "integration")
        defer { try? store.delete() }

        let credential = try StoredMobileCredential(
            gatewayURL: XCTUnwrap(URL(string: "https://mac.example-tailnet.ts.net")),
            device: RemoteGatewayDeviceSummary(
                id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
                name: "Native phone",
                scopes: [.read, .send]
            ),
            credentialCreatedAt: Date(timeIntervalSince1970: 1_786_200_000),
            bearerToken: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        )

        try store.save(credential)
        XCTAssertEqual(store.load(), .available(credential))

        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "integration",
            kSecUseDataProtectionKeychain: true,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        XCTAssertEqual(status, errSecSuccess)
        let attributes = try XCTUnwrap(result as? [CFString: Any])
        XCTAssertEqual(
            attributes[kSecAttrAccessible] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        XCTAssertNotEqual(attributes[kSecAttrSynchronizable] as? Bool, true)
    }
}
