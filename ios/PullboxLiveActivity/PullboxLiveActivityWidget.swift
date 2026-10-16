import WidgetKit
import SwiftUI
import ActivityKit
import PullboxCore

@available(iOS 16.1, *)
struct PullboxLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PullboxDownloadAttributes.self) { context in
            // Lock screen / banner
            HStack(alignment: .top, spacing: 12) {
                activityIcon(for: context.state)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Pullbox")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        if let progress = context.state.progress {
                            Text("\(Int((progress * 100).rounded()))%")
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                        }
                    }

                    Text(context.state.title ?? title(for: context.state))
                        .font(.headline)
                        .lineLimit(1)

                    if let progress = context.state.progress {
                        ProgressView(value: progress)
                            .tint(Color.accentColor)
                    }

                    Text(subtitle(for: context.state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
            .activitySystemActionForegroundColor(Color.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    activityIcon(for: context.state)
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
                    Text(context.state.title ?? title(for: context.state))
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

    private func activityIcon(for state: PullboxDownloadAttributes.ContentState) -> some View {
        Image(systemName: icon(for: state.status))
            .font(.title3.weight(.semibold))
            .foregroundStyle(color(for: state.status))
            .frame(width: 34, height: 34)
            .background(color(for: state.status).opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
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
