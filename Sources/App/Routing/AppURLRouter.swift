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
    var browserPlacement: URLBrowserOpenPlacement = .newTab
    var alternateBrowserPlacement: URLBrowserOpenPlacement = .rootRight

    func resolvedBrowserPlacement(alternateOpen: Bool) -> URLBrowserOpenPlacement {
        alternateOpen ? alternateBrowserPlacement : browserPlacement
    }
}

enum AppURLRoute: Equatable {
    case external
    case toasttyBrowser(placement: URLBrowserOpenPlacement)
}

enum AppURLRouter {
    private static func externalOpenTarget(for url: URL) -> URL {
        guard url.scheme == nil,
              let localFileURL = localFileURL(forExternalOpen: url) else {
            return url
        }

        return localFileURL
    }

    private static func localFileURL(forExternalOpen url: URL) -> URL? {
        let path = url.path
        guard path.hasPrefix("/") || path.hasPrefix("~/") else {
            return nil
        }

        let expandedPath = NSString(string: path).standardizingPath
        guard expandedPath.isEmpty == false else {
            return nil
        }

        return URL(filePath: expandedPath)
    }

    static func route(
        for url: URL,
        preferences: URLRoutingPreferences,
        useAlternatePlacement: Bool = false
    ) -> AppURLRoute {
        guard preferences.destination == .toasttyBrowser,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .external
        }

        return .toasttyBrowser(placement: preferences.resolvedBrowserPlacement(alternateOpen: useAlternatePlacement))
    }

    @discardableResult
    @MainActor
    static func open(
        _ url: URL,
        preferredWindowID: UUID?,
        appStore: AppStore,
        useAlternatePlacement: Bool = false,
        preferences: URLRoutingPreferences? = nil,
        openExternally: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Bool {
        let resolvedPreferences = preferences ?? appStore.urlRoutingPreferences
        switch route(for: url, preferences: resolvedPreferences, useAlternatePlacement: useAlternatePlacement) {
        case .external:
            return openExternally(externalOpenTarget(for: url))
        case .toasttyBrowser(let placement):
            if appStore.openURLInBrowser(
                preferredWindowID: preferredWindowID,
                url: url,
                placement: placement
            ) {
                return true
            }
            return openExternally(externalOpenTarget(for: url))
        }
    }
}
