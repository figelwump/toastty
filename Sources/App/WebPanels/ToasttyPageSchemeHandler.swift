import CoreState
import Foundation
import WebKit

enum ToasttyPageAssetLocator {
    private static let gettingStartedDirectory = "WebPanels/getting-started-panel"
    private static let coordinatorDirectory = "WebPanels/coordinator-panel"

    static func gettingStartedDirectoryURL(bundle: Bundle = .main) -> URL? {
        bundle.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: gettingStartedDirectory
        )?.deletingLastPathComponent()
    }

    static func coordinatorDirectoryURL(bundle: Bundle = .main) -> URL? {
        bundle.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: coordinatorDirectory
        )?.deletingLastPathComponent()
    }
}

/// What `toastty://coordinator/` serves beyond its bundled files: a
/// task's stored packet as JSON, and the packet's screenshots. The app sets
/// it once at launch; without it those paths are not found.
@MainActor
protocol ToasttyCoordinatorPageDataSource: AnyObject {
    func packetReportJSON(taskID: UUID, version: Int) -> Data?
    func packetFileURL(taskID: UUID, version: Int, fileName: String) -> URL?
}

struct ToasttyPageSchemeResource: Equatable, Sendable {
    let resourceURL: URL
    let mimeType: String
}

enum ToasttyPageSchemeRouter {
    static func resolve(
        url: URL,
        pageDirectories: [String: URL]
    ) -> ToasttyPageSchemeResource? {
        guard url.scheme?.caseInsensitiveCompare("toastty") == .orderedSame,
              let host = url.host?.lowercased(),
              let pageDirectoryURL = pageDirectories[host],
              let pathComponents = pathComponents(for: url) else {
            return nil
        }

        let resourceComponents = pathComponents.isEmpty ? ["index.html"] : pathComponents
        let rootURL = pageDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let resourceURL = resourceComponents.reduce(rootURL) { partialResult, component in
            partialResult.appendingPathComponent(component)
        }
        let resolvedResourceURL = resourceURL.standardizedFileURL.resolvingSymlinksInPath()

        guard isDescendant(resolvedResourceURL, of: rootURL) else {
            return nil
        }

        return ToasttyPageSchemeResource(
            resourceURL: resolvedResourceURL,
            mimeType: mimeType(for: resolvedResourceURL)
        )
    }

    static func mimeType(for resourceURL: URL) -> String {
        switch resourceURL.pathExtension.lowercased() {
        case "html":
            "text/html"
        case "css":
            "text/css"
        case "js":
            "text/javascript"
        case "svg":
            "image/svg+xml"
        case "png":
            "image/png"
        case "jpg", "jpeg":
            "image/jpeg"
        case "gif":
            "image/gif"
        case "webp":
            "image/webp"
        case "json":
            "application/json"
        default:
            "application/octet-stream"
        }
    }

    static func pathComponents(for url: URL) -> [String]? {
        let encodedComponents = url.path(percentEncoded: true).split(
            separator: "/",
            omittingEmptySubsequences: true
        )
        let components = encodedComponents.compactMap { String($0).removingPercentEncoding }

        guard components.count == encodedComponents.count,
              components.allSatisfy({ component in
                  component != ".." &&
                      component.contains("/") == false &&
                      component.contains("\\") == false
              }) else {
            return nil
        }

        return components
    }

    private static func isDescendant(_ resourceURL: URL, of directoryURL: URL) -> Bool {
        let directoryPath = directoryURL.path.hasSuffix("/")
            ? directoryURL.path
            : "\(directoryURL.path)/"
        return resourceURL.path.hasPrefix(directoryPath)
    }
}

final class ToasttyPageSchemeHandler: NSObject, WKURLSchemeHandler {
    private static let notFoundURL = URL(string: "toastty://not-found/")
    private static let notFoundHTML = """
    <!doctype html>
    <html lang="en">
      <head><meta charset="utf-8"><title>Page Not Found</title></head>
      <body><h1>404 Not Found</h1></body>
    </html>
    """

    @MainActor static weak var coordinatorDataSource: (any ToasttyCoordinatorPageDataSource)?

    private let pageDirectories: [String: URL]

    init(bundle: Bundle = .main) {
        var pageDirectories: [String: URL] = [:]
        if let gettingStartedDirectoryURL = ToasttyPageAssetLocator.gettingStartedDirectoryURL(bundle: bundle) {
            pageDirectories["getting-started"] = gettingStartedDirectoryURL
        }
        if let coordinatorDirectoryURL = ToasttyPageAssetLocator.coordinatorDirectoryURL(bundle: bundle) {
            pageDirectories["coordinator"] = coordinatorDirectoryURL
        }
        self.pageDirectories = pageDirectories
        super.init()
    }

    func webView(_: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        if let requestURL = urlSchemeTask.request.url,
           requestURL.host?.lowercased() == "coordinator",
           let route = ToasttyCoordinatorPageRoute(url: requestURL) {
            serveCoordinatorRoute(route, requestURL: requestURL, to: urlSchemeTask)
            return
        }
        guard let requestURL = urlSchemeTask.request.url,
              let resource = ToasttyPageSchemeRouter.resolve(
                  url: requestURL,
                  pageDirectories: pageDirectories
              ),
              let data = try? Data(contentsOf: resource.resourceURL, options: .mappedIfSafe) else {
            respondNotFound(to: urlSchemeTask, requestURL: urlSchemeTask.request.url)
            return
        }

        respond(
            to: urlSchemeTask,
            requestURL: requestURL,
            statusCode: 200,
            mimeType: resource.mimeType,
            data: data
        )
    }

    func webView(_: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func serveCoordinatorRoute(_ route: ToasttyCoordinatorPageRoute, requestURL: URL, to urlSchemeTask: WKURLSchemeTask) {
        // WebKit calls scheme handlers on the main thread.
        let found: (data: Data, mimeType: String)? = MainActor.assumeIsolated {
            switch route {
            case .summary:
                guard let url = pageDirectories["coordinator"]?.appending(path: "dashboard.html", directoryHint: .notDirectory),
                      let data = try? Data(contentsOf: url) else { return nil }
                return (data, "text/html")
            case .report:
                guard let url = pageDirectories["coordinator"]?.appending(path: "report.html", directoryHint: .notDirectory),
                      let data = try? Data(contentsOf: url) else { return nil }
                return (data, "text/html")
            case .packetData(let taskID, let version):
                return Self.coordinatorDataSource?.packetReportJSON(taskID: taskID, version: version).map { ($0, "application/json") }
            case .packetFile(let taskID, let version, let fileName):
                guard let url = Self.coordinatorDataSource?.packetFileURL(taskID: taskID, version: version, fileName: fileName),
                      let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
                return (data, ToasttyPageSchemeRouter.mimeType(for: url))
            }
        }
        guard let found else {
            respondNotFound(to: urlSchemeTask, requestURL: requestURL)
            return
        }
        respond(to: urlSchemeTask, requestURL: requestURL, statusCode: 200, mimeType: found.mimeType, data: found.data)
    }

    private func respondNotFound(to urlSchemeTask: WKURLSchemeTask, requestURL: URL?) {
        guard let responseURL = requestURL ?? Self.notFoundURL else {
            urlSchemeTask.didFailWithError(URLError(.cannotParseResponse))
            return
        }

        respond(
            to: urlSchemeTask,
            requestURL: responseURL,
            statusCode: 404,
            mimeType: "text/html",
            data: Data(Self.notFoundHTML.utf8)
        )
    }

    private func respond(
        to urlSchemeTask: WKURLSchemeTask,
        requestURL: URL,
        statusCode: Int,
        mimeType: String,
        data: Data
    ) {
        guard let response = HTTPURLResponse(
            url: requestURL,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Cache-Control": "no-store",
                "Content-Type": mimeType,
            ]
        ) else {
            urlSchemeTask.didFailWithError(URLError(.cannotParseResponse))
            return
        }

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }
}

/// The coordinator page's dynamic paths. Everything else under
/// `toastty://coordinator/` is a bundled file.
enum ToasttyCoordinatorPageRoute: Equatable {
    case summary
    /// `report/<task-id>/<version>`: the report page, which reads its packet.
    case report(taskID: UUID, version: Int)
    /// `packet-data/<task-id>/<version>`.
    case packetData(taskID: UUID, version: Int)
    /// `packet-files/<task-id>/<version>/<file>`: one stored screenshot.
    case packetFile(taskID: UUID, version: Int, fileName: String)

    init?(url: URL) {
        if CoordinatorSummaryPageBridge.isSummaryURL(url) { self = .summary; return }
        guard let components = ToasttyPageSchemeRouter.pathComponents(for: url), components.count >= 3,
              let taskID = UUID(uuidString: components[1]),
              let version = Int(components[2].hasPrefix("v") ? String(components[2].dropFirst()) : components[2]),
              version > 0 else { return nil }
        switch (components[0], components.count) {
        case ("report", 3): self = .report(taskID: taskID, version: version)
        case ("packet-data", 3): self = .packetData(taskID: taskID, version: version)
        case ("packet-files", 4):
            let fileName = components[3]
            // One stored file name; never a path out of the packet folder.
            guard fileName.hasPrefix(".") == false, TaskPacket.isValidScreenshotName(URL(filePath: fileName).deletingPathExtension().lastPathComponent),
                  TaskPacket.screenshotExtensions.contains(URL(filePath: fileName).pathExtension.lowercased()) else { return nil }
            self = .packetFile(taskID: taskID, version: version, fileName: fileName)
        default:
            return nil
        }
    }
}
