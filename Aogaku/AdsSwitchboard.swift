//
//  AdsSwitchboard.swift
//  Aogaku
//
//  Created by shu m on 2025/10/02.
//
import Foundation
import FirebaseRemoteConfig
import GoogleMobileAds

// ロック画面など他画面からも使えるように共通定義
enum BannerStyle: String { case mrec, adaptive }

final class AdsSwitchboard {
    static let shared = AdsSwitchboard()
    static let didUpdate = Notification.Name("AdsSwitchboard.didUpdate")

    private let rc = RemoteConfig.remoteConfig()

    private init() {
        let settings = RemoteConfigSettings()
        #if DEBUG
        settings.minimumFetchInterval = 0        // 開発中は即反映
        #else
        settings.minimumFetchInterval = 3600     // 本番は 1 時間
        #endif
        rc.configSettings = settings

        // ▼ デフォルト値（未設定でも動くように）
        rc.setDefaults([
            "ads_enabled": true as NSObject,              // 緊急停止スイッチ
            "ads_live": true as NSObject,                 // true=本番ID, false=テストID
            "ads_style": "mrec" as NSObject,              // "mrec" or "adaptive"
            "ads_banner_id_prod": "" as NSObject,         // 小バナー用（本番）
            "ads_banner_id_test": "ca-app-pub-3940256099942544/2934735716" as NSObject, // 小バナー(テスト)
            "ads_mrec_id_prod": "" as NSObject,           // MREC用（本番）※空なら小バナーIDをフォールバック
            "ads_mrec_id_test":   "ca-app-pub-3940256099942544/2934735716" as NSObject,  // MREC(テスト)
            "ads_test_devices": "" as NSObject            // 例: "IDFA1,IDFA2"
        ])
    }

    /// 起動時に1回呼ぶ。フェッチしてMobileAds設定も反映。
    func start() {
        rc.fetchAndActivate { _, _ in
            self.configureMobileAds()
            print("[AdsRC] enabled=\(self.enabled) live=\(self.live) style=\(self.style.rawValue) " +
                  "unit(mrec)=\(self.unitID(for: .mrec)) unit(adaptive)=\(self.unitID(for: .adaptive))")
            NotificationCenter.default.post(name: Self.didUpdate, object: nil)
        }
    }


    var enabled: Bool { rc["ads_enabled"].boolValue }
    var live: Bool { rc["ads_live"].boolValue }
    var style: BannerStyle { BannerStyle(rawValue: rc["ads_style"].stringValue ?? "") ?? .mrec }

    /// スタイルごとのユニットID（本番/テスト/フォールバックを吸収）
    func unitID(for style: BannerStyle) -> String {
        let testBanner = "ca-app-pub-3940256099942544/2934735716"
        let testMREC   = "ca-app-pub-3940256099942544/4411468910"

        switch style {
        case .adaptive:
            let prod = rc["ads_banner_id_prod"].stringValue ?? ""
            let test = rc["ads_banner_id_test"].stringValue ?? ""
            if live, !prod.isEmpty { return prod }
            return test.isEmpty ? testBanner : test

        case .mrec:
            let prod = rc["ads_mrec_id_prod"].stringValue ?? ""
            let test = rc["ads_mrec_id_test"].stringValue ?? ""
            if live, !prod.isEmpty { return prod }
            if !test.isEmpty { return test }
            return testMREC
        }
    }



    private func configureMobileAds() {
        let list = (rc["ads_test_devices"].stringValue ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        MobileAds.shared.requestConfiguration.testDeviceIdentifiers = list
    }

}
