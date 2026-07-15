import SwiftUI
import UIKit
import VisionKit

/// SwiftUI wrapper around VisionKit's `VNDocumentCameraViewController`.
///
/// Presents the system document-camera UI (edge detection, multi-page capture,
/// perspective correction) and hands the finished scan back as an array of
/// baseline-JPEG `Data` — one entry per scanned page, in capture order. Each
/// `Data` is ready to feed straight into `AttachmentStore.add(data:)`, which
/// re-normalises it (downscale + re-encode) before upload.
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
    /// Pages from a successful scan, JPEG-encoded in capture order. Empty if the
    /// user finished with no pages.
    let onComplete: ([Data]) -> Void
    /// Called instead of ``onComplete`` when the scanner fails. The default
    /// presents nothing extra; callers typically just dismiss.
    var onError: ((Error) -> Void)? = nil
    /// Called when the user taps Cancel. Defaults to dismissing via ``onComplete``
    /// with an empty array if not provided.
    var onCancel: (() -> Void)? = nil

    /// JPEG quality used to encode each scanned page. Generous because
    /// `AttachmentStore` re-compresses; this just avoids losing fidelity early.
    private static let jpegQuality: CGFloat = 0.9

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
        Coordinator(
            onComplete: onComplete,
            onError: onError,
            onCancel: onCancel,
            jpegQuality: Self.jpegQuality
        )
    }

    /// Bridges the UIKit delegate callbacks back to the SwiftUI closures.
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onComplete: ([Data]) -> Void
        private let onError: ((Error) -> Void)?
        private let onCancel: (() -> Void)?
        private let jpegQuality: CGFloat

        init(
            onComplete: @escaping ([Data]) -> Void,
            onError: ((Error) -> Void)?,
            onCancel: (() -> Void)?,
            jpegQuality: CGFloat
        ) {
            self.onComplete = onComplete
            self.onError = onError
            self.onCancel = onCancel
            self.jpegQuality = jpegQuality
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            var pages: [Data] = []
            pages.reserveCapacity(scan.pageCount)
            for index in 0..<scan.pageCount {
                let image = scan.imageOfPage(at: index)
                if let jpeg = image.jpegData(compressionQuality: jpegQuality) {
                    pages.append(jpeg)
                }
            }
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
