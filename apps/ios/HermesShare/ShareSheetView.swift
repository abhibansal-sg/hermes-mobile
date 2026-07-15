import SwiftUI
import UIKit

/// The SwiftUI surface hosted inside the share extension. Shows a compact
/// summary of what's being shared (text / URL / image count), an optional
/// comment field, and the Cancel / "Queue for Hermes" actions.
///
/// All work that touches the app group happens off this view via the supplied
/// closures; the view is intentionally dumb so it can be previewed and reasoned
/// about in isolation.
struct ShareSheetView: View {
    /// The resolved payload to display and queue.
    let content: SharedItemLoader.LoadedShareContent
    /// Thumbnails for the loaded images, built once by the controller.
    let thumbnails: [UIImage]
    /// Called when the user confirms; receives the trimmed comment. Performs the
    /// write and then completes the extension request.
    let onQueue: (_ comment: String) -> Void
    /// Called when the user cancels.
    let onCancel: () -> Void

    @State private var comment: String = ""
    @State private var isQueueing = false
    @FocusState private var commentFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                contentSection
                commentSection
            }
            .navigationTitle("Share to Hermes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { onCancel() }
                        .disabled(isQueueing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard !isQueueing else { return }
                        isQueueing = true
                        commentFocused = false
                        onQueue(comment)
                    } label: {
                        if isQueueing {
                            ProgressView()
                        } else {
                            Text("Queue")
                        }
                    }
                    .disabled(content.isEmpty || isQueueing)
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var contentSection: some View {
        Section("Sharing") {
            if let url = content.url {
                Label {
                    Text(url)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .font(.callout)
                } icon: {
                    Image(systemName: "link")
                }
            }

            if let text = content.text {
                Label {
                    Text(text)
                        .lineLimit(4)
                        .font(.callout)
                } icon: {
                    Image(systemName: "text.alignleft")
                }
            }

            if !thumbnails.isEmpty {
                imageStrip
            }

            if content.isEmpty {
                Label("Nothing shareable was found.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var imageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityLabel("\(thumbnails.count) image\(thumbnails.count == 1 ? "" : "s")")
    }

    private var commentSection: some View {
        Section("Comment (optional)") {
            TextField("Add a note for Hermes…", text: $comment, axis: .vertical)
                .lineLimit(1...4)
                .focused($commentFocused)
                .disabled(isQueueing)
        }
    }
}
