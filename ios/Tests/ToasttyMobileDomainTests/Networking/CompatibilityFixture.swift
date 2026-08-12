import Foundation
import XCTest

enum CompatibilityFixture {
    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Compatibility"
        ) ?? bundle.url(forResource: name, withExtension: "json") else {
            throw XCTSkip("Missing bundled compatibility fixture \(name).json")
        }
        return try Data(contentsOf: url)
    }

    private final class BundleToken: NSObject {}
}
