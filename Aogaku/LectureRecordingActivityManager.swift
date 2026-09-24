//
//  LectureRecordingActivityManager.swift
//  Aogaku
//
//  授業ノート(AI)機能: 録音中であることをLive Activityでロック画面に表示し続ける
//

import ActivityKit
import Foundation

final class LectureRecordingActivityManager {
    static let shared = LectureRecordingActivityManager()
    private var activity: Activity<LectureRecordingActivityAttributes>?

    func start(courseTitle: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = LectureRecordingActivityAttributes(courseTitle: courseTitle)
        let state = LectureRecordingActivityAttributes.ContentState(elapsedSeconds: 0, isPaused: false)
        activity = try? Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
    }

    func update(elapsedSeconds: Int, isPaused: Bool) {
        guard let activity else { return }
        let state = LectureRecordingActivityAttributes.ContentState(elapsedSeconds: elapsedSeconds, isPaused: isPaused)
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func end() {
        guard let activity else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        self.activity = nil
    }
}
