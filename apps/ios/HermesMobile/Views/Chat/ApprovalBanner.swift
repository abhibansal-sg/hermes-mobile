import SwiftUI

/// Thin wrapper kept for backward compatibility. Delegates all rendering to
/// `ApprovalCard` (ABH-83). The floating-banner slot in the banners stack is
/// no longer used for approvals — they appear inline in the transcript — but
/// `ApprovalBanner` is preserved so any future fallback surface can reference
/// it without needing to duplicate the card layout.
struct ApprovalBanner: View {
    let approval: PendingApproval
    let chatStore: ChatStore

    var body: some View {
        ApprovalCard(approval: approval, chatStore: chatStore)
    }
}
