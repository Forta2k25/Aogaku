
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
    case aoyama, language, department, free, teacher   // ← 追加: 教職課程（非表示）

    /// ドーナツ／凡例など“表示に使う”4区分だけ
    static var visibleCases: [Seg4] { [.aoyama, .language, .department, .free] }

    var title: String {
        switch self {
        case .aoyama:     return "青山スタンダード"
        case .language:   return "外国語科目"
        case .department: return "学科科目"
        case .free:       return "自由選択科目"
        case .teacher:    return "教職課程科目"   // ← 追加（画面では使わないが網羅のため定義）
        }
    }
    var color: UIColor {
        switch self {
        case .aoyama:     return UIColor.systemBlue
        case .language:   return UIColor.systemIndigo
        case .department: return UIColor.systemRed
        case .free:       return UIColor.systemGreen
        case .teacher:    return UIColor.systemGray3   // ← 任意（非表示なので参照されない）
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

private enum DisplayCategory: CaseIterable {
    case aoyama, department, language, free, teacher
    var title: String {
        switch self {
        case .aoyama:     return "青山スタンダード"
        case .department: return "学科科目"
        case .language:   return "外国語科目"
        case .free:       return "自由選択科目"
        case .teacher:    return "教職課程科目"   // ← 追加
        }
    }
}


// ======================== 卒業要件詳細セル ========================
private final class ReqProgressCell: UITableViewCell {
    private let titleLabel  = UILabel()
    private let countLabel  = UILabel()
    private let progressBar = UIProgressView(progressViewStyle: .bar)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        if #available(iOS 14.0, *) {
            var bg = UIBackgroundConfiguration.clear()
            bg.backgroundColor = .cardBG
            backgroundConfiguration = bg
        } else {
            backgroundColor = .cardBG
        }
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.numberOfLines = 1
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.8
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        countLabel.textAlignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        progressBar.layer.cornerRadius = 3
        progressBar.clipsToBounds = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(titleLabel)
        contentView.addSubview(countLabel)
        contentView.addSubview(progressBar)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -8),

            countLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),

            progressBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            progressBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            progressBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            progressBar.heightAnchor.constraint(equalToConstant: 5),
            progressBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    // アニメーション用
    private var targetProgress: Float = 0
    private var targetEarned: Int = 0
    private var targetRequired: Int = 0   // 0 = 必要数なし

    func configure(item: CreditSummaryItem) {
        titleLabel.text = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
        progressBar.layer.removeAllAnimations()
        if let e = item.earned, let r = item.required, r > 0 {
            let done = e >= r
            let color: UIColor = done ? .systemGreen : .systemIndigo
            targetEarned = e; targetRequired = r
            targetProgress = Float(min(e, r)) / Float(r)
            countLabel.text = "0 / \(r)"       // アニメーション前は 0
            countLabel.textColor = done ? .systemGreen : .secondaryLabel
            titleLabel.textColor = done ? .systemGreen : .label
            progressBar.progressTintColor = color
            progressBar.trackTintColor = color.withAlphaComponent(0.15)
            progressBar.setProgress(0, animated: false)
            progressBar.isHidden = false
        } else if let e = item.earned {
            targetEarned = e; targetRequired = 0; targetProgress = 0
            countLabel.text = "0"              // アニメーション前は 0
            countLabel.textColor = .secondaryLabel
            titleLabel.textColor = .label
            progressBar.isHidden = true
        } else {
            targetEarned = 0; targetRequired = 0; targetProgress = 0
            countLabel.text = nil
            titleLabel.textColor = .label
            progressBar.isHidden = true
        }
    }

    /// 初期表示アニメーション: バー + 数値を 0 から伸ばす
    func animateIn(delay: TimeInterval = 0) {
        guard targetEarned > 0 || targetProgress > 0 else { return }
        let tp = targetProgress; let te = targetEarned; let tr = targetRequired
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // バー
            if tp > 0 {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.65)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
                self.progressBar.setProgress(tp, animated: true)
                CATransaction.commit()
            }
            // 数値カウントアップ
            guard te > 0 else { return }
            let dur: TimeInterval = 0.65; let start = CACurrentMediaTime()
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0/60, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                let progress = min((CACurrentMediaTime() - start) / dur, 1.0)
                let eased = 1.0 - pow(1.0 - progress, 3)
                let cur = Int(round(Double(te) * eased))
                self.countLabel.text = tr > 0 ? "\(cur) / \(tr)" : "\(cur)"
                if progress >= 1.0 { t.invalidate() }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    /// スクロールで表示される際に使う: アニメーションなしで最終値を即表示
    func showFinalValue() {
        progressBar.layer.removeAllAnimations()
        if !progressBar.isHidden { progressBar.setProgress(targetProgress, animated: false) }
        if targetEarned > 0 {
            countLabel.text = targetRequired > 0 ? "\(targetEarned) / \(targetRequired)" : "\(targetEarned)"
        }
    }
}

// ======================== アニメーション付きヘッダービュー ========================
/// willDisplayHeaderView で onDisplay?() を呼ぶためのラッパー
private final class AnimatableHeaderView: UIView {
    var onDisplay: (() -> Void)?
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
    private let deptInfoLabel = UILabel()   // 学部・学科（ポータルから自動設定）
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
        case earnedTermGroup(String, [Course])               // (termText, courses)
        case mergedCategory(DisplayCategory, [Course], [Course])  // (category, planned, earned)
        case portalSummary([CreditSummaryItem])               // (旧) ポータル取得の詳細要件
        case portalYear(Int, [GradeRecord])                   // (year, records) 年度別成績一覧
        case requirementGroup(CreditSummaryItem, [CreditSummaryItem])  // 卒業要件詳細 (header, subItems)
        var title: String {
            switch self {
            case .planned(let d):
                return "取得予定（今学期） — \(d.title)"
            case .earned(let d):
                return "取得済み（過年度） — \(d.title)"
            case .earnedTermGroup(let t, let arr):
                let total = arr.reduce(0) { $0 + (($1.credits as Int?) ?? 0) }
                return "\(t)　\(total) 単位"
            case .mergedCategory(let d, _, _):
                return d.title
            case .portalSummary:
                return "卒業要件詳細（ポータル取得）"
            case .portalYear(let year, let records):
                let credits = records.reduce(0) { $0 + $1.credits }
                return "\(year)年度　\(credits) 単位"
            case .requirementGroup(let header, _):
                return header.label.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
    private var sections: [SectionKind] = []

    // 学期別ビュー用
    private var earnedByTerm: [(String, [Course])] = []   // (termText, courses) 新→旧順
    private var earnedViewMode = 0                        // 0=卒業要件詳細 / 1=年度別

    // ポータル成績データ（GradeStore から）
    private var portalGrades: GradesData? = nil
    /// 科目名 → 成績文字列リスト のルックアップ（同名授業が複数学期ある場合を配列で保持）
    private var gradeLookup: [String: [String]] = [:]
    /// 科目名 → カテゴリ文字列 のルックアップ（ポータル成績データから）
    private var categoryLookup: [String: String] = [:]

    // バナー
    private let graduationBannerView  = UIView()
    private let graduationBannerLabel = UILabel()
    // GPAカード（ポータルデータ存在時のみ表示）
    private let gpaBannerView  = UIView()
    private let gpaBannerLabel = UILabel()      // 合格数・取込日サブテキスト
    private let gpaValueLabel  = UILabel()      // 大きいGPA数値
    private var gpaHidden      = false          // 伏せ字フラグ
    private var gpaTargetDouble: Double? = nil  // アニメーション用ターゲット

    // アニメーション管理
    private var hasAppeared = false             // viewDidAppear が一度でも呼ばれたか
    /// requirementGroup ヘッダービューのキャッシュ（section index → view）
    /// headerView(forSection:) が UITableViewHeaderFooterView を返すため独自管理
    private var requirementHeaderCache: [Int: AnimatableHeaderView] = [:]

    // 凡例アニメーション用ターゲット
    private struct LegendAnimTarget {
        let countLabel: UILabel
        let progressBar: UIProgressView
        let earned: Int
        let ep: Int    // earned + planned (need 未満)
        let need: Int
    }
    private var legendAnimTargets: [LegendAnimTarget] = []

    // ドーナツ中央の数値アニメーション用ターゲット
    private var centerEarnedTarget = 0
    private var centerFullTarget = 0
    private let emptyStateView = UIView()       // 成績データなし時の空状態

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

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: self,
            action: #selector(showManualEditor)
        )

        buildUI()
        loadSelection()
        reloadPortalGrades()
        updateFilterButtons() // ← 復元→再計算→UI反映

        NotificationCenter.default.addObserver(self,
            selector: #selector(onGradesImport),
            name: .gradesImportDidComplete, object: nil)
    }

    // MARK: - 成績データ読み込み

    private func reloadPortalGrades() {
        portalGrades = GradeStore.load()
        var lookup: [String: [String]] = [:]
        var catLookup: [String: String] = [:]
        for record in portalGrades?.records ?? [] {
            // 全角ASCII→半角変換・ブラケット除去で時間割科目名との表記ゆれを吸収
            let key = normalizeForGradeLookup(record.name)
            // 同名授業が複数学期ある場合（通年など）も全件保持する
            lookup[key, default: []].append(record.grade.trimmingCharacters(in: .whitespaces))
            if !record.category.trimmingCharacters(in: .whitespaces).isEmpty {
                catLookup[key] = record.category.trimmingCharacters(in: .whitespaces)
            }
        }
        gradeLookup    = lookup
        categoryLookup = catLookup
        // ポータルの学部・学科情報から selectedFaculty/selectedDepartment を自動設定
        if let deptStr = portalGrades?.department, !deptStr.isEmpty {
            autoDetectFacultyDept(from: deptStr)
        }
        updateDeptInfoLabel()
        if let g = portalGrades {
            print("[CreditsVC] portalGrades loaded: \(g.records.count) records, GPA=\(g.gpa), summary=\(g.creditSummary.count) rows")
        } else {
            print("[CreditsVC] portalGrades = nil (GradeStore empty)")
        }
    }

    @objc private func onGradesImport() {
        reloadPortalGrades()
        compute()
        apply()
        updateEmptyState()
    }

    /// CreditSummaryItem の配列を非インデント行ごとにグループ化する。
    /// ・常に非表示: 総修得単位 / 卒業要件内
    /// ・earned == 0 のとき非表示: 卒業要件外 / 他学科（サブ項目）
    /// ・卒業要件単位 を先頭に移動
    private func groupRequirements(_ items: [CreditSummaryItem]) -> [(CreditSummaryItem, [CreditSummaryItem])] {
        // 常に非表示にするヘッダーキーワード
        let alwaysHidden = ["総修得単位", "卒業要件内"]
        // earned == 0 (or nil) のとき非表示にするヘッダーキーワード
        let zeroHidden   = ["卒業要件外"]

        var groups: [(CreditSummaryItem, [CreditSummaryItem])] = []
        var currentHeader: CreditSummaryItem? = nil
        var currentSubs: [CreditSummaryItem] = []

        func flushGroup() {
            guard let h = currentHeader else { return }
            let t = h.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let hide = alwaysHidden.contains(where: { t.contains($0) })
                    || (zeroHidden.contains(where: { t.contains($0) }) && (h.earned ?? 0) == 0)
            if !hide { groups.append((h, currentSubs)) }
        }

        for item in items {
            let trimmed = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let isIndented = item.label.hasPrefix("　") || item.label.hasPrefix(" ")
            if isIndented {
                // 他学科: earned == 0 のとき非表示
                if trimmed.contains("他学科") && (item.earned ?? 0) == 0 { continue }
                currentSubs.append(item)
            } else {
                flushGroup()
                currentHeader = item
                currentSubs = []
            }
        }
        flushGroup()

        // 卒業要件単位 を先頭に移動
        if let idx = groups.firstIndex(where: {
            $0.0.label.trimmingCharacters(in: .whitespacesAndNewlines).contains("卒業要件単位")
        }) {
            let g = groups.remove(at: idx)
            groups.insert(g, at: 0)
        }
        return groups
    }

    /// 要件ラベルから対応する表示カラーを返す。
    private func colorForRequirementLabel(_ label: String) -> UIColor {
        let l = label.trimmingCharacters(in: .whitespaces)
        if l.contains("卒業要件単位")                      { return .systemOrange }
        if l.contains("スタンダード") || l.contains("青山") { return Seg4.aoyama.color }
        if l.contains("学") && l.contains("科")            { return Seg4.department.color }
        if l.contains("外国語")                             { return Seg4.language.color }
        if l.contains("自由")                              { return Seg4.free.color }
        return .systemGray3
    }

    /// ポータル科目名と時間割科目名の表記ゆれを吸収する正規化。
    /// 全角ASCII→半角変換、末尾の "[英語講義]" 等ブラケットサフィックスを除去。
    private func normalizeForGradeLookup(_ s: String) -> String {
        var result = ""
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if v >= 0xFF21, v <= 0xFF3A {
                // 全角大文字 Ａ-Ｚ → 半角 A-Z
                result.append(Character(UnicodeScalar(v - 0xFF21 + 0x41)!))
            } else if v >= 0xFF41, v <= 0xFF5A {
                // 全角小文字 ａ-ｚ → 半角 a-z
                result.append(Character(UnicodeScalar(v - 0xFF41 + 0x61)!))
            } else if v >= 0xFF10, v <= 0xFF19 {
                // 全角数字 ０-９ → 半角 0-9
                result.append(Character(UnicodeScalar(v - 0xFF10 + 0x30)!))
            } else {
                result.append(Character(scalar))
            }
        }
        // " [英語講義]" "[英語講義]" のようなブラケットサフィックスを除去
        if let range = result.range(of: " [", options: .literal) {
            result = String(result[..<range.lowerBound])
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// 科目名（Course.title）から対応する成績を返す（完全一致 → 部分一致 → スペース除去一致）
    /// 複数の成績がある場合（通年など）は最初の1件のみ返す。詳細は年度別タブで確認できる。
    private func gradeForCourse(_ course: Course) -> String? {
        let title = normalizeForGradeLookup(course.title)
        if let gs = gradeLookup[title], let first = gs.first { return first }
        // 部分一致フォールバック
        if let gs = gradeLookup.first(where: { title.contains($0.key) || $0.key.contains(title) })?.value,
           let first = gs.first { return first }
        // スペース除去後に再試行（「英語 I」と「英語I」のような揺れに対応）
        let stripped = title.filter { !$0.isWhitespace }
        if let gs = gradeLookup.first(where: {
            let k = $0.key.filter { !$0.isWhitespace }
            return stripped == k || stripped.contains(k) || k.contains(stripped)
        })?.value, let first = gs.first { return first }
        return nil
    }

    // MARK: - ポータルデータから Seg4 別取得済み単位数を取得

    /// gvw_tani（creditSummary）の大分類行から Seg4 別の修得単位数を返す。
    ///
    /// ・先頭が全角/半角スペースのサブ行はスキップ（親行の合計に含まれているため二重計上防止）
    /// ・学部によって外国語が「学　科」に統合されている場合、ポータル側に外国語行が出ないため
    ///   `.language` は 0 になり、ドーナツの外国語スライスも自動的に非表示になる
    /// ・ポータルデータがない場合は nil を返し、呼び出し側が時間割データにフォールバックする
    private func earnedFromPortalSummary() -> [Seg4: Int]? {
        guard let summary = portalGrades?.creditSummary, !summary.isEmpty else { return nil }
        var result: [Seg4: Int] = [:]
        for item in summary {
            // インデント行（サブ項目）はスキップ
            guard !item.label.hasPrefix("　"), !item.label.hasPrefix(" ") else { continue }
            guard let e = item.earned, e > 0 else { continue }
            let label = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.contains("スタンダード") || label.contains("ｽﾀﾝﾀﾞｰ") {
                result[.aoyama, default: 0] += e
            } else if label.contains("外国語") || label.contains("ｶﾞｲｺｸｺﾞ") {
                // 外国語行が別にある学部はそのまま .language へ
                // 英米文学科など languageSink=.department の学部では
                // ポータル側に外国語行が出ず自然に 0 になる
                result[.language, default: 0] += e
            } else if label.contains("自由") {
                // 「自　由　選　択」など → .free
                // 他学科サブ行は親の自由選択合計に含まれているためスキップ済み
                result[.free, default: 0] += e
            } else if label.contains("学") && label.contains("科") {
                // 「学　科」→ .department（「他学科」はサブ行なので到達しない）
                result[.department, default: 0] += e
            }
            // 「卒業要件単位」「総修得単位」等は Seg4 に対応しないのでスキップ
        }
        return result.isEmpty ? nil : result
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 画面表示のたびに成績データを再読み込み（取り込み後に開いた場合も拾う）
        let prev = portalGrades?.importedAt
        reloadPortalGrades()
        if portalGrades?.importedAt != prev {
            compute()
            apply()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true

        // ① ドーナツ
        donut.animateIn(duration: 1.0)

        // ② ドーナツ中央の数値
        animateCenterValue()

        // ③ 凡例（右側4行）
        animateLegend()

        // ④ GPA カウントアップ
        if !gpaHidden { animateGPA() }

        // ⑤ 卒業要件詳細: 現在表示中のヘッダー・セルをアニメーション
        //    （willDisplay は viewDidAppear より先に呼ばれるため、ここで改めて起動）
        triggerVisibleRequirementAnimations()
    }

    /// 卒業要件詳細セクションの可視ヘッダー・セルにアニメーションを適用する
    /// headerView(forSection:) は UITableViewHeaderFooterView を返すため
    /// requirementHeaderCache に保持した独自ビューを直接使う
    /// DispatchQueue.main.async で1ランループ遅らせ、レイアウト確定後に発火する
    private func triggerVisibleRequirementAnimations() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for (section, header) in self.requirementHeaderCache {
                guard section < self.sections.count,
                      case .requirementGroup = self.sections[section] else { continue }
                header.onDisplay?()
            }
            for ip in self.tableView.indexPathsForVisibleRows ?? [] {
                guard ip.section < self.sections.count,
                      case .requirementGroup = self.sections[ip.section],
                      let cell = self.tableView.cellForRow(at: ip) as? ReqProgressCell else { continue }
                cell.animateIn(delay: Double(ip.row) * 0.04)
            }
        }
    }

    /// ドーナツ中央の数値を 0 からカウントアップ
    private func animateCenterValue() {
        guard centerEarnedTarget > 0 else { return }
        let te = centerEarnedTarget; let tf = centerFullTarget
        let dur: TimeInterval = 1.0; let start = CACurrentMediaTime()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0/60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let progress = min((CACurrentMediaTime() - start) / dur, 1.0)
            let eased = 1.0 - pow(1.0 - progress, 3)
            let curE = Int(round(Double(te) * eased))
            let curF = Int(round(Double(tf) * eased))
            self.centerValueLabel.attributedText = self.makeCenterValue(earned: curE, totalWithPlanned: curF)
            if progress >= 1.0 { t.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 凡例の数値とバーを 0 から順番にアニメーション（0.08s ずつずらす）
    private func animateLegend() {
        for (i, target) in legendAnimTargets.enumerated() {
            let delay = Double(i) * 0.08
            let e = target.earned; let ep = target.ep; let need = target.need
            let barTarget: Float = need > 0 ? Float(ep) / Float(need) : 0
            let bar = target.progressBar   // UIProgressView（クラス）
            let cl  = target.countLabel    // UILabel（クラス）
            // バー
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak bar] in
                guard let bar else { return }
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.8)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
                bar.setProgress(barTarget, animated: true)
                CATransaction.commit()
            }
            // 数値カウントアップ
            guard e > 0 || ep > 0 else { continue }
            let dur: TimeInterval = 0.8
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak cl] in
                guard let cl else { return }
                let start = CACurrentMediaTime()
                let timer = Timer.scheduledTimer(withTimeInterval: 1.0/60, repeats: true) { [weak cl] t in
                    guard let cl else { t.invalidate(); return }
                    let progress = min((CACurrentMediaTime() - start) / dur, 1.0)
                    let eased = 1.0 - pow(1.0 - progress, 3)
                    let curE  = Int(round(Double(e)  * eased))
                    let curEp = Int(round(Double(ep) * eased))
                    cl.text = need > 0 ? "\(curE)(\(curEp))/\(need)" : "–"
                    if progress >= 1.0 { t.invalidate() }
                }
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    /// GPA 数値を 0.00 からカウントアップさせる（ease-out cubic）
    private func animateGPA() {
        guard let target = gpaTargetDouble, target > 0 else { return }
        let animDuration: TimeInterval = 1.0
        let startTime = CACurrentMediaTime()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self, !self.gpaHidden else { t.invalidate(); return }
            let elapsed  = CACurrentMediaTime() - startTime
            let progress = min(elapsed / animDuration, 1.0)
            let eased    = 1.0 - pow(1.0 - progress, 3)
            self.gpaValueLabel.text = String(format: "%.2f", target * eased)
            if progress >= 1.0 {
                t.invalidate()
                self.gpaValueLabel.text = String(format: "%.2f", target)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
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

    /// Course のカテゴリ文字列を複数ソースから解決する。
    /// 優先順位: Course.category → 成績ルックアップ → シラバスURL の FN コード
    private func effectiveCategory(for c: Course) -> String {
        // 1. Course 本体に category がある場合はそのまま
        if let cat = c.category, !cat.trimmingCharacters(in: .whitespaces).isEmpty {
            return cat
        }
        // 2. 成績データ（tuutisho.aspx）の category 列から科目名で引く（完全一致 → 部分一致）
        let titleKey = normalizeForGradeLookup(c.title)
        if let cat = categoryLookup[titleKey], !cat.isEmpty {
            return cat
        }
        if let cat = categoryLookup.first(where: { titleKey.contains($0.key) || $0.key.contains(titleKey) })?.value,
           !cat.isEmpty {
            return cat
        }
        // 3. シラバス URL の FN コードから推測
        if let url = c.syllabusURL, let cat = categoryFromFNCode(url) {
            return cat
        }
        return ""
    }

    /// シラバス URL（shousai.ashx?YR=YYYY&FN=XXXXXXX-NNNN）の FN 接頭辞から
    /// カテゴリ文字列を返す。不明なコードは nil。
    private func categoryFromFNCode(_ urlString: String) -> String? {
        // FN パラメータを取り出す（URLComponents 優先 → 文字列検索フォールバック）
        var fn: String?
        if let comps = URLComponents(string: urlString) {
            fn = comps.queryItems?.first(where: { $0.name == "FN" })?.value
        }
        // フォールバック: "FN=..." を文字列検索で取り出す
        if fn == nil, let range = urlString.range(of: "FN=") {
            let after = String(urlString[range.upperBound...])
            fn = String(after.prefix(while: { $0 != "&" && $0 != "#" }))
        }
        guard let fn = fn, !fn.isEmpty else { return nil }

        // FN の形式: "1611020-0001" → prefix = "1611020"（先頭 1 桁はダミー、次の 6 桁が分類コード）
        let prefix = String(fn.prefix(while: { $0 != "-" }))
        // 6 桁コード部分：先頭 1 桁を除いた 6 桁、または先頭 6 桁
        let code6: String
        if prefix.count >= 7 {
            code6 = String(prefix.dropFirst())   // 先頭の "1" を除く
        } else {
            code6 = prefix                        // 6 桁以下ならそのまま
        }

        // 青山キャンパス共通教育（青山スタンダード科目）
        let aoyamaCodes: Set<String> = ["611020", "611021"]
        // 外国語科目
        let languageCodes: Set<String> = ["611100", "611101", "611102", "611110"]
        // 教職課程
        let teacherCodes: Set<String>  = ["611400", "611401"]

        if aoyamaCodes.contains(code6)  { return "青山スタンダード科目" }
        if languageCodes.contains(code6) { return "外国語科目" }
        if teacherCodes.contains(code6)  { return "教職課程科目" }
        // その他は学科科目として扱う（部門コードがあれば department 判定は後段で）
        return nil
    }

    // 語学判定（既定は「外国語」を含むもの）
    private func isLanguageCourse(_ c: Course) -> Bool {
        let cat = effectiveCategory(for: c)
        // category 文字列の照合（全角・半角カタカナどちらも対応）
        let catL = cat.lowercased()
        if catL.contains("外国語") || catL.contains("ｶﾞｲｺｸｺﾞ") { return true }
        // タイトル由来のフォールバック
        let s = c.title.lowercased()
        let keys = ["外国語", "english", "advanced english", "speaking", "abroad"]
        return keys.contains { s.contains($0) }
    }

    // 自学科の科目か（選択中の学科ごとの詳細ルールで判定）
    private func isOwnDepartmentCourse(_ c: Course) -> Bool {
        guard let depName = selectedDepartment, !depName.isEmpty else { return false }
        let cat = effectiveCategory(for: c)
        let hay = norm("\(c.title) \(cat)")

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
        let cat = effectiveCategory(for: c).lowercased()
        // 全角カタカナ "スタンダード" と半角カタカナ "ｽﾀﾝﾀﾞｰﾄﾞ" の両方に対応
        return cat.contains("スタンダード") || cat.contains("ｽﾀﾝﾀﾞｰ") || cat.contains("standard")
    }

    // 教職課程科目
    private func isTeacherTraining(_ c: Course) -> Bool {
        let cat = effectiveCategory(for: c)
        return cat.contains("教職")
    }

    private func classifySeg4(_ c: Course) -> Seg4 {
        if let seg = manualSegMap[c.id] { return seg }

        let ov = loadOverrides()
        if let raw = ov[courseKey(c)], let fixed = Seg4.allCases.first(where: { "\($0)" == raw }) {
            return fixed
        }

        // 教職課程は最優先で teacher に振る
        if isTeacherTraining(c) { return .teacher }

        if isAoyamaStandard(c) { return .aoyama }
        if isLanguageCourse(c) { return currentLanguageSink() }
        if isOwnDepartmentCourse(c) { return .department }

        // 成績データのカテゴリで最終判断（"学　科" 系はすでに isOwnDepartmentCourse でカバー
        // されない場合のための安全網）
        let finalCat = effectiveCategory(for: c)
        if finalCat.contains("学科") || finalCat.contains("ｶﾞｸｶ") { return .department }

        return .free
    }
    
    // すべての学期候補を作る（前期/後期の並び）
    private func makeFullTermChoices() -> [String] {
        // 現在の学期の年を中心に、最長6年（例：-3年〜+2年）をベースにする
        let centerYear = currentTerm.year
        var minY = centerYear - 3
        var maxY = centerYear + 2

        // 既に保存されている学期の年があれば、それも範囲に含める
        let saved = allSavedTermsIncludingOnline()
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


    private func classifyDisplay(_ c: Course) -> DisplayCategory {
        switch classifySeg4(c) {
        case .aoyama:     return .aoyama
        case .language:   return .language
        case .department: return .department
        case .free:       return .free
        case .teacher:    return .teacher   // ← そのまま表示カテゴリへ
        }
    }


    private var currentTermText: String { currentTerm.displayTitle }  // displayTitle は既存で使用中
    
    /// オンデマンド行（period==0）として保存された科目を学期単位で読む
    private func loadOnlineCourses(for term: TermKey) -> [Course] {
        let ud = UserDefaults.standard
        let dayPrefix = "tt.online.\(term.storageKey).d"
        let keys = ud.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(dayPrefix) }

        var out: [Course] = []
        for key in keys {
            guard let data = ud.data(forKey: key),
                  let arr = try? JSONDecoder().decode([Course].self, from: data) else { continue }
            out.append(contentsOf: arr)
        }
        return out
    }

    /// 通常時間割 + オンデマンド保存の両方を見て、保存済み学期を列挙
    private func allSavedTermsIncludingOnline() -> [TermKey] {
        var set = Set(TermStore.allSavedTerms())
        let prefix = "tt.online.assignedCourses."
        let keys = UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
        for key in keys {
            // 形式: tt.online.assignedCourses.<year>_<前期|後期>.d<day>
            let tail = String(key.dropFirst(prefix.count))
            let parts = tail.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
            guard let termRaw = parts.first else { continue }
            let termParts = termRaw.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: true)
            guard termParts.count == 2,
                  let y = Int(termParts[0]),
                  let sem = Semester(rawValue: String(termParts[1])) else { continue }
            set.insert(TermKey(year: y, semester: sem))
        }
        return set.sorted()
    }
    
    
    // MARK: - 集計
    private func compute() {
        // データ読み出し
        let now = TermStore.loadAssigned(for: currentTerm) + loadOnlineCourses(for: currentTerm)
        var plannedCourses = uniqueCourses(now)
        var all: [Course] = []
        let allTerms = allSavedTermsIncludingOnline()
        for term in allTerms where term < currentTerm {
            all.append(contentsOf: TermStore.loadAssigned(for: term))
            all.append(contentsOf: loadOnlineCourses(for: term))
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
        for term in allTerms where term < currentTerm {
            let arr = TermStore.loadAssigned(for: term) + loadOnlineCourses(for: term)
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
                    case .teacher:    return "教職課程科目"   // 分類上は存在、表示/集計では除外
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

        // ドーナツ用集計（教職課程は除外）
        func add(_ c: Course, to dict: inout [Seg4: Int]) {
            let k = classifySeg4(c)
            guard k != .teacher else { return }           // ← 追加
            let val = (c.credits as Int?) ?? 0
            dict[k, default: 0] += val
        }

        totals = Totals()

        // 表示対象（teacher を除外）に絞った配列を用意
        let displayEarned  = earnedCourses.filter  { classifySeg4($0) != .teacher }
        let displayPlanned = plannedCourses.filter { classifySeg4($0) != .teacher }

        // ドーナツ用の加算
        // ポータルの修得済単位表（gvw_tani）が取り込まれていればそちらを優先。
        // 学校システムが正しい区分で集計済みのため、ヒューリスティック分類より正確。
        // 今学期の取得予定（planned）はポータルにないため時間割データを継続使用。
        if let portalEarned = earnedFromPortalSummary() {
            totals.earned = portalEarned
            // 中央表示の合計はポータルの総修得単位数（教職・他学科含む全科目）
            totals.earnedTotal = portalGrades?.totalEarnedCredits
                ?? displayEarned.reduce(0) { $0 + (($1.credits as Int?) ?? 0) }
        } else {
            // ポータルデータなし → 時間割から計算（フォールバック）
            displayEarned.forEach { add($0, to: &totals.earned) }
            totals.earnedTotal = displayEarned.reduce(0) { $0 + (($1.credits as Int?) ?? 0) }
        }
        displayPlanned.forEach { add($0, to: &totals.planned) }

        // 合計（中央表示用）
        totals.plannedTotal = displayPlanned.reduce(0) { $0 + (( $1.credits as Int?) ?? 0) }

        // クリップ：teacher を含まない visibleCases を使用
        let req = requirement4()
        for seg in Seg4.visibleCases {                      // ← 変更: allCases → visibleCases
            let need: Int = {
                switch seg {
                case .aoyama:     return req.aoyama
                case .language:   return req.language
                case .department: return req.department
                case .free:       return req.free
                case .teacher:    return 0  // 通らないが網羅性のため
                }
            }()
            let e = totals.earned[seg] ?? 0
            let p = totals.planned[seg] ?? 0
            totals.earned[seg]  = min(e, need)
            totals.planned[seg] = min(p, max(0, need - (totals.earned[seg] ?? 0)))
        }


        // 一覧カテゴリ分割（teacher も含めて分割）
        let listPlanned = plannedCourses       // ← 変更
        let listEarned  = earnedCourses        // ← 変更
        plannedByDisplay = Dictionary(grouping: listPlanned, by: classifyDisplay)
        earnedByDisplay  = Dictionary(grouping: listEarned,  by: classifyDisplay)
        for k in DisplayCategory.allCases {
            plannedByDisplay[k] = (plannedByDisplay[k] ?? []).sorted { $0.title < $1.title }
            earnedByDisplay[k]  = (earnedByDisplay[k]  ?? []).sorted { $0.title < $1.title }
        }

        // 学期別集計（新→旧順）
        var tg: [String: [Course]] = [:]
        for c in earnedCourses {
            let t = earnedTermText[courseKey(c)] ?? "不明"
            tg[t, default: []].append(c)
        }
        earnedByTerm = tg
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value.sorted { $0.title < $1.title }) }

        // セクション
        sections.removeAll()
        if earnedViewMode == 0 {
            // 卒業要件詳細: ポータルの修得済単位表を要件グループごとに表示
            for (header, subs) in groupRequirements(portalGrades?.creditSummary ?? []) {
                sections.append(.requirementGroup(header, subs))
            }
        } else {
            // 年度別: 今学期の取得予定を先頭にまとめ、続けてポータル成績データを年度でグループ化
            let plannedAll = DisplayCategory.allCases
                .flatMap { plannedByDisplay[$0] ?? [] }
                .sorted { $0.title < $1.title }
            if !plannedAll.isEmpty {
                sections.append(.earnedTermGroup("今学期（取得予定）", plannedAll))
            }
            if let records = portalGrades?.records, !records.isEmpty {
                // ポータルデータあり → 年度別で各 GradeRecord を独立表示
                var byYear: [Int: [GradeRecord]] = [:]
                for record in records {
                    byYear[record.year, default: []].append(record)
                }
                for year in byYear.keys.sorted(by: >) {
                    let sorted = byYear[year]!.sorted { $0.name < $1.name }
                    sections.append(.portalYear(year, sorted))
                }
            } else {
                // ポータルデータなし → 時間割の学期別にフォールバック
                for (t, arr) in earnedByTerm where !arr.isEmpty {
                    sections.append(.earnedTermGroup(t, arr))
                }
            }
        }
    }

    // MARK: - 表示反映
    private func apply() {
        let earned = totals.earnedTotal
        let full   = totals.earnedTotal + totals.plannedTotal
        centerEarnedTarget = earned
        centerFullTarget   = full
        // 表示済み（タブ切り替えなど）は最終値を即表示。初回開封時は 0 にして viewDidAppear でアニメーション
        centerValueLabel.attributedText = hasAppeared
            ? makeCenterValue(earned: earned, totalWithPlanned: full)
            : makeCenterValue(earned: 0, totalWithPlanned: 0)

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

        // 凡例 4行（プログレスバー付き）
        legendStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        legendAnimTargets.removeAll()
        func legendRow(_ seg: Seg4, need: Int) -> UIView {
            let e = totals.earned[seg] ?? 0
            let p = totals.planned[seg] ?? 0
            let ep = min(need, e + p)

            let outer = UIStackView(); outer.axis = .vertical; outer.spacing = 4

            // 上段: ドット＋名前 | カウント
            let dot = UIView()
            dot.backgroundColor = seg.color; dot.layer.cornerRadius = 5
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 10),
                dot.heightAnchor.constraint(equalToConstant: 10)
            ])
            let nameLabel = UILabel()
            nameLabel.text = seg.title
            nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)

            let countLabel = UILabel()
            // 表示済みは最終値、初回は 0（viewDidAppear でアニメーション）
            countLabel.text = need > 0 ? (hasAppeared ? "\(e)(\(ep))/\(need)" : "0(0)/\(need)") : "–"
            countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            countLabel.textColor = .secondaryLabel

            let topLine = UIStackView(arrangedSubviews: [dot, nameLabel, UIView(), countLabel])
            topLine.axis = .horizontal; topLine.alignment = .center; topLine.spacing = 6

            // プログレスバー
            let progress = UIProgressView(progressViewStyle: .default)
            progress.progressTintColor = seg.color
            progress.trackTintColor = seg.color.withAlphaComponent(0.18)
            // 表示済みは最終値、初回は 0（viewDidAppear でアニメーション）
            progress.progress = hasAppeared && need > 0 ? Float(ep) / Float(need) : 0
            progress.layer.cornerRadius = 2.5; progress.clipsToBounds = true
            progress.translatesAutoresizingMaskIntoConstraints = false
            progress.heightAnchor.constraint(equalToConstant: 5).isActive = true

            outer.addArrangedSubview(topLine)
            outer.addArrangedSubview(progress)

            // アニメーション対象として登録
            legendAnimTargets.append(LegendAnimTarget(
                countLabel: countLabel, progressBar: progress,
                earned: e, ep: ep, need: need))
            return outer
        }
        legendStack.spacing = 10
        legendStack.addArrangedSubview(legendRow(.aoyama,     need: req.aoyama))
        if req.language > 0 {
            legendStack.addArrangedSubview(legendRow(.language, need: req.language))
        }
        legendStack.addArrangedSubview(legendRow(.department, need: req.department))
        legendStack.addArrangedSubview(legendRow(.free,       need: req.free))

        requirementHeaderCache.removeAll()
        tableView.reloadData()

        // GPAカード更新
        if let grades = portalGrades {
            let df = DateFormatter()
            df.dateStyle = .short
            df.timeStyle = .none
            df.locale = Locale(identifier: "ja_JP")
            let dateStr = df.string(from: grades.importedAt)
            if let v = Double(grades.gpa) {
                gpaTargetDouble = v
                if gpaHidden {
                    gpaValueLabel.text = "●●●"
                } else if hasAppeared {
                    // 表示済み（タブ切替など）: 最終値を即表示（再アニメーションしない）
                    gpaValueLabel.text = String(format: "%.2f", v)
                } else {
                    // 初回: 0.00 にしておき viewDidAppear でアニメーション
                    gpaValueLabel.text = "0.00"
                }
            } else {
                gpaTargetDouble = nil
                gpaValueLabel.text = grades.gpa.isEmpty ? "–" : grades.gpa
            }
            gpaBannerLabel.text = "取込: \(dateStr)"
            gpaBannerView.isHidden = false
        } else {
            gpaTargetDouble = nil
            gpaBannerView.isHidden = true
        }
        updateEmptyState()

        updateTableHeaderHeightIfNeeded()
    }

    private func makeCenterValue(earned: Int, totalWithPlanned: Int) -> NSAttributedString {
        let s = "\(earned)(\(totalWithPlanned))"
        let big = UIFont.systemFont(ofSize: 26, weight: .black)
        let small = UIFont.systemFont(ofSize: 18, weight: .black)
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
        tableView.register(ReqProgressCell.self, forCellReuseIdentifier: "reqCell")
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

        // 学部・学科（ポータルデータから自動設定・変更不可）
        let filtersRow = UIStackView(); filtersRow.axis = .horizontal; filtersRow.spacing = 8; filtersRow.distribution = .fill
        deptInfoLabel.font = .systemFont(ofSize: 13, weight: .medium)
        deptInfoLabel.textColor = .secondaryLabel
        deptInfoLabel.textAlignment = .center
        deptInfoLabel.numberOfLines = 1
        deptInfoLabel.text = "学部・学科はポータルから自動設定されます"
        filtersRow.addArrangedSubview(deptInfoLabel)

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
            donut.widthAnchor.constraint(equalTo: donutWrap.widthAnchor, multiplier: 0.92),
            donut.heightAnchor.constraint(equalTo: donut.widthAnchor)
        ])
        centerValueLabel.textAlignment = .center
        centerValueLabel.adjustsFontSizeToFitWidth = true
        centerValueLabel.minimumScaleFactor = 0.5
        centerValueLabel.translatesAutoresizingMaskIntoConstraints = false
        donutWrap.addSubview(centerValueLabel)
        NSLayoutConstraint.activate([
            centerValueLabel.centerXAnchor.constraint(equalTo: donutWrap.centerXAnchor),
            centerValueLabel.centerYAnchor.constraint(equalTo: donutWrap.centerYAnchor),
            centerValueLabel.widthAnchor.constraint(lessThanOrEqualTo: donutWrap.widthAnchor, multiplier: 0.42)
        ])
        let ratio = donutWrap.heightAnchor.constraint(equalTo: donutWrap.widthAnchor, multiplier: 0.92)
        ratio.priority = .defaultHigh   // AutoLayout 警告回避
        ratio.isActive = true

        // 必要単位ラベル
        needLabel.font = .systemFont(ofSize: 12)
        needLabel.textColor = .tertiaryLabel
        needLabel.textAlignment = .left

        legendStack.axis = .vertical
        legendStack.spacing = 6

        // 卒業要件詳細 / 年度別 セグメント
        let earnedSeg = UISegmentedControl(items: ["卒業要件詳細", "年度別"])
        earnedSeg.selectedSegmentIndex = earnedViewMode
        earnedSeg.setTitleTextAttributes([.foregroundColor: UIColor.label], for: .normal)
        earnedSeg.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        earnedSeg.addTarget(self, action: #selector(earnedViewModeChanged(_:)), for: .valueChanged)

        // 卒業バナー
        graduationBannerView.layer.cornerRadius = 10
        graduationBannerView.layer.masksToBounds = true
        graduationBannerView.isHidden = true
        graduationBannerView.layoutMargins = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        graduationBannerLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        graduationBannerLabel.textAlignment = .center
        graduationBannerLabel.numberOfLines = 0
        graduationBannerLabel.translatesAutoresizingMaskIntoConstraints = false
        graduationBannerView.addSubview(graduationBannerLabel)
        NSLayoutConstraint.activate([
            graduationBannerLabel.topAnchor.constraint(equalTo: graduationBannerView.layoutMarginsGuide.topAnchor),
            graduationBannerLabel.bottomAnchor.constraint(equalTo: graduationBannerView.layoutMarginsGuide.bottomAnchor),
            graduationBannerLabel.leadingAnchor.constraint(equalTo: graduationBannerView.layoutMarginsGuide.leadingAnchor),
            graduationBannerLabel.trailingAnchor.constraint(equalTo: graduationBannerView.layoutMarginsGuide.trailingAnchor),
        ])

        // ── GPAカード ──────────────────────────────────────────────
        // 左アクセントバー（indigo）＋ 大きいGPA数値 ＋ 縦区切り ＋ サブテキスト
        gpaBannerView.backgroundColor = .secondarySystemBackground
        gpaBannerView.layer.cornerRadius = 14
        gpaBannerView.layer.masksToBounds = true
        gpaBannerView.isHidden = true
        // タップで伏せ字トグル
        let gpaTap = UITapGestureRecognizer(target: self, action: #selector(toggleGPAVisibility))
        gpaBannerView.addGestureRecognizer(gpaTap)
        gpaBannerView.isUserInteractionEnabled = true

        let gpaStripe = UIView()
        gpaStripe.backgroundColor = .systemIndigo
        gpaStripe.translatesAutoresizingMaskIntoConstraints = false
        gpaBannerView.addSubview(gpaStripe)

        let gpaTagLabel = UILabel()
        gpaTagLabel.text = "GPA"
        gpaTagLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        gpaTagLabel.textColor = UIColor.systemIndigo.withAlphaComponent(0.75)
        gpaTagLabel.translatesAutoresizingMaskIntoConstraints = false

        gpaValueLabel.font = .systemFont(ofSize: 34, weight: .black)
        gpaValueLabel.textColor = .systemIndigo
        gpaValueLabel.text = "–"
        gpaValueLabel.translatesAutoresizingMaskIntoConstraints = false

        let gpaLeftCol = UIStackView(arrangedSubviews: [gpaTagLabel, gpaValueLabel])
        gpaLeftCol.axis = .vertical
        gpaLeftCol.spacing = 0
        gpaLeftCol.alignment = .leading
        gpaLeftCol.translatesAutoresizingMaskIntoConstraints = false
        gpaBannerView.addSubview(gpaLeftCol)

        let gpaDivider = UIView()
        gpaDivider.backgroundColor = .separator
        gpaDivider.translatesAutoresizingMaskIntoConstraints = false
        gpaBannerView.addSubview(gpaDivider)

        gpaBannerLabel.font = .systemFont(ofSize: 13)
        gpaBannerLabel.textColor = .secondaryLabel
        gpaBannerLabel.numberOfLines = 0
        gpaBannerLabel.translatesAutoresizingMaskIntoConstraints = false
        gpaBannerView.addSubview(gpaBannerLabel)

        NSLayoutConstraint.activate([
            gpaStripe.leadingAnchor.constraint(equalTo: gpaBannerView.leadingAnchor),
            gpaStripe.topAnchor.constraint(equalTo: gpaBannerView.topAnchor),
            gpaStripe.bottomAnchor.constraint(equalTo: gpaBannerView.bottomAnchor),
            gpaStripe.widthAnchor.constraint(equalToConstant: 4),

            gpaLeftCol.leadingAnchor.constraint(equalTo: gpaStripe.trailingAnchor, constant: 14),
            gpaLeftCol.topAnchor.constraint(equalTo: gpaBannerView.topAnchor, constant: 12),
            gpaLeftCol.bottomAnchor.constraint(equalTo: gpaBannerView.bottomAnchor, constant: -12),

            gpaDivider.leadingAnchor.constraint(equalTo: gpaLeftCol.trailingAnchor, constant: 14),
            gpaDivider.centerYAnchor.constraint(equalTo: gpaBannerView.centerYAnchor),
            gpaDivider.widthAnchor.constraint(equalToConstant: 1),
            gpaDivider.heightAnchor.constraint(equalTo: gpaBannerView.heightAnchor, multiplier: 0.55),

            gpaBannerLabel.leadingAnchor.constraint(equalTo: gpaDivider.trailingAnchor, constant: 14),
            gpaBannerLabel.trailingAnchor.constraint(equalTo: gpaBannerView.trailingAnchor, constant: -14),
            gpaBannerLabel.centerYAnchor.constraint(equalTo: gpaBannerView.centerYAnchor),
        ])

        // add
        stack.addArrangedSubview(filtersRow)
        stack.addArrangedSubview(gpaBannerView)
        stack.addArrangedSubview(captionLabel)

        // ── ドーナツ ＋ 凡例 を横並び ──────────────────────────────
        let chartRow = UIStackView()
        chartRow.axis = .horizontal
        chartRow.alignment = .center
        chartRow.spacing = 16
        chartRow.distribution = .fill

        let legendSide = UIStackView()
        legendSide.axis = .vertical
        legendSide.spacing = 10
        legendSide.alignment = .fill
        legendSide.addArrangedSubview(legendStack)
        legendSide.addArrangedSubview(needLabel)

        chartRow.addArrangedSubview(donutWrap)
        chartRow.addArrangedSubview(legendSide)
        // donutWrap 幅 ≈ legendSide の 75%（全体の約43%）
        donutWrap.widthAnchor.constraint(equalTo: legendSide.widthAnchor, multiplier: 0.75).isActive = true

        stack.addArrangedSubview(chartRow)
        stack.setCustomSpacing(12, after: chartRow)
        stack.addArrangedSubview(earnedSeg)
        
        
        

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
        
        // フッターは不要（追加はナビバーの + ボタンに移動）
        tableView.tableFooterView = UIView(frame: .zero)

        buildEmptyState()
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

    
    @objc private func earnedViewModeChanged(_ seg: UISegmentedControl) {
        earnedViewMode = seg.selectedSegmentIndex
        compute()
        apply()
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

    /// ポータルの「学部・学科」文字列（例: "文学部英米文学科"）から selectedFaculty / selectedDepartment を設定する。
    /// すでに設定済みの場合はスキップしない（ポータルデータを優先）。
    private func autoDetectFacultyDept(from deptStr: String) {
        // 学部を先頭一致で探す
        for faculty in FACULTY_MAP.keys.sorted(by: { $0.count > $1.count }) {  // 長い名前を優先
            guard deptStr.contains(faculty) else { continue }
            selectedFaculty = faculty
            // 学科を含むか確認
            if let depts = FACULTY_MAP[faculty] {
                for dept in depts.sorted(by: { $0.count > $1.count }) {
                    if deptStr.contains(dept) {
                        selectedDepartment = dept
                        return
                    }
                }
            }
            selectedDepartment = nil
            return
        }
    }

    private func updateDeptInfoLabel() {
        if let f = selectedFaculty {
            let d = selectedDepartment ?? ""
            deptInfoLabel.text = d.isEmpty ? f : "\(f)  \(d)"
            deptInfoLabel.textColor = .label
        } else {
            deptInfoLabel.text = "学部・学科はポータルから自動設定されます"
            deptInfoLabel.textColor = .secondaryLabel
        }
    }

    private func loadSelection() {
        // 学部・学科はポータルデータから自動検出するため、UserDefaults からは読み込まない
        // （既存の保存値は autoDetectFacultyDept で上書きされる）
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
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { nil }

    // MARK: - カスタムセクションヘッダー
    private func sectionAccentColor(for kind: SectionKind) -> UIColor {
        switch kind {
        case .mergedCategory(let d, _, _):
            switch d {
            case .aoyama:     return Seg4.aoyama.color
            case .language:   return Seg4.language.color
            case .department: return Seg4.department.color
            case .free:       return Seg4.free.color
            case .teacher:    return .systemOrange
            }
        case .planned(let d):
            switch d {
            case .aoyama:     return Seg4.aoyama.color
            case .language:   return Seg4.language.color
            case .department: return Seg4.department.color
            case .free:       return Seg4.free.color
            case .teacher:    return .systemOrange
            }
        case .earned(let d):
            switch d {
            case .aoyama:     return Seg4.aoyama.color
            case .language:   return Seg4.language.color
            case .department: return Seg4.department.color
            case .free:       return Seg4.free.color
            case .teacher:    return .systemOrange
            }
        case .earnedTermGroup:  return .systemGray3
        case .portalSummary:    return .systemTeal
        case .portalYear:       return .systemGray3
        case .requirementGroup(let h, _): return colorForRequirementLabel(h.label)
        }
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let kind = sections[section]

        // 卒業要件詳細モード: プログレスバー付き専用ヘッダー
        if case .requirementGroup(let header, _) = kind {
            let isGraduation = header.label.trimmingCharacters(in: .whitespacesAndNewlines).contains("卒業要件単位")

            // ── 卒業要件単位: 特別カード ──────────────────────────────
            if isGraduation {
                let wrapper = AnimatableHeaderView()
                wrapper.backgroundColor = .clear

                let card = UIView()
                card.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.09)
                card.layer.cornerRadius = 14
                card.layer.borderWidth = 1.5
                card.layer.borderColor = UIColor.systemOrange.withAlphaComponent(0.35).cgColor
                card.translatesAutoresizingMaskIntoConstraints = false
                wrapper.addSubview(card)

                let titleLabel = UILabel()
                titleLabel.text = "卒業要件単位"
                titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
                titleLabel.textColor = UIColor.systemOrange.withAlphaComponent(0.85)
                titleLabel.translatesAutoresizingMaskIntoConstraints = false

                let countLabel = UILabel()
                countLabel.font = .monospacedDigitSystemFont(ofSize: 26, weight: .black)
                countLabel.textColor = .systemOrange
                countLabel.textAlignment = .right
                countLabel.setContentHuggingPriority(.required, for: .horizontal)
                countLabel.translatesAutoresizingMaskIntoConstraints = false

                let targetEarned   = header.earned   ?? 0
                let targetRequired = header.required ?? 0
                // 今学期の取得予定（卒業要件の残り分を上限とする）
                let targetPlanned  = min(totals.plannedTotal, max(0, targetRequired - targetEarned))
                let targetFull     = targetEarned + targetPlanned

                // 初期値は 0 表示（アニメーション開始前）
                countLabel.text = targetPlanned > 0 ? "0(0) / \(targetRequired)" : "0 / \(targetRequired)"

                // 後ろのバー（取得予定まで含む薄い表示）
                let barBack = UIProgressView(progressViewStyle: .bar)
                barBack.layer.cornerRadius = 4
                barBack.clipsToBounds = true
                barBack.progressTintColor = UIColor.systemOrange.withAlphaComponent(0.4)
                barBack.trackTintColor    = UIColor.systemOrange.withAlphaComponent(0.15)
                barBack.translatesAutoresizingMaskIntoConstraints = false
                barBack.progress = 0

                // 前のバー（取得済みのみ・濃い）
                let bar = UIProgressView(progressViewStyle: .bar)
                bar.layer.cornerRadius = 4
                bar.clipsToBounds = true
                bar.progressTintColor = .systemOrange
                bar.trackTintColor    = .clear   // barBack を透かして見せる
                bar.translatesAutoresizingMaskIntoConstraints = false
                bar.progress = 0

                let targetBarProgress: Float = targetRequired > 0
                    ? Float(min(targetEarned, targetRequired)) / Float(targetRequired) : 0
                let targetBarProgressFull: Float = targetRequired > 0
                    ? Float(min(targetFull, targetRequired)) / Float(targetRequired) : 0

                let remainLabel = UILabel()
                remainLabel.font = .systemFont(ofSize: 12)
                remainLabel.textColor = .secondaryLabel
                remainLabel.translatesAutoresizingMaskIntoConstraints = false
                if targetRequired > 0 {
                    let left = max(0, targetRequired - targetEarned)
                    remainLabel.text = left > 0 ? "残り \(left) 単位" : "卒業要件達成"
                    remainLabel.textColor = targetEarned >= targetRequired ? .systemGreen : .secondaryLabel
                }

                card.addSubview(titleLabel)
                card.addSubview(countLabel)
                card.addSubview(barBack)
                card.addSubview(bar)
                card.addSubview(remainLabel)
                NSLayoutConstraint.activate([
                    card.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 4),
                    card.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -4),
                    card.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 16),
                    card.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -16),

                    titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
                    titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),

                    countLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                    countLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
                    countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),

                    // barBack と bar は同じ位置に重ねる
                    barBack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
                    barBack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
                    barBack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
                    barBack.heightAnchor.constraint(equalToConstant: 8),

                    bar.topAnchor.constraint(equalTo: barBack.topAnchor),
                    bar.leadingAnchor.constraint(equalTo: barBack.leadingAnchor),
                    bar.trailingAnchor.constraint(equalTo: barBack.trailingAnchor),
                    bar.heightAnchor.constraint(equalTo: barBack.heightAnchor),

                    remainLabel.topAnchor.constraint(equalTo: barBack.bottomAnchor, constant: 8),
                    remainLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
                    remainLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
                ])

                // アニメーション: 画面に現れたとき発火
                wrapper.onDisplay = { [weak bar, weak barBack, weak countLabel] in
                    guard let bar = bar, let barBack = barBack, let countLabel = countLabel else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak bar, weak barBack] in
                        guard let bar = bar, let barBack = barBack else { return }
                        CATransaction.begin()
                        CATransaction.setAnimationDuration(0.9)
                        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
                        barBack.setProgress(targetBarProgressFull, animated: true)
                        bar.setProgress(targetBarProgress, animated: true)
                        CATransaction.commit()
                    }
                    guard targetEarned > 0 || targetFull > 0 else { return }
                    let animDuration: TimeInterval = 0.9
                    let startTime = CACurrentMediaTime()
                    let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak countLabel] t in
                        guard let countLabel = countLabel else { t.invalidate(); return }
                        let elapsed  = CACurrentMediaTime() - startTime
                        let progress = min(elapsed / animDuration, 1.0)
                        let eased    = 1.0 - pow(1.0 - progress, 3)
                        let curE = Int(round(Double(targetEarned) * eased))
                        let curF = Int(round(Double(targetFull)   * eased))
                        countLabel.text = targetPlanned > 0
                            ? "\(curE)(\(curF)) / \(targetRequired)"
                            : "\(curE) / \(targetRequired)"
                        if progress >= 1.0 {
                            t.invalidate()
                            countLabel.text = targetPlanned > 0
                                ? "\(targetEarned)(\(targetFull)) / \(targetRequired)"
                                : "\(targetEarned) / \(targetRequired)"
                        }
                    }
                    RunLoop.main.add(timer, forMode: .common)
                }

                requirementHeaderCache[section] = wrapper
                return wrapper
            }

            // ── 通常要件ヘッダー ─────────────────────────────────────
            let wrapper = AnimatableHeaderView()
            wrapper.backgroundColor = .clear

            let color = colorForRequirementLabel(header.label)

            let dot = UIView()
            dot.backgroundColor = color
            dot.layer.cornerRadius = 4
            dot.translatesAutoresizingMaskIntoConstraints = false

            let titleLabel = UILabel()
            titleLabel.text = header.label.trimmingCharacters(in: .whitespacesAndNewlines)
            titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            titleLabel.translatesAutoresizingMaskIntoConstraints = false

            let countLabel = UILabel()
            countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            countLabel.setContentHuggingPriority(.required, for: .horizontal)
            countLabel.translatesAutoresizingMaskIntoConstraints = false

            if let e = header.earned, let r = header.required, r > 0 {
                let done = e >= r
                let c: UIColor = done ? .systemGreen : .secondaryLabel
                countLabel.text = "\(e) / \(r)"
                countLabel.textColor = c
                titleLabel.textColor = done ? .systemGreen : .secondaryLabel
            } else if let e = header.earned {
                countLabel.text = "\(e)"
                countLabel.textColor = .secondaryLabel
                titleLabel.textColor = .secondaryLabel
            } else {
                titleLabel.textColor = .secondaryLabel
            }

            let bar = UIProgressView(progressViewStyle: .bar)
            bar.layer.cornerRadius = 3
            bar.clipsToBounds = true
            bar.translatesAutoresizingMaskIntoConstraints = false
            var normalBarTarget: Float = 0
            if let e = header.earned, let r = header.required, r > 0 {
                let done = e >= r
                let c: UIColor = done ? .systemGreen : color
                bar.progressTintColor = c
                bar.trackTintColor = c.withAlphaComponent(0.18)
                normalBarTarget = Float(min(e, r)) / Float(r)
                bar.progress = 0   // アニメーション前は 0
            } else {
                bar.isHidden = true
            }

            wrapper.addSubview(dot)
            wrapper.addSubview(titleLabel)
            wrapper.addSubview(countLabel)
            wrapper.addSubview(bar)
            NSLayoutConstraint.activate([
                dot.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 24),
                dot.widthAnchor.constraint(equalToConstant: 8),
                dot.heightAnchor.constraint(equalToConstant: 8),
                dot.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 13),

                titleLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
                titleLabel.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 10),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -8),

                countLabel.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -24),
                countLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),

                bar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
                bar.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 24),
                bar.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -24),
                bar.heightAnchor.constraint(equalToConstant: 6),
                bar.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -8),
            ])

            // アニメーション: バーを 0 から伸ばす
            let capturedTarget = normalBarTarget
            wrapper.onDisplay = { [weak bar] in
                guard let bar = bar, capturedTarget > 0 else { return }
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.7)
                CATransaction.setAnimationTimingFunction(
                    CAMediaTimingFunction(name: .easeOut))
                bar.setProgress(capturedTarget, animated: true)
                CATransaction.commit()
            }
            requirementHeaderCache[section] = wrapper
            return wrapper
        }

        let color = sectionAccentColor(for: kind)

        let wrapper = UIView()
        wrapper.backgroundColor = .clear

        let dot = UIView()
        dot.backgroundColor = color
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = kind.title
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabel
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let countLabel = UILabel()
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .tertiaryLabel
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        switch kind {
        case .mergedCategory(_, let p, let e):
            let units = (p + e).reduce(0) { $0 + ($1.credits ?? 0) }
            countLabel.text = "\(p.count + e.count)科目 · \(units)単位"
        case .earnedTermGroup(_, let arr):
            let units = arr.reduce(0) { $0 + ($1.credits ?? 0) }
            countLabel.text = "\(arr.count)科目 · \(units)単位"
        case .portalYear(_, let records):
            let units = records.reduce(0) { $0 + $1.credits }
            countLabel.text = "\(records.count)科目 · \(units)単位"
        default:
            countLabel.text = nil
        }

        wrapper.addSubview(dot)
        wrapper.addSubview(titleLabel)
        wrapper.addSubview(countLabel)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 24),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
            titleLabel.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -8),

            countLabel.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -24),
            countLabel.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
        ])

        return wrapper
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if case .requirementGroup(let header, _) = sections[section] {
            if header.label.trimmingCharacters(in: .whitespacesAndNewlines).contains("卒業要件単位") {
                return 110
            }
            return 58
        }
        return 34
    }

    // ヘッダーが画面に表示されたらアニメーション開始
    // （初期表示はviewDidAppear→triggerVisibleRequirementAnimationsで管理。
    //   スクロールで新たに出てきたヘッダーのみここで処理）
    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard hasAppeared, case .requirementGroup = sections[section] else { return }
        (view as? AnimatableHeaderView)?.onDisplay?()
    }

    // スクロールでセルが表示されるとき: 再アニメーションせず最終値を即表示
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard hasAppeared,
              case .requirementGroup = sections[indexPath.section],
              let reqCell = cell as? ReqProgressCell else { return }
        reqCell.showFinalValue()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .planned(let d):                    return plannedByDisplay[d]?.count ?? 0
        case .earned(let d):                    return earnedByDisplay[d]?.count ?? 0
        case .earnedTermGroup(_, let arr):       return arr.count
        case .mergedCategory(_, let p, let e):  return p.count + e.count
        case .portalSummary(let items):          return items.count
        case .portalYear(_, let records):        return records.count
        case .requirementGroup(_, let subs):     return subs.count
        }
    }
    // 右から左スワイプのアクション（iOS 11+）
    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {

        // ポータル要件・年度別・卒業要件詳細セクションはスワイプ不可
        if case .portalSummary = sections[indexPath.section] { return nil }
        if case .portalYear = sections[indexPath.section] { return nil }
        if case .requirementGroup = sections[indexPath.section] { return nil }

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
        case .planned(let d):                    return plannedByDisplay[d] ?? []
        case .earned(let d):                    return earnedByDisplay[d]  ?? []
        case .earnedTermGroup(_, let arr):       return arr
        case .mergedCategory(_, let p, let e):  return p + e
        case .portalSummary:                    return []
        case .portalYear:                        return []
        case .requirementGroup:                  return []
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // ── ポータル詳細要件セクション専用セル ──────────────────────
        if case .portalSummary(let items) = sections[indexPath.section] {
            let item = items[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
            var cfg = cell.defaultContentConfiguration()

            // インデント（先頭スペース量でレベルを表現）
            let label = item.label
            let isIndented = label.hasPrefix("　") || label.hasPrefix(" ")
            cfg.text = isIndented ? label : label

            // 右側: 修得/必要
            var rightParts: [String] = []
            if let e = item.earned   { rightParts.append("修得\(e)") }
            if let r = item.required { rightParts.append("必要\(r)") }
            cfg.secondaryText = rightParts.isEmpty ? nil : rightParts.joined(separator: " / ")

            // 合格ライン表示（修得≧必要なら緑）
            if let e = item.earned, let r = item.required, e >= r {
                cfg.textProperties.color = .systemGreen
            }

            // 背景
            if #available(iOS 14.0, *) {
                var bg = UIBackgroundConfiguration.clear()
                bg.backgroundColor = UIColor.cardBG
                cell.backgroundConfiguration = bg
            } else {
                cell.backgroundColor = UIColor.cardBG
            }
            cell.contentConfiguration = cfg
            cell.selectionStyle = .none
            return cell
        }

        // ── 卒業要件詳細セル（ReqProgressCell） ────────────────────────
        if case .requirementGroup(_, let subs) = sections[indexPath.section] {
            let cell = tableView.dequeueReusableCell(withIdentifier: "reqCell", for: indexPath) as! ReqProgressCell
            cell.configure(item: subs[indexPath.row])
            return cell
        }

        // ── 年度別ポータル成績セル（GradeRecord を直接表示） ─────────────
        if case .portalYear(_, let records) = sections[indexPath.section] {
            let record = records[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
            var cfg = cell.defaultContentConfiguration()
            cfg.text = record.name
            let teacherPart = record.teacher.trimmingCharacters(in: .whitespaces).isEmpty
                ? "–" : record.teacher
            let catPart = record.category.trimmingCharacters(in: .whitespaces)
            cfg.secondaryText = catPart.isEmpty
                ? "\(teacherPart) ・ \(record.credits)単位"
                : "\(teacherPart) ・ \(record.credits)単位 ・ \(catPart)"

            let badgeLabel = UILabel()
            let g = record.grade.trimmingCharacters(in: .whitespaces)
            badgeLabel.text = " \(g.isEmpty ? "–" : g) "
            badgeLabel.font = .systemFont(ofSize: 11, weight: .bold)
            badgeLabel.textColor = .white
            badgeLabel.layer.cornerRadius = 5
            badgeLabel.layer.masksToBounds = true
            let passed = ["AA", "A", "B", "C", "++", "**"]
            if passed.contains(g) {
                badgeLabel.backgroundColor = .systemGreen
            } else if g.isEmpty {
                badgeLabel.backgroundColor = .systemGray
            } else {
                badgeLabel.backgroundColor = .systemRed
            }
            badgeLabel.sizeToFit()
            cell.accessoryView = badgeLabel
            cell.selectionStyle = .none

            if #available(iOS 14.0, *) {
                var bg = UIBackgroundConfiguration.clear()
                bg.backgroundColor = UIColor.cardBG
                cell.backgroundConfiguration = bg
            } else {
                cell.backgroundColor = UIColor.cardBG
            }
            cell.contentConfiguration = cfg
            return cell
        }

        // ── 通常の科目セル ────────────────────────────────────────
        let c = rows(for: indexPath.section)[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var cfg = cell.defaultContentConfiguration()
        cfg.text = c.title
        let creditsText = "\(((c.credits as Int?) ?? 0))単位"
        var subtitle = "\(c.teacher) ・ \(creditsText)"

        switch sections[indexPath.section] {
        case .earned:
            // 取得済みセクション: 学期を挿入
            if let t = earnedTermText[courseKey(c)] {
                subtitle = "\(c.teacher) ・ \(t) ・ \(creditsText)"
            }
        case .mergedCategory(_, let planned, _):
            // 統合セクション: 取得予定 or 取得済み + 学期 のラベルを先頭に
            if indexPath.row < planned.count {
                subtitle = "今学期（取得予定） ・ \(c.teacher) ・ \(creditsText)"
            } else {
                let termLabel = earnedTermText[courseKey(c)] ?? "取得済み"
                subtitle = "\(termLabel) ・ \(c.teacher) ・ \(creditsText)"
            }
        default:
            break
        }

        // 取得予定行かどうかを判定
        var isPlannedRow = false
        if case .mergedCategory(_, let planned, _) = sections[indexPath.section] {
            isPlannedRow = indexPath.row < planned.count
        } else if case .planned = sections[indexPath.section] {
            isPlannedRow = true
        }
        // 年度別の今学期セクション: 成績はまだ確定していないのでバッジ自体を非表示
        let isCurrentTermGroup: Bool
        if case .earnedTermGroup = sections[indexPath.section] { isCurrentTermGroup = true }
        else { isCurrentTermGroup = false }

        // ポータル成績バッジ（右端に成績文字を accessoryView として表示）
        // 今学期セクションは成績未確定のため accessoryView なし
        if isCurrentTermGroup {
            cell.accessoryView = nil
        } else if let grade = gradeForCourse(c), !isPlannedRow {
            let badgeLabel = UILabel()
            badgeLabel.text = " \(grade) "
            badgeLabel.font = .systemFont(ofSize: 11, weight: .bold)
            badgeLabel.textColor = .white
            badgeLabel.layer.cornerRadius = 5
            badgeLabel.layer.masksToBounds = true
            let passed = ["AA", "A", "B", "C", "++", "**"]
            let g = grade.trimmingCharacters(in: .whitespaces)
            if passed.contains(g) {
                badgeLabel.backgroundColor = .systemGreen
            } else {
                badgeLabel.backgroundColor = .systemRed
            }
            badgeLabel.sizeToFit()
            cell.accessoryView = badgeLabel
        } else if isPlannedRow {
            let badgeLabel = UILabel()
            badgeLabel.text = " 未定 "
            badgeLabel.font = .systemFont(ofSize: 11, weight: .bold)
            badgeLabel.textColor = .white
            badgeLabel.backgroundColor = .systemPurple
            badgeLabel.layer.cornerRadius = 5
            badgeLabel.layer.masksToBounds = true
            badgeLabel.sizeToFit()
            cell.accessoryView = badgeLabel
        } else {
            cell.accessoryView = nil
        }

        cfg.secondaryText = subtitle
        cell.contentConfiguration = cfg

        if #available(iOS 14.0, *) {
            var bg = UIBackgroundConfiguration.clear()
            bg.backgroundColor = UIColor.cardBG
            cell.backgroundConfiguration = bg
        } else {
            cell.backgroundColor = UIColor.cardBG
            cell.contentView.backgroundColor = UIColor.cardBG
        }

        // ── 左アクセントバー（カテゴリ色） ──────────────────────
        cell.contentView.viewWithTag(9901)?.removeFromSuperview()
        let accentBar = UIView()
        accentBar.tag = 9901
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        let accentColor: UIColor = {
            switch classifySeg4(c) {
            case .aoyama:     return Seg4.aoyama.color
            case .language:   return Seg4.language.color
            case .department: return Seg4.department.color
            case .free:       return Seg4.free.color
            case .teacher:    return .systemOrange
            }
        }()
        accentBar.backgroundColor = accentColor
        cell.contentView.addSubview(accentBar)
        NSLayoutConstraint.activate([
            accentBar.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
            accentBar.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
            accentBar.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: 3),
        ])

        return cell
    }
    
    //追加
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        // ポータル要件・年度別・卒業要件詳細セクションはタップ不可
        if case .portalSummary = sections[indexPath.section] { return }
        if case .portalYear = sections[indexPath.section] { return }
        if case .requirementGroup = sections[indexPath.section] { return }
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
        addAction(.teacher,    "教職課程科目")   // ← 追加（表示はするが集計はゼロ）
        sheet.addAction(UIAlertAction(title: "元に戻す（自動判定）", style: .destructive) { _ in
            var map = self.loadOverrides(); map.removeValue(forKey: key); self.saveOverrides(map)
            self.compute(); self.apply()
        })
        sheet.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        present(sheet, animated: true)
    }

    // MARK: - GPA 伏せ字トグル
    @objc private func toggleGPAVisibility() {
        gpaHidden.toggle()
        // gpaValueLabel だけ切り替える（合格数・取込日はそのまま）
        if gpaHidden {
            gpaValueLabel.text = "●●●"
        } else if let target = gpaTargetDouble {
            // 伏せ字解除 → 最終値を直接表示（カウントアップは初回表示のみ）
            gpaValueLabel.text = String(format: "%.2f", target)
        } else if let grades = portalGrades {
            gpaValueLabel.text = grades.gpa.isEmpty ? "–" : grades.gpa
        }
        // 軽くバウンスしてフィードバック
        UIView.animate(withDuration: 0.1, animations: {
            self.gpaValueLabel.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
        }, completion: { _ in
            UIView.animate(withDuration: 0.2,
                           delay: 0,
                           usingSpringWithDamping: 0.5,
                           initialSpringVelocity: 0.5) {
                self.gpaValueLabel.transform = .identity
            }
        })
    }

    // MARK: - 空状態（成績データなし）
    private func buildEmptyState() {
        emptyStateView.backgroundColor = .appBG
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyStateView)
        NSLayoutConstraint.activate([
            emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyStateView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let iconLabel = UILabel()
        iconLabel.text = "📊"
        iconLabel.font = .systemFont(ofSize: 64)
        iconLabel.textAlignment = .center

        let titleLabel = UILabel()
        titleLabel.text = "成績データがありません"
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textAlignment = .center

        let bodyLabel = UILabel()
        bodyLabel.text = "Safari でポータルにログインし\n共有ボタン → 青山ハック で\n成績を取り込んでください"
        bodyLabel.font = .systemFont(ofSize: 15)
        bodyLabel.textColor = .secondaryLabel
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0

        var portalConfig = UIButton.Configuration.filled()
        portalConfig.title = "ポータルを開く"
        portalConfig.image = UIImage(systemName: "safari")
        portalConfig.imagePlacement = .leading
        portalConfig.imagePadding = 6
        portalConfig.cornerStyle = .capsule
        portalConfig.baseBackgroundColor = .systemGreen
        portalConfig.baseForegroundColor = .white
        let portalBtn = UIButton(configuration: portalConfig)
        portalBtn.addTarget(self, action: #selector(openPortalForGrades), for: .touchUpInside)

        let emptyStack = UIStackView(arrangedSubviews: [iconLabel, titleLabel, bodyLabel, portalBtn])
        emptyStack.axis = .vertical
        emptyStack.spacing = 12
        emptyStack.alignment = .center
        emptyStack.setCustomSpacing(20, after: bodyLabel)
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.addSubview(emptyStack)

        NSLayoutConstraint.activate([
            emptyStack.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: emptyStateView.centerYAnchor, constant: -40),
            emptyStack.leadingAnchor.constraint(greaterThanOrEqualTo: emptyStateView.leadingAnchor, constant: 32),
            emptyStack.trailingAnchor.constraint(lessThanOrEqualTo: emptyStateView.trailingAnchor, constant: -32),
        ])

        updateEmptyState()
    }

    @objc private func openPortalForGrades() {
        guard let url = URL(string: "https://aguinfo.jm.aoyama.ac.jp/AGUInfo/message_list.aspx") else { return }
        UIApplication.shared.open(url)
    }

    private func updateEmptyState() {
        emptyStateView.isHidden = (portalGrades != nil)
    }
}


