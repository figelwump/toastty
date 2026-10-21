import AppKit
import Foundation

struct BrowserAnnotationRenderedSection: Equatable {
    var section: BrowserAnnotationSection
    var fileURL: URL
}

enum BrowserAnnotationPayloadBuilder {
    static func payload(
        renderedSections: [BrowserAnnotationRenderedSection],
        source: WebPanelAnnotationSource = .browser
    ) -> String {
        // Self-describing preamble so receiving agents act on the feedback
        // directly instead of searching for a skill that explains the format.
        var lines: [String] = [
            "\(source.label) annotation feedback from Toastty.",
            "Each numbered comment refers to the matching numbered mark drawn in the screenshot listed above it. Read each screenshot and address the comments.",
            "For small/medium scope changes, go ahead with implementation. Only ask the user for plan review for large changes.",
        ]

        for (index, renderedSection) in renderedSections.enumerated() {
            let section = renderedSection.section
            lines.append("")
            lines.append("Screenshot \(index + 1): \(renderedSection.fileURL.path(percentEncoded: false))")
            if let title = normalized(section.title) {
                lines.append("Page: \(title)")
            }
            if let url = normalized(section.url) {
                lines.append("URL: \(url)")
            }
            lines.append(
                "Viewport: x=\(rounded(section.scrollOffset.x)), y=\(rounded(section.scrollOffset.y)), " +
                    "w=\(rounded(section.viewportSize.width)), h=\(rounded(section.viewportSize.height))"
            )
            for annotation in section.annotations.sorted(by: { $0.sequenceNumber < $1.sequenceNumber }) {
                // Indent continuation lines of multiline comments so they stay
                // attached to their numbered entry in the payload.
                let commentLines = annotation.comment.components(separatedBy: .newlines)
                lines.append("\(annotation.sequenceNumber). \(commentLines[0])")
                for continuationLine in commentLines.dropFirst() {
                    lines.append("   \(continuationLine)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func rounded(_ value: CGFloat) -> String {
        String(format: "%.0f", Double(value))
    }
}

enum BrowserAnnotationScreenshotWriter {
    private static let directoryName = "toastty-browser-annotations"

    static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func writeRenderedSections(
        from sections: [BrowserAnnotationSection],
        date: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> [BrowserAnnotationRenderedSection] {
        let directoryURL = defaultDirectoryURL(fileManager: fileManager)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var renderedSections: [BrowserAnnotationRenderedSection] = []
        let batchID = UUID()
        do {
            for (index, section) in sections.enumerated() {
                let renderedData = try BrowserAnnotatedScreenshotRenderer.render(section: section)
                let fileURL = directoryURL.appendingPathComponent(
                    fileName(for: section, index: index, date: date, batchID: batchID),
                    isDirectory: false
                )
                try renderedData.write(to: fileURL, options: [.atomic])
                renderedSections.append(BrowserAnnotationRenderedSection(
                    section: section,
                    fileURL: fileURL
                ))
            }
        } catch {
            for renderedSection in renderedSections {
                try? fileManager.removeItem(at: renderedSection.fileURL)
            }
            throw error
        }

        return renderedSections
    }

    private static func fileName(
        for section: BrowserAnnotationSection,
        index: Int,
        date: Date,
        batchID: UUID
    ) -> String {
        let baseName = BrowserPanelScreenshotWriter.suggestedFileName(
            title: section.title,
            urlString: section.url,
            date: date
        )
        let baseURL = URL(fileURLWithPath: baseName)
        let stem = baseURL.deletingPathExtension().lastPathComponent
        let pathExtension = baseURL.pathExtension.isEmpty ? "png" : baseURL.pathExtension
        return "\(stem)-annotation-\(index + 1)-\(batchID.uuidString).\(pathExtension)"
    }
}
