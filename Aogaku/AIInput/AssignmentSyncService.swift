import Foundation
import FirebaseFirestore

/// 課題(Moodleの予定・自分で足した課題・提出済み)を、Webと合わせる。置き場は、本人だけが読み書きできる userAssignments/{uid}。
/// MoodleのiCal URL(本人専用の鍵)は、送らない。送るのは、課題の名前・期限・授業名・リンクと、提出済みの印だけ。
/// 失敗しても、アプリの課題は止めない(次の機会に、もう一度試す)。
@MainActor
final class AssignmentSyncService {
    static let shared = AssignmentSyncService()
    private var pushing = false

    private func document() -> DocumentReference? {
        guard !AppBackend.isOffline, let uid = AppBackend.currentUID else { return nil }
        return Firestore.firestore(database: "aogaku-ai").collection("userAssignments").document(uid)
    }

    /// 課題の一覧と提出済みを、Webに渡す。`courseTitle` は、画面と同じ授業名の解決(登録番号 → 授業名)。
    func push(events: [MoodleEvent], courseTitle: (MoodleEvent) -> String?) {
        guard let doc = document(), !pushing else { return }
        pushing = true
        let items: [[String: Any]] = events.prefix(400).map { ev in
            var item: [String: Any] = [
                "uid": ev.uid,
                "title": ev.cleanTitle,
                "course": courseTitle(ev) ?? "",
                "type": ev.eventType.rawValue,
                "custom": ev.uid.hasPrefix("custom:"),
            ]
            if let due = ev.dueDate { item["due"] = Int(due.timeIntervalSince1970 * 1000) }
            if let url = ev.eventURL, !url.isEmpty { item["url"] = url }
            return item
        }
        let submitted = Array(MoodleService.shared.submittedUIDs)
        Task {
            defer { pushing = false }
            // 提出済みは、WebとアプリのどちらかがWebに追加したものを消さないよう、合わせてから書く(下の pullSubmitted と同じ考え方)
            try? await doc.setData(["events": items, "submitted": submitted,
                                    "appUpdatedAt": FieldValue.serverTimestamp()], merge: true)
        }
    }

    /// 提出済みの印を1件だけ、Webに反映する(配列の追加・削除なので、別の端末の印を巻き込まない)
    func pushSubmitted(uid: String, submitted: Bool) {
        guard let doc = document() else { return }
        Task {
            try? await doc.setData(["submitted": submitted ? FieldValue.arrayUnion([uid]) : FieldValue.arrayRemove([uid]),
                                    "appUpdatedAt": FieldValue.serverTimestamp()], merge: true)
        }
    }

    /// Webでつけた提出済みの印を、アプリに取り込む。変わったら true(画面を読み直す)。
    @discardableResult
    func pullSubmitted() async -> Bool {
        guard let doc = document(), let snap = try? await doc.getDocument(), snap.exists,
              let remote = snap.data()?["submitted"] as? [String] else { return false }
        let remoteSet = Set(remote)
        guard remoteSet != MoodleService.shared.submittedUIDs else { return false }
        MoodleService.shared.submittedUIDs = remoteSet
        NotificationCenter.default.post(name: .moodleSubmittedStateChanged, object: nil)
        return true
    }
}
