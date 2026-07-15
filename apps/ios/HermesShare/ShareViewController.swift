import UIKit
import SwiftUI

/// Principal class for the Hermes share extension.
///
/// Modern, `SLComposeServiceViewController`-free approach: a plain
/// `UIViewController` that resolves the incoming `NSExtensionItem`s, then hosts
/// ``ShareSheetView`` via a `UIHostingController`. On confirm it persists a
/// ``SharedStore/SharedInboxItem`` (plus image files) into the app group and
/// completes the request. The extension performs **no networking** — the app's
/// `SharedInboxDrainer` (X3) picks the item up on next foreground.
@MainActor
final class ShareViewController: UIViewController {
    private var hostingController: UIHostingController<AnyView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        // Resolve providers first, then present the sheet with real content.
        // `SharedItemLoader.load` is `@MainActor`, so the non-Sendable
        // `NSExtensionItem` array stays within this controller's isolation
        // region (no actor boundary crossed under Swift 6 strict concurrency).
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        Task { [weak self] in
            let content = await SharedItemLoader.load(from: items)
            self?.presentSheet(for: content)
        }
    }

    // MARK: - Presentation

    private func presentSheet(for content: SharedItemLoader.LoadedShareContent) {
        let thumbnails = content.images.compactMap { Self.thumbnail(from: $0) }

        let root = ShareSheetView(
            content: content,
            thumbnails: thumbnails,
            onQueue: { [weak self] comment in
                self?.queue(content: content, comment: comment)
            },
            onCancel: { [weak self] in
                self?.cancel()
            }
        )

        let hosting = UIHostingController(rootView: AnyView(root))
        hosting.view.backgroundColor = .clear
        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        self.hostingController = hosting
    }

    // MARK: - Actions

    private func queue(content: SharedItemLoader.LoadedShareContent, comment: String) {
        do {
            try SharedInboxWriter.queue(content: content, comment: comment)
            complete()
        } catch {
            presentError(error)
        }
    }

    private func cancel() {
        extensionContext?.cancelRequest(
            withError: NSError(domain: "ai.hermes.share", code: NSUserCancelledError)
        )
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func presentError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        let alert = UIAlertController(
            title: "Couldn’t queue",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.cancel()
        })
        present(alert, animated: true)
    }

    // MARK: - Helpers

    /// Small preview built off the already-normalised JPEG bytes.
    private static func thumbnail(from jpeg: Data) -> UIImage? {
        UIImage(data: jpeg)
    }
}
