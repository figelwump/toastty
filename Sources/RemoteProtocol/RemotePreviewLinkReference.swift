import Foundation

/// Link parsing shared by the phone, which decides what a tapped transcript
/// link requests, and the Mac, which grants only references its own
/// transcript data contains. Both sides must derive references the same way,
/// or a link the phone can tap becomes one the Mac cannot grant.
public enum RemotePreviewLinkReference {
    /// Longer references can never resolve (`RemotePreviewFileReader` rejects
    /// them), so they are not worth recording as grants either.
    public static let maximumReferenceBytes = 4096

    /// Only actual link destinations are routed here. Plain transcript prose is never scanned.
    public static func localFileReference(_ url: URL) -> String? {
        let scheme = url.scheme?.lowercased()
        if scheme != nil && scheme != "file" {
            // URL parses a bare filename followed by :line as a scheme. This
            // narrow exception applies only to an existing Markdown link.
            let raw = url.absoluteString
            guard raw.range(of: #"^[^\s/:]+\.[A-Za-z0-9]+:[1-9][0-9]*(?::[1-9][0-9]*)?(?:#L[1-9][0-9]*)?$"#,
                            options: .regularExpression) != nil else { return nil }
            return raw
        }
        guard url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
        let reference = scheme == "file" ? url.path : url.relativeString.components(separatedBy: "#")[0]
        guard !reference.isEmpty, !reference.hasPrefix("#") else { return nil }
        let decoded = scheme == "file" ? reference : (reference.removingPercentEncoding ?? reference)
        return decoded + (url.fragment.map { "#" + $0 } ?? "")
    }

    /// The local file references a transcript renderer would produce for the
    /// link destinations in `markdown`, in document order. Uses the same
    /// Foundation Markdown grammar as the phone's transcript view.
    public static func localFileReferences(inMarkdown markdown: String) -> [String] {
        // Every Markdown link form needs a bracket (inline and reference
        // links) or an angle bracket (autolinks). Skipping the parse for
        // other text keeps transcript ingestion cheap.
        guard markdown.contains("]") || markdown.contains("<"),
              let attributed = try? AttributedString(markdown: markdown) else { return [] }
        var references: [String] = []
        for run in attributed.runs {
            guard let url = run.link, let reference = localFileReference(url),
                  reference.utf8.count <= maximumReferenceBytes,
                  references.last != reference else { continue }
            references.append(reference)
        }
        return references
    }
}
