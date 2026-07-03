import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - Attributes
//
// `HermesTurnAttributes` is the canonical shared type, defined once in
// `HermesMobile/Support/HermesTurnAttributes.swift` and compiled into BOTH this
// widget-extension target and the app target (see project.yml `sources`). The
// duplicate definition that used to live here has been removed so the build has
// exactly one `HermesTurnAttributes` — ActivityKit matches activities to widget
// presentations by the attributes type's name + codable layout, so a divergent
// re-declaration would silently fail to render. This file is pure UI and simply
// references that canonical struct (and its `ContentState`).

// MARK: - Formatting helpers

private func elapsedString(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let m = s / 60
    let r = s % 60
    return String(format: "%d:%02d", m, r)
}

private func elapsedAccessibilityString(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let minutes = s / 60
    let seconds = s % 60

    switch (minutes, seconds) {
    case (0, 1): return "1 second elapsed"
    case (0, let seconds): return "\(seconds) seconds elapsed"
    case (1, 0): return "1 minute elapsed"
    case (1, 1): return "1 minute 1 second elapsed"
    case (1, let seconds): return "1 minute \(seconds) seconds elapsed"
    case (let minutes, 0): return "\(minutes) minutes elapsed"
    case (let minutes, 1): return "\(minutes) minutes 1 second elapsed"
    default: return "\(minutes) minutes \(seconds) seconds elapsed"
    }
}

/// Elapsed-time display for a Live Activity state.
///
/// While the turn is running and the start instant is known, render a
/// `Text(timerInterval:)` that counts UP locally on-device — so the timer
/// advances continuously regardless of how often the activity is updated or
/// pushed (the build-29 "stuck at 0" bug: the static `elapsedSeconds` only moved
/// on a remote content-state push, which never arrived). When the turn is done,
/// or no start instant is present (e.g. a server push that omits it), fall back
/// to the static formatted `elapsedSeconds`.
@available(iOS 16.1, *)
@ViewBuilder
private func elapsedView(_ state: HermesTurnAttributes.ContentState) -> some View {
    if let startedAt = state.startedAt, state.phase.lowercased() != "done" {
        // countsDown:false → counts up from the start; the range end is far
        // enough out that a turn never reaches it.
        Text(
            timerInterval: startedAt...startedAt.addingTimeInterval(60 * 60 * 24),
            countsDown: false
        )
    } else {
        Text(elapsedString(state.elapsedSeconds))
    }
}

private extension HermesTurnAttributes.ContentState {
    /// Short human label for the current phase / tool.
    var statusLabel: String {
        if needsApproval { return "Needs approval" }
        if let toolName, !toolName.isEmpty { return toolName }
        switch phase.lowercased() {
        case "thinking": return "Thinking…"
        case "responding", "streaming": return "Responding…"
        case "running", "tool": return "Working…"
        default: return phase.isEmpty ? "Working…" : phase
        }
    }

    var glyphName: String {
        if needsApproval { return "exclamationmark.triangle.fill" }
        if toolName?.isEmpty == false { return "wrench.and.screwdriver.fill" }
        switch phase.lowercased() {
        case "thinking": return "brain"
        case "responding", "streaming": return "text.bubble.fill"
        default: return "bolt.horizontal.fill"
        }
    }

    var tintColor: Color { needsApproval ? .orange : .accentColor }

    var elapsedAccessibilityValue: String {
        let currentElapsedSeconds: Int
        if let startedAt, phase.lowercased() != "done" {
            currentElapsedSeconds = max(elapsedSeconds, Int(Date().timeIntervalSince(startedAt)))
        } else {
            currentElapsedSeconds = elapsedSeconds
        }
        return elapsedAccessibilityString(currentElapsedSeconds)
    }
}

// MARK: - Live Activity

@available(iOS 16.1, *)
struct HermesTurnLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HermesTurnAttributes.self) { context in
            // Lock screen / banner presentation.
            HermesTurnLockScreenView(
                title: context.attributes.sessionTitle,
                state: context.state
            )
            .activityBackgroundTint(Color.black.opacity(0.30))
            .widgetURL(context.state.needsApproval ? HermesWidgetLink.review : HermesWidgetLink.open)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded presentation.
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.glyphName)
                        .font(.title2)
                        .foregroundStyle(context.state.tintColor)
                        .padding(.leading, 4)
                        .accessibilityLabel("Turn status")
                        .accessibilityValue(context.state.statusLabel)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    elapsedView(context.state)
                        .font(.system(.title3, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .padding(.trailing, 4)
                        .accessibilityLabel("Elapsed time")
                        .accessibilityValue(context.state.elapsedAccessibilityValue)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.attributes.sessionTitle)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.state.statusLabel)
                            .font(.caption)
                            .foregroundStyle(context.state.needsApproval ? .orange : .secondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(context.attributes.sessionTitle), \(context.state.statusLabel)")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.needsApproval {
                        Link(destination: HermesWidgetLink.review) {
                            Label("Review approval", systemImage: "arrow.up.forward.app.fill")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel("Review approval required")
                        }
                        .tint(.orange)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.needsApproval ? "exclamationmark.triangle.fill" : "bolt.horizontal.fill")
                    .foregroundStyle(context.state.tintColor)
                    .accessibilityLabel("Turn status")
                    .accessibilityValue(context.state.statusLabel)
            } compactTrailing: {
                elapsedView(context.state)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Elapsed time")
                    .accessibilityValue(context.state.elapsedAccessibilityValue)
            } minimal: {
                Image(systemName: context.state.needsApproval ? "exclamationmark.triangle.fill" : "bolt.horizontal.fill")
                    .foregroundStyle(context.state.tintColor)
                    .accessibilityLabel("Turn status")
                    .accessibilityValue(context.state.statusLabel)
            }
            .widgetURL(context.state.needsApproval ? HermesWidgetLink.review : HermesWidgetLink.open)
            .keylineTint(context.state.tintColor)
        }
    }
}

// MARK: - Lock screen view

@available(iOS 16.1, *)
struct HermesTurnLockScreenView: View {
    let title: String
    let state: HermesTurnAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.glyphName)
                .font(.title2)
                .foregroundStyle(state.tintColor)
                .frame(width: 36)
                .accessibilityLabel("Turn status")
                .accessibilityValue(state.statusLabel)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(state.statusLabel)
                    .font(.subheadline)
                    .foregroundStyle(state.needsApproval ? .orange : .secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(state.statusLabel)")

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                elapsedView(state)
                    .font(.system(.title3, design: .rounded).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("Elapsed time")
                    .accessibilityValue(state.elapsedAccessibilityValue)
                if state.needsApproval {
                    Text("tap to review")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Tap to review approval")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Previews

@available(iOS 16.2, *)
#Preview("Live Activity", as: .content, using: HermesTurnAttributes(sessionTitle: "Refactor auth flow")) {
    HermesTurnLiveActivity()
} contentStates: {
    HermesTurnAttributes.ContentState(phase: "thinking", toolName: nil, elapsedSeconds: 12, needsApproval: false)
    HermesTurnAttributes.ContentState(phase: "tool", toolName: "edit_file", elapsedSeconds: 47, needsApproval: false)
    HermesTurnAttributes.ContentState(phase: "tool", toolName: "run_shell", elapsedSeconds: 83, needsApproval: true)
}
