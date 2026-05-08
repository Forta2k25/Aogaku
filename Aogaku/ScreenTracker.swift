import UIKit
import FirebaseFirestore
import FirebaseAuth

/// 画面の滞在時間をFirestoreに記録するシングルトン。
///
/// 使い方:
///   override func viewDidAppear(_ animated: Bool) {
///       super.viewDidAppear(animated)
///       ScreenTracker.shared.appear("友だちリスト")
///   }
///   override func viewWillDisappear(_ animated: Bool) {
///       super.viewWillDisappear(animated)
///       ScreenTracker.shared.disappear("友だちリスト")
///   }
final class ScreenTracker {
    static let shared = ScreenTracker()
    private init() {
        // バックグラウンド期間を計測から除外するための通知を登録
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    private let db = Firestore.firestore()
    private var startTimes: [String: Date] = [:]
    private var resignedAt: Date?   // バックグラウンドに入った時刻

    // MARK: - Background handling

    @objc private func appWillResignActive() {
        resignedAt = Date()
    }

    @objc private func appDidBecomeActive() {
        guard let resigned = resignedAt else { return }
        let bgDuration = Date().timeIntervalSince(resigned)
        resignedAt = nil

        // 計測中の全画面の開始時刻をバックグラウンド時間分だけ後ろにずらす
        // → 結果として duration からバックグラウンド滞在時間が除外される
        for key in startTimes.keys {
            startTimes[key] = startTimes[key].map { $0.addingTimeInterval(bgDuration) }
        }
    }

    // MARK: - Public API

    /// 画面が表示されたときに呼ぶ
    func appear(_ screen: String) {
        startTimes[screen] = Date()
    }

    /// 画面が非表示になったときに呼ぶ。滞在時間を計算してFirestoreに書き込む。
    func disappear(_ screen: String) {
        guard let start = startTimes.removeValue(forKey: screen) else { return }
        let duration = Date().timeIntervalSince(start)
        guard duration >= 1.0 else { return }   // 1秒未満は誤タップとして除外
        // 念のため上限を設ける（残留タイマーが万一残っていた場合の安全弁）
        guard duration <= 3600 else { return }  // 1時間超は異常値として破棄

        let now = Date()
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let dateStr = fmt.string(from: now)

        let uid = Auth.auth().currentUser?.uid ?? "unknown"

        db.collection("analytics_events").addDocument(data: [
            "screen":    screen,
            "duration":  duration,          // 秒（Double）
            "userId":    uid,
            "timestamp": Timestamp(date: now),
            "hour":      hour,              // 0-23
            "date":      dateStr            // "2026-05-06"
        ])
    }
}
