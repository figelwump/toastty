import CoreState
import Foundation
import RemoteProtocol

/// Immutable state captured on the main actor. Equality is checked again after
/// IO so a closed/moved panel or changed conversation cannot keep a stale grant.
struct RemotePreviewContext: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// `isTranscriptLinked` is the Mac's own finding that this reference is
        /// a link destination in the conversation's assistant output. It is
        /// part of the context so the post-IO equality check covers the grant.
        case file(
            reference: String, recordedCWD: String?, openPaths: [String],
            format: LocalDocumentFormat?, isTranscriptLinked: Bool)
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
        var grant: RemotePreviewFileReader.FileGrant?
        do {
            return try response(operation: operation, context: context, grant: &grant)
        } catch {
            if (error is CancellationError) == false {
                logFailure(
                    error, stage: .read, request: operation.request, context: context, grant: grant)
            }
            throw error
        }
    }

    private static func response(
        operation: RemoteGatewayPreviewOperation, context: RemotePreviewContext,
        grant: inout RemotePreviewFileReader.FileGrant?
    ) throws -> RemoteGatewayHTTPResponse {
        let encoder = JSONEncoder()
        switch operation.request {
        case .preview:
            let content = try preview(context, grant: &grant)
            return .json(
                status: 200, reason: "OK",
                body: try encoder.encode(RemotePreviewResponse(content: content)))
        case .resource(let request):
            guard case .file(let reference, let cwd, let openPaths, _, let isLinked) = context.source
            else {
                throw RemotePreviewError.unsupported
            }
            let parsed = try fileReference(reference)
            let resolved = try RemotePreviewFileReader.resolveFile(
                reference: parsed.path, recordedCWD: cwd, explicitlyOpenPaths: openPaths,
                isTranscriptLinked: isLinked)
            grant = resolved.grant
            let entry = resolved.path
            guard ["html", "htm"].contains(URL(fileURLWithPath: entry).pathExtension.lowercased()),
                request.expectedSourcePath == entry
            else { throw RemotePreviewError.stale }
            guard try RemotePreviewFileReader.allowsSubresources(of: resolved) else {
                throw RemotePreviewError.denied
            }
            // Confirm the entry still exists as a bounded regular HTML file.
            _ = try RemotePreviewFileReader.read(
                path: entry, maximumBytes: RemotePreviewFileReader.maximumDocumentBytes)
            let asset = try RemotePreviewFileReader.resourcePath(
                relativePath: request.relativePath, entryPath: entry)
            let snapshot = try RemotePreviewFileReader.read(
                path: asset.path, maximumBytes: RemotePreviewFileReader.maximumAssetBytes)
            guard
                try RemotePreviewFileReader.resolveFile(
                    reference: parsed.path, recordedCWD: cwd, explicitlyOpenPaths: openPaths,
                    isTranscriptLinked: isLinked) == resolved,
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

    private static func preview(
        _ context: RemotePreviewContext, grant: inout RemotePreviewFileReader.FileGrant?
    ) throws -> RemotePreviewContent {
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
        case .file(let reference, let cwd, let openPaths, let format, let isLinked):
            let parsed = try fileReference(reference)
            let resolved = try RemotePreviewFileReader.resolveFile(
                reference: parsed.path, recordedCWD: cwd, explicitlyOpenPaths: openPaths,
                isTranscriptLinked: isLinked)
            grant = resolved.grant
            let path = resolved.path
            let snapshot = try RemotePreviewFileReader.read(
                path: path, maximumBytes: RemotePreviewFileReader.maximumDocumentBytes)
            guard
                try RemotePreviewFileReader.resolveFile(
                    reference: parsed.path, recordedCWD: cwd, explicitlyOpenPaths: openPaths,
                    isTranscriptLinked: isLinked) == resolved
            else {
                throw RemotePreviewError.stale
            }
            let content = try decodedText(snapshot.data)
            let title = URL(fileURLWithPath: path).lastPathComponent
            // The desktop classifier opens dotenv files, and the older grants
            // keep that. A transcript link alone does not extend it: these
            // files usually hold secrets, wherever the agent pointed.
            if resolved.grant == .transcriptLink,
                LocalDocumentClassifier.supportsDotenvFileName(title)
            {
                throw RemotePreviewError.unsupported
            }
            if ["html", "htm"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
                return .html(
                    .init(
                        title: title, sourcePath: path, html: content, revision: snapshot.revision))
            }
            let classification =
                LocalDocumentClassifier.classification(forFilePath: path)
                ?? format.map { LocalDocumentClassifier.classification(format: $0) }
                ?? plainTextFallback(forFileName: title)
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

    /// Remote-only: `LocalDocumentClassifier` also drives the desktop file
    /// picker and panel formats, which this must not widen. The content has
    /// already decoded as NUL-free text. Dotfiles and other unknown
    /// extensions (for example `.env`-style secrets) stay unsupported.
    static func plainTextFallback(forFileName fileName: String) -> LocalDocumentClassification? {
        let pathExtension = (fileName as NSString).pathExtension.lowercased()
        let label: String
        switch pathExtension {
        case "patch", "diff": label = "Patch"
        case "" where !fileName.hasPrefix("."): label = "Plain Text"
        default: return nil
        }
        return .init(
            format: .code, syntaxLanguage: nil, formatLabel: label,
            warnsWhenSyntaxHighlightUnavailable: false)
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

    // MARK: - Failure logging

    /// Where a request failed. Grant fields are reported only for `read`,
    /// the one stage that decides a grant.
    enum FailureStage: String {
        /// Refused before any work because too many previews were in flight.
        case admission
        /// The panel or conversation could not be turned into a source.
        case context
        /// Resolving, authorizing, reading, or decoding the content.
        case read
        /// The content was read, but the source changed during the read.
        case recheck
    }

    static func logFailure(
        _ error: any Error, stage: FailureStage,
        request: RemoteGatewayPreviewOperation.Request,
        context: RemotePreviewContext?, grant: RemotePreviewFileReader.FileGrant? = nil
    ) {
        ToasttyLog.warning(
            "Remote preview failed", category: .automation,
            metadata: failureLogMetadata(
                error, stage: stage, request: request, context: context, grant: grant))
    }

    /// Describes a failure without paths, file names, or content: those can
    /// carry a login, hostname, or project name across the logging boundary.
    static func failureLogMetadata(
        _ error: any Error, stage: FailureStage,
        request: RemoteGatewayPreviewOperation.Request,
        context: RemotePreviewContext?, grant: RemotePreviewFileReader.FileGrant?
    ) -> [String: String] {
        var metadata: [String: String] = ["stage": stage.rawValue]
        if let error = error as? RemotePreviewError {
            metadata["reason"] = error.rawValue
        } else {
            // The gateway reports these as `missing`; keep what they were.
            metadata["reason"] = RemotePreviewError.missing.rawValue
            metadata["underlying_error"] = String(reflecting: type(of: error))
        }
        switch request {
        case .preview: metadata["request"] = "preview"
        case .resource: metadata["request"] = "resource"
        }
        let requestedReference: String?
        switch request.target {
        case .panel:
            metadata["target"] = "panel"
            requestedReference = nil
        case .conversationFile(_, let reference):
            metadata["target"] = "conversation-file"
            requestedReference = reference
        }
        guard case .file(let contextReference, let cwd, let openPaths, _, let isLinked)? =
            context?.source
        else {
            if let context {
                metadata["source"] = if case .web = context.source { "web" } else { "scratchpad" }
            } else if let requestedReference {
                describe(reference: requestedReference, in: &metadata)
            }
            return metadata
        }
        describe(reference: requestedReference ?? contextReference, in: &metadata)
        metadata["source"] = "file"
        metadata["cwd"] = cwd == nil ? "absent" : "present"
        metadata["transcript_linked"] = isLinked ? "true" : "false"
        guard stage == .read else { return metadata }
        if let grant {
            metadata["grant"] = grant.rawValue
        } else {
            var attempted: [RemotePreviewFileReader.FileGrant] = []
            if !openPaths.isEmpty { attempted.append(.openPanel) }
            if cwd != nil { attempted.append(.projectRoot) }
            if isLinked { attempted.append(.transcriptLink) }
            metadata["grant"] = "none"
            metadata["grants_attempted"] =
                attempted.isEmpty ? "none" : attempted.map(\.rawValue).joined(separator: ",")
        }
        return metadata
    }

    private static func describe(reference: String, in metadata: inout [String: String]) {
        let path = (try? fileReference(reference).path) ?? reference
        metadata["reference"] = path.hasPrefix("/") ? "absolute" : "relative"
        let pathExtension = (path as NSString).pathExtension.lowercased()
        // Bounded and alphanumeric, so a crafted name cannot smuggle text.
        metadata["extension"] =
            pathExtension.isEmpty
            ? "none"
            : pathExtension.count <= 16
                && pathExtension.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
                ? pathExtension : "other"
    }
}
