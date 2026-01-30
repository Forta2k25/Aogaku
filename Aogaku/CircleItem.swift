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

    /// "サークル" / "部活" / "その他"（ブクマ画面のセグメント用）
    let kind: String

    // ✅ 絞り込み用
    let category: String?
    let targets: [String]
    let weekdays: [String]
    let canDouble: Bool?
    let hasSelection: Bool?
    let annualFeeYen: Int?

    // ✅ 人数（Firestore: members.size 文字列）
    let memberSizeText: String?

    /// ソート用に、members.size から数字を抽出した値（取れなければ nil）
    var memberCount: Int? {
        Self.parseMemberCount(from: memberSizeText)
    }

    init(id: String,
         name: String,
         campus: String,
         intensity: String = "ふつう",
         imageURL: String? = nil,
         popularity: Int = 0,
         kind: String = "その他",
         category: String? = nil,
         targets: [String] = [],
         weekdays: [String] = [],
         canDouble: Bool? = nil,
         hasSelection: Bool? = nil,
         annualFeeYen: Int? = nil,
         memberSizeText: String? = nil) {

        self.id = id
        self.name = name
        self.campus = campus
        self.intensity = intensity
        self.imageURL = imageURL
        self.popularity = popularity

        self.kind = kind

        self.category = category
        self.targets = targets
        self.weekdays = weekdays
        self.canDouble = canDouble
        self.hasSelection = hasSelection
        self.annualFeeYen = annualFeeYen

        self.memberSizeText = memberSizeText
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

        // ---- kind（サークル/部活/その他）----
        if let raw = rawCategory {
            if raw.contains("部活") { self.kind = "部活" }
            else if raw.contains("サークル") { self.kind = "サークル" }
            else { self.kind = "その他" }
        } else {
            self.kind = "その他"
        }

        // ---- nested: beforeJoin / activity / members ----
        let beforeJoin = data["beforeJoin"] as? [String: Any]
        let activity = data["activity"] as? [String: Any]
        let members = data["members"] as? [String: Any]

        // ✅ members.size（人数文字列）
        if let size = members?["size"] as? String, !size.isEmpty {
            self.memberSizeText = size
        } else if let size = data["size"] as? String, !size.isEmpty {
            // 念のため旧フィールド互換
            self.memberSizeText = size
        } else {
            self.memberSizeText = nil
        }

        // targets
        var t: [String] = []
        if let target = beforeJoin?["target"] as? String, !target.isEmpty {
            t.append(Self.normalizeTarget(target))
        }
        if let nonFreshman = beforeJoin?["nonFreshman"] as? String {
            if nonFreshman.contains("不可") {
                t.append("新入生のみ")
            }
        }
        self.targets = Array(Set(t))

        // 兼サー
        if let partTime = beforeJoin?["partTime"] as? String {
            self.canDouble = Self.parseYesNo(partTime)
        } else {
            self.canDouble = data["canDouble"] as? Bool
        }

        // 選考
        if let selection = beforeJoin?["selection"] as? String {
            self.hasSelection = Self.parseHasSelection(selection)
        } else {
            self.hasSelection = data["hasSelection"] as? Bool
        }

        // 曜日
        if let schedule = activity?["schedule"] as? String {
            self.weekdays = Self.extractWeekdays(from: schedule)
        } else {
            self.weekdays = (data["weekdays"] as? [String]) ?? []
        }

        // 年額費用
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
        var s = raw
        s = s.replacingOccurrences(of: "系サークル", with: "")
        s = s.replacingOccurrences(of: "サークル", with: "")
        s = s.replacingOccurrences(of: "部活", with: "")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? raw : s
    }

    private static func normalizeTarget(_ raw: String) -> String {
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
        if schedule.contains("不定期") { return ["不定期"] }

        let map: [(key: String, val: String)] = [
            ("月", "月"), ("火", "火"), ("水", "水"), ("木", "木"),
            ("金", "金"), ("土", "土"), ("日", "日")
        ]

        var found: [String] = []
        for (k, v) in map {
            if schedule.contains(k) { found.append(v) }
        }
        return Array(Set(found))
    }

    // ✅ members.size から人数を推定
    private static func parseMemberCount(from raw: String?) -> Int? {
        guard var s = raw, !s.isEmpty else { return nil }

        // 全角数字 → 半角数字
        s = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s

        // 数字を抽出
        let nums = s
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .filter { !$0.isEmpty }
            .compactMap { Int($0) }

        guard !nums.isEmpty else { return nil }

        // "20〜30" / "20-30" / "20～30" などは平均を使う
        if nums.count >= 2, (s.contains("〜") || s.contains("～") || s.contains("-") || s.contains("–") || s.contains("ー")) {
            let a = nums[0], b = nums[1]
            return (a + b) / 2
        }

        // それ以外は最初の数字を代表値に
        return nums[0]
    }

    static func mock(for campus: String) -> [CircleItem] {
        if campus == "相模原" {
            return [
                CircleItem(id: "m1", name: "理工サイエンス部", campus: campus, intensity: "ガチめ", popularity: 90,
                           kind: "部活",
                           category: "IT・ビジネス", targets: ["青学生のみ"], weekdays: ["水"], canDouble: false, hasSelection: true, annualFeeYen: 20000,
                           memberSizeText: "50人前後"),
                CircleItem(id: "m2", name: "Sagamihara Music", campus: campus, intensity: "ゆるめ", popularity: 80,
                           kind: "サークル",
                           category: "音楽", targets: ["インカレ"], weekdays: ["不定期"], canDouble: true, hasSelection: false, annualFeeYen: 5000,
                           memberSizeText: "20〜30人"),
            ]
        } else {
            return [
                CircleItem(id: "a1", name: "茶道部", campus: campus, intensity: "ふつう", popularity: 100,
                           kind: "部活",
                           category: "文化・芸術", targets: ["青学生のみ"], weekdays: ["木"], canDouble: true, hasSelection: false, annualFeeYen: 15000,
                           memberSizeText: "40人程度"),
                CircleItem(id: "a2", name: "ESS123daily", campus: campus, intensity: "ゆるめ", popularity: 95,
                           kind: "サークル",
                           category: "国際・語学", targets: ["インカレ"], weekdays: ["木"], canDouble: true, hasSelection: false, annualFeeYen: 10000,
                           memberSizeText: "100人前後"),
                CircleItem(id: "a3", name: "Sonickers", campus: campus, intensity: "ふつう", popularity: 90,
                           kind: "サークル",
                           category: "音楽", targets: ["新入生のみ"], weekdays: ["土"], canDouble: true, hasSelection: true, annualFeeYen: 30000,
                           memberSizeText: "30人前後"),
                CircleItem(id: "a4", name: "英字新聞編集委員会", campus: campus, intensity: "ガチめ", popularity: 85,
                           kind: "その他",
                           category: "学生団体", targets: ["青学生のみ"], weekdays: ["月","金"], canDouble: false, hasSelection: true, annualFeeYen: 0,
                           memberSizeText: "10人程度"),
            ]
        }
    }
}
