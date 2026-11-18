#if DEBUG
import Foundation
import RemoteProtocol
import ToasttyMobileDomain
import UIKit

/// The fixture Mac's images for the coordinator chat. It finds the file as
/// the Mac does, by the message's event and the file's place in the
/// message's list, and draws an image for it. `Photo-91C2.jpg` is gone from
/// the Mac, and `slow-capture.png` does not come, so a box stays loading.
enum ToasttyAttachmentImageFixture {
    static let goneFileName = "Photo-91C2.jpg"
    static let slowFileName = "slow-capture.png"
    /// The name the Mac gave the photo that the phone sent.
    static let phonePhotoFileName = "9B1E4C2A-7D3F-4E21-8C5B-2A6F1D0E9C47.jpg"

    static func image(for request: RemoteCoordinatorAttachmentImageRequest) async throws -> Data {
        try Task.checkCancellation()
        guard request.conversationID.rawValue == ToasttyMobileFixture.coordinatorConversationID else {
            throw RemotePreviewError.denied
        }
        let events = ToasttyConversationFixture.coordinatorEvents(
            for: ToasttyMobileFixture.coordinatorConversationID, attachedImages: true)
        guard let event = events.last(where: { $0.eventID == request.eventID }) else { throw RemotePreviewError.missing }
        guard case .userMessage(let payload) = event.payload else { throw RemotePreviewError.denied }
        let paths = payload.attachmentPaths ?? CoordinatorMessageHeader.displayParts(of: payload.text).attachmentPaths
        guard paths.indices.contains(request.attachmentIndex) else { throw RemotePreviewError.denied }
        let name = URL(fileURLWithPath: paths[request.attachmentIndex]).lastPathComponent
        switch name {
        case goneFileName:
            throw RemotePreviewError.missing
        case slowFileName:
            try await Task.sleep(for: .seconds(3_600))
        default:
            break
        }
        // The image's shape and colour come from its name, so each one is
        // easy to tell apart in a screenshot.
        let (aspect, colour): (CGFloat, UIColor) = switch name {
        case "crash-screen.png": (16.0 / 10.0, UIColor(red: 0.62, green: 0.18, blue: 0.16, alpha: 1))
        case "csv-mockup.png": (4.0 / 3.0, UIColor(red: 0.16, green: 0.42, blue: 0.30, alpha: 1))
        default: (3.0 / 4.0, UIColor(red: 0.18, green: 0.32, blue: 0.62, alpha: 1))
        }
        let longSide = CGFloat(request.size.maximumPixelSize == RemoteCoordinatorAttachmentImagePolicy.thumbnailMaximumPixelSize
            ? 600 : 2_400)
        let size = aspect >= 1
            ? CGSize(width: longSide, height: (longSide / aspect).rounded())
            : CGSize(width: (longSide * aspect).rounded(), height: longSide)
        return draw(name: name, size: size, colour: colour, isFull: request.size == .full)
    }

    private static func draw(name: String, size: CGSize, colour: UIColor, isFull: Bool) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            colour.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            // A window, with lines of text, inside the image.
            let unit = min(size.width, size.height) / 12
            let window = CGRect(x: unit, y: unit, width: size.width - 2 * unit, height: size.height - 2 * unit)
            UIColor(white: 0.96, alpha: 1).setFill()
            UIBezierPath(roundedRect: window, cornerRadius: unit / 2).fill()
            UIColor(white: 0.75, alpha: 1).setFill()
            for line in 0..<4 {
                let width = window.width * (line.isMultiple(of: 2) ? 0.7 : 0.5)
                context.fill(CGRect(x: window.minX + unit, y: window.minY + unit * CGFloat(2 + line * 2),
                                    width: width - unit, height: unit * 0.8))
            }
            let label = isFull ? "\(name) · full size" : name
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: unit * 0.9),
                .foregroundColor: colour,
            ]
            (label as NSString).draw(at: CGPoint(x: window.minX + unit, y: window.maxY - unit * 2), withAttributes: attributes)
        }
    }
}
#endif
