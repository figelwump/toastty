import Foundation

enum ToasttyMobileDeepLinkDestination: Equatable, Sendable {
    case conversation(UUID)
    case workspace(UUID)
}

/// Pure, strict parser for the routes owned by the current app build.
///
/// The URL scheme is injected from this build's Info.plist so production,
/// development, and prod-test installs cannot route one another's links.
struct DeepLinkParser: Equatable, Sendable {
    private let scheme: String

    init?(scheme: String) {
        let normalizedScheme = scheme.lowercased()
        guard Self.isValidScheme(normalizedScheme) else { return nil }
        self.scheme = normalizedScheme
    }

    func parse(_ url: URL) -> ToasttyMobileDeepLinkDestination? {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ), components.scheme?.lowercased() == scheme,
           components.user == nil,
           components.password == nil,
           components.port == nil,
           components.query == nil,
           components.fragment == nil,
           let encodedRoute = components.percentEncodedHost,
           encodedRoute.allSatisfy(\.isASCII)
        else {
            return nil
        }

        let rawIdentifier = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: false)
        guard rawIdentifier.count == 2,
              rawIdentifier[0].isEmpty,
              let identifier = UUID(uuidString: String(rawIdentifier[1])),
              identifier.uuidString.caseInsensitiveCompare(String(rawIdentifier[1])) == .orderedSame
        else {
            return nil
        }

        switch encodedRoute.lowercased() {
        case "conversation":
            return .conversation(identifier)
        case "workspace":
            return .workspace(identifier)
        default:
            return nil
        }
    }

    private static func isValidScheme(_ value: String) -> Bool {
        guard let first = value.first,
              first.isASCII,
              first.isLetter
        else {
            return false
        }
        return value.dropFirst().allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".")
        }
    }
}
