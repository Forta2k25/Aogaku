import Foundation

// MARK: - 開発者用広告トグル（DEBUG ビルドのみ）
#if DEBUG
enum AdsDebugState {
    private static let key = "ads_enabled"

    /// 現在、開発者によって広告が非表示にされているか
    static var isHidden: Bool {
        UserDefaults.standard.object(forKey: key) != nil
            && !UserDefaults.standard.bool(forKey: key)
    }

    /// 非表示 ↔ デフォルト(通常表示) をトグルする
    static func toggle() {
        if isHidden {
            // 強制OFFを解除 → AdsConfig 本来のロジックへ戻す
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            // 強制OFF
            UserDefaults.standard.set(false, forKey: key)
        }
        // 次回起動時に確実に反映されるようフラッシュ
        UserDefaults.standard.synchronize()
        // 今開いているバナーにも即時反映
        NotificationCenter.default.post(name: .adsEnabledDidChange, object: nil)
    }
}

extension Notification.Name {
    static let adsEnabledDidChange = Notification.Name("adsEnabledDidChange")
}
#endif

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
