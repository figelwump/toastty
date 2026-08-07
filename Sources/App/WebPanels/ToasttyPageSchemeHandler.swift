import Foundation
import WebKit

enum ToasttyPageAssetLocator {
    private static let gettingStartedDirectory = "WebPanels/getting-started-panel"

    static func gettingStartedDirectoryURL(bundle: Bundle = .main) -> URL? {
        bundle.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: gettingStartedDirectory
        )?.deletingLastPathComponent()
    }
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
        default:
            "application/octet-stream"
        }
    }

    private static func pathComponents(for url: URL) -> [String]? {
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

    private let pageDirectories: [String: URL]

    init(bundle: Bundle = .main) {
        var pageDirectories: [String: URL] = [:]
        if let gettingStartedDirectoryURL = ToasttyPageAssetLocator.gettingStartedDirectoryURL(bundle: bundle) {
            pageDirectories["getting-started"] = gettingStartedDirectoryURL
        }
        self.pageDirectories = pageDirectories
        super.init()
    }

    func webView(_: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
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
