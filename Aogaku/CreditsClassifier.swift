//
//  CreditsClassifier.swift
//  Aogaku
//
//  Created by shu m on 2025/09/01.
//

import UIKit

enum CreditCategory: String, CaseIterable, Codable {
    case aostandard = "青山スタンダード科目"
    case department = "学科科目"
    case free       = "自由選択科目"
}


// 文字正規化（空白・改行・記号・括弧などをまとめて除去）
private extension String {
    var normalizedForCategory: String {
        var s = self
        let remove = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet.punctuationCharacters)
            .union(CharacterSet(charactersIn: "　・･•/／-‐–—()（）[]【】『』「」、,.．，"))
        s = s.components(separatedBy: remove).joined()
        return s.lowercased()
    }
}

// 文字列 → カテゴリ
extension CreditCategory {
    static func from(_ raw: String?) -> CreditCategory? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let t = raw.normalizedForCategory

        // 自由選択（自由・自由選択・自由選択科目 など）
        if t.contains("自由選択") || t.contains("自由科目") || t.contains("自由") {
            return .free
        }

        // 学科（「学科科目」「〇〇学部」「専攻」などを広めに拾う）
        if t.contains("学科科目") || t.contains("専攻") || t.contains("学部") {
            return .department
        }

        // 青スタ（外国語科目を含む表記でもOK）
        if t.contains("青山スタンダード") || t.contains("青スタ") {
            return .aostandard
        }

        return nil
    }
}


// Course から単位数 / カテゴリを安全に取得（KVC 不使用）
// Course から使いやすく
extension Course {
    /// 単位数（nilなら0として扱う）
    var creditValue: Int { credits ?? 0 }

    /// カテゴリ（categoryが空ならtitleからの推測にフォールバック）
    var creditCategory: CreditCategory? {
        CreditCategory.from(category) ?? CreditCategory.from(title)
    }
}

func totalsByCategory(from courses: [Course]) -> [CreditCategory: Int] {
    var totals: [CreditCategory: Int] = [:]
    for c in courses {
        guard let cat = c.creditCategory else { continue }
        totals[cat, default: 0] += c.creditValue
    }
    return totals
}

class CreditsClassifier: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        // Do any additional setup after loading the view.
    }
    

    /*
    // MARK: - Navigation

    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        // Get the new view controller using segue.destination.
        // Pass the selected object to the new view controller.
    }
    */

}
