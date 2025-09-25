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

        rc.fetchAndActivate { [weak self] _, _ in
            self?.evaluate(on: presenter)
        }
    }

    private func evaluate(on presenter: UIViewController) {
        let minV  = rc["rc_min_supported_version_ios"].stringValue ?? "0.0.0"
        let stop  = rc["rc_maintenance_mode"].boolValue
        let msg   = rc["rc_maintenance_message"].stringValue ?? ""
        let store = rc["rc_appstore_url"].stringValue ?? ""
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

        if stop {
            presentBlocking(on: presenter, title: "メンテナンス中",
                            message: msg.isEmpty ? "現在一時的にご利用いただけません。" : msg,
                            storeURL: nil)
            return
        }
        if current.isSemverLower(than: minV) {
            presentBlocking(on: presenter, title: "アップデートが必要です",
                            message: "最新バージョンに更新してください。",
                            storeURL: URL(string: store))
        }
    }

    private func presentBlocking(on presenter: UIViewController, title: String, message: String, storeURL: URL?) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        if let url = storeURL {
            alert.addAction(UIAlertAction(title: "App Store を開く", style: .default) { _ in
                UIApplication.shared.open(url)
            })
        }
        presenter.present(alert, animated: true)
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
