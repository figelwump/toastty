import AppKit
import Foundation
import WebKit

enum BrowserNavigationPolicyDecision: Equatable {
    case allow
    case openSecondary(URL)
}

enum BrowserPopupRoutingDecision: Equatable {
    case openSecondary(URL)
    case awaitCapturedURL
}

enum BrowserLinkRoutingRules {
    static func navigationPolicyDecision(
        url: URL?,
        navigationType: WKNavigationType,
        modifierFlags: NSEvent.ModifierFlags,
        targetFrameIsNil: Bool
    ) -> BrowserNavigationPolicyDecision {
        guard targetFrameIsNil == false,
              navigationType == .linkActivated,
              let url else {
            return .allow
        }

        let relevantModifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
        if relevantModifiers.contains(.command) {
            return .openSecondary(url)
        }

        if isBrowserNavigableInPlace(url) == false {
            return .openSecondary(url)
        }

        return .allow
    }

    static func popupRoutingDecision(requestURL: URL?) -> BrowserPopupRoutingDecision {
        guard let requestURL,
              popupCaptureURL(requestURL) != nil else {
            return .awaitCapturedURL
        }

        return .openSecondary(requestURL)
    }

    static func popupCaptureURL(_ url: URL?) -> URL? {
        guard let url else {
            return nil
        }

        let absoluteString = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard absoluteString.isEmpty == false,
              absoluteString.caseInsensitiveCompare("about:blank") != .orderedSame else {
            return nil
        }

        return url
    }

    private static func isBrowserNavigableInPlace(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }

        return scheme == "http" || scheme == "https"
    }
}
