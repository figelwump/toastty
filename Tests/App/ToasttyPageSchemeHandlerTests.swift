@testable import ToasttyApp
import Foundation
import XCTest

final class ToasttyPageSchemeHandlerTests: XCTestCase {
    func testIndexRoutesResolveWithAndWithoutTrailingSlashAndFragment() throws {
        let pageDirectoryURL = try makePageDirectoryURL()
        defer { try? FileManager.default.removeItem(at: pageDirectoryURL.deletingLastPathComponent()) }

        for urlString in [
            "toastty://getting-started",
            "toastty://getting-started/",
            "toastty://getting-started/#onboarding",
        ] {
            let resource = try XCTUnwrap(resolve(urlString, pageDirectoryURL: pageDirectoryURL))
            XCTAssertEqual(resource.resourceURL, pageDirectoryURL.appendingPathComponent("index.html"))
            XCTAssertEqual(resource.mimeType, "text/html")
        }
    }

    func testAssetRouteResolvesWithinGettingStartedDirectory() throws {
        let pageDirectoryURL = try makePageDirectoryURL()
        defer { try? FileManager.default.removeItem(at: pageDirectoryURL.deletingLastPathComponent()) }

        let resource = try XCTUnwrap(
            resolve("toastty://getting-started/assets/getting-started.css", pageDirectoryURL: pageDirectoryURL)
        )

        XCTAssertEqual(
            resource.resourceURL,
            pageDirectoryURL.appendingPathComponent("assets/getting-started.css")
        )
        XCTAssertEqual(resource.mimeType, "text/css")
    }

    func testPathTraversalIsRejected() throws {
        let pageDirectoryURL = try makePageDirectoryURL()
        defer { try? FileManager.default.removeItem(at: pageDirectoryURL.deletingLastPathComponent()) }

        XCTAssertNil(resolve("toastty://getting-started/../secret.html", pageDirectoryURL: pageDirectoryURL))
        XCTAssertNil(resolve("toastty://getting-started/%2E%2E/secret.html", pageDirectoryURL: pageDirectoryURL))
    }

    func testUnknownHostIsRejected() throws {
        let pageDirectoryURL = try makePageDirectoryURL()
        defer { try? FileManager.default.removeItem(at: pageDirectoryURL.deletingLastPathComponent()) }

        XCTAssertNil(resolve("toastty://unknown/", pageDirectoryURL: pageDirectoryURL))
    }

    func testMimeTypeMapping() {
        XCTAssertEqual(mimeType(for: "index.html"), "text/html")
        XCTAssertEqual(mimeType(for: "panel.css"), "text/css")
        XCTAssertEqual(mimeType(for: "panel.js"), "text/javascript")
        XCTAssertEqual(mimeType(for: "toast.svg"), "image/svg+xml")
        XCTAssertEqual(mimeType(for: "toast.png"), "image/png")
        XCTAssertEqual(mimeType(for: "asset.bin"), "application/octet-stream")
    }

    private func resolve(_ urlString: String, pageDirectoryURL: URL) -> ToasttyPageSchemeResource? {
        ToasttyPageSchemeRouter.resolve(
            url: URL(string: urlString)!,
            pageDirectories: ["getting-started": pageDirectoryURL]
        )
    }

    private func mimeType(for fileName: String) -> String {
        ToasttyPageSchemeRouter.mimeType(for: URL(fileURLWithPath: fileName))
    }

    private func makePageDirectoryURL() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-page-scheme-\(UUID().uuidString)", isDirectory: true)
        let pageDirectoryURL = rootURL.appendingPathComponent("getting-started", isDirectory: true)
        try FileManager.default.createDirectory(at: pageDirectoryURL, withIntermediateDirectories: true)
        return pageDirectoryURL
    }
}
