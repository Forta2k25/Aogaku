//
//  PushManager.swift
//  Aogaku
//
//  Created by shu m on 2025/09/20.
//
import UIKit
import UserNotifications
import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging

final class PushManager: NSObject, UNUserNotificationCenterDelegate, MessagingDelegate {
    static let shared = PushManager()
    private let db = Firestore.firestore()

    // ② ログイン完了を検知して、そのタイミングで保存
    func start() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
        Messaging.messaging().delegate = self

        // 起動直後の取得（既存）
        Messaging.messaging().token { [weak self] token, error in
            if let token = token { self?.saveFCMToken(token) }
            if let error = error { print("FCM token fetch error:", error) }
        }

        // ← これを追加：Authの状態が「ログイン済み」になったら保存を試みる
        Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard user != nil else { return }
            Messaging.messaging().token { token, error in
                if let token = token { self?.saveFCMToken(token) }
                if let error = error { print("FCM token fetch after sign-in error:", error) }
            }
        }
    }

    // ① APNsトークンを受け取った直後に FCM トークンを再取得
    func didRegisterForRemoteNotifications(deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
        // ← これを追加：APNs設定後に再取得（ログの “re-retrieve the FCM token” の指示どおり）
        Messaging.messaging().token { [weak self] token, error in
            if let token = token { self?.saveFCMToken(token) }
            if let error = error { print("FCM token re-fetch after APNs set error:", error) }
        }
    }
    // FCMトークンが更新/取得された時に呼ばれる
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken else { return }
        print("FCM token (refresh): \(token)")
        saveFCMToken(token)
    }

    // フォアグラウンドでもバナーを出す
    // 通知タップ時の遷移
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let screen = userInfo["screen"] as? String {
            // TODO: ここで画面遷移。例：
            // DeepLinkRouter.open(screen) など、あなたのルーターに合わせて実装
            openFromNotification(screen: screen)   // ← ここだけ呼ぶ
        }
        completionHandler()
    }

    // Firestoreに保存：users/{uid}/fcmTokens/{token}
    private func saveFCMToken(_ token: String) {
        guard let uid = Auth.auth().currentUser?.uid else {
            print("Skip saveFCMToken: no signed-in user")
            return
        }
        let ref = db.collection("users").document(uid).collection("fcmTokens").document(token)
        ref.setData([
            "platform": "ios",
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true) { err in
            if let err = err {
                print("saveFCMToken error: \(err)")
            } else {
                print("saveFCMToken saved: \(uid)/\(token)")
            }
        }
    }
    
    // MARK: - Routing from notification
    private let friendsTabIndex = 2  // ← 友だちタブのインデックス（必要に応じて調整）

    private func keyWindow() -> UIWindow? {
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    private func rootTab() -> UITabBarController? {
        return keyWindow()?.rootViewController as? UITabBarController
    }

    /// 通知の `screen` に応じてナビゲーション
    private func openFromNotification(screen: String) {
        DispatchQueue.main.async {
            guard let tab = self.rootTab() else { return }

            // 何かモーダルが出ていたら閉じておく（安全策）
            tab.dismiss(animated: false)

            // 友だちタブへ
            guard let vcs = tab.viewControllers,
                  self.friendsTabIndex < vcs.count,
                  let nav = vcs[self.friendsTabIndex] as? UINavigationController else { return }

            tab.selectedIndex = self.friendsTabIndex
            nav.popToRootViewController(animated: false)

            switch screen {
            case "friend_requests":
                // 申請一覧へ（push）
                let vc = FriendRequestsViewController()
                nav.pushViewController(vc, animated: true)

            case "friends_list":
                // 友だちリストへ（root を見せるだけでOK）
                break

            default:
                break
            }
        }
    }

}
