//
////
//  TermStore.swift
//  学期キー（年度＋前期/後期）と学期ごとの科目保存ヘルパ
//

import Foundation

// 学期（前期/後期）
enum Semester: String, Codable, CaseIterable {
    case spring = "前期"
    case fall   = "後期"

    var display: String { rawValue }

    // 並び順（前期=0, 後期=1）
    var order: Int { self == .spring ? 0 : 1 }
}

// 学期キー（年度＋学期）
struct TermKey: Codable, Hashable, Comparable {
    let year: Int
    let semester: Semester

    var displayTitle: String { "\(year)年\(semester.display)" }

    // UserDefaults キー（学期ごとの保存領域）
    var storageKey: String { "assignedCourses.\(year)_\(semester.rawValue)" }

    // 年 → 学期の順で昇順比較できるように
    static func < (lhs: TermKey, rhs: TermKey) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        return lhs.semester.order < rhs.semester.order
    }
}

// 学期の選択状態と、学期ごとの登録科目の保存/読込
enum TermStore {

    // 現在選択中の学期を保存するキー
    private static let selectedKey = "selectedTerm.v1"

    // 既定の学期（4〜9月: 前期 / 10〜12月: 後期 / 1〜3月: 前年の後期）
    static func defaultTerm(now: Date = Date()) -> TermKey {
        let cal = Calendar(identifier: .gregorian)
        let y = cal.component(.year, from: now)
        let m = cal.component(.month, from: now)
        if (4...9).contains(m) { return TermKey(year: y, semester: .spring) }
        if (10...12).contains(m) { return TermKey(year: y, semester: .fall) }
        return TermKey(year: y - 1, semester: .fall)
    }

    // 選択中の学期（無ければ既定値を保存して返す）
    static func loadSelected() -> TermKey {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: selectedKey),
           let t = try? JSONDecoder().decode(TermKey.self, from: data) {
            return t
        }
        let t = defaultTerm()
        saveSelected(t)
        return t
    }

    static func saveSelected(_ term: TermKey) {
        if let data = try? JSONEncoder().encode(term) {
            UserDefaults.standard.set(data, forKey: selectedKey)
        }
    }

    // MARK: - 学期ごとの登録授業（保存/読込/削除）

    /// 指定学期の登録授業を保存
    /// - Note: Course は Codable（構造体は既存の定義をそのまま利用）
    static func saveAssigned(_ courses: [Course], for term: TermKey) {
        if let data = try? JSONEncoder().encode(courses) {
            UserDefaults.standard.set(data, forKey: term.storageKey)
        }
    }

    /// 指定学期の登録授業を読込（無ければ空配列）
    static func loadAssigned(for term: TermKey) -> [Course] {
        let ud = UserDefaults.standard
        guard let data = ud.data(forKey: term.storageKey) else { return [] }

        // 1) 通常: [Course]
        if let a = try? JSONDecoder().decode([Course].self, from: data) {
            return a
        }
        // 2) 時間割側の保存形式: [Course?]
        if let b = try? JSONDecoder().decode([Course?].self, from: data) {
            return b.compactMap { $0 }
        }
        return []
    }


    /// 指定学期の登録授業を削除
    static func removeAssigned(for term: TermKey) {
        UserDefaults.standard.removeObject(forKey: term.storageKey)
    }

    // MARK: - 保存されている全学期キーの列挙

    /// UserDefaults に保存済みの全学期キー（古い順にソート）
    static func allSavedTerms() -> [TermKey] {
        let prefix = "assignedCourses."
        let keys = UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }

        var terms: [TermKey] = []
        for key in keys {
            // 例: assignedCourses.2025_前期
            let tail = String(key.dropFirst(prefix.count))
            let parts = tail.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2,
                  let y = Int(parts[0]),
                  let sem = Semester(rawValue: String(parts[1])) else { continue }
            terms.append(TermKey(year: y, semester: sem))
        }
        return terms.sorted()
    }
}
