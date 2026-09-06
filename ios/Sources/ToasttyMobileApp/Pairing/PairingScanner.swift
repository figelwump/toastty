import AVFoundation
import SwiftUI
import VisionKit

@MainActor
protocol PairingCodeScanning: AnyObject {
    var availability: PairingScannerAvailability { get }
    func requestAuthorization() async -> PairingScannerAuthorization
    func makeScannerView(
        onCode: @escaping @MainActor (String) -> Void,
        onFailure: @escaping @MainActor (PairingScannerFailure) -> Void
    ) -> AnyView
}

@MainActor
final class LivePairingCodeScanner: PairingCodeScanning {
    var availability: PairingScannerAvailability {
        PairingScannerAvailability(
            isSupported: DataScannerViewController.isSupported,
            isAvailable: DataScannerViewController.isAvailable
        )
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

    func makeScannerView(
        onCode: @escaping @MainActor (String) -> Void,
        onFailure: @escaping @MainActor (PairingScannerFailure) -> Void
    ) -> AnyView {
        AnyView(
            LivePairingScannerView(onCode: onCode, onFailure: onFailure)
                .accessibilityLabel("Camera view for scanning the Toastty pairing code")
                .accessibilityIdentifier("toastty-mobile-pairing-camera")
        )
    }
}

private struct LivePairingScannerView: UIViewControllerRepresentable {
    let onCode: @MainActor (String) -> Void
    let onFailure: @MainActor (PairingScannerFailure) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onFailure: onFailure)
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
        context.coordinator.startScanning(controller)
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.startScanning(controller)
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        coordinator.stopScanning(controller)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: @MainActor (String) -> Void
        private let onFailure: @MainActor (PairingScannerFailure) -> Void
        private var hasFinished = false

        init(
            onCode: @escaping @MainActor (String) -> Void,
            onFailure: @escaping @MainActor (PairingScannerFailure) -> Void
        ) {
            self.onCode = onCode
            self.onFailure = onFailure
        }

        func startScanning(_ controller: DataScannerViewController) {
            guard !hasFinished, !controller.isScanning else { return }
            do {
                try controller.startScanning()
            } catch {
                reportFailure(.couldNotStart, controller: controller)
            }
        }

        func stopScanning(_ controller: DataScannerViewController) {
            hasFinished = true
            controller.stopScanning()
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            reportFailure(.becameUnavailable, controller: dataScanner)
        }

        private func reportFailure(
            _ failure: PairingScannerFailure,
            controller: DataScannerViewController
        ) {
            guard !hasFinished else { return }
            stopScanning(controller)
            // Startup can fail during a representable update. Publish after
            // that update so SwiftUI does not mutate observed state mid-render.
            Task { @MainActor [onFailure] in onFailure(failure) }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !hasFinished else { return }
            guard case .barcode(let barcode) = addedItems.first,
                  let value = barcode.payloadStringValue else { return }
            stopScanning(dataScanner)
            onCode(value)
        }
    }
}
