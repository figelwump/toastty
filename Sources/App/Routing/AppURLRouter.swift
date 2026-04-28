import AppKit
import CoreState
import Foundation

enum URLOpenDestination: String, Equatable {
    case toasttyBrowser = "toastty-browser"
    case systemBrowser = "system-browser"
}

enum URLBrowserOpenPlacement: Equatable, RawRepresentable {
    case rightPanel
    case newTab

    static var rootRight: URLBrowserOpenPlacement {
        .rightPanel
    }

    init?(rawValue: String) {
        switch rawValue {
        case "rightPanel", "rootRight":
            self = .rightPanel
        case "newTab":
            self = .newTab
        default:
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .rightPanel:
            return "rightPanel"
        case .newTab:
            return "newTab"
        }
    }

    var webPanelPlacement: WebPanelPlacement {
        switch self {
        case .rightPanel:
            return .rightPanel
        case .newTab:
            return .newTab
        }
    }
}

struct URLRoutingPreferences: Equatable {
    var destination: URLOpenDestination = .toasttyBrowser
    var browserPlacement: URLBrowserOpenPlacement = .rightPanel
    var alternateBrowserPlacement: URLBrowserOpenPlacement = .newTab

    func resolvedBrowserPlacement(alternateOpen: Bool) -> URLBrowserOpenPlacement {
        alternateOpen ? alternateBrowserPlacement : browserPlacement
    }
}

enum LocalDocumentOpenPlacement: Equatable, RawRepresentable {
    case rightPanel
    case newTab

    static var rootRight: LocalDocumentOpenPlacement {
        .rightPanel
    }

    init?(rawValue: String) {
        switch rawValue {
        case "rightPanel", "rootRight":
            self = .rightPanel
        case "newTab":
            self = .newTab
        default:
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .rightPanel:
            return "rightPanel"
        case .newTab:
            return "newTab"
        }
    }

    var webPanelPlacement: WebPanelPlacement {
        switch self {
        case .rightPanel:
            return .rightPanel
        case .newTab:
            return .newTab
        }
    }
}

struct LocalDocumentRoutingPreferences: Equatable {
    var openingPlacement: LocalDocumentOpenPlacement = .rightPanel
    var alternateOpeningPlacement: LocalDocumentOpenPlacement = .newTab

    func resolvedPlacement(alternateOpen: Bool) -> LocalDocumentOpenPlacement {
        alternateOpen ? alternateOpeningPlacement : openingPlacement
    }
}

enum AppURLRoute: Equatable {
    case external
    case localDocument(LocalDocumentPanelCreateRequest)
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
        localDocumentPreferences: LocalDocumentRoutingPreferences = LocalDocumentRoutingPreferences(),
        useAlternatePlacement: Bool = false
    ) -> AppURLRoute {
        if let localDocumentTarget = LocalFileLinkResolver.resolvedLocalDocumentTarget(for: url) {
            let placement = localDocumentPreferences
                .resolvedPlacement(alternateOpen: useAlternatePlacement)
                .webPanelPlacement
            return .localDocument(
                LocalDocumentPanelCreateRequest(
                    filePath: localDocumentTarget.path,
                    lineNumber: localDocumentTarget.lineNumber,
                    placementOverride: placement
                )
            )
        }

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
        requestLocalDocumentReveal: ((UUID, Int) -> Bool)? = nil,
        openExternally: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Bool {
        let resolvedPreferences = preferences ?? appStore.urlRoutingPreferences
        let resolvedRoute = route(
            for: url,
            preferences: resolvedPreferences,
            localDocumentPreferences: appStore.localDocumentRoutingPreferences,
            useAlternatePlacement: useAlternatePlacement
        )
        switch resolvedRoute {
        case .external:
            let externalTarget = externalOpenTarget(for: url)
            return openExternally(externalTarget)
        case .localDocument(let request):
            if let outcome = appStore.createLocalDocumentPanelFromCommandOutcome(
                preferredWindowID: preferredWindowID,
                request: request
            ) {
                if let lineNumber = request.lineNumber {
                    _ = requestLocalDocumentReveal?(outcome.panelID, lineNumber)
                }
                return true
            }
            let externalTarget = externalOpenTarget(for: url)
            return openExternally(externalTarget)
        case .toasttyBrowser(let placement):
            if appStore.openURLInBrowser(
                preferredWindowID: preferredWindowID,
                url: url,
                placement: placement
            ) {
                return true
            }
            let externalTarget = externalOpenTarget(for: url)
            return openExternally(externalTarget)
        }
    }
}
