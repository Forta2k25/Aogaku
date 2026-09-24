//
//  LectureRecordingActivityAttributes.swift
//  Aogaku
//
//  授業ノート(AI)機能: 録音中であることをロック画面/Dynamic Islandに表示するためのLive Activity定義。
//  AogakuとAogakuWidgetsExtensionの両方に同じ内容のファイルを置く(target間で型を共有するため)。
//

import ActivityKit
import Foundation

struct LectureRecordingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var elapsedSeconds: Int
        var isPaused: Bool
    }

    var courseTitle: String
}
