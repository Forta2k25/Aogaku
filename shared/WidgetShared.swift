//
//  WidgetShared.swift
//  Aogaku
//
//  Created by shu m on 2025/09/18.
//
import Foundation

public struct WidgetPeriod: Codable, Hashable {
    public let index: Int
    public let title: String
    public let room: String
    public let start: String
    public let end: String
    let teacher: String?    // ⬅︎ 追加（Optional 推奨）
}

public struct WidgetSnapshot: Codable {
    public let date: Date
    public let weekday: Int
    public let dayLabel: String
    public let periods: [WidgetPeriod]
}

public enum WidgetBridge {
    static let appGroupID = "group.jp.forta.Aogaku"   // ←あなたの App Group に合わせて
    static let key = "today_timetable_snapshot"

    public static func save(_ snap: WidgetSnapshot) {
        let ud = UserDefaults(suiteName: appGroupID)
        if let data = try? JSONEncoder().encode(snap) {
            ud?.set(data, forKey: key)
        }
    }

    public static func load() -> WidgetSnapshot? {
        let ud = UserDefaults(suiteName: appGroupID)
        guard let data = ud?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

