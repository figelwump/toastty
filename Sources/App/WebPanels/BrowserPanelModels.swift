import CoreState
import Foundation

struct BrowserPanelRuntimeAutomationState: Equatable, Sendable {
    let lifecycleState: PanelHostLifecycleState
    let pageZoom: Double
    let observedURL: String?
    let title: String?
    let isLoading: Bool
    let navigationState: BrowserNavigationResult
    let navigationError: BrowserNavigationError?
}

enum BrowserNavigationResult: String, Sendable {
    case idle, loading, finished, failed
}

struct BrowserNavigationError: Equatable, Sendable {
    let domain: String
    let code: Int
    let message: String

    init(_ error: Error) {
        let error = error as NSError
        domain = error.domain
        code = error.code
        message = error.localizedDescription
    }
}

struct BrowserPanelNavigationState: Equatable {
    var displayedURLString: String?
    var canGoBack = false
    var canGoForward = false
    var isLoading = false

    var canReloadOrStop: Bool {
        isLoading || displayedURLString != nil
    }
}

struct FaviconLinkReference: Equatable, Sendable {
    var href: String
    var rel: String
}

struct BrowserPanelFileLoad: Equatable, Sendable {
    var fileURL: URL
    // Parent-directory access lets relative sibling and descendant assets load
    // without widening access past the clicked document's containing folder.
    var readAccessURL: URL
}
