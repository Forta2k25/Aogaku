
//  CreditsFullViewController.swift
//  Aogaku
//
//  学部・学科セレクタ
//  必要単位：青山スタンダード / 外国語 / 学科科目 / 自由選択 の4区分で可変
//  ドーナツ＆凡例は4分割、一覧は（青山/学科/外国語/自由）で分割表示
//

import UIKit

// ---- Darkでも薄いグレーにする自前カラー ----
extension UIColor {
    /// 画面全体の背景
    static var appBG: UIColor {
        UIColor { t in
            t.userInterfaceStyle == .dark ? UIColor(white: 0.14, alpha: 1.0)
                                          : UIColor(white: 0.98, alpha: 1.0)
        }
    }
    /// カード/セル/ボタンの地
    static var cardBG: UIColor {
        UIColor { t in
            t.userInterfaceStyle == .dark ? UIColor(white: 0.20, alpha: 1.0)
                                          : UIColor.secondarySystemBackground
        }
    }
}


// ======================== 4区分 要件モデル ========================
private struct Requirement4 {
    let aoyama: Int
    let language: Int
    let department: Int
    let free: Int
    var total: Int { aoyama + language + department + free }
}

// Requirement.standard を4区分にマップ（初期は語学0）
private let DEFAULT_REQ4 = Requirement4(
    aoyama: Requirement.standard.aoyama,
    language: 0,
    department: Requirement.standard.department,
    free: Requirement.standard.free
)

// 手動追加した科目 → Seg4 の強制分類マップ（"manual:<id>" → Seg4）
private var manualSegMap: [String: Seg4] = [:]

// ======================== 表示セグメント（ドーナツ＆凡例） ========================
private enum Seg4: String, CaseIterable, Codable {
    case aoyama, language, department, free
    var title: String {
        switch self {
        case .aoyama:     return "青山スタンダード"
        case .language:   return "外国語科目"
        case .department: return "学科科目"
        case .free:       return "自由選択科目"
        }
    }
    var color: UIColor {
        switch self {
        case .aoyama:     return UIColor.systemBlue
        case .language:   return UIColor.systemIndigo   // 語学は紫系
        case .department: return UIColor.systemRed
        case .free:       return UIColor.systemGreen
        }
    }
}

// ======================== 学部・学科マスタ ========================
private let FACULTY_MAP: [String: [String]] = [
    // 青山
    "文学部": ["英米文学科", "フランス文学科", "日本文学科日本文学コース", "日本文学科日本語・日本語教育コース", "史学科西洋史コース", "史学科日本史コース", "史学科考古学コース", "史学科東洋史コース", "比較芸術学科"],
    "教育人間科学部": ["教育学科一般心理コース", "教育学科臨床心理コース", "心理学科"],
    "経済学部": ["経済学科", "現代経済デザイン学科"],
    "法学部": ["法学科", "ヒューマンライツ学科"],
    "経営学部": ["経営学科", "マーケティング学科"],
    "国際政治経済学部": ["国際政治学科", "国際経済学科", "国際コミュニケーション学科"],
    "総合文化政策学部": ["総合文化政策学科"],
    // 相模原
    "理工学部": ["物理科学科", "数理サイエンス学科", "化学・生命科学科", "電気電子工学科", "機械創造工学科", "経営システム工学科", "情報テクノロジー学科"],
    "コミュニティ人間科学部": ["コミュニティ人間科学科"],
    "社会情報学部": ["社会情報学科"],
    "地球社会共生学部": ["地球社会共生学科"]
]

// ======================== 学科ごとの判定ルール（自学科かどうか） ========================
// 使い方：selectedDepartment に一致するキーのルールで、講義タイトル/カテゴリ文字列を判定します。
// - anyOf: いずれか1つ以上含まれていればOK（OR）
// - allOf: すべて含まれていなければNG（AND）
// - noneOf: 1つでも含まれていたらNG（NOT）
// 文字は lowercased + 全角/半角スペース除去後に contains で照合します。
// 追加は自由。キーは学科ボタンで保存している名称と一致させてください。
private struct DeptMatchRule {
    var anyOf:  [String] = []
    var allOf:  [String] = []
    var noneOf: [String] = []
    func matches(_ haystack: String) -> Bool {
        let orOK  = anyOf.isEmpty  || anyOf.contains { haystack.contains($0) }
        let andOK = allOf.allSatisfy { haystack.contains($0) }
        let notOK = noneOf.allSatisfy { !haystack.contains($0) }
        return orOK && andOK && notOK
    }
}

// 正規化（小文字化 + スペース除去。必要なら記号除去など拡張してOK）
private func norm(_ s: String) -> String {
    return s.lowercased()
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "　", with: "")
}



// ここを好きなだけ足してOK。未定義の学科はフォールバック（学科名が含まれるかどうか）で判定します。
private let DEPT_RULES: [String: DeptMatchRule] = [
    // ===== 文学部系サンプル =====
    "英米文学科": DeptMatchRule(
        anyOf:  ["英米文学科", "英米文学", "英文学", "英語学", "english", "american", "british"],
        noneOf: ["フランス", "仏文", "ドイツ", "独文", "中国語", "スペイン", "韓国", "朝鮮", "ロシア", "イタリア"]
    ),
    "フランス文学科": DeptMatchRule(
        anyOf: ["フランス文学科", "仏文", "french", "français"]
    ),
    "日本文学科日本文学コース": DeptMatchRule(
        anyOf: ["日本文学科"]
    ),
    "日本文学科日本語・日本語教育コース": DeptMatchRule(
        anyOf: ["日本文学科"]
    ),
    "史学科日本史コース": DeptMatchRule(
        anyOf: ["史学科"]
    ),
    "史学科考古学コース": DeptMatchRule(
        anyOf: ["史学科"]
    ),
    "史学科西洋史コース": DeptMatchRule(
        anyOf: ["史学科"]
    ),
    "史学科東洋史コース": DeptMatchRule(
        anyOf: ["史学科"]
    ),

    // ===== ここからは雛形：必要に応じて学科名ごとに追加してください =====
    "比較芸術学科": DeptMatchRule(anyOf: ["比較芸術学科"]),
    "国際政治学科": DeptMatchRule(anyOf: ["国際政治経済学部"]),
    "国際経済学科": DeptMatchRule(anyOf: ["国際政治経済学部"]),
    "国際コミュニケーション学科": DeptMatchRule(anyOf: ["国際政治経済学部"]),
    "経済学科": DeptMatchRule(anyOf: ["経済学部"]),
    "現代経済デザイン学科": DeptMatchRule(anyOf: ["経済学部"]),
    "法学科": DeptMatchRule(anyOf: ["法学部"]),
    "ヒューマンライツ学科": DeptMatchRule(anyOf: ["法学部"]),
    "社会情報学科": DeptMatchRule(anyOf: ["社会情報学部"]),
    "コミュニティ人間科学科": DeptMatchRule(anyOf: ["人間科学部"]),
    "地球社会共生学科": DeptMatchRule(anyOf: ["地球社会共生学部"]),
    "物理科学科": DeptMatchRule(anyOf: ["理工学部共通", "物理科学", "物理・数理"],
                           noneOf: ["English", "Abroad", "Speaking"]),
    "数理サイエンス学科": DeptMatchRule(anyOf: ["理工学部共通", "数理サイエンス", "物理・数理"],
                               noneOf: ["English", "Abroad", "Speaking"]),
    "化学・生命科学科": DeptMatchRule(anyOf:["理工学部共通", "化学・生命"],
                              noneOf: ["English", "Abroad", "Speaking"]),
    "電気電子工学科": DeptMatchRule(anyOf: ["理工学部共通", "電気電子工学科"],
                             noneOf: ["English", "Abroad", "Speaking"]),
    "機械創造工学科": DeptMatchRule(anyOf: ["理工学部共通", "機械創造"],
                             noneOf: ["English", "Abroad", "Speaking"]),
    "経営システム工学科": DeptMatchRule(anyOf:["理工学部共通", "経営システム"],
                               noneOf: ["English", "Abroad", "Speaking"]),
    "情報テクノロジー学科": DeptMatchRule(anyOf: ["理工学部共通", "情報テクノロジ"],
                                noneOf: ["English", "Abroad", "Speaking"]),
    "教育学科一般心理コース": DeptMatchRule(anyOf: ["教育学科"]),
    "教育学科臨床心理コース": DeptMatchRule(anyOf: ["教育学科"]),
    "心理学科": DeptMatchRule(anyOf: ["心理学科"]),
    "経営学科": DeptMatchRule(anyOf: ["経営学部"]),
    "マーケティング学科": DeptMatchRule(anyOf: ["経営学部"]),
    "総合文化政策学科": DeptMatchRule(anyOf: ["総合文化政策学部"]),
    
]


// ======================== 必要単位カタログ（学部→学科） ========================
// ここに学部学科を自由に追加してください。未記載は DEFAULT_REQ4 で動きます。
// 置き換え：Requirement カタログ用の型
private struct GradRule {
    let requirement: Requirement4
    /// 語学を 4 区分のどこに入れるか（既定は .language）
    let languageSink: Seg4
    init(requirement: Requirement4, languageSink: Seg4 = .language) {
        self.requirement = requirement
        self.languageSink = languageSink
    }
}

private let REQUIREMENT_CATALOG: [String: [String: GradRule]] = [
    // ── 文学部 ──
    "文学部": [
        // 画像① 英米文学科：青山24 / 外国語(英語) 6+12=18 / 学科(専門) 4+40=44 / 自由38 = 124
        "英米文学科": GradRule(
            requirement: Requirement4(aoyama: 24, language: 0, department: 62, free: 38),
            languageSink: .department     // ← 追加
        ),
        // 画像② フランス文学科：青山24 / 外国語(仏語)16 / 学科 24+40=64 / 自由24 = 128
        "フランス文学科": GradRule(
            requirement: Requirement4(aoyama: 24, language: 0, department: 80, free: 24),
            languageSink: .department     // ← 追加
        ),
        // ───────── ここから写真の分 ─────────

          // 日本文学科（コース別）
          // 画像：青山24 / 外国語8 / 学科（必修20 + 選択必修44）/ 自由30 = 126
          "日本文学科日本文学コース": GradRule(
              requirement: Requirement4(aoyama: 24, language: 8, department: 64, free: 30)
          ),
          // 画像：青山24 / 外国語8 / 学科（必修40 + 選択必修34）/ 自由20 = 126
          "日本文学科日本語・日本語教育コース": GradRule(
              requirement: Requirement4(aoyama: 24, language: 8, department: 74, free: 20)
          ),

          // 史学科（コース別）
          // 画像：青山24 / 外国語8 / 自由28 / 総計128 → 学科は 128-24-8-28=68
          "史学科日本史コース": GradRule(
              requirement: Requirement4(aoyama: 24, language: 8, department: 68, free: 28)
          ),
          "史学科東洋史コース": GradRule(
              requirement: Requirement4(aoyama: 24, language: 8, department: 68, free: 28)
          ),
          "史学科西洋史コース": GradRule(
              requirement: Requirement4(aoyama: 24, language: 8, department: 68, free: 28)
          ),

          // 比較芸術学科
          // 画像：青山24 / 外国語8 / 学科（必修20 + 選択必修50=70）/ 自由26 = 128
          "比較芸術学科": GradRule(
              requirement: Requirement4(aoyama: 24, language: 8, department: 70, free: 26)
          ),

          // 既定（未指定学科用）
          "*": GradRule(requirement: DEFAULT_REQ4)
      ],

    // ── 教育人間科学部 ──
    "教育人間科学部": [
        // 画像③ 教育学科：青山26 / 外国語I 10 / 学科 30+12+16=58 / 自由34 = 128
        "教育学科": GradRule(
            requirement: Requirement4(aoyama: 26, language: 10, department: 58, free: 34)
        ),
        // 心理学科（コースで更に分岐が必要なら後で拡張可）
        // 画像④ 心理学科（一般心理コース例）：青山24 / 外国語10 / 学科(共通22+コース必修0+選択必修36=58) / 自由36 = 128
        "心理学科一般心理コース": GradRule(
            requirement: Requirement4(aoyama: 24, language: 10, department: 58, free: 36)),
            
        "心理学科臨床心理コース": GradRule(
            requirement: Requirement4(aoyama: 24, language: 10, department: 79, free: 15)
        ),
        "*": GradRule(requirement: DEFAULT_REQ4)
    ],
    // ───────── 経済学部 ─────────
    "経済学部": [
        // 経済学科：青山26 / 外国語8 / 学科80 / 自由10 = 124
        "経済学科": GradRule(
            requirement: Requirement4(aoyama: 26, language: 8, department: 80, free: 10)
        ),
        // 現代経済デザイン学科：青山26 / 外国語10 / 学科80 / 自由8 = 124
        "現代経済デザイン学科": GradRule(
            requirement: Requirement4(aoyama: 26, language: 10, department: 80, free: 8)
        ),
        "*": GradRule(requirement: DEFAULT_REQ4)
    ],

    // ───────── 法学部 ─────────
    "法学部": [
        // 法学科：青山24 / 外国語10 / 学科82 / 自由16 = 132
        "法学科": GradRule(
            requirement: Requirement4(aoyama: 24, language: 10, department: 82, free: 16)
        ),
        // ヒューマンライツ学科：青山24 / 外国語10 / 学科82 / 自由16 = 132
        "ヒューマンライツ学科": GradRule(
            requirement: Requirement4(aoyama: 24, language: 10, department: 82, free: 16)
        ),
        "*": GradRule(requirement: DEFAULT_REQ4)
    ],

    // ───────── 経営学部 ─────────
    "経営学部": [
        // 経営学科：青山26 / 外国語8 / 学科72 / 自由18 = 124
        "経営学科": GradRule(
            requirement: Requirement4(aoyama: 26, language: 8, department: 72, free: 18)
        ),
        // マーケティング学科：青山26 / 外国語8 / 学科72 / 自由18 = 124
        "マーケティング学科": GradRule(
            requirement: Requirement4(aoyama: 26, language: 8, department: 72, free: 18)
        ),
        "*": GradRule(requirement: DEFAULT_REQ4)
    ],

    // ───────── 国際政治経済学部 ─────────
    "国際政治経済学部": [
        // 学科共通（A/B/C群小計より）：青山24 / 外国語18 / 学科70 / 自由20 = 132
        "国際政治学科": GradRule(
            requirement: Requirement4(aoyama: 24, language: 18, department: 70, free: 20)
        ),
        "国際経済学科": GradRule(
            requirement: Requirement4(aoyama: 24, language: 18, department: 70, free: 20)
        ),
        "国際コミュニケーション学科": GradRule(
            requirement: Requirement4(aoyama: 24, language: 18, department: 70, free: 20)
        ),
        "*": GradRule(requirement: DEFAULT_REQ4)
    ],

    // ───────── 総合文化政策学部 ─────────
    "総合文化政策学部": [
        // 総合文化政策学科：青山26 / 外国語12 / 学科72 / 自由20 = 130
        "総合文化政策学科": GradRule(
            requirement: Requirement4(aoyama: 26, language: 12, department: 72, free: 20)
        ),
        "*": GradRule(requirement: DEFAULT_REQ4)
    ],
    
    // ───────── 理工学部 ─────────
    "理工学部": [
        // 物理科学科：青山24 / 外国語10 / 学科98 / 自由6 = 138
        "物理科学科": GradRule(
            requirement: Requirement4(aoyama: 24, language: 10, department: 98, free: 6)
        ),

        // 数理サイエンス学科：青山24 / 外国語10 / 学科96 / 自由6 = 136
        "数理サイエンス学科": GradRule(
            requirement: Requirement4(aoyama: 24, language: 10, department: 96, free: 6)
        ),

        // 化学・生命科学科：青山24 / 外国語10 / 学科94 / 自由10 = 138
        "化学・生命科学科": GradRule(
            requirement: Requirement4(aoyama: 24, language: 10, department: 94, free: 10)
        ),

        // 電気電子工学科：青山24 / 外国語10 / 学科95 / 自由8 = 137
        "電気電子工学科": GradRule(
            requirement: Requirement4(aoyama: 24, language: 10, department: 95, free: 8)
        ),

        // 機械創造工学科：青山24 / 外国語10 / 学科96 / 自由6 = 136
        "機械創造工学科": GradRule(
            requirement: Requirement4(aoyama: 24, language: 10, department: 96, free: 6)
        ),

        // 経営システム工学科：青山24 / 外国語10 / 学科96 / 自由6 = 136
        "経営システム工学科": GradRule(
            requirement: Requirement4(aoyama: 24, language: 10, department: 96, free: 6)
        ),

        // 情報テクノロジー学科：青山24 / 外国語10 / 学科86 / 自由16 = 136
        "情報テクノロジー学科": GradRule(
            requirement: Requirement4(aoyama: 24, language: 10, department: 86, free: 16)
        ),

        "*": GradRule(requirement: DEFAULT_REQ4)
    ],
    
    // ───────── 社会情報学部 ─────────
    "社会情報学部": [
        // 社会情報学科：青山26 / 外国語8 / 学科82 / 自由8 = 124
        "社会情報学科": GradRule(
            requirement: Requirement4(aoyama: 26, language: 8, department: 82, free: 8)
        ),
        "*": GradRule(requirement: DEFAULT_REQ4)
    ],

    // ───────── 地球社会共生学部 ─────────
    "地球社会共生学部": [
        // 地球社会共生学科：青山26 / 外国語16 / 学科66 / 自由16 = 124
        "地球社会共生学科": GradRule(
            requirement: Requirement4(aoyama: 26, language: 16, department: 66, free: 16)
        ),
        "*": GradRule(requirement: DEFAULT_REQ4)
    ],

    // ───────── コミュニティ人間科学部 ─────────
    "コミュニティ人間科学部": [
        // コミュニティ人間科学科：青山26 / 外国語10 / 学科34 / 自由40 = 124
        "コミュニティ人間科学科": GradRule(
            requirement: Requirement4(aoyama: 26, language: 10, department: 34, free: 40)
        ),
        "*": GradRule(requirement: DEFAULT_REQ4)
    ],


]

// ======================== 一覧表示カテゴリ（語学は独立） ========================
private enum DisplayCategory: CaseIterable {
    case aoyama, department, language, free
    var title: String {
        switch self {
        case .aoyama:     return "青山スタンダード"
        case .department: return "学科科目"
        case .language:   return "外国語科目"
        case .free:       return "自由選択科目"
        }
    }
}

// ======================== 本体 ========================
final class CreditsFullViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    // 入力：現在表示中の学期（timetable から渡す）
    private let currentTerm: TermKey
    init(currentTerm: TermKey) {
        self.currentTerm = currentTerm
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // UI
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let headerContainer = UIView()
    private let facultyButton = UIButton(type: .system)
    private let departmentButton = UIButton(type: .system)
    private let captionLabel = UILabel()
    private let donut = DonutChartView()
    private let centerValueLabel = UILabel()
    private let needLabel = UILabel()
    private let legendStack = UIStackView()

    // UserDefaults
    private enum Prefs {
        static let faculty = "credits.selectedFaculty"
        static let dept    = "credits.selectedDepartment"
        // ★ ここから追加
        static let manualCredits = "credits.manual.entries"   // 手動追加した単位
        static let overrides     = "credits.category.override"// コースごとのカテゴリ上書き
        // ★ ここまで追加
    }

    // 状態
    private var selectedFaculty: String?
    private var selectedDepartment: String?

    // 集計
    private struct Totals {
        var earned: [Seg4: Int] = [:]
        var planned: [Seg4: Int] = [:]
        var earnedTotal = 0
        var plannedTotal = 0
    }
    private var totals = Totals()
    
    // ★ ここから追加：手動追加エントリ（画面内だけで使う軽量モデル）
    private struct ManualCredit: Codable {
        let id: String           // UUID
        var title: String
        var credits: Int
        var category: Seg4       // どの区分に入れるか（表示もこのまま使う）
        var isPlanned: Bool      // 取得予定なら true（今学期の一覧へ）
        var termText: String   // ← ここが正
        //let termRaw: String      // 保存用（currentTerm.rawValue として）
    }

    private func loadManualCredits() -> [ManualCredit] {
        let ud = UserDefaults.standard
        guard let data = ud.data(forKey: Prefs.manualCredits) else { return [] }
        return (try? JSONDecoder().decode([ManualCredit].self, from: data)) ?? []
    }
    private func saveManualCredits(_ list: [ManualCredit]) {
        let ud = UserDefaults.standard
        let data = try? JSONEncoder().encode(list)
        ud.set(data, forKey: Prefs.manualCredits)
    }
    // ★ ここまで追加

    // ★ ここから追加：カテゴリ上書き（コースごとに Seg4 を固定）
    private typealias OverrideMap = [String: String]   // key: courseKey → Seg4.rawValue

    //private func courseKey(_ c: Course) -> String { "\(c.id)#\(c.title)" }
    // どの学期で取ったか表示用に保持
    private var earnedTermText: [String: String] = [:]

    private func courseKey(_ c: Course) -> String {
        // ユニークキー（登録番号+科目名）
        return (c.id.isEmpty ? "" : c.id) + "#" + c.title
    }

    private func loadOverrides() -> OverrideMap {
        UserDefaults.standard.dictionary(forKey: Prefs.overrides) as? OverrideMap ?? [:]
    }
    private func saveOverrides(_ map: OverrideMap) {
        UserDefaults.standard.set(map, forKey: Prefs.overrides)
    }
    // ★ ここまで追加

    

    // 一覧（カテゴリ分割）
    private var plannedByDisplay: [DisplayCategory: [Course]] = [:]
    private var earnedByDisplay:  [DisplayCategory: [Course]] = [:]

    private enum SectionKind {
        case planned(DisplayCategory)
        case earned(DisplayCategory)
        var title: String {
            switch self {
            case .planned(let d): return "取得予定（今学期） — \(d.title)"
            case .earned(let d):  return "取得済み（過年度） — \(d.title)"
            }
        }
    }
    private var sections: [SectionKind] = []

    // MARK: - Life
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.appBG
        tableView.backgroundColor = UIColor.appBG
        title = "単位"
        if presentingViewController != nil && navigationController?.viewControllers.first == self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                systemItem: .close,
                primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
            )
        }
        donut.backgroundColor = .clear
        donut.isOpaque = false

        buildUI()
        loadSelection()
        updateFilterButtons() // ← 復元→再計算→UI反映
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        donut.transform = CGAffineTransform.identity.scaledBy(x: 0.86, y: 0.86)
        updateTableHeaderHeightIfNeeded()
    }

    // MARK: - ルール取得
    private func currentGradRule() -> GradRule? {
        guard let f = selectedFaculty else { return nil }
        let dict = REQUIREMENT_CATALOG[f]
        if let d = selectedDepartment, let r = dict?[d] { return r }
        if let r = dict?["*"] { return r }
        return nil
    }
    private func requirement4() -> Requirement4 {
        currentGradRule()?.requirement ?? DEFAULT_REQ4
    }
    
    // 現在選択中の学科ルールから語学の吸収先を取得
    private func currentLanguageSink() -> Seg4 {
        currentGradRule()?.languageSink ?? .language
    }

    // MARK: - 判定
    // 語学判定（既定は「外国語」を含むもの）
    private func isLanguageCourse(_ c: Course) -> Bool {
        // c.title は非Optional のはずなので ?? "" は不要
        let s = "\(c.title) \(c.category ?? "")".lowercased()
        let keys = ["外国語", "english", "advanced", "speaking", "abroad", ]  // 必要に応じて ["english","英語",…] など拡張
        return keys.contains { s.contains($0) }
    }
    
    // 自学科の科目か（選択中の学科ごとの詳細ルールで判定）
    private func isOwnDepartmentCourse(_ c: Course) -> Bool {
        guard let depName = selectedDepartment, !depName.isEmpty else { return false }
        let hay = norm("\(c.title) \(c.category ?? "")")

        if let rule = DEPT_RULES[depName] {
            // ルールがあればルールで判定（キーワードも正規化してから）
            let r = DeptMatchRule(
                anyOf:  rule.anyOf.map(norm),
                allOf:  rule.allOf.map(norm),
                noneOf: rule.noneOf.map(norm)
            )
            return r.matches(hay)
        } else {
            // フォールバック：学科名が含まれていれば自学科扱い
            return hay.contains(norm(depName))
        }
    }
    // 青山スタンダード
    private func isAoyamaStandard(_ c: Course) -> Bool {
        let cat = (c.category ?? "").lowercased()
        return cat.contains("スタンダード") || cat.contains("standard")
    }
    // 4区分（ドーナツ/凡例/一覧用）
    private func classifySeg4(_ c: Course) -> Seg4 {
        
        // ✅ 手動追加は ID で強制分類
        if let seg = manualSegMap[c.id] { return seg }
        
        // ★ ここから追加：上書きがあれば最優先
        let ov = loadOverrides()
        if let raw = ov[courseKey(c)], let fixed = Seg4.allCases.first(where: { "\($0)" == raw }) {
            return fixed
        }
        // ★ ここまで追加
        
        if isAoyamaStandard(c) { return .aoyama }
        if isLanguageCourse(c) { return currentLanguageSink() }  // 学科吸収 or 外国語として独立
        if isOwnDepartmentCourse(c) { return .department }
        return .free
    }
    
    // すべての学期候補を作る（前期/後期の並び）
    private func makeFullTermChoices() -> [String] {
        // 現在の学期の年を中心に、最長6年（例：-3年〜+2年）をベースにする
        let centerYear = currentTerm.year
        var minY = centerYear - 3
        var maxY = centerYear + 2

        // 既に保存されている学期の年があれば、それも範囲に含める
        let saved = TermStore.allSavedTerms()
        if let yMin = saved.map({ $0.year }).min() { minY = min(minY, yMin) }
        if let yMax = saved.map({ $0.year }).max() { maxY = max(maxY, yMax) }

        // 表示文字列で返す（アプリ内の表記に合わせて）
        var out: [String] = []
        for y in minY...maxY {
            out.append("\(y) 年前期")
            out.append("\(y) 年後期")
        }
        return out
    }


    // 一覧カテゴリ（見出し用）も同じロジックで
    private func classifyDisplay(_ c: Course) -> DisplayCategory {
        
        // ✅ 手動追加は ID で強制分類
        //if manualSegMap[c.id] != nil{}
        
            switch classifySeg4(c) {
            case .aoyama:     return .aoyama
            case .language:   return .language
            case .department: return .department
            case .free:       return .free
            }

    }

    private var currentTermText: String { currentTerm.displayTitle }  // displayTitle は既存で使用中
    
    // MARK: - 集計
    private func compute() {
        // データ読み出し
        let now = TermStore.loadAssigned(for: currentTerm)
        var plannedCourses = uniqueCourses(now)
        var all: [Course] = []
        for term in TermStore.allSavedTerms().sorted(by: <) where term < currentTerm {
            all.append(contentsOf: TermStore.loadAssigned(for: term))
        }
        var earnedCourses = uniqueCourses(all)
        
        // ✅ 手動マップをクリア
        manualSegMap.removeAll()
        
        // ★ ここから追加：手動単位を Course化して合流
        var planned = plannedCourses
        var earned  = earnedCourses
        
        // --- ここから追加：取得学期マップを組み立てる ---
        earnedTermText.removeAll()
        // 過去学期分
        for term in TermStore.allSavedTerms().sorted(by: <) where term < currentTerm {
            let arr = TermStore.loadAssigned(for: term)
            for c in arr {
                earnedTermText[courseKey(c)] = term.displayTitle   // 例: "2024 年前期"
            }
        }
        // 手動追加の過年度（isPlanned == false）の場合
        for m in loadManualCredits() where m.termText != currentTermText {
            let fake = Course(id: "manual:\(m.id)", title: m.title,
                              room: "", teacher: "", credits: m.credits,
                              campus: "", category: nil, syllabusURL: "", term: nil)
            earnedTermText[courseKey(fake)] = m.termText   // 例: "2023 年前期"
        }
        // --- 追加ここまで ---
        
        for m in loadManualCredits() {
            // Course を最小限で合成（teacher はダミー）
            let manualId = "manual:\(m.id)"
            manualSegMap[manualId] = m.category   // ← m.category は Seg4 型のはず
            
            let course = Course(
                id: "manual:\(m.id)",
                title: m.title,
                room: "",                 // ← teacher より前に
                teacher: "手動追加 (長押しで編集)",
                credits: m.credits,                // ← 次項で説明（Int を渡す）
                campus: "",               // ← ここも定義順に合わせる
                category: {
                    switch m.category {
                    case .aoyama:     return "青山スタンダード"
                    case .language:   return "外国語"
                    case .department: return "学科科目"
                    case .free:       return "自由選択"
                    }
                }(),
                syllabusURL: "",
                term: ""                    // ← String 型なら空文字 / URL? なら nil
            )
            let isPlannedNow = (m.termText == currentTermText)   // ★ 比較で判定
            if isPlannedNow { planned.append(course) } else { earned.append(course) }
            //if m.isPlanned { planned.append(course) } else { earned.append(course) }
        }
        // 以降の処理は planned / earned を使う
        plannedCourses = planned
        earnedCourses  = earned
        // ★ ここまで追加

        // ドーナツ用集計
        func add(_ c: Course, to dict: inout [Seg4: Int]) {
            let val = (c.credits as Int?) ?? 0
            let k = classifySeg4(c)
            dict[k, default: 0] += val
        }
        totals = Totals()
        earnedCourses.forEach { add($0, to: &totals.earned) }
        plannedCourses.forEach { add($0, to: &totals.planned) }
        totals.earnedTotal  = earnedCourses.reduce(0) { $0 + (( $1.credits as Int?) ?? 0) }
        totals.plannedTotal = plannedCourses.reduce(0) { $0 + (( $1.credits as Int?) ?? 0) }

        // クリップ（各区分の必要単位で）
        let req = requirement4()
        for seg in Seg4.allCases {
            let need: Int = {
                switch seg {
                case .aoyama:     return req.aoyama
                case .language:   return req.language
                case .department: return req.department
                case .free:       return req.free
                }
            }()
            let e = totals.earned[seg] ?? 0
            let p = totals.planned[seg] ?? 0
            totals.earned[seg]  = min(e, need)
            totals.planned[seg] = min(p, max(0, need - (totals.earned[seg] ?? 0)))
        }

        // 一覧カテゴリ分割
        plannedByDisplay = Dictionary(grouping: plannedCourses, by: classifyDisplay)
        earnedByDisplay  = Dictionary(grouping: earnedCourses,  by: classifyDisplay)
        for k in DisplayCategory.allCases {
            plannedByDisplay[k] = (plannedByDisplay[k] ?? []).sorted { $0.title < $1.title }
            earnedByDisplay[k]  = (earnedByDisplay[k]  ?? []).sorted { $0.title < $1.title }
        }

        // セクション
        sections.removeAll()
        for d in DisplayCategory.allCases {
            if let arr = plannedByDisplay[d], !arr.isEmpty { sections.append(.planned(d)) }
        }
        for d in DisplayCategory.allCases {
            if let arr = earnedByDisplay[d], !arr.isEmpty { sections.append(.earned(d)) }
        }
    }

    // MARK: - 表示反映
    private func apply() {
        let earned = totals.earnedTotal
        let full   = totals.earnedTotal + totals.plannedTotal
        centerValueLabel.attributedText = makeCenterValue(earned: earned, totalWithPlanned: full)

        let req = requirement4()
        needLabel.text = "合計必要単位数 \(req.total)"

        // ドーナツ 4分割
        let segs: [DonutSegment] = [
            .init(color: Seg4.aoyama.color,
                  earned: CGFloat(totals.earned[.aoyama] ?? 0),
                  planned: CGFloat(totals.planned[.aoyama] ?? 0),
                  required: CGFloat(req.aoyama)),
            .init(color: Seg4.language.color,
                  earned: CGFloat(totals.earned[.language] ?? 0),
                  planned: CGFloat(totals.planned[.language] ?? 0),
                  required: CGFloat(req.language)),
            .init(color: Seg4.department.color,
                  earned: CGFloat(totals.earned[.department] ?? 0),
                  planned: CGFloat(totals.planned[.department] ?? 0),
                  required: CGFloat(req.department)),
            .init(color: Seg4.free.color,
                  earned: CGFloat(totals.earned[.free] ?? 0),
                  planned: CGFloat(totals.planned[.free] ?? 0),
                  required: CGFloat(req.free))
        ]
        donut.configure(segments: segs)

        // 凡例 4行
        legendStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        func row(_ seg: Seg4, need: Int) -> UIStackView {
            let dot = UIView(); dot.backgroundColor = seg.color; dot.layer.cornerRadius = 6
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 12).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 12).isActive = true

            let name = UILabel(); name.text = seg.title; name.font = .systemFont(ofSize: 15, weight: .semibold)
            let left = UIStackView(arrangedSubviews: [dot, name]); left.axis = .horizontal; left.alignment = .center; left.spacing = 8

            let right = UILabel(); right.textColor = .secondaryLabel; right.font = .systemFont(ofSize: 15)
            let e = totals.earned[seg] ?? 0, p = totals.planned[seg] ?? 0
            let ep = min(need, e + p)   // 必要単位を超えないようクリップ
            right.text = "\(e)(\(ep)) / \(need)"

            let line = UIStackView(arrangedSubviews: [left, UIView(), right]); line.alignment = .center
            return line
        }
        legendStack.addArrangedSubview(row(.aoyama,     need: req.aoyama))
        legendStack.addArrangedSubview(row(.language,   need: req.language))
        legendStack.addArrangedSubview(row(.department, need: req.department))
        legendStack.addArrangedSubview(row(.free,       need: req.free))

        tableView.reloadData()
        updateTableHeaderHeightIfNeeded()
    }

    private func makeCenterValue(earned: Int, totalWithPlanned: Int) -> NSAttributedString {
        let s = "\(earned)(\(totalWithPlanned))"
        let big = UIFont.systemFont(ofSize: 44, weight: .black)
        let small = UIFont.systemFont(ofSize: 32, weight: .black)
        let attr = NSMutableAttributedString(string: s, attributes: [.font: big, .foregroundColor: UIColor.label])
        if let open = s.firstIndex(of: "("), let close = s.firstIndex(of: ")") {
            let r = NSRange(open...close, in: s)
            attr.addAttributes([.font: small, .foregroundColor: UIColor.secondaryLabel], range: r)
        }
        return attr
    }

    // MARK: - ユーティリティ
    private func uniqueCourses(_ list: [Course]) -> [Course] {
        var seen = Set<String>(), out: [Course] = []
        for c in list {
            let key = "\(c.id)#\(c.title)"
            if seen.insert(key).inserted { out.append(c) }
        }
        return out
    }
    
    // "manual:<uuid>" で作った Course.id から手動IDを取り出す
    private func manualId(from c: Course) -> String? {
        if c.id.hasPrefix("manual:") {
            return String(c.id.dropFirst("manual:".count))
        }
        return nil
    }
    

    // MARK: - UI（ヘッダー = tableHeaderView）
    private func buildUI() {
        // Table
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        tableView.backgroundColor = .appBG
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16) // お好み

        // 長押しで編集
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPressOnRow(_:)))
        tableView.addGestureRecognizer(lp)

        // Header container
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 8, trailing: 16)

        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 6; stack.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: headerContainer.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: headerContainer.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: headerContainer.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: headerContainer.layoutMarginsGuide.bottomAnchor)
        ])

        // フィルタ（学部/学科）
        let filtersRow = UIStackView(); filtersRow.axis = .horizontal; filtersRow.spacing = 8; filtersRow.distribution = .fillEqually
        styleFilterButton(facultyButton, placeholder: "学部（指定なし）")
        styleFilterButton(departmentButton, placeholder: "学科（指定なし）", enabled: false)
        filtersRow.addArrangedSubview(facultyButton)
        filtersRow.addArrangedSubview(departmentButton)

        // キャプション
        captionLabel.text = "取得済み単位（取得予定）"
        captionLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        captionLabel.textAlignment = .center

        // ドーナツ
        let donutWrap = UIView(); donutWrap.translatesAutoresizingMaskIntoConstraints = false
        donut.translatesAutoresizingMaskIntoConstraints = false
        donutWrap.addSubview(donut)
        NSLayoutConstraint.activate([
            donut.centerXAnchor.constraint(equalTo: donutWrap.centerXAnchor),
            donut.centerYAnchor.constraint(equalTo: donutWrap.centerYAnchor),
            donut.widthAnchor.constraint(equalTo: donutWrap.widthAnchor, multiplier: 0.78),
            donut.heightAnchor.constraint(equalTo: donut.widthAnchor)
        ])
        centerValueLabel.textAlignment = .center
        centerValueLabel.adjustsFontSizeToFitWidth = true
        centerValueLabel.minimumScaleFactor = 0.6
        centerValueLabel.translatesAutoresizingMaskIntoConstraints = false
        donutWrap.addSubview(centerValueLabel)
        NSLayoutConstraint.activate([
            centerValueLabel.centerXAnchor.constraint(equalTo: donutWrap.centerXAnchor),
            centerValueLabel.centerYAnchor.constraint(equalTo: donutWrap.centerYAnchor),
            centerValueLabel.widthAnchor.constraint(lessThanOrEqualTo: donutWrap.widthAnchor, multiplier: 0.8)
        ])
        let ratio = donutWrap.heightAnchor.constraint(equalTo: donutWrap.widthAnchor, multiplier: 0.78)
        ratio.priority = .defaultHigh   // AutoLayout 警告回避
        ratio.isActive = true

        // 必要単位ラベル
        needLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        needLabel.textColor = .secondaryLabel
        needLabel.textAlignment = .center

        legendStack.axis = .vertical
        legendStack.spacing = 6

        // add
        stack.addArrangedSubview(filtersRow)
        stack.addArrangedSubview(captionLabel)
        stack.addArrangedSubview(donutWrap)
        stack.setCustomSpacing(4, after: donutWrap)
        stack.addArrangedSubview(needLabel)
        stack.addArrangedSubview(legendStack)
        
        
        

        // tableHeaderView
        let container = UIView(frame: .zero)
        container.addSubview(headerContainer)
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            headerContainer.topAnchor.constraint(equalTo: container.topAnchor),
            headerContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            headerContainer.widthAnchor.constraint(equalTo: container.widthAnchor)
        ])
        tableView.tableHeaderView = container
        
        // ★ ここから追加：テーブルのフッター（追加＋）を用意
        let footer = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 64))
        let addBtn = UIButton(type: .system)
        addBtn.configuration = {
            var c = UIButton.Configuration.filled()
            c.title = "追加＋"
            c.baseBackgroundColor = .systemGray5
            c.baseForegroundColor = .label
            c.cornerStyle = .large
            return c
        }()
        addBtn.addAction(UIAction { [weak self] _ in self?.showManualEditor() }, for: .touchUpInside)
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(addBtn)
        NSLayoutConstraint.activate([
            addBtn.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            addBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            addBtn.widthAnchor.constraint(equalTo: footer.widthAnchor, multiplier: 0.92),
            addBtn.heightAnchor.constraint(equalToConstant: 44)
        ])
        tableView.tableFooterView = footer
        // ★ ここまで追加

    }
    
    @objc private func handleLongPressOnRow(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }
        let point = gr.location(in: tableView)
        guard let indexPath = tableView.indexPathForRow(at: point) else { return }

        let course = rows(for: indexPath.section)[indexPath.row]
        guard let mid = manualId(from: course) else { return } // 手動追加だけ編集可

        // 編集用の初期値を用意
        var list = loadManualCredits()
        guard let idx = list.firstIndex(where: { $0.id == mid }) else { return }
        let m = list[idx]
        

        let terms = makeFullTermChoices()
        // Seg4 <-> index 変換（UIはセグメントで0..3）
        let segOrder: [Seg4] = [.aoyama, .language, .department, .free]
        let initial = ManualCreditEditorViewController.Input(
            title: m.title,
            credits: m.credits,
            categoryIndex: segOrder.firstIndex(of: m.category) ?? 0,
            isPlanned: (m.termText == currentTerm.displayTitle),
            termText: m.termText
        )

        // エディタ起動（完了で保存→再計算→反映）
        let vc = ManualCreditEditorViewController(termChoices: terms, currentTermText: currentTerm.displayTitle, initial: initial) { [weak self] input in
            guard let self else { return }
            list[idx].title     = input.title
            list[idx].credits   = input.credits
            list[idx].category  = segOrder[min(max(0, input.categoryIndex), 3)]
            list[idx].isPlanned = (input.termText == self.currentTerm.displayTitle)
            list[idx].termText   = input.termText
            self.saveManualCredits(list)
            
            // ← ここに override 更新を追加
            let mid = list[idx].id
            var ov = self.loadOverrides()
            ov["manual:\(mid)#\(list[idx].title)"] = "\(list[idx].category)"
            self.saveOverrides(ov)
            
            self.compute()
            self.apply()
        }
        present(vc, animated: true)
    }

    // ★ ここから追加：手動追加 UI
    // MARK: - 手動追加 画面遷移（アラート→専用画面）
    @objc private func showManualEditor() {
        // ここを一行でOK
        let terms = makeFullTermChoices()
        // 画面を組み立て
        let vc = ManualCreditEditorViewController(termChoices: terms, currentTermText: currentTerm.displayTitle, initial: nil) { [weak self] input in
            guard let self else { return }
            // Seg4 へ変換
            let segOrder: [Seg4] = [.aoyama, .language, .department, .free]
            let seg4 = segOrder[min(max(0, input.categoryIndex), 3)]

            // 保存
            var list = self.loadManualCredits()
            let newId = UUID().uuidString
            let isPlannedNow = (input.termText == self.currentTerm.displayTitle)
            list.append(ManualCredit(
                id: newId,
                title: input.title,
                credits: input.credits,
                category: seg4,
                isPlanned: isPlannedNow,
                termText: input.termText
            ))
            self.saveManualCredits(list)
            
            // ← ここを追加：手動追加分のカテゴリを固定（override）
            var ov = self.loadOverrides()
            ov["manual:\(newId)#\(input.title)"] = "\(seg4)"
            self.saveOverrides(ov)


            // 再集計→反映
            self.compute()
            self.apply()
        }

        // Push（モーダルでも可）
        if let nav = navigationController {
            nav.pushViewController(vc, animated: true)
        } else {
            present(UINavigationController(rootViewController: vc), animated: true)
        }
    }

    
    private func makeTermText(_ key: TermKey) -> String {
        // 手元の実装に合わせて整形。分からなければ最小限これでOK
        return String(describing: key)
        // 例: もし TermKey(year: Int, term: Int) なら
        // return "\(key.year)年 \(key.term)学期"
    }
    // ★ ここまで追加


    private func updateTableHeaderHeightIfNeeded() {
        guard let header = tableView.tableHeaderView else { return }
        header.setNeedsLayout()
        header.layoutIfNeeded()
        let width = tableView.bounds.width
        let height = header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        if header.frame.height != height {
            header.frame.size = CGSize(width: width, height: height)
            tableView.tableHeaderView = header
        }
    }

    private func styleFilterButton(_ button: UIButton, placeholder: String, enabled: Bool = true) {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = UIColor.cardBG
        config.baseForegroundColor = .label
        config.image = UIImage(systemName: "chevron.down")
        config.imagePadding = 6
        config.imagePlacement = .trailing
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        config.cornerStyle = .large
        config.title = placeholder
        button.configuration = config
        button.layer.cornerRadius = 10
        button.showsMenuAsPrimaryAction = true
        button.isEnabled = enabled
    }

    // MARK: - メニュー生成 & 反映
    private func configureFacultyMenus() {
        let noneTitle = "指定なし"

        // 学部
        var facultyActions: [UIAction] = [
            UIAction(title: noneTitle, state: selectedFaculty == nil ? .on : .off) { [weak self] _ in
                guard let self else { return }
                selectedFaculty = nil
                selectedDepartment = nil
                updateFilterButtons()
            }
        ]
        for name in FACULTY_MAP.keys.sorted() {
            facultyActions.append(UIAction(title: name, state: (selectedFaculty == name) ? .on : .off) { [weak self] _ in
                guard let self else { return }
                selectedFaculty = name
                selectedDepartment = nil
                updateFilterButtons()
            })
        }
        facultyButton.menu = UIMenu(children: facultyActions)

        // 学科
        var deptActions: [UIAction] = [
            UIAction(title: noneTitle, state: selectedDepartment == nil ? .on : .off) { [weak self] _ in
                guard let self else { return }
                selectedDepartment = nil
                updateFilterButtons()
            }
        ]
        if let f = selectedFaculty, let list = FACULTY_MAP[f] {
            for d in list {
                deptActions.append(UIAction(title: d, state: (selectedDepartment == d) ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    selectedDepartment = d
                    updateFilterButtons()
                })
            }
            departmentButton.isEnabled = true
        } else {
            departmentButton.isEnabled = false
        }
        departmentButton.menu = UIMenu(children: deptActions)
    }

    private func updateFilterButtons() {
        func setTitle(_ b: UIButton, _ t: String) { var c = b.configuration; c?.title = t; b.configuration = c }
        setTitle(facultyButton, selectedFaculty ?? "学部（指定なし）")
        setTitle(departmentButton, selectedDepartment ?? "学科（指定なし）")
        departmentButton.isEnabled = (selectedFaculty != nil)

        // 保存
        let ud = UserDefaults.standard
        if let f = selectedFaculty { ud.set(f, forKey: Prefs.faculty) } else { ud.removeObject(forKey: Prefs.faculty) }
        if let d = selectedDepartment { ud.set(d, forKey: Prefs.dept) } else { ud.removeObject(forKey: Prefs.dept) }

        compute()
        apply()
        configureFacultyMenus()
    }

    private func loadSelection() {
        let ud = UserDefaults.standard
        if let f = ud.string(forKey: Prefs.faculty), FACULTY_MAP.keys.contains(f) {
            selectedFaculty = f
            if let d = ud.string(forKey: Prefs.dept), (FACULTY_MAP[f]?.contains(d) ?? false) {
                selectedDepartment = d
            } else { selectedDepartment = nil }
        } else {
            selectedFaculty = nil
            selectedDepartment = nil
        }
    }

    // MARK: - Table
    func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .planned(let d): return plannedByDisplay[d]?.count ?? 0
        case .earned(let d):  return earnedByDisplay[d]?.count ?? 0
        }
    }
    // 右から左スワイプのアクション（iOS 11+）
    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {

        let course = rows(for: indexPath.section)[indexPath.row]
        guard let mid = manualId(from: course) else {
            return nil // 手動以外はスワイプ不可
        }

        let delete = UIContextualAction(style: .destructive, title: "削除") { [weak self] _, _, done in
            guard let self else { done(false); return }
            var list = self.loadManualCredits()
            if let idx = list.firstIndex(where: { $0.id == mid }) {
                list.remove(at: idx)
                self.saveManualCredits(list)
                self.compute()
                self.apply()
                done(true)
            } else {
                done(false)
            }
        }

        let config = UISwipeActionsConfiguration(actions: [delete])
        config.performsFirstActionWithFullSwipe = true
        return config
    }

    private func rows(for section: Int) -> [Course] {
        switch sections[section] {
        case .planned(let d): return plannedByDisplay[d] ?? []
        case .earned(let d):  return earnedByDisplay[d]  ?? []
        }
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let c = rows(for: indexPath.section)[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var cfg = cell.defaultContentConfiguration()
        cfg.text = c.title
        var creditsText = "\(((c.credits as Int?) ?? 0))単位"
        var subtitle = "\(c.teacher) ・ \(creditsText)"

        // 取得済みセクションなら学期を間に挟む
        if case .earned = sections[indexPath.section] {
            if let t = earnedTermText[courseKey(c)] {
                subtitle = "\(c.teacher) ・ \(t) ・ \(creditsText)"
            }
        }
        cfg.secondaryText = subtitle
        cell.contentConfiguration = cfg
        
        if #available(iOS 14.0, *) {
            var bg = UIBackgroundConfiguration.clear()   // ← listInsetGroupedCell() は使わない
            bg.backgroundColor = UIColor.cardBG          // ← 型を明示
            cell.backgroundConfiguration = bg
        } else {
            cell.backgroundColor = UIColor.cardBG
            cell.contentView.backgroundColor = UIColor.cardBG
        }

        return cell
    }
    
    //追加
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let course = rows(for: indexPath.section)[indexPath.row]
        let key = courseKey(course)

        let sheet = UIAlertController(title: course.title, message: "単位のカテゴリを変更", preferredStyle: .actionSheet)
        func addAction(_ seg: Seg4, _ title: String) {
            sheet.addAction(UIAlertAction(title: title, style: .default) { _ in
                var map = self.loadOverrides()
                map[key] = "\(seg)"          // rawValue 代わりに文字列化
                self.saveOverrides(map)
                self.compute()
                self.apply()
            })
        }
        addAction(.aoyama,     "青山スタンダード")
        addAction(.language,   "外国語科目")
        addAction(.department, "学科科目")
        addAction(.free,       "自由選択科目")
        sheet.addAction(UIAlertAction(title: "元に戻す（自動判定）", style: .destructive) { _ in
            var map = self.loadOverrides(); map.removeValue(forKey: key); self.saveOverrides(map)
            self.compute(); self.apply()
        })
        sheet.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        present(sheet, animated: true)
    }

}


