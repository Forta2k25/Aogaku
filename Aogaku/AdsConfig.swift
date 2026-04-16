import Foundation

/// AdMob設定（RemoteConfigが無い/未導入のブランチでも落ちないように最低限で定義）
/// - enabled: 広告表示ON/OFF
/// - bannerUnitID: バナー広告のUnitID（DebugはテストID優先）
///
/// 本番IDを使う場合は Info.plist に `ADMOB_BANNER_UNIT_ID` を追加して埋めてください。
enum AdsConfig {

    /// 広告を出すか（UserDefaults "ads_enabled" があれば最優先）
    static var enabled: Bool {

        // UserDefaults に "ads_enabled" があればそれを優先（テストでOFFに便利）
        if UserDefaults.standard.object(forKey: "ads_enabled") != nil {
            return UserDefaults.standard.bool(forKey: "ads_enabled")
        }
        return AdsSwitchboard.shared.enabled

    }

    /// 画面下バー向けバナー Unit ID（RC の本番/テスト切替を利用）
    static var bannerUnitID: String {
        AdsSwitchboard.shared.unitID(for: .adaptive)
    }
}
