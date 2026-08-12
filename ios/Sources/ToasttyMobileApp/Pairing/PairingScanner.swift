import AVFoundation
import SwiftUI
import VisionKit

@MainActor
protocol PairingCodeScanning: AnyObject {
    var availability: PairingScannerAvailability { get }
    func requestAuthorization() async -> PairingScannerAuthorization
    func makeScannerView(onCode: @escaping @MainActor (String) -> Void) -> AnyView
}

@MainActor
final class LivePairingCodeScanner: PairingCodeScanning {
    var availability: PairingScannerAvailability {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
            ? .available
            : .unsupported
    }

    func requestAuthorization() async -> PairingScannerAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    func makeScannerView(onCode: @escaping @MainActor (String) -> Void) -> AnyView {
        AnyView(
            LivePairingScannerView(onCode: onCode)
                .accessibilityLabel("Camera view for scanning the Toastty pairing code")
                .accessibilityIdentifier("toastty-mobile-pairing-camera")
        )
    }
}

private struct LivePairingScannerView: UIViewControllerRepresentable {
    let onCode: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        guard !controller.isScanning else { return }
        try? controller.startScanning()
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: @MainActor (String) -> Void
        private var hasDeliveredCode = false

        init(onCode: @escaping @MainActor (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !hasDeliveredCode else { return }
            guard case .barcode(let barcode) = addedItems.first,
                  let value = barcode.payloadStringValue else { return }
            hasDeliveredCode = true
            dataScanner.stopScanning()
            onCode(value)
        }
    }
}
