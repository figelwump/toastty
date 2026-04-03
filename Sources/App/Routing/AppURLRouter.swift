import AppKit
import CoreState
import Foundation

enum URLOpenDestination: String, Equatable {
    case toasttyBrowser = "toastty-browser"
    case systemBrowser = "system-browser"
}

enum URLBrowserOpenPlacement: String, Equatable {
    case rootRight
    case newTab

    var webPanelPlacement: WebPanelPlacement {
        switch self {
        case .rootRight:
            return .rootRight
        case .newTab:
            return .newTab
        }
    }
}

struct URLRoutingPreferences: Equatable {
    var destination: URLOpenDestination = .toasttyBrowser
    var browserPlacement: URLBrowserOpenPlacement = .rootRight
}

enum AppURLRoute: Equatable {
    case external
    case toasttyBrowser(placement: URLBrowserOpenPlacement)
}

enum AppURLRouter {
    static func route(for url: URL, preferences: URLRoutingPreferences) -> AppURLRoute {
        guard preferences.destination == .toasttyBrowser,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .external
        }

        return .toasttyBrowser(placement: preferences.browserPlacement)
    }

    @discardableResult
    @MainActor
    static func open(
        _ url: URL,
        preferredWindowID: UUID?,
        appStore: AppStore,
        preferences: URLRoutingPreferences? = nil,
        openExternally: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Bool {
        let resolvedPreferences = preferences ?? appStore.urlRoutingPreferences
        switch route(for: url, preferences: resolvedPreferences) {
        case .external:
            return openExternally(url)
        case .toasttyBrowser(let placement):
            if appStore.openURLInBrowser(
                preferredWindowID: preferredWindowID,
                url: url,
                placement: placement
            ) {
                return true
            }
            return openExternally(url)
        }
    }
}
