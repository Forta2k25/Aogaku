//
//  BroadcastAlertService.swift
//  Aogaku
//
//  Created by shu m on 2025/10/10.
//

import UIKit
import FirebaseCore
import FirebaseRemoteConfig
import CryptoKit

/// 全ユーザーに一度だけ表示する「お知らせ」アラート。
/// - 表示条件: Remote Config で enabled=true のとき、かつ
///   (version が未表示 or 変更された) 場合にのみ表示。
/// - version は `broadcast_alert_version` を優先。未設定なら
///   (title|message|ok) のSHA256で自動的に版管理します。
final class BroadcastAlertService {

    // 保存する「最後に表示した版」のキー（末尾の v を上げれば全員に再表示させられる）
    private static let lastShownVersionKey = "broadcastAlert_lastShownVersion_v1"

    // RC Keys
    private static let rcEnabledKey = "broadcast_alert_enabled"     // Bool
    private static let rcTitleKey   = "broadcast_alert_title"       // String
    private static let rcMessageKey = "broadcast_alert_message"     // String
    private static let rcOkKey      = "broadcast_alert_ok"          // String
    private static let rcVersionKey = "broadcast_alert_version"     // String（任意）

    // フォールバック（RC未取得時のローカル既定値）
    // ※ デフォルトは enabled=false にしておくことで、RCが取れない初回でも誤表示しない。
    private static let defaultEnabled = false
    private static let defaultTitle   = "お知らせ"
    private static let defaultMessage = "メッセージ本文（Remote Config で編集）"
    private static let defaultOk      = "OK"
    // 本番のフェッチ間隔（即時反映したいなら 0、負荷を抑えるなら 300〜3600 あたり）
    private static let prodFetchInterval: TimeInterval = 300

    /// アプリ起動時などで1回呼べばOK（SceneDelegate の sceneDidBecomeActive 推奨）
    static func maybeShow() {
        // Firebase 初期化（済ならスキップ）
        if FirebaseApp.app() == nil { FirebaseApp.configure() }

        let rc = RemoteConfig.remoteConfig()
        rc.setDefaults([
            rcEnabledKey: NSNumber(value: defaultEnabled),
            rcTitleKey:   NSString(string: defaultTitle),
            rcMessageKey: NSString(string: defaultMessage),
            rcOkKey:      NSString(string: defaultOk),
            rcVersionKey: NSString(string: ""), // 明示版が無い場合は空文字
        ])

        let settings = RemoteConfigSettings()
        #if DEBUG
        settings.minimumFetchInterval = 0
        #else
        settings.minimumFetchInterval = prodFetchInterval
        #endif
        rc.configSettings = settings

        // まずは現在の有効設定（過去に有効化済みの値があればそれ）で判定しておき、
        // さらに fetchAndActivate 後にもう一度「未決定なら」判定する二段構え。
        // （※ ただし初期値の enabled=false を入れているので、RC未取得の初回起動で誤表示しない）
        var decided = false
        decideAndMaybePresent(using: rc, decidedFlag: &decided)

        rc.fetchAndActivate { _, _ in
            DispatchQueue.main.async {
                // まだ出して（or 不要判定して）いなければ最終決定
                decideAndMaybePresent(using: rc, decidedFlag: &decided)
            }
        }
    }

    // 判定して必要なら表示
    private static func decideAndMaybePresent(using rc: RemoteConfig, decidedFlag: inout Bool) {
        guard decidedFlag == false else { return }
        let enabled = rc[rcEnabledKey].boolValue ?? defaultEnabled
        guard enabled else { return } // 無効なら何もしない

        let title   = rc[rcTitleKey].stringValue ?? defaultTitle
        let message = rc[rcMessageKey].stringValue ?? defaultMessage
        let ok      = rc[rcOkKey].stringValue ?? defaultOk

        // 版（version）は明示指定があればそれを優先、無ければ内容から自動生成
        let explicitVersion = rc[rcVersionKey].stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let version = (explicitVersion.isEmpty == false)
        ? explicitVersion
            : sha256("\(title)|\(message)|\(ok)")

        // すでに同じ版を表示済みならスキップ
        let lastShown = UserDefaults.standard.string(forKey: lastShownVersionKey)
        guard lastShown != version else { return }

        decidedFlag = true
        presentAlert(title: title, message: message, ok: ok, version: version)
    }

    // 表示処理
    private static func presentAlert(title: String, message: String, ok: String, version: String) {
        guard let top = topViewController() else {
            // 画面がまだ出ていなければ少し待って再試行
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                presentAlert(title: title, message: message, ok: ok, version: version)
            }
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: ok, style: .default, handler: { _ in
            // OK時に「この版は表示済み」と記録 → 同じ版では再表示しない
            UserDefaults.standard.set(version, forKey: lastShownVersionKey)
        }))
        top.present(alert, animated: true)
    }

    // 現在のトップVC取得
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

    // SHA256（CryptoKit）
    private static func sha256(_ text: String) -> String {
        let data = Data(text.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // デバッグ用：記録した版を消す（再表示テスト）
    static func _debugReset() {
        UserDefaults.standard.removeObject(forKey: lastShownVersionKey)
    }
}
