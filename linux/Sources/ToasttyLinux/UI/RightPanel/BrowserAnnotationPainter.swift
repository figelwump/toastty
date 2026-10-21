#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import Foundation
import ToasttyAppLogic

/// Draws annotation marks with cairo + Pango: the live overlay and the
/// annotated screenshot use the same routines, so sent PNGs match what the
/// overlay showed (macOS shares `BrowserAnnotationMarkStyle` between its
/// AppKit overlay and its CoreGraphics renderer the same way).
enum AnnotationMarkPainter {
    typealias Style = LinuxAnnotationMarkStyle

    static func setMarkColor(_ cr: OpaquePointer, alpha: Double = 1) {
        let color = Style.markColor
        cairo_set_source_rgba(cr, color.red, color.green, color.blue, alpha)
    }

    /// Translucent fill plus a solid outline.
    static func drawRectangle(_ cr: OpaquePointer, _ rect: CGRect, scale: CGFloat = 1) {
        cairo_save(cr)
        cairo_new_path(cr)
        cairo_rectangle(cr, rect.minX, rect.minY, rect.width, rect.height)
        setMarkColor(cr, alpha: Double(Style.rectangleFillAlpha))
        cairo_fill_preserve(cr)
        setMarkColor(cr)
        cairo_set_line_width(cr, Double(Style.rectangleLineWidth * scale))
        cairo_stroke(cr)
        cairo_restore(cr)
    }

    static func drawHoverHalo(_ cr: OpaquePointer, bubbleRect: CGRect) {
        let radius = bubbleRect.width / 2 + Style.bubbleRingWidth + Style.hoverRingExtraRadius
        cairo_save(cr)
        cairo_new_path(cr)
        cairo_arc(cr, bubbleRect.midX, bubbleRect.midY, radius, 0, 2 * .pi)
        setMarkColor(cr, alpha: Double(Style.hoverRingAlpha))
        cairo_fill(cr)
        cairo_restore(cr)
    }

    /// White-ringed red disc with the number, over a soft drop shadow.
    static func drawBubble(_ cr: OpaquePointer, number: Int, center: CGPoint, scale: CGFloat = 1) {
        let radius = Style.bubbleDiameter * scale / 2
        let ring = Style.bubbleRingWidth * scale
        let blur = Style.shadowBlurRadius * scale
        let offset = Style.shadowOffsetDown * scale
        cairo_save(cr)
        // Cairo has no blur: approximate the AppKit shadow with stacked
        // translucent discs that grow by the blur radius.
        let steps = 3
        for step in stride(from: steps, through: 1, by: -1) {
            let grow = blur * CGFloat(step) / CGFloat(steps)
            cairo_new_path(cr)
            cairo_arc(cr, center.x, center.y + offset, radius + ring + grow, 0, 2 * .pi)
            cairo_set_source_rgba(cr, 0, 0, 0, Double(Style.shadowAlpha) / Double(steps + 1))
            cairo_fill(cr)
        }
        cairo_new_path(cr)
        cairo_arc(cr, center.x, center.y, radius + ring, 0, 2 * .pi)
        cairo_set_source_rgba(cr, 1, 1, 1, 1)
        cairo_fill(cr)
        cairo_new_path(cr)
        cairo_arc(cr, center.x, center.y, radius, 0, 2 * .pi)
        setMarkColor(cr)
        cairo_fill(cr)

        if let layout = pango_cairo_create_layout(cr) {
            let font = pango_font_description_from_string("Sans Bold")
            pango_font_description_set_absolute_size(font, Double(Style.numberFontSize * scale) * Double(PANGO_SCALE))
            pango_layout_set_font_description(layout, font)
            pango_font_description_free(font)
            pango_layout_set_text(layout, "\(number)", -1)
            var width: Int32 = 0
            var height: Int32 = 0
            pango_layout_get_pixel_size(layout, &width, &height)
            cairo_set_source_rgba(cr, 1, 1, 1, 1)
            cairo_move_to(cr, center.x - Double(width) / 2, center.y - Double(height) / 2)
            pango_cairo_show_layout(cr, layout)
            g_object_unref(UnsafeMutableRawPointer(layout))
        }
        cairo_restore(cr)
    }

    /// One overlay mark (rectangle body, hover halo, bubble).
    static func drawMark(_ cr: OpaquePointer, _ mark: LinuxAnnotationMark) {
        if case .rectangle(let rect) = mark.shape { drawRectangle(cr, rect) }
        if mark.isHovered { drawHoverHalo(cr, bubbleRect: mark.bubbleRect) }
        drawBubble(cr, number: mark.number, center: CGPoint(x: mark.bubbleRect.midX, y: mark.bubbleRect.midY))
    }
}

public enum LinuxAnnotationScreenshotRendererError: Error, Equatable {
    case invalidPNG
    case encodingFailed
}

/// The annotated screenshot renderer installed into the app-logic layer
/// (`LinuxAppLogic.installAnnotationScreenshotRenderer`).
public enum LinuxAnnotationScreenshotRenderer {
    public static func render(_ request: LinuxAnnotationRenderRequest) throws -> Data {
        guard let image = DecodedImage(png: request.pngData) else { throw LinuxAnnotationScreenshotRendererError.invalidPNG }
        let width = image.width, height = image.height
        let scale = request.markScale(imagePixelWidth: width)
        guard let cr = cairo_create(image.surface) else { throw LinuxAnnotationScreenshotRendererError.encodingFailed }
        cairo_set_antialias(cr, CAIRO_ANTIALIAS_GOOD)
        for mark in request.marks {
            switch mark.kind {
            case .point(let point):
                let center = CGPoint(x: clamp(point.x) * CGFloat(width), y: clamp(point.y) * CGFloat(height))
                AnnotationMarkPainter.drawBubble(cr, number: mark.number, center: center, scale: scale)
            case .rectangle(let normalized):
                let rect = normalized.standardized
                let minX = clamp(rect.minX), maxX = clamp(rect.maxX), minY = clamp(rect.minY), maxY = clamp(rect.maxY)
                let pixels = CGRect(
                    x: minX * CGFloat(width), y: minY * CGFloat(height),
                    width: max(0, maxX - minX) * CGFloat(width), height: max(0, maxY - minY) * CGFloat(height)
                )
                AnnotationMarkPainter.drawRectangle(cr, pixels, scale: scale)
                // Badge on the top-left corner so it covers as little of
                // the marked content as possible.
                AnnotationMarkPainter.drawBubble(cr, number: mark.number, center: pixels.origin, scale: scale)
            }
        }
        cairo_destroy(cr)
        guard let png = image.pngData() else { throw LinuxAnnotationScreenshotRendererError.encodingFailed }
        return png
    }

    /// RGBA of one pixel of a PNG (tests, automation checks).
    public static func pixel(png: Data, x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)? {
        guard let image = DecodedImage(png: png), x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        // CAIRO_FORMAT_ARGB32 is B, G, R, A in memory on little-endian hosts.
        let offset = y * image.stride + x * 4
        let data = image.data
        return (data[offset + 2], data[offset + 1], data[offset], data[offset + 3])
    }

    /// Pixel size of a PNG.
    public static func size(png: Data) -> (width: Int, height: Int)? {
        DecodedImage(png: png).map { ($0.width, $0.height) }
    }

    private static func clamp(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }

    /// A PNG decoded by GdkTexture into a cairo ARGB32 image surface.
    private final class DecodedImage {
        let surface: OpaquePointer
        let width: Int
        let height: Int
        let stride: Int

        init?(png: Data) {
            let bytes = png.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
            defer { g_bytes_unref(bytes) }
            var error: UnsafeMutablePointer<GError>?
            guard let texture = gdk_texture_new_from_bytes(bytes, &error) else {
                if let error { g_error_free(error) }
                return nil
            }
            defer { g_object_unref(UnsafeMutableRawPointer(texture)) }
            width = Int(gdk_texture_get_width(texture))
            height = Int(gdk_texture_get_height(texture))
            guard width > 0, height > 0, let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(width), Int32(height)) else {
                return nil
            }
            self.surface = surface
            stride = Int(cairo_image_surface_get_stride(surface))
            cairo_surface_flush(surface)
            guard let pixels = cairo_image_surface_get_data(surface) else { return nil }
            // GDK_MEMORY_DEFAULT (premultiplied B8G8R8A8) is cairo's ARGB32.
            gdk_texture_download(texture, pixels, gsize(stride))
            cairo_surface_mark_dirty(surface)
        }

        deinit { cairo_surface_destroy(surface) }

        var data: UnsafeMutablePointer<UInt8> {
            cairo_surface_flush(surface)
            return cairo_image_surface_get_data(surface)!
        }

        func pngData() -> Data? {
            cairo_surface_flush(surface)
            guard let pixels = cairo_image_surface_get_data(surface) else { return nil }
            let bytes = g_bytes_new(pixels, gsize(stride * height))
            defer { g_bytes_unref(bytes) }
            guard let texture = gdk_memory_texture_new(Int32(width), Int32(height), GDK_MEMORY_B8G8R8A8_PREMULTIPLIED, bytes, gsize(stride)) else {
                return nil
            }
            defer { g_object_unref(UnsafeMutableRawPointer(texture)) }
            return ToasttyLinuxUI.pngData(fromTexture: texture)
        }
    }
}
#endif
