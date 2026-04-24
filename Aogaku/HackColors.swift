import UIKit

/// 青山ハック — マイナスの美学 カラーシステム
///
/// Light: Appleインスパイア・クリーン（白・精密・シャープ）
/// Dark : ターミナル美学（#0D0D0D・蛍光グリーンアクセント）
///
/// すべての色はシステムのダーク/ライト設定に自動追従する。
enum HackColors {

    // MARK: - Private helper
    private static func make(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    // MARK: - 背景
    /// アプリ全体の背景
    /// Light: 純白 / Dark: #0D0D0D（ほぼ黒）
    static let background = make(
        light: .systemBackground,
        dark:  UIColor(white: 0.05, alpha: 1)
    )

    // MARK: - 授業セル
    /// 授業コマの背景色（デフォルト = teal 相当）
    /// Light: 深い青山グリーン / Dark: ダーク背景で視認できる明るめ深緑
    static let cellFill = make(
        light: UIColor(red:  0/255, green: 105/255, blue: 52/255, alpha: 1),  // #006934
        dark:  UIColor(red: 30/255, green: 140/255, blue: 70/255, alpha: 1)   // #1E8C46 明るく
    )

    /// 授業コマのボーダー（ダーク限定。ライトは不要）
    static let cellBorder = make(
        light: .clear,
        dark:  UIColor(red: 30/255, green: 100/255, blue: 55/255, alpha: 0.4)
    )

    // MARK: - 空きコマ
    /// 空きコマの背景
    /// Light: systemBackground / Dark: 背景より少し明るいグレー（グリッドが視認できる）
    static let emptyCellBg = make(
        light: UIColor.systemBackground,
        dark:  UIColor(white: 0.10, alpha: 1)
    )

    /// 空きコマのボーダー（グリッド線）
    /// Light: 標準separator / Dark: やや見えるライン
    static let gridLine = make(
        light: .separator,
        dark:  UIColor(white: 0.18, alpha: 1)
    )

    /// 空きコマの + アイコン色
    /// Light: tertiaryLabel / Dark: 薄く見える白（グリッドの存在感を保つ）
    static let plusIcon = make(
        light: .tertiaryLabel,
        dark:  UIColor(white: 0.22, alpha: 1)
    )

    /// UISwitch のオン色（ライトは systemGreen で見やすく）
    static let switchTint = make(
        light: UIColor.systemGreen,
        dark:  UIColor(red: 45/255, green: 255/255, blue: 110/255, alpha: 1)
    )

    // MARK: - アクセント（今・選択・強調）
    /// 「今この瞬間」にだけ使うアクセント色
    /// Light: 深い青山グリーン / Dark: ターミナルグリーン #2DFF6E
    static let nowAccent = make(
        light: UIColor(red:  0/255, green: 105/255, blue: 52/255, alpha: 1),
        dark:  UIColor(red: 45/255, green: 255/255, blue: 110/255, alpha: 1)
    )

    /// タブバー・ボタン等のUIアクセント（nowAccentと同値）
    static let accent = nowAccent

    /// 今日のヘッダーハイライト背景
    static let todayHighlightBg = make(
        light: UIColor.systemGreen.withAlphaComponent(0.22),
        dark:  UIColor(red: 45/255, green: 255/255, blue: 110/255, alpha: 0.22)
    )

    // MARK: - テキスト
    /// ヘッダーラベル（曜日・時限）の通常色
    static let headerText = make(
        light: .secondaryLabel,
        dark:  UIColor(white: 0.32, alpha: 1)
    )

    /// 今日の曜日ラベル文字色
    static let todayHeaderText = nowAccent

    // MARK: - セルの角丸半径
    /// ライト・ダーク共通: Apple風の丸み
    static func cellCornerRadius(for traitCollection: UITraitCollection) -> CGFloat { 8 }

    /// 空きコマのボーダー幅
    static func emptyCellBorderWidth(for traitCollection: UITraitCollection) -> CGFloat {
        traitCollection.userInterfaceStyle == .dark ? 0.5 : 0.5
    }
}
