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
