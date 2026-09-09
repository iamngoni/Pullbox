import WidgetKit
import SwiftUI
import ActivityKit
import PullboxCore

@available(iOS 16.1, *)
struct PullboxLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PullboxDownloadAttributes.self) { context in
            // Lock screen / banner
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: icon(for: context.state.status))
                        .foregroundStyle(color(for: context.state.status))
                    Text(title(for: context.state))
                        .font(.headline)
                    Spacer()
                    if context.state.status == .downloading, let p = context.state.progress {
                        Text("\(Int((p * 100).rounded()))%")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                }
                if context.state.status == .downloading, let p = context.state.progress {
                    ProgressView(value: p)
                        .tint(Color.accentColor)
                }
                if let title = context.state.title, !title.isEmpty {
                    Text(title)
                        .font(.subheadline)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                }
                Text(subtitle(for: context.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
            .activitySystemActionForegroundColor(Color.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: icon(for: context.state.status))
                        .foregroundStyle(color(for: context.state.status))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.status == .downloading, let p = context.state.progress {
                        Text("\(Int((p * 100).rounded()))%")
                            .font(.caption2.weight(.bold))
                    } else {
                        Text(shortStatus(for: context.state.status))
                            .font(.caption2.weight(.semibold))
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(title(for: context.state))
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.status == .downloading, let p = context.state.progress {
                        ProgressView(value: p)
                            .tint(Color.accentColor)
                    } else {
                        Text(subtitle(for: context.state))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: icon(for: context.state.status))
                    .foregroundStyle(color(for: context.state.status))
            } compactTrailing: {
                if context.state.status == .downloading, let p = context.state.progress {
                    Text("\(Int(p * 100))%")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                }
            } minimal: {
                Image(systemName: icon(for: context.state.status))
            }
            .widgetURL(URL(string: context.attributes.sourceURL))
            .keylineTint(color(for: context.state.status))
        }
    }

    private func title(for state: PullboxDownloadAttributes.ContentState) -> String {
        switch state.status {
        case .queued: return "Queued"
        case .preparing: return "Preparing"
        case .downloading: return "Downloading"
        case .saving: return "Saving to Photos"
        case .succeeded: return "Saved"
        case .failed: return "Failed"
        }
    }

    private func subtitle(for state: PullboxDownloadAttributes.ContentState) -> String {
        switch state.status {
        case .queued: return "Waiting to start"
        case .preparing: return "Getting media info"
        case .downloading:
            if let p = state.progress { return "Downloading \(Int(p*100))%" }
            return "Downloading"
        case .saving: return "Adding to Photos"
        case .succeeded: return "Saved to Photos"
        case .failed: return state.errorMessage ?? "Could not save"
        }
    }

    private func shortStatus(for status: LiveActivityStatus) -> String {
        switch status {
        case .queued: return "Queued"
        case .preparing: return "Prep"
        case .downloading: return "DL"
        case .saving: return "Save"
        case .succeeded: return "Done"
        case .failed: return "Fail"
        }
    }

    private func icon(for status: LiveActivityStatus) -> String {
        switch status {
        case .queued: return "clock.fill"
        case .preparing: return "gearshape.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .saving: return "photo.fill"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func color(for status: LiveActivityStatus) -> Color {
        switch status {
        case .queued: return .secondary
        case .preparing: return .orange
        case .downloading: return .accentColor
        case .saving: return .purple
        case .succeeded: return .green
        case .failed: return .red
        }
    }
}
