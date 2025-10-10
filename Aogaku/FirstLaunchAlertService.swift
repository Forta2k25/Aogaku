//
//  FirstLaunchAlertService.swift
//  Aogaku
//
//  Created by shu m on 2025/10/10.
//

import UIKit
import FirebaseRemoteConfig
import FirebaseCore

/// 初回インストール時の一回限りアラート（Remote Configで文言と有効/無効を制御）
final class FirstLaunchAlertService {

    // ← バージョンを上げると全ユーザーに再表示させられます（例: v2）
    private static let shownKey = "firstLaunchAlertShown_v1"

    // Remote Config keys
    private static let rcEnabledKey = "first_launch_alert_enabled"
    private static let rcTitleKey   = "first_launch_alert_title"
    private static let rcMessageKey = "first_launch_alert_message"
    private static let rcOkKey      = "first_launch_alert_ok"

    // ローカルのフォールバック（RC未取得時）
    private static let defaultEnabled = true
    private static let defaultTitle   = "ようこそ 青学ハックへ"
    private static let defaultMessage = "はじめに簡単なご案内です。メニューから時間割を作成し、シラバス検索で授業を追加できます。"
    private static let defaultOk      = "OK"

    // 本番のフェッチ間隔（即時反映したければ 0、負荷を抑えるなら 300〜3600 など）
    private static let prodFetchInterval: TimeInterval = 0

    /// アプリ起動時に1回だけ呼べばOK（SceneDelegateのsceneDidBecomeActive等）
    static func maybeShow() {
        // すでに表示済みなら何もしない
        guard !UserDefaults.standard.bool(forKey: shownKey) else { return }

        // Firebase 初期化（済みならスキップ）
        if FirebaseApp.app() == nil { FirebaseApp.configure() }

        let rc = RemoteConfig.remoteConfig()
        rc.setDefaults([
            rcEnabledKey: NSNumber(value: defaultEnabled),
            rcTitleKey:   NSString(string: defaultTitle),
            rcMessageKey: NSString(string: defaultMessage),
            rcOkKey:      NSString(string: defaultOk),
        ])

        let settings = RemoteConfigSettings()
        #if DEBUG
        settings.minimumFetchInterval = 0
        #else
        settings.minimumFetchInterval = prodFetchInterval
        #endif
        rc.configSettings = settings

        // 2秒以内にRCが返ってこなければ、手元の値で判定して出す（＝確実にユーザーに見せる）
        var didDecide = false
        let fallback = DispatchWorkItem { [weak rc] in
            guard didDecide == false else { return }
            didDecide = true
            decideAndMaybePresent(using: rc)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: fallback)

        rc.fetchAndActivate { _, _ in
            DispatchQueue.main.async {
                guard didDecide == false else { return }
                didDecide = true
                fallback.cancel()
                decideAndMaybePresent(using: rc)
            }
        }
    }

    /// enabled の値を見て表示するか決定
    private static func decideAndMaybePresent(using rc: RemoteConfig?) {
        let enabled = (rc?[rcEnabledKey].boolValue ?? defaultEnabled)
        guard enabled else {
            // 無効なら何もせず、表示済みフラグも付けない（＝後で有効化されたら初回として出せる）
            return
        }
        let title   = rc?[rcTitleKey].stringValue ?? defaultTitle
        let message = rc?[rcMessageKey].stringValue ?? defaultMessage
        let ok      = rc?[rcOkKey].stringValue ?? defaultOk
        presentAlert(title: title, message: message, ok: ok)
    }

    /// 実表示
    private static func presentAlert(title: String, message: String, ok: String) {
        guard let top = topViewController() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                presentAlert(title: title, message: message, ok: ok)
            }
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: ok, style: .default, handler: { _ in
            // OKを押したタイミングで一回限りフラグを立てる
            UserDefaults.standard.set(true, forKey: shownKey)
        }))
        top.present(alert, animated: true)
    }

    /// 表示中トップVC
    private static func topViewController() -> UIViewController? {
        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
            let window = scene.windows.first(where: { $0.isKeyWindow })
        else { return nil }

        var top = window.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        if let nav = top as? UINavigationController { top = nav.visibleViewController }
        if let tab = top as? UITabBarController { top = tab.selectedViewController }
        return top
    }

    // ▼ デバッグ用：一度表示済みにした後に再テストしたい場合に
    static func _debugResetShownFlag() {
        UserDefaults.standard.removeObject(forKey: shownKey)
    }
}
