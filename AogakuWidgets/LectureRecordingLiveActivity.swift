//
//  LectureRecordingLiveActivity.swift
//  AogakuWidgets
//
//  授業ノート(AI)機能: 録音中であることをロック画面/Dynamic Islandに常時表示する
//

import ActivityKit
import WidgetKit
import SwiftUI

private func formatted(_ seconds: Int) -> String {
    String(format: "%02d:%02d", seconds / 60, seconds % 60)
}

struct LectureRecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LectureRecordingActivityAttributes.self) { context in
            // ロック画面 / バナー
            HStack(spacing: 12) {
                Circle()
                    .fill(context.state.isPaused ? Color.gray : Color.red)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.isPaused ? "一時停止中" : "録音中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(context.attributes.courseTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                }
                Spacer()
                Text(formatted(context.state.elapsedSeconds))
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
            }
            .padding(16)
            .activityBackgroundTint(Color(.systemBackground))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Circle()
                        .fill(context.state.isPaused ? Color.gray : Color.red)
                        .frame(width: 10, height: 10)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(formatted(context.state.elapsedSeconds))
                        .font(.system(size: 16, weight: .semibold).monospacedDigit())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.courseTitle)
                        .font(.caption)
                        .lineLimit(1)
                }
            } compactLeading: {
                Circle()
                    .fill(context.state.isPaused ? Color.gray : Color.red)
                    .frame(width: 8, height: 8)
            } compactTrailing: {
                Text(formatted(context.state.elapsedSeconds))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
            } minimal: {
                Circle()
                    .fill(context.state.isPaused ? Color.gray : Color.red)
                    .frame(width: 8, height: 8)
            }
        }
    }
}
