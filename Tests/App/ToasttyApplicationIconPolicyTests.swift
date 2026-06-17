@testable import ToasttyApp
import AppKit
import XCTest

final class ToasttyApplicationIconPolicyTests: XCTestCase {
    func testUsesLegacySwitcherIconThroughMacOS15() {
        XCTAssertTrue(
            ToasttyApplicationIconPolicy.shouldUseLegacySwitcherIcon(
                for: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
            )
        )
        XCTAssertTrue(
            ToasttyApplicationIconPolicy.shouldUseLegacySwitcherIcon(
                for: OperatingSystemVersion(majorVersion: 15, minorVersion: 7, patchVersion: 0)
            )
        )
    }

    func testKeepsBundleIconOnModernMacOSVersions() {
        XCTAssertFalse(
            ToasttyApplicationIconPolicy.shouldUseLegacySwitcherIcon(
                for: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
            )
        )
        XCTAssertFalse(
            ToasttyApplicationIconPolicy.shouldUseLegacySwitcherIcon(
                for: OperatingSystemVersion(majorVersion: 16, minorVersion: 0, patchVersion: 0)
            )
        )
    }

    func testLoadsLegacySwitcherIconOnlyForLegacyMacOSVersions() {
        let legacyImage = NSImage(size: NSSize(width: 512, height: 512))
        var requestedNames: [NSImage.Name] = []
        let loadImage: (NSImage.Name) -> NSImage? = { name in
            requestedNames.append(name)
            return legacyImage
        }

        let resolvedImage = ToasttyApplicationIconPolicy.legacySwitcherIconImage(
            for: OperatingSystemVersion(majorVersion: 15, minorVersion: 7, patchVersion: 0),
            loadImage: loadImage
        )

        XCTAssertTrue(resolvedImage === legacyImage)
        XCTAssertEqual(requestedNames, [NSImage.Name(ToasttyApplicationIconPolicy.legacySwitcherIconName)])

        requestedNames.removeAll()
        XCTAssertNil(
            ToasttyApplicationIconPolicy.legacySwitcherIconImage(
                for: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
                loadImage: loadImage
            )
        )
        XCTAssertTrue(requestedNames.isEmpty)
    }

    func testLegacySwitcherIconAssetResolves() throws {
        let image = try XCTUnwrap(
            NSImage(named: NSImage.Name(ToasttyApplicationIconPolicy.legacySwitcherIconName))
        )

        XCTAssertFalse(image.representations.isEmpty)
    }
}
