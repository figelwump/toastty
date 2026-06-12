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
    private static let pointDiameter: CGFloat = 24
    private static let rectangleLineWidth: CGFloat = 3

    private static var markColor: NSColor { .systemRed }
    private static var textColor: NSColor { .white }
    private static var numberFont: NSFont { .systemFont(ofSize: 13, weight: .bold) }

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
        context.setShouldAntialias(true)
        context.draw(sourceCGImage, in: CGRect(origin: .zero, size: imageSize))
        for annotation in section.annotations {
            draw(annotation: annotation, imageSize: imageSize, context: context)
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

    private static func draw(
        annotation: BrowserAnnotationItem,
        imageSize: CGSize,
        context: CGContext
    ) {
        switch annotation.kind {
        case .point(let point):
            let center = BrowserAnnotationCoordinateMapper.drawingPoint(
                forNormalizedTopLeftPoint: point,
                imageSize: imageSize
            )
            drawNumberBubble(
                sequenceNumber: annotation.sequenceNumber,
                center: center,
                diameter: pointDiameter,
                context: context
            )

        case .rectangle(let rect):
            let drawingRect = BrowserAnnotationCoordinateMapper.drawingRect(
                forNormalizedTopLeftRect: rect,
                imageSize: imageSize
            )
            context.setStrokeColor(markColor.cgColor)
            context.setLineWidth(rectangleLineWidth)
            context.stroke(drawingRect)

            let labelCenter = CGPoint(
                x: drawingRect.minX + pointDiameter * 0.5,
                y: drawingRect.maxY - pointDiameter * 0.5
            )
            drawNumberBubble(
                sequenceNumber: annotation.sequenceNumber,
                center: labelCenter,
                diameter: pointDiameter,
                context: context
            )
        }
    }

    private static func drawNumberBubble(
        sequenceNumber: Int,
        center: CGPoint,
        diameter: CGFloat,
        context: CGContext
    ) {
        let bubbleRect = CGRect(
            x: center.x - diameter * 0.5,
            y: center.y - diameter * 0.5,
            width: diameter,
            height: diameter
        )
        context.setFillColor(markColor.cgColor)
        context.fillEllipse(in: bubbleRect)

        let text = "\(sequenceNumber)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: textColor,
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
        var lines: [String] = ["Browser annotations"]

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
                lines.append("\(annotation.sequenceNumber). \(annotation.comment)")
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
