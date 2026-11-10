import CoreState
import Foundation

enum ScratchpadPanelAssetLocator {
    private static let directory = "WebPanels/scratchpad-panel"
    private static let fileName = "index"
    private static let fileExtension = "html"

    static func entryURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: fileName, withExtension: fileExtension, subdirectory: directory)
    }

    static func directoryURL(bundle: Bundle = .main) -> URL? {
        entryURL(bundle: bundle)?.deletingLastPathComponent()
    }
}

struct ScratchpadPanelRuntimeAutomationState: Equatable, Sendable {
    let lifecycleState: PanelHostLifecycleState
    let currentTheme: ScratchpadPanelTheme
    let hasPendingBootstrapScript: Bool
    let currentAssetPath: String?
    let currentBootstrap: ScratchpadPanelBootstrap?
    let recentDiagnostics: [ScratchpadPanelDiagnostic]
}

struct ScratchpadPanelDiagnostic: Equatable, Sendable {
    let sequence: Int
    let source: String
    let kind: String
    let level: String?
    let message: String
    let metadata: [String: String]
}
