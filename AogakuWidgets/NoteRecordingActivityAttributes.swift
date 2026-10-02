import ActivityKit
import Foundation

/// 録音中のライブアクティビティ(ロック画面・Dynamic Island)。
/// 同じ定義が AogakuWidgets/NoteRecordingActivityAttributes.swift にもある。型名と形を揃えること。
struct NoteRecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 録音を始めた時刻(経過時間の表示に使う)
        var startDate: Date
        /// 今週の上限(180分)に達する時刻(残り時間のカウントダウンに使う)
        var limitDate: Date
    }

    var courseTitle: String
    var sessionLabel: String
}
