import SwiftUI
import UIKit
import VisionKit

/// SwiftUI wrapper around VisionKit's `VNDocumentCameraViewController`.
///
/// Presents the system document-camera UI (edge detection, multi-page capture,
/// perspective correction) and hands the finished pages to `AttachmentStore`,
/// which performs the single JPEG normalization pass off the main actor.
///
/// Cancellation and scanner errors both resolve with an empty array via
/// ``onError`` / ``onComplete`` so the caller can simply dismiss. Present this
/// from a `.sheet`/`.fullScreenCover`; gate the presenting button on
/// ``isSupported`` since the document camera requires hardware that the
/// simulator and some devices lack.
///
/// Camera usage is already declared (`NSCameraUsageDescription`), shared with
/// the existing photo-capture path.
struct DocumentScanner: UIViewControllerRepresentable {
    /// Pages from a successful scan in capture order.
    let onComplete: ([UIImage]) -> Void
    /// Called instead of ``onComplete`` when the scanner fails. The default
    /// presents nothing extra; callers typically just dismiss.
    var onError: ((Error) -> Void)? = nil
    /// Called when the user taps Cancel. Defaults to dismissing via ``onComplete``
    /// with an empty array if not provided.
    var onCancel: (() -> Void)? = nil

    /// Whether the document camera is available on this device. Mirror this on
    /// the presenting control's `disabled`/visibility.
    static var isSupported: Bool {
        VNDocumentCameraViewController.isSupported
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete, onError: onError, onCancel: onCancel)
    }

    /// Bridges the UIKit delegate callbacks back to the SwiftUI closures.
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onComplete: ([UIImage]) -> Void
        private let onError: ((Error) -> Void)?
        private let onCancel: (() -> Void)?

        init(
            onComplete: @escaping ([UIImage]) -> Void,
            onError: ((Error) -> Void)?,
            onCancel: (() -> Void)?
        ) {
            self.onComplete = onComplete
            self.onError = onError
            self.onCancel = onCancel
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            onComplete(pages)
        }

        func documentCameraViewControllerDidCancel(
            _ controller: VNDocumentCameraViewController
        ) {
            if let onCancel {
                onCancel()
            } else {
                onComplete([])
            }
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            if let onError {
                onError(error)
            } else {
                onComplete([])
            }
        }
    }
}
