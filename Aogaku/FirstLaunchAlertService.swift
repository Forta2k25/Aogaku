//
//  FirstLaunchAlertService.swift
//  Aogaku
//
//  Created by shu m on 2025/10/10.
//

import UIKit
import FirebaseRemoteConfig
import FirebaseCore

/// 初回起動（バージョンキー更新ごと）に画像モーダルを一回だけ表示するサービス。
/// Remote Config の "first_launch_alert_enabled" で表示ON/OFFを制御できます。
final class FirstLaunchAlertService {

    private static var shownKey: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return "firstLaunchAlertShown_\(version)"
    }

    private static let rcEnabledKey  = "first_launch_alert_enabled"
    private static let defaultEnabled = true
    private static let prodFetchInterval: TimeInterval = 0

    /// アプリ起動時に1回だけ呼べばOK（SceneDelegate の sceneDidBecomeActive 等）
    static func maybeShow() {
        guard !UserDefaults.standard.bool(forKey: shownKey) else { return }

        if FirebaseApp.app() == nil { FirebaseApp.configure() }

        let rc = RemoteConfig.remoteConfig()
        rc.setDefaults([rcEnabledKey: NSNumber(value: defaultEnabled)])

        let settings = RemoteConfigSettings()
        #if DEBUG
        settings.minimumFetchInterval = 0
        #else
        settings.minimumFetchInterval = prodFetchInterval
        #endif
        rc.configSettings = settings

        // 2秒以内に RC が返らなければローカル値で判定して表示する
        var didDecide = false
        let fallback = DispatchWorkItem { [weak rc] in
            guard !didDecide else { return }
            didDecide = true
            decideAndMaybePresent(using: rc)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: fallback)

        rc.fetchAndActivate { _, _ in
            DispatchQueue.main.async {
                guard !didDecide else { return }
                didDecide = true
                fallback.cancel()
                decideAndMaybePresent(using: rc)
            }
        }
    }

    private static func decideAndMaybePresent(using rc: RemoteConfig?) {
        let enabled = rc?[rcEnabledKey].boolValue ?? defaultEnabled
        // 無効なら表示しない（フラグも立てない = 次に有効化されたら初回として出せる）
        guard enabled else { return }
        presentAnnouncement()
    }

    private static func presentAnnouncement() {
        guard let top = topViewController() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                presentAnnouncement()
            }
            return
        }
        let vc = UpdateAnnouncementViewController()
        vc.modalPresentationStyle = .fullScreen
        vc.onDismiss = {
            UserDefaults.standard.set(true, forKey: shownKey)
        }
        top.present(vc, animated: true)
    }

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

    // デバッグ用：表示済みフラグをリセットして再テスト
    static func _debugResetShownFlag() {
        UserDefaults.standard.removeObject(forKey: shownKey)
    }
}
