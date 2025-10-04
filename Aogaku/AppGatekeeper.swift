//
//  AppGatekeeper.swift
//  Aogaku
//
//  Created by shu m on 2025/09/25.
//

import UIKit
import FirebaseRemoteConfig

final class AppGatekeeper {
    static let shared = AppGatekeeper()
    private let rc = RemoteConfig.remoteConfig()

    #if DEBUG
    private let fetchInterval: TimeInterval = 0
    #else
    private let fetchInterval: TimeInterval = 3600
    #endif

    func checkAndPresentIfNeeded(on presenter: UIViewController) {
        rc.setDefaults([
            "rc_min_supported_version_ios": "0.0.0" as NSString,
            "rc_recommended_version_ios":  "" as NSString,
            "rc_maintenance_mode": false as NSNumber,
            "rc_maintenance_message": "" as NSString,
            "rc_appstore_url": "" as NSString
        ])

        let settings = RemoteConfigSettings()
        settings.minimumFetchInterval = fetchInterval
        rc.configSettings = settings
        
        // ① まず“現在有効化済み”の値で即判定
        evaluate(on: presenter)

        rc.fetchAndActivate { [weak self] _, _ in
            self?.evaluate(on: presenter)
        }
    }
    
    func forceRefreshAndPresentIfNeeded(on presenter: UIViewController) {
        let prev = rc.configSettings                       // 退避
        let tmp = RemoteConfigSettings()
        tmp.minimumFetchInterval = 0                       // このリクエストだけ即時
        rc.configSettings = tmp

        rc.fetchAndActivate { [weak self] _, _ in
            self?.evaluate(on: presenter)                  // 反映して判定
            self?.rc.configSettings = prev                 // 元に戻す
        }
    }

    private weak var maintenanceAlert: UIAlertController?
    
    private func evaluate(on presenter: UIViewController) {
        let minV  = rc["rc_min_supported_version_ios"].stringValue ?? "0.0.0"
        let stop  = rc["rc_maintenance_mode"].boolValue
        let msg   = rc["rc_maintenance_message"].stringValue ?? ""
        let store = rc["rc_appstore_url"].stringValue ?? ""
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

        if stop {
            let text = msg.isEmpty ? "現在メンテナンス中です。しばらくお待ちください。" : msg
            showMaintenanceAlert(on: presenter, message: text)
        return
        } else {
            hideMaintenanceAlert()
        }
        if current.isSemverLower(than: minV) {
            presentBlocking(on: presenter, title: "アップデートが必要です",
                            message: "最新バージョンに更新してください。",
                            storeURL: URL(string: store))
        }
    }
    private func showMaintenanceAlert(on presenter: UIViewController, message: String) {
        DispatchQueue.main.async {
            // すでに表示中なら文言だけ更新
            if let alert = self.maintenanceAlert {
                alert.message = message
                return
            }
            let alert = UIAlertController(title: "メンテナンス中",
                                          message: message,
                                          preferredStyle: .alert)   // ← アクションを一切追加しない
            presenter.present(alert, animated: true)
            self.maintenanceAlert = alert
        }
    }

    private func hideMaintenanceAlert() {
        DispatchQueue.main.async {
            self.maintenanceAlert?.dismiss(animated: true)
            self.maintenanceAlert = nil
        }
    }

    private var isPresenting = false

    private func presentBlocking(on presenter: UIViewController,
                                 title: String, message: String, storeURL: URL?) {
        DispatchQueue.main.async {
            // すでに何かを表示中なら一旦閉じてから再帰的に提示（即時ブロック）
            if let presented = presenter.presentedViewController {
                presented.dismiss(animated: false) { [weak self] in
                    self?.presentBlocking(on: presenter, title: title, message: message, storeURL: storeURL)
                }
                return
            }
            guard !self.isPresenting else { return }
            self.isPresenting = true

            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            if let url = storeURL {
                alert.addAction(UIAlertAction(title: "App Store を開く", style: .default) { _ in
                    UIApplication.shared.open(url)
                })
            } else {
                // 完全停止したい場合は OK 押下でも再表示（閉じられない）
                alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                    guard let self else { return }
                    self.isPresenting = false
                    self.presentBlocking(on: presenter, title: title, message: message, storeURL: nil)
                })
            }
            presenter.present(alert, animated: true) { self.isPresenting = false }
        }
    }

}

private extension String {
    func isSemverLower(than other: String) -> Bool {
        let a = split(separator: ".").map { Int($0) ?? 0 }
        let b = other.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av < bv }
        }
        return false
    }
}
