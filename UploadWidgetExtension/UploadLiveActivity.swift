//
//  UploadLiveActivity.swift
//  UploadWidgetExtension
//
//  Live Activity widget for upload progress on Dynamic Island and Lock Screen.
//

import SwiftUI
import WidgetKit

#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.2, *)
struct UploadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: UploadActivityAttributes.self) { context in
            // Lock Screen / Banner UI
            LockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI (when long-pressed or tapped)
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Image(systemName: "icloud.and.arrow.up.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Uploading")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(context.state.albumName)
                                .font(.caption)
                                .fontWeight(.medium)
                                .lineLimit(1)
                        }
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(context.state.completedCount)/\(context.state.totalCount)")
                            .font(.caption)
                            .fontWeight(.bold)
                            .monospacedDigit()

                        Text("\(Int(context.state.progress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        // Progress bar
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color(.systemGray5))
                                    .frame(height: 6)

                                Capsule()
                                    .fill(.blue)
                                    .frame(width: geometry.size.width * context.state.progress, height: 6)
                            }
                        }
                        .frame(height: 6)

                        // Current file
                        Text(context.state.currentFileName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                // Compact leading (left pill on Dynamic Island) - cloud with progress ring
                ZStack {
                    Circle()
                        .stroke(Color(.systemGray4), lineWidth: 2)
                        .frame(width: 24, height: 24)

                    Circle()
                        .trim(from: 0, to: context.state.progress)
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 24, height: 24)
                        .rotationEffect(.degrees(-90))

                    Image(systemName: "icloud.and.arrow.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.blue)
                }
            } compactTrailing: {
                // Compact trailing (right pill on Dynamic Island)
                Text("\(context.state.completedCount)/\(context.state.totalCount)")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .monospacedDigit()
            } minimal: {
                // Minimal view (when another activity is also running)
                ZStack {
                    Circle()
                        .stroke(Color(.systemGray4), lineWidth: 2)

                    Circle()
                        .trim(from: 0, to: context.state.progress)
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))

                    Image(systemName: "icloud.and.arrow.up")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.blue)
                }
            }
        }
    }
}

// MARK: - Lock Screen View

@available(iOS 16.2, *)
private struct LockScreenView: View {
    let context: ActivityViewContext<UploadActivityAttributes>

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "icloud.and.arrow.up.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Uploading to \(context.state.albumName)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Text(context.state.currentFileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(context.state.completedCount)/\(context.state.totalCount)")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .monospacedDigit()

                    if context.state.hasFailures {
                        Text("Has failures")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.systemGray5))
                        .frame(height: 8)

                    Capsule()
                        .fill(.blue)
                        .frame(width: geometry.size.width * context.state.progress, height: 8)
                }
            }
            .frame(height: 8)
        }
        .padding()
        .activityBackgroundTint(.black.opacity(0.8))
    }
}

// MARK: - Preview

@available(iOS 16.2, *)
#Preview("Live Activity", as: .dynamicIsland(.expanded), using: UploadActivityAttributes(albumId: "test")) {
    UploadLiveActivity()
} contentStates: {
    UploadActivityAttributes.ContentState(
        progress: 0.35,
        remainingCount: 5,
        totalCount: 8,
        currentFileName: "IMG_20240215_123456.jpg",
        albumName: "Family Photos",
        hasFailures: false,
        completedCount: 3
    )
}
#endif
