import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import RemoteProtocol

/// First-party QR rendering for the native pairing offer. The source payload
/// remains an in-memory value owned by the pairing view; callers must not use
/// it as an accessibility label, log field, URL, or diagnostic attachment.
@MainActor
enum RemoteAccessPairingQRCode {
    private static let context = CIContext(options: [
        .cacheIntermediates: false,
    ])

    static func image(payload: String, scale: CGFloat = 8) -> NSImage? {
        let data = Data(payload.utf8)
        guard data.isEmpty == false,
              data.count <= RemoteNativePairingQRPayload.maximumEncodedByteCount,
              scale >= 1 else {
            return nil
        }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }

        let scaledImage = outputImage.transformed(by: CGAffineTransform(
            scaleX: scale,
            y: scale
        ))
        guard let cgImage = context.createCGImage(
            scaledImage,
            from: scaledImage.extent,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        ) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(
            width: scaledImage.extent.width,
            height: scaledImage.extent.height
        ))
    }
}

enum RemoteAccessPairingPresentation {
    static func expiryLabel(expiresAt: Date, at date: Date) -> String {
        let remaining = max(0, Int(ceil(expiresAt.timeIntervalSince(date))))
        return "Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))"
    }
}
