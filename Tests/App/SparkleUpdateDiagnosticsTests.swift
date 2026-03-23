@testable import ToasttyApp
import Foundation
import XCTest

final class SparkleUpdateDiagnosticsTests: XCTestCase {
    func testDiagnosticsModeEnablesForDebugBuildsAndIsolatedDevRuns() {
        XCTAssertTrue(
            SparkleUpdateDiagnosticsMode.isEnabled(
                environment: [:],
                isDebugBuild: true
            )
        )
        XCTAssertTrue(
            SparkleUpdateDiagnosticsMode.isEnabled(
                environment: ["TOASTTY_RUNTIME_HOME": "/tmp/toastty-runtime"],
                isDebugBuild: false
            )
        )
        XCTAssertTrue(
            SparkleUpdateDiagnosticsMode.isEnabled(
                environment: ["TOASTTY_DEV_WORKTREE_ROOT": "/tmp/toastty"],
                isDebugBuild: false
            )
        )
        XCTAssertFalse(
            SparkleUpdateDiagnosticsMode.isEnabled(
                environment: [:],
                isDebugBuild: false
            )
        )
    }

    func testPreflightReportsMissingFeedURLWithoutFetching() async {
        let preflight = SparkleUpdatePreflight(
            context: .init(
                bundlePath: "/Applications/Toastty.app",
                feedURLString: nil,
                publicEDKey: "public-key"
            ),
            feedLoader: { _ in
                XCTFail("feed loader should not run when SUFeedURL is missing")
                throw URLError(.badURL)
            }
        )

        let issue = await preflight.validate()

        XCTAssertEqual(issue, .missingFeedURL(bundlePath: "/Applications/Toastty.app"))
    }

    func testPreflightReportsMissingPublicKeyWithoutFetching() async {
        let preflight = SparkleUpdatePreflight(
            context: .init(
                bundlePath: "/Applications/Toastty.app",
                feedURLString: "https://updates.toastty.dev/appcast.xml",
                publicEDKey: nil
            ),
            feedLoader: { _ in
                XCTFail("feed loader should not run when SUPublicEDKey is missing")
                throw URLError(.badURL)
            }
        )

        let issue = await preflight.validate()

        XCTAssertEqual(issue, .missingPublicEDKey(bundlePath: "/Applications/Toastty.app"))
    }

    func testPreflightReportsMalformedFeed() async {
        let feedURL = URL(string: "https://updates.toastty.dev/appcast.xml")!
        let preflight = SparkleUpdatePreflight(
            context: .init(
                bundlePath: "/Applications/Toastty.app",
                feedURLString: feedURL.absoluteString,
                publicEDKey: "public-key"
            ),
            feedLoader: { _ in
                (
                    Data("<rss><channel><item>".utf8),
                    Self.makeHTTPResponse(url: feedURL)
                )
            }
        )

        let issue = await preflight.validate()

        guard case .malformedFeed(let failingFeedURL, let reason)? = issue else {
            return XCTFail("expected malformed feed issue, got \(String(describing: issue))")
        }

        XCTAssertEqual(failingFeedURL, feedURL.absoluteString)
        XCTAssertFalse(reason.isEmpty)
    }

    func testPreflightReportsEmptyFeedWithActionableGuidance() async {
        let feedURL = URL(string: "https://updates.toastty.dev/appcast.xml")!
        let preflight = SparkleUpdatePreflight(
            context: .init(
                bundlePath: "/Applications/Toastty.app",
                feedURLString: feedURL.absoluteString,
                publicEDKey: "public-key"
            ),
            feedLoader: { _ in
                (
                    Data(
                        """
                        <?xml version="1.0" encoding="utf-8"?>
                        <rss version="2.0">
                            <channel>
                                <title>Toastty Updates</title>
                            </channel>
                        </rss>
                        """.utf8
                    ),
                    Self.makeHTTPResponse(url: feedURL)
                )
            }
        )

        let issue = await preflight.validate()

        XCTAssertEqual(issue, .emptyFeed(feedURL: feedURL.absoluteString))
        XCTAssertEqual(issue?.messageText, "Sparkle Feed Check Failed")
        XCTAssertTrue(issue?.informativeText.contains("non-draft release") == true)
    }

    func testPreflightAllowsFeedWithAtLeastOneItem() async {
        let feedURL = URL(string: "https://updates.toastty.dev/appcast.xml")!
        let preflight = SparkleUpdatePreflight(
            context: .init(
                bundlePath: "/Applications/Toastty.app",
                feedURLString: feedURL.absoluteString,
                publicEDKey: "public-key"
            ),
            feedLoader: { _ in
                (
                    Data(
                        """
                        <?xml version="1.0" encoding="utf-8"?>
                        <rss version="2.0">
                            <channel>
                                <title>Toastty Updates</title>
                                <item>
                                    <title>Version 0.1.0</title>
                                    <enclosure url="https://github.com/figelwump/toastty/releases/download/v0.1.0/Toastty-0.1.0.dmg" />
                                </item>
                            </channel>
                        </rss>
                        """.utf8
                    ),
                    Self.makeHTTPResponse(url: feedURL)
                )
            }
        )

        let issue = await preflight.validate()

        XCTAssertNil(issue)
    }

    private static func makeHTTPResponse(
        url: URL,
        statusCode: Int = 200
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
