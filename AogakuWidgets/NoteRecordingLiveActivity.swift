import ActivityKit
import WidgetKit
import SwiftUI

/// 録音中にロック画面とDynamic Islandへ出す表示。時間は Text(timerInterval:) なので、アプリが動いていなくても進む。
struct NoteRecordingLiveActivity: Widget {
    private let green = Color(red: 0/255, green: 120/255, blue: 87/255)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NoteRecordingActivityAttributes.self) { context in
            // ロック画面
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 10, height: 10)
                    Text("録音中").font(.system(size: 14, weight: .bold)).foregroundStyle(.red)
                    Spacer()
                    Text("\(context.attributes.courseTitle)  \(context.attributes.sessionLabel)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(timerInterval: context.state.startDate...Date.distantFuture, countsDown: false)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(maxWidth: 160, alignment: .leading)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("今週の残り").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(timerInterval: context.state.startDate...context.state.limitDate, countsDown: true)
                            .font(.system(size: 16, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(green)
                            .frame(maxWidth: 90, alignment: .trailing)
                    }
                }
            }
            .padding(16)
            .activityBackgroundTint(Color(.systemBackground).opacity(0.9))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 10, height: 10)
                        Text("録音中").font(.system(size: 13, weight: .bold)).foregroundStyle(.red)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.startDate...Date.distantFuture, countsDown: false)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(maxWidth: 90, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text("\(context.attributes.courseTitle)  \(context.attributes.sessionLabel)")
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text("残り").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(timerInterval: context.state.startDate...context.state.limitDate, countsDown: true)
                            .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                            .frame(maxWidth: 70, alignment: .trailing)
                    }
                }
            } compactLeading: {
                Circle().fill(.red).frame(width: 10, height: 10)
            } compactTrailing: {
                Text(timerInterval: context.state.startDate...Date.distantFuture, countsDown: false)
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .frame(maxWidth: 52)
            } minimal: {
                Circle().fill(.red).frame(width: 10, height: 10)
            }
        }
    }
}
