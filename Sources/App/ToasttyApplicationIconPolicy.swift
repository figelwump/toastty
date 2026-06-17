import AppKit
import CoreState
import Foundation

enum ToasttyApplicationIconPolicy {
    static let legacySwitcherIconName = "LegacySwitcherIcon"
    static let latestLegacySwitcherIconMajorVersion = 15

    static func shouldUseLegacySwitcherIcon(for version: OperatingSystemVersion) -> Bool {
        version.majorVersion <= latestLegacySwitcherIconMajorVersion
    }

    static func legacySwitcherIconImage(
        for version: OperatingSystemVersion,
        loadImage: (NSImage.Name) -> NSImage? = { NSImage(named: $0) }
    ) -> NSImage? {
        guard shouldUseLegacySwitcherIcon(for: version) else {
            return nil
        }

        return loadImage(NSImage.Name(legacySwitcherIconName))
    }

    @MainActor
    static func applyLegacySwitcherIconIfNeeded(
        processInfo: ProcessInfo = .processInfo,
        application: NSApplication = .shared
    ) {
        let operatingSystemVersion = processInfo.operatingSystemVersion
        guard shouldUseLegacySwitcherIcon(for: operatingSystemVersion) else {
            return
        }

        guard let image = legacySwitcherIconImage(for: operatingSystemVersion) else {
            ToasttyLog.warning(
                "Legacy switcher icon asset is missing",
                category: .bootstrap,
                metadata: ["asset_name": legacySwitcherIconName]
            )
            assertionFailure("Missing \(legacySwitcherIconName) asset")
            return
        }

        application.applicationIconImage = image
    }
}
