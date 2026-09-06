import CoreState
import Foundation
import RemoteProtocol

/// Immutable state captured on the main actor. Equality is checked again after
/// IO so a closed/moved panel or changed conversation cannot keep a stale grant.
struct RemotePreviewContext: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case file(
            reference: String, recordedCWD: String?, openPaths: [String],
            format: LocalDocumentFormat?)
        case scratchpad(documentID: UUID, revision: Int, storeDirectory: URL)
        case web(URL)
    }
    var title: String
    var source: Source
}

enum RemotePreviewProvider {
    static func response(operation: RemoteGatewayPreviewOperation, context: RemotePreviewContext)
        throws -> RemoteGatewayHTTPResponse
    {
        let encoder = JSONEncoder()
        switch operation.request {
        case .preview:
            let content = try preview(context)
            return .json(
                status: 200, reason: "OK",
                body: try encoder.encode(RemotePreviewResponse(content: content)))
        case .resource(let request):
            guard case .file(let reference, let cwd, let openPaths, _) = context.source else {
                throw RemotePreviewError.unsupported
            }
            let parsed = try fileReference(reference)
            let entry = try RemotePreviewFileReader.resolveFile(
                reference: parsed.path, recordedCWD: cwd, explicitlyOpenPaths: openPaths)
            guard ["html", "htm"].contains(URL(fileURLWithPath: entry).pathExtension.lowercased()),
                request.expectedSourcePath == entry
            else { throw RemotePreviewError.stale }
            // Confirm the entry still exists as a bounded regular HTML file.
            _ = try RemotePreviewFileReader.read(
                path: entry, maximumBytes: RemotePreviewFileReader.maximumDocumentBytes)
            let asset = try RemotePreviewFileReader.resourcePath(
                relativePath: request.relativePath, entryPath: entry)
            let snapshot = try RemotePreviewFileReader.read(
                path: asset.path, maximumBytes: RemotePreviewFileReader.maximumAssetBytes)
            guard
                try RemotePreviewFileReader.resolveFile(
                    reference: parsed.path, recordedCWD: cwd, explicitlyOpenPaths: openPaths)
                    == entry,
                try RemotePreviewFileReader.resourcePath(
                    relativePath: request.relativePath, entryPath: entry
                ).path == asset.path
            else {
                throw RemotePreviewError.stale
            }
            return .json(
                status: 200, reason: "OK",
                body: try encoder.encode(
                    RemoteHTMLResourceResponse(mimeType: asset.mimeType, data: snapshot.data)))
        }
    }

    private static func preview(_ context: RemotePreviewContext) throws -> RemotePreviewContent {
        switch context.source {
        case .web(let url):
            guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                let host = url.host?.lowercased(),
                host != "localhost", !host.hasSuffix(".localhost"),
                host != "::1", host != "[::1]", !host.hasPrefix("127."),
                host != "0.0.0.0", url.user == nil, url.password == nil
            else {
                throw RemotePreviewError.unsupported
            }
            return .webURL(url)
        case .scratchpad(let documentID, let revision, let directory):
            let store = ScratchpadDocumentStore(directoryURL: directory)
            // Use the store's document identity and schema, but bound actual
            // encoded bytes before decoding rather than Data(contentsOf:).
            let documentPath = try RemotePreviewFileReader.canonicalPath(
                store.documentURL(for: documentID).path)
            let snapshot = try RemotePreviewFileReader.read(
                path: documentPath, maximumBytes: 8 * 1024 * 1024)
            let document = try JSONDecoder().decode(ScratchpadDocument.self, from: snapshot.data)
            guard document.documentID == documentID, document.revision == revision else {
                throw RemotePreviewError.stale
            }
            guard document.content.utf8.count <= ScratchpadDocumentStore.defaultMaxContentBytes
            else { throw RemotePreviewError.tooLarge }
            return .scratchpad(
                .init(
                    documentID: documentID, title: document.title ?? context.title,
                    html: document.content, revision: document.revision))
        case .file(let reference, let cwd, let openPaths, let format):
            let parsed = try fileReference(reference)
            let path = try RemotePreviewFileReader.resolveFile(
                reference: parsed.path, recordedCWD: cwd, explicitlyOpenPaths: openPaths)
            let snapshot = try RemotePreviewFileReader.read(
                path: path, maximumBytes: RemotePreviewFileReader.maximumDocumentBytes)
            guard
                try RemotePreviewFileReader.resolveFile(
                    reference: parsed.path, recordedCWD: cwd, explicitlyOpenPaths: openPaths)
                    == path
            else {
                throw RemotePreviewError.stale
            }
            let content = try decodedText(snapshot.data)
            let title = URL(fileURLWithPath: path).lastPathComponent
            if ["html", "htm"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
                return .html(
                    .init(
                        title: title, sourcePath: path, html: content, revision: snapshot.revision))
            }
            let classification =
                LocalDocumentClassifier.classification(forFilePath: path)
                ?? format.map { LocalDocumentClassifier.classification(format: $0) }
            guard let classification else { throw RemotePreviewError.unsupported }
            let state: String
            if !classification.warnsWhenSyntaxHighlightUnavailable {
                state = "plainText"
            } else if classification.syntaxLanguage == nil && classification.format != .markdown {
                state = "unsupportedFormat"
            } else if content.utf8.count > 512 * 1024 {
                state = "disabledForLargeFile"
            } else {
                state = "enabled"
            }
            return .document(
                .init(
                    title: title, sourcePath: path, content: content,
                    format: classification.format.rawValue,
                    language: classification.syntaxLanguage?.rawValue,
                    highlight: state == "enabled", line: parsed.line, revision: snapshot.revision,
                    formatLabel: classification.formatLabel, highlightState: state))
        }
    }

    private static func decodedText(_ data: Data) throws -> String {
        if let utf8 = String(data: data, encoding: .utf8), !utf8.utf8.contains(0) {
            return utf8
        }
        // Detect an encoding from the already bounded bytes, as the desktop
        // loader does for files. Never reopen the path for text conversion.
        var converted: NSString?
        var lossy: ObjCBool = false
        let encoding = NSString.stringEncoding(
            for: data,
            encodingOptions: [.allowLossyKey: false],
            convertedString: &converted,
            usedLossyConversion: &lossy
        )
        guard encoding != 0, !lossy.boolValue, let converted,
            !(converted as String).utf8.contains(0)
        else { throw RemotePreviewError.unsupported }
        return converted as String
    }

    static func fileReference(_ reference: String) throws -> (path: String, line: Int?) {
        guard !reference.isEmpty, reference.utf8.count <= 4096 else {
            throw RemotePreviewError.denied
        }
        var path = reference
        var line: Int?
        // Accept the two explicit line-reference forms emitted by conversation
        // links. This is not a prose/filename guesser.
        if let range = path.range(
            of: #"(?:#L|:)([1-9][0-9]*)(?::[1-9][0-9]*)?$"#, options: .regularExpression)
        {
            let suffix = String(path[range]).replacingOccurrences(of: "#L", with: ":")
            line = suffix.split(separator: ":").first.flatMap { Int($0) }
            path.removeSubrange(range)
        }
        if path.hasPrefix("file:") {
            guard let url = URL(string: path), url.isFileURL,
                url.host == nil || url.host == "" || url.host == "localhost"
            else {
                throw RemotePreviewError.denied
            }
            path = url.path
        }
        guard !path.isEmpty, line == nil || (line! <= 10_000_000) else {
            throw RemotePreviewError.denied
        }
        return (path, line)
    }
}
