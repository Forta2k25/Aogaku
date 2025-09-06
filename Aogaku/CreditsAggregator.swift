//
//  Aogaku
//
//  Created by shu m on 2025/09/03.////
//  CreditsAggregator.swift
//  学期跨ぎに保存された授業から「取得済み / 取得予定」を分けて返す
//
//
//  CreditsAggregator.swift
//  Aogaku
//
//  取得済み(過年度) と 今学期の取得予定 を合算して返す
//

import Foundation
import UIKit

/// 表示用に集計した結果
struct CreditsAggregation {
    /// カテゴリ別「取得済み」単位
    var earnedByCategory: [ChartCategory: Int]
    /// カテゴリ別「今学期 取得予定」単位
    var plannedByCategory: [ChartCategory: Int]
    /// 合計（太字表示用）
    var earnedTotal: Int
    var plannedTotal: Int
}

/// ドーナツで使うカテゴリ（名前衝突を避けるため `ChartCategory`）
enum ChartCategory: CaseIterable, Hashable {
    case aoyamaStandard   // 青山スタンダード
    case department       // 学科科目
    case freeChoice       // 自由選択

    var title: String {
        switch self {
        case .aoyamaStandard: return "青山スタンダード"
        case .department:     return "学科科目"
        case .freeChoice:     return "自由選択科目"
        }
    }

    var color: UIColor {
        switch self {
        case .aoyamaStandard: return .systemBlue
        case .department:     return .systemRed
        case .freeChoice:     return .systemGreen
        }
    }
}

/// 学部要件（必要単位数）
struct Requirement {
    let aoyama: Int
    let department: Int
    let free: Int
    var total: Int { aoyama + department + free }

    /// 既定（サンプル：24 / 62 / 38 → 合計 124）
    static let standard = Requirement(aoyama: 24, department: 62, free: 38)

    func required(for cat: ChartCategory) -> Int {
        switch cat {
        case .aoyamaStandard: return aoyama
        case .department:     return department
        case .freeChoice:     return free
        }
    }
}


enum CreditsAggregator {
    /// 集計のメイン。`currentTerm` と timetable で表示中の今学期授業 `currentTermCourses`
    /// を受け取り、過年度=earned / 今学期=planned に分けて返す。
    static func aggregate(currentTerm: TermKey,
                          currentTermCourses: [Course],
                          requirement: Requirement = .standard) -> CreditsAggregation {

        // 1) 保存済みの全学期 → [(term, [Course])]
        let termToCourses: [(TermKey, [Course])] = loadAllTermsFromUserDefaults()

        // 2) カテゴリ別集計バケツ
        var earned:  [ChartCategory: Int] = [:]
        var planned: [ChartCategory: Int] = [:]

        // 3) 過年度 (= currentTerm より小さい) は earned へ
        for (term, courses) in termToCourses {
            guard term < currentTerm else { continue }
            let uniques = uniqueCourses(courses)
            for c in uniques {
                let cat = classify(c)
                earned[cat, default: 0] += (c.credits ?? 0)
            }
        }

        // 4) 今学期は引数（タイムテーブル上で重複除去済みの配列を想定）を planned へ
        for c in uniqueCourses(currentTermCourses) {
            let cat = classify(c)
            planned[cat, default: 0] += (c.credits ?? 0)
        }

        // 5) 合計
        let earnedTotal  = earned.values.reduce(0, +)
        let plannedTotal = planned.values.reduce(0, +)

        return CreditsAggregation(
            earnedByCategory: earned,
            plannedByCategory: planned,
            earnedTotal: earnedTotal,
            plannedTotal: plannedTotal
        )
    }
}

// MARK: - Helpers

/// 学期保存のキー接頭辞
private let kAssignedPrefix = "assignedCourses."

/// UserDefaults から「学期ごとのコース配列」を全部読み出す
private func loadAllTermsFromUserDefaults() -> [(TermKey, [Course])] {
    let ud = UserDefaults.standard

    // UserDefaults の全キーから該当キーだけ拾う
    let keys = ud.dictionaryRepresentation().keys
        .filter { $0.hasPrefix(kAssignedPrefix) }

    var out: [(TermKey, [Course])] = []

    for key in keys {
        guard let data = ud.data(forKey: key) else { continue }
        guard let courses = try? JSONDecoder().decode([Course].self, from: data) else { continue }

        // key = "assignedCourses.2025_前期" の想定
        let suffix = key.replacingOccurrences(of: kAssignedPrefix, with: "")
        let parts = suffix.split(separator: "_")
        guard parts.count == 2,
              let y = Int(parts[0]) else { continue }
        let sem: Semester = parts[1] == "前期" ? .spring : .fall

        out.append((TermKey(year: y, semester: sem), courses))
    }
    // 古い順→新しい順にしておくとあとで便利
    out.sort { $0.0 < $1.0 }
    return out
}

/// ケンカ回避用：id がなければ `title` を混ぜてユニーク化
private func uniqueKey(for c: Course) -> String {
    let id = c.id.isEmpty ? "?" : c.id
    return id + "#" + c.title
}
private func uniqueCourses(_ list: [Course]) -> [Course] {
    var seen = Set<String>(); var out: [Course] = []
    for c in list {
        let key = uniqueKey(for: c)
        if seen.insert(key).inserted { out.append(c) }
    }
    return out
}

/// コース → カテゴリ判定（学内の表記に合わせて必要なら拡張）
private func classify(_ c: Course) -> ChartCategory {
    let cat = (c.category ?? "").lowercased()
    if cat.contains("スタンダード") || cat.contains("standard") { return .aoyamaStandard }
    if cat.contains("学科") || cat.contains("英米") || cat.contains("department") { return .department }
    return .freeChoice
}
