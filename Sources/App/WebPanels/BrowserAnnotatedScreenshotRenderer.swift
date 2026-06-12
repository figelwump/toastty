import AppKit
import Foundation

enum BrowserAnnotatedScreenshotRendererError: LocalizedError, Equatable {
    case invalidPNGData
    case bitmapContextUnavailable
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidPNGData:
            return "browser annotation screenshot data is not a valid PNG"
        case .bitmapContextUnavailable:
            return "failed to create an annotation rendering context"
        case .pngEncodingFailed:
            return "failed to encode annotated browser screenshot"
        }
    }
}

enum BrowserAnnotatedScreenshotRenderer {
    static func render(section: BrowserAnnotationSection) throws -> Data {
        guard let sourceRep = NSBitmapImageRep(data: section.pngData),
              let sourceCGImage = sourceRep.cgImage else {
            throw BrowserAnnotatedScreenshotRendererError.invalidPNGData
        }

        let pixelWidth = max(1, sourceRep.pixelsWide)
        let pixelHeight = max(1, sourceRep.pixelsHigh)
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw BrowserAnnotatedScreenshotRendererError.bitmapContextUnavailable
        }

        let imageSize = CGSize(width: pixelWidth, height: pixelHeight)
        // Screenshots are usually denser than the viewport (Retina). Scale
        // mark sizes by that ratio so sent PNGs match what the overlay showed.
        let scale = markScale(imageSize: imageSize, viewportSize: section.viewportSize)
        context.setShouldAntialias(true)
        context.draw(sourceCGImage, in: CGRect(origin: .zero, size: imageSize))
        for annotation in section.annotations {
            draw(annotation: annotation, imageSize: imageSize, scale: scale, context: context)
        }

        guard let renderedImage = context.makeImage() else {
            throw BrowserAnnotatedScreenshotRendererError.bitmapContextUnavailable
        }
        let bitmap = NSBitmapImageRep(cgImage: renderedImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw BrowserAnnotatedScreenshotRendererError.pngEncodingFailed
        }
        return pngData
    }

    static func markScale(imageSize: CGSize, viewportSize: CGSize) -> CGFloat {
        guard viewportSize.width > 0 else { return 1 }
        let scale = imageSize.width / viewportSize.width
        return scale > 0 ? scale : 1
    }

    private static func draw(
        annotation: BrowserAnnotationItem,
        imageSize: CGSize,
        scale: CGFloat,
        context: CGContext
    ) {
        let diameter = BrowserAnnotationMarkStyle.bubbleDiameter * scale

        switch annotation.kind {
        case .point(let point):
            let center = BrowserAnnotationCoordinateMapper.drawingPoint(
                forNormalizedTopLeftPoint: point,
                imageSize: imageSize
            )
            drawNumberBubble(
                sequenceNumber: annotation.sequenceNumber,
                center: center,
                diameter: diameter,
                scale: scale,
                context: context
            )

        case .rectangle(let rect):
            let drawingRect = BrowserAnnotationCoordinateMapper.drawingRect(
                forNormalizedTopLeftRect: rect,
                imageSize: imageSize
            )
            context.setFillColor(
                BrowserAnnotationMarkStyle.markColor
                    .withAlphaComponent(BrowserAnnotationMarkStyle.rectangleFillAlpha)
                    .cgColor
            )
            context.fill(drawingRect)
            context.setStrokeColor(BrowserAnnotationMarkStyle.markColor.cgColor)
            context.setLineWidth(BrowserAnnotationMarkStyle.rectangleLineWidth * scale)
            context.stroke(drawingRect)

            // Badge centered on the rectangle's top-left corner so it covers
            // as little marked content as possible.
            drawNumberBubble(
                sequenceNumber: annotation.sequenceNumber,
                center: CGPoint(x: drawingRect.minX, y: drawingRect.maxY),
                diameter: diameter,
                scale: scale,
                context: context
            )
        }
    }

    private static func drawNumberBubble(
        sequenceNumber: Int,
        center: CGPoint,
        diameter: CGFloat,
        scale: CGFloat,
        context: CGContext
    ) {
        let bubbleRect = CGRect(
            x: center.x - diameter * 0.5,
            y: center.y - diameter * 0.5,
            width: diameter,
            height: diameter
        )
        let ringWidth = BrowserAnnotationMarkStyle.bubbleRingWidth * scale

        context.saveGState()
        context.setShadow(
            offset: CGSize(
                width: BrowserAnnotationMarkStyle.shadowOffset.width * scale,
                height: BrowserAnnotationMarkStyle.shadowOffset.height * scale
            ),
            blur: BrowserAnnotationMarkStyle.shadowBlurRadius * scale,
            color: BrowserAnnotationMarkStyle.shadowColor.cgColor
        )
        context.setFillColor(BrowserAnnotationMarkStyle.ringColor.cgColor)
        context.fillEllipse(in: bubbleRect.insetBy(dx: -ringWidth, dy: -ringWidth))
        context.restoreGState()

        context.setFillColor(BrowserAnnotationMarkStyle.markColor.cgColor)
        context.fillEllipse(in: bubbleRect)

        let text = "\(sequenceNumber)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: BrowserAnnotationMarkStyle.numberFont(scale: scale),
            .foregroundColor: BrowserAnnotationMarkStyle.numberTextColor,
        ]
        let textSize = text.size(withAttributes: attributes)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(
            at: CGPoint(
                x: center.x - textSize.width * 0.5,
                y: center.y - textSize.height * 0.5
            ),
            withAttributes: attributes
        )
        NSGraphicsContext.restoreGraphicsState()
    }
}

struct BrowserAnnotationRenderedSection: Equatable {
    var section: BrowserAnnotationSection
    var fileURL: URL
}

enum BrowserAnnotationPayloadBuilder {
    static func payload(renderedSections: [BrowserAnnotationRenderedSection]) -> String {
        // Self-describing preamble so receiving agents act on the feedback
        // directly instead of searching for a skill that explains the format.
        var lines: [String] = [
            "Browser annotation feedback from Toastty.",
            "Each numbered comment refers to the matching numbered mark drawn in the screenshot listed above it. Read each screenshot and address the comments.",
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
