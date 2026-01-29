import Foundation

/// AdMob設定（RemoteConfigが無い/未導入のブランチでも落ちないように最低限で定義）
/// - enabled: 広告表示ON/OFF
/// - bannerUnitID: バナー広告のUnitID（DebugはテストID優先）
///
/// 本番IDを使う場合は Info.plist に `ADMOB_BANNER_UNIT_ID` を追加して埋めてください。
enum AdsConfig {

    /// 広告を出すか（必要なら UserDefaults で強制OFFできる）
    static var enabled: Bool {
        // UserDefaults に "ads_enabled" があればそれを優先（テストでOFFに便利）
        if UserDefaults.standard.object(forKey: "ads_enabled") != nil {
            return UserDefaults.standard.bool(forKey: "ads_enabled")
        }
        return true
    }

    /// バナー広告 Unit ID
    static var bannerUnitID: String {
        #if DEBUG
        // Google公式テスト用バナーUnitID
        return "ca-app-pub-3940256099942544/2934735716"
        #else
        // Info.plist から取得（無ければテストIDにフォールバック）
        if let s = Bundle.main.object(forInfoDictionaryKey: "ADMOB_BANNER_UNIT_ID") as? String,
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
        return "ca-app-pub-3940256099942544/2934735716"
        #endif
    }
}
