import ConversationUI
import RemoteProtocol
import SwiftUI
import UIKit

/// An image attached to a message in the coordinator's chat, full size, on
/// black. It shows the bubble's thumbnail at once, if it has one, and the
/// full image when the Mac sends it. Pinch or double-tap to zoom; Done, or
/// a swipe down while the image fits the screen, closes it.
struct ToasttyAttachmentImageViewer: View {
    let image: ToasttyAttachedImage
    let source: ToasttyAttachmentImageSource
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var shown: ToasttyAttachmentImage?
    @State private var isFullSize = false
    @State private var fullSizeFailed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let shown {
                ToasttyZoomableImage(
                    image: shown.image,
                    accessibilityLabel: "Image \(image.name)",
                    accessibilityState: isFullSize ? "Full size" : "Small copy",
                    close: { dismiss() }
                )
                .ignoresSafeArea()
            } else if fullSizeFailed {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                    Text(image.name)
                        .font(.callout)
                    Text("The Mac could not send this image.")
                        .font(.footnote)
                }
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(24)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("toastty-mobile-attachment-viewer-unavailable")
            }
            if isFullSize == false, fullSizeFailed == false {
                ToasttySpinner(size: 22, lineWidth: 2.5, color: .white.opacity(0.8))
            }
        }
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottom) {
            if fullSizeFailed, shown != nil {
                Text("The full-size image is not available. This is the small copy.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.bottom, 24)
            }
        }
        .statusBarHidden()
        .task { await load() }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button("Done") { dismiss() }
                .font(.body.weight(.semibold))
                .accessibilityIdentifier("toastty-mobile-attachment-viewer-done")
            Spacer(minLength: 0)
            Text(image.name)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            // Balances Done, so the name stays in the middle.
            Text("Done").font(.body.weight(.semibold)).hidden()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }

    private func load() async {
        let thumbnailPixelSize = ToasttyAttachmentThumbnailMetrics.pixelSize(displayScale: displayScale)
        shown = ToasttyAttachmentImageStore.cachedThumbnail(
            for: image, maximumPixelSize: thumbnailPixelSize, source: source)
        let full = await ToasttyAttachmentImageStore.image(
            for: image,
            size: .full,
            maximumPixelSize: RemoteCoordinatorAttachmentImagePolicy.fullMaximumPixelSize,
            source: source
        )
        guard Task.isCancelled == false else { return }
        if let full {
            shown = full
            isFullSize = true
        } else {
            fullSizeFailed = true
        }
    }
}

/// The image in a scroll view that zooms it. It fits the screen at first.
private struct ToasttyZoomableImage: UIViewRepresentable {
    let image: CGImage
    let accessibilityLabel: String
    let accessibilityState: String
    let close: () -> Void

    func makeUIView(context: Context) -> ToasttyZoomingScrollView {
        let view = ToasttyZoomingScrollView()
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "toastty-mobile-attachment-viewer-image"
        view.accessibilityTraits = .image
        return view
    }

    func updateUIView(_ view: ToasttyZoomingScrollView, context: Context) {
        view.close = close
        view.accessibilityLabel = accessibilityLabel
        view.stateText = accessibilityState
        view.show(image)
    }
}

final class ToasttyZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    var close: () -> Void = {}
    /// Full size or the small copy; the accessibility value adds whether
    /// the image is zoomed.
    var stateText = "" { didSet { updateAccessibilityValue() } }
    private let imageView = UIImageView()
    private var shownImage: CGImage?
    private var laidOutSize: CGSize = .zero
    /// How far the image must be pulled down, while it fits the screen,
    /// to close the view.
    private static let closeDistance: CGFloat = 90

    init() {
        super.init(frame: .zero)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        // A pull down bounces, so a swipe down can close the view.
        alwaysBounceVertical = true
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(zoomOnDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ image: CGImage) {
        guard image !== shownImage else { return }
        // The full image replaces the small copy at the same place on
        // screen, so the image only gets sharper.
        let wasFit = shownImage == nil || zoomScale <= minimumZoomScale * 1.01
        shownImage = image
        imageView.image = UIImage(cgImage: image)
        if wasFit { fitImage() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != laidOutSize {
            laidOutSize = bounds.size
            fitImage()
        }
        centerImage()
    }

    private func fitImage() {
        guard let shownImage, bounds.width > 0, bounds.height > 0 else { return }
        let size = CGSize(width: shownImage.width, height: shownImage.height)
        minimumZoomScale = 0.0001
        zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        minimumZoomScale = fit
        // Up to five times the fitted size, and at least one image pixel
        // to a screen pixel.
        maximumZoomScale = max(fit * 5, 1 / max(traitCollection.displayScale, 1))
        zoomScale = fit
        centerImage()
        updateAccessibilityValue()
    }

    /// Insets that keep a smaller image in the middle of the screen.
    private func centerImage() {
        let frame = imageView.frame
        let horizontal = max(0, (bounds.width - frame.width) / 2)
        let vertical = max(0, (bounds.height - frame.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    private var isZoomed: Bool { zoomScale > minimumZoomScale * 1.01 }

    private func updateAccessibilityValue() {
        accessibilityValue = [stateText, isZoomed ? "Zoomed" : "Fits the screen"]
            .filter { $0.isEmpty == false }.joined(separator: ", ")
    }

    @objc private func zoomOnDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if isZoomed {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = recognizer.location(in: imageView)
            let scale = min(maximumZoomScale, minimumZoomScale * 2.5)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        updateAccessibilityValue()
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        // A swipe down closes the view only while the image fits: a zoomed
        // image pans instead.
        guard isZoomed == false else { return }
        let pulledDown = -(contentOffset.y + contentInset.top)
        if pulledDown > Self.closeDistance || (pulledDown > 24 && velocity.y < -0.8) {
            close()
        }
    }
}
