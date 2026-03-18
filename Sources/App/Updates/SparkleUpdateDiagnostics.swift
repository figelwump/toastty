import AppKit
import Foundation

enum SparkleUpdateDiagnosticsMode {
    static func isEnabled(processInfo: ProcessInfo = .processInfo) -> Bool {
        isEnabled(
            environment: processInfo.environment,
            isDebugBuild: _isDebugAssertConfiguration()
        )
    }

    static func isEnabled(
        environment: [String: String],
        isDebugBuild: Bool
    ) -> Bool {
        if isDebugBuild {
            return true
        }

        return environment["TOASTTY_RUNTIME_HOME"] != nil
            || environment["TOASTTY_DEV_WORKTREE_ROOT"] != nil
    }
}

struct SparkleUpdatePreflight {
    typealias FeedLoader = @Sendable (URL) async throws -> (Data, URLResponse)

    struct Context: Equatable {
        let bundlePath: String
        let feedURLString: String?
        let publicEDKey: String?
    }

    enum Issue: Equatable {
        case missingFeedURL(bundlePath: String)
        case invalidFeedURL(bundlePath: String, value: String)
        case insecureFeedURL(bundlePath: String, value: String)
        case missingPublicEDKey(bundlePath: String)
        case feedRequestFailed(feedURL: String, reason: String)
        case malformedFeed(feedURL: String, reason: String)
        case emptyFeed(feedURL: String)

        var messageText: String {
            switch self {
            case .missingFeedURL, .invalidFeedURL, .insecureFeedURL, .missingPublicEDKey:
                return "Sparkle Is Misconfigured in This Build"
            case .feedRequestFailed, .malformedFeed, .emptyFeed:
                return "Sparkle Feed Check Failed"
            }
        }

        var informativeText: String {
            switch self {
            case .missingFeedURL(let bundlePath):
                return """
                This build is missing SUFeedURL in its Info.plist.

                Bundle: \(bundlePath)

                Regenerate the Xcode project and rebuild so the Sparkle feed URL is embedded in the app bundle before checking for updates again.
                """
            case .invalidFeedURL(let bundlePath, let value):
                return """
                This build has an invalid SUFeedURL value in its Info.plist.

                Bundle: \(bundlePath)
                SUFeedURL: \(value)

                Set SUFeedURL to a valid HTTPS appcast.xml URL, regenerate if needed, and rebuild before checking for updates again.
                """
            case .insecureFeedURL(let bundlePath, let value):
                return """
                Sparkle requires an HTTPS feed URL, but this build is configured with a non-HTTPS SUFeedURL.

                Bundle: \(bundlePath)
                SUFeedURL: \(value)

                Point SUFeedURL at an HTTPS appcast.xml endpoint and rebuild before checking for updates again.
                """
            case .missingPublicEDKey(let bundlePath):
                return """
                This build is missing SUPublicEDKey in its Info.plist.

                Bundle: \(bundlePath)

                Regenerate the Xcode project and rebuild so Sparkle can verify release signatures before checking for updates again.
                """
            case .feedRequestFailed(let feedURL, let reason):
                return """
                Toastty could not fetch the Sparkle feed.

                Feed: \(feedURL)
                Reason: \(reason)

                Verify that the feed host is reachable over HTTPS and presents a certificate that matches this hostname.
                """
            case .malformedFeed(let feedURL, let reason):
                return """
                Toastty fetched the Sparkle feed, but the response is not a valid appcast XML document.

                Feed: \(feedURL)
                Reason: \(reason)

                Fix the published appcast contents before checking for updates again.
                """
            case .emptyFeed(let feedURL):
                return """
                Toastty fetched the Sparkle feed successfully, but it does not contain any <item> entries yet.

                Feed: \(feedURL)

                Publish a non-draft release or fix the feed contents before checking for updates from a debug or dev build.
                """
            }
        }
    }

    private let context: Context
    private let feedLoader: FeedLoader

    init(bundle: Bundle, feedLoader: @escaping FeedLoader = Self.defaultFeedLoader) {
        self.init(
            context: Context(
                bundlePath: bundle.bundleURL.path,
                feedURLString: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                publicEDKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
            ),
            feedLoader: feedLoader
        )
    }

    init(context: Context, feedLoader: @escaping FeedLoader) {
        self.context = context
        self.feedLoader = feedLoader
    }

    func validate() async -> Issue? {
        let bundlePath = context.bundlePath
        guard let rawFeedURL = context.feedURLString?.trimmedNonEmpty else {
            return .missingFeedURL(bundlePath: bundlePath)
        }
        guard let feedURL = URL(string: rawFeedURL),
              feedURL.scheme != nil,
              feedURL.host != nil else {
            return .invalidFeedURL(bundlePath: bundlePath, value: rawFeedURL)
        }
        guard feedURL.scheme?.lowercased() == "https" else {
            return .insecureFeedURL(bundlePath: bundlePath, value: rawFeedURL)
        }
        guard context.publicEDKey?.trimmedNonEmpty != nil else {
            return .missingPublicEDKey(bundlePath: bundlePath)
        }

        do {
            let (data, response) = try await feedLoader(feedURL)
            if let httpResponse = response as? HTTPURLResponse,
               (200..<300).contains(httpResponse.statusCode) == false {
                return .feedRequestFailed(
                    feedURL: rawFeedURL,
                    reason: "HTTP \(httpResponse.statusCode)"
                )
            }

            return Self.validateAppcast(data: data, feedURLString: rawFeedURL)
        } catch {
            return .feedRequestFailed(
                feedURL: rawFeedURL,
                reason: Self.describeFeedLoadFailure(error)
            )
        }
    }

    static func defaultFeedLoader(url: URL) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(from: url)
    }

    private static func validateAppcast(
        data: Data,
        feedURLString: String
    ) -> Issue? {
        let parser = XMLParser(data: data)
        let itemCounter = SparkleAppcastItemCounter()
        parser.delegate = itemCounter

        guard parser.parse() else {
            let parseFailure = parser.parserError?.localizedDescription ?? "Unknown XML parsing error."
            return .malformedFeed(feedURL: feedURLString, reason: parseFailure)
        }

        guard itemCounter.itemCount > 0 else {
            return .emptyFeed(feedURL: feedURLString)
        }

        return nil
    }

    private static func describeFeedLoadFailure(_ error: Error) -> String {
        guard let urlError = error as? URLError else {
            return error.localizedDescription
        }

        switch urlError.code {
        case .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .serverCertificateUntrusted,
             .secureConnectionFailed:
            return "\(urlError.localizedDescription) Check the feed host certificate and HTTPS settings."
        case .appTransportSecurityRequiresSecureConnection:
            return "App Transport Security rejected a non-HTTPS response."
        default:
            return urlError.localizedDescription
        }
    }
}

@MainActor
enum SparkleUpdateDiagnosticsPresenter {
    static func present(issue: SparkleUpdatePreflight.Issue) {
        let alert = NSAlert()
        alert.messageText = issue.messageText
        alert.informativeText = issue.informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private final class SparkleAppcastItemCounter: NSObject, XMLParserDelegate {
    private(set) var itemCount = 0

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        _ = parser
        _ = namespaceURI
        _ = qName
        _ = attributeDict

        if elementName == "item" {
            itemCount += 1
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
