//
//  CircleItem.swift
//  AogakuHack
//
//  Firestore model + mock data
//

import Foundation
import FirebaseFirestore

struct CircleItem: Hashable {
    let id: String
    let name: String
    let campus: String
    let intensity: String
    let imageURL: String?
    let popularity: Int

    // ✅ 絞り込み用
    let category: String?
    let targets: [String]          // 例: ["青学生のみ", "インカレ"]
    let weekdays: [String]         // 例: ["月","木"] or ["不定期"]
    let canDouble: Bool?           // 兼サー可否
    let hasSelection: Bool?        // 選考あり/なし
    let annualFeeYen: Int?         // 年額目安（円）

    init(id: String,
         name: String,
         campus: String,
         intensity: String = "ふつう",
         imageURL: String? = nil,
         popularity: Int = 0,
         category: String? = nil,
         targets: [String] = [],
         weekdays: [String] = [],
         canDouble: Bool? = nil,
         hasSelection: Bool? = nil,
         annualFeeYen: Int? = nil) {

        self.id = id
        self.name = name
        self.campus = campus
        self.intensity = intensity
        self.imageURL = imageURL
        self.popularity = popularity

        self.category = category
        self.targets = targets
        self.weekdays = weekdays
        self.canDouble = canDouble
        self.hasSelection = hasSelection
        self.annualFeeYen = annualFeeYen
    }

    init?(document: QueryDocumentSnapshot) {
        let data = document.data()
        guard
            let name = data["name"] as? String,
            let campus = data["campus"] as? String
        else { return nil }

        self.id = document.documentID
        self.name = name
        self.campus = campus
        self.intensity = (data["intensity"] as? String) ?? "ふつう"
        self.imageURL = data["imageURL"] as? String
        self.popularity = (data["popularity"] as? Int) ?? 0

        // ---- category（Firestoreの表記ゆれを吸収）----
        let rawCategory = data["category"] as? String
        self.category = rawCategory.map { Self.normalizeCategory($0) }

        // ---- nested: beforeJoin / activity ----
        let beforeJoin = data["beforeJoin"] as? [String: Any]
        let activity = data["activity"] as? [String: Any]

        // targets（複数チップ用に配列化）
        var t: [String] = []

        // beforeJoin.target 例: "青学生のみ" / "インカレ"
        if let target = beforeJoin?["target"] as? String, !target.isEmpty {
            t.append(Self.normalizeTarget(target))
        }

        // nonFreshman が "不可" なら「新入生のみ」
        if let nonFreshman = beforeJoin?["nonFreshman"] as? String {
            if nonFreshman.contains("不可") {
                t.append("新入生のみ")
            }
        }

        // 重複削除
        self.targets = Array(Set(t))

        // 兼サー可否（beforeJoin.partTime: "可"/"不可" を Bool に）
        if let partTime = beforeJoin?["partTime"] as? String {
            self.canDouble = Self.parseYesNo(partTime)   // "可"->true, "不可"->false
        } else {
            self.canDouble = data["canDouble"] as? Bool  // fallback
        }

        // 選考（beforeJoin.selection: "あり"/"なし" を Bool に）
        if let selection = beforeJoin?["selection"] as? String {
            self.hasSelection = Self.parseHasSelection(selection) // "あり"->true, "なし"->false
        } else {
            self.hasSelection = data["hasSelection"] as? Bool     // fallback
        }

        // 曜日（activity.schedule から抽出）
        if let schedule = activity?["schedule"] as? String {
            self.weekdays = Self.extractWeekdays(from: schedule)  // ["木"] や ["不定期"]
        } else {
            self.weekdays = (data["weekdays"] as? [String]) ?? []
        }

        // 年額費用（あれば）
        if let top = data["annualFeeYen"] as? Int {
            self.annualFeeYen = top
        } else if
            let fee = data["fee"] as? [String: Any],
            let annual = fee["annualYen"] as? Int {
            self.annualFeeYen = annual
        } else {
            self.annualFeeYen = nil
        }
    }

    // MARK: - Normalize helpers

    private static func normalizeCategory(_ raw: String) -> String {
        // 例: "国際・語学系サークル" -> "国際・語学"
        var s = raw
        s = s.replacingOccurrences(of: "系サークル", with: "")
        s = s.replacingOccurrences(of: "サークル", with: "")
        s = s.replacingOccurrences(of: "部活", with: "")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? raw : s
    }

    private static func normalizeTarget(_ raw: String) -> String {
        // UIのチップと合わせる
        if raw.contains("インカレ") { return "インカレ" }
        if raw.contains("青学生") { return "青学生のみ" }
        if raw.contains("新入生") { return "新入生のみ" }
        return raw
    }

    private static func parseYesNo(_ raw: String) -> Bool? {
        if raw.contains("可") { return true }
        if raw.contains("不可") { return false }
        return nil
    }

    private static func parseHasSelection(_ raw: String) -> Bool? {
        if raw.contains("あり") { return true }
        if raw.contains("なし") { return false }
        return nil
    }

    private static func extractWeekdays(from schedule: String) -> [String] {
        // "不定期" が入ってたらそれ優先
        if schedule.contains("不定期") { return ["不定期"] }

        // 日本語曜日を全部拾う（"毎週木曜日" など）
        let map: [(key: String, val: String)] = [
            ("月", "月"), ("火", "火"), ("水", "水"), ("木", "木"),
            ("金", "金"), ("土", "土"), ("日", "日")
        ]

        var found: [String] = []
        for (k, v) in map {
            if schedule.contains(k) { found.append(v) }
        }
        // 重複除去して返す
        return Array(Set(found))
    }


    static func mock(for campus: String) -> [CircleItem] {
        if campus == "相模原" {
            return [
                CircleItem(id: "m1", name: "理工サイエンス部", campus: campus, intensity: "ガチめ", popularity: 90,
                           category: "IT・ビジネス", targets: ["青学生のみ"], weekdays: ["水"], canDouble: false, hasSelection: true, annualFeeYen: 20000),
                CircleItem(id: "m2", name: "Sagamihara Music", campus: campus, intensity: "ゆるめ", popularity: 80,
                           category: "音楽", targets: ["インカレ"], weekdays: ["不定期"], canDouble: true, hasSelection: false, annualFeeYen: 5000),
            ]
        } else {
            return [
                CircleItem(id: "a1", name: "茶道部", campus: campus, intensity: "ふつう", popularity: 100,
                           category: "文化・芸術", targets: ["青学生のみ"], weekdays: ["木"], canDouble: true, hasSelection: false, annualFeeYen: 15000),
                CircleItem(id: "a2", name: "ESS123daily", campus: campus, intensity: "ゆるめ", popularity: 95,
                           category: "国際・語学", targets: ["インカレ"], weekdays: ["木"], canDouble: true, hasSelection: false, annualFeeYen: 10000),
                CircleItem(id: "a3", name: "Sonickers", campus: campus, intensity: "ふつう", popularity: 90,
                           category: "音楽", targets: ["新入生のみ"], weekdays: ["土"], canDouble: true, hasSelection: true, annualFeeYen: 30000),
                CircleItem(id: "a4", name: "英字新聞編集委員会", campus: campus, intensity: "ガチめ", popularity: 85,
                           category: "学生団体", targets: ["青学生のみ"], weekdays: ["月","金"], canDouble: false, hasSelection: true, annualFeeYen: 0),
            ]
        }
    }
}
