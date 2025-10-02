import UIKit

enum SlotColorKey: String, Codable, CaseIterable {
    case teal, blue, green, orange, red, gray, purple   // ← 追加

    var uiColor: UIColor {
        switch self {
        case .teal:   return .systemTeal
        case .blue:   return .systemBlue
        case .green:  return .systemGreen
        case .orange: return .systemOrange
        case .red:    return .systemRed
        case .gray:   return .systemGray
        case .purple: return .systemPurple
        }
    }
}

/// (曜日,時限)ごとの色を UserDefaults に保存/読込する軽量ストア
struct SlotColorStore {
    private static let storeKey = "slotColors_v2"             // ← 文字列キー名
    static func storageKey(for loc: SlotLocation) -> String { // "day-period" 例: "3-2"
        "\(loc.day)-\(loc.period)"
    }

    /// 現在の色（未設定なら nil）
    static func color(for loc: SlotLocation) -> SlotColorKey? {
        guard let dict = UserDefaults.standard.dictionary(forKey: storeKey) as? [String:String],
              let raw  = dict[storageKey(for: loc)]
        else { return nil }
        return SlotColorKey(rawValue: raw)
    }

    /// 色を保存（即時永続化）
    static func set(_ color: SlotColorKey, for loc: SlotLocation) {
        var dict = (UserDefaults.standard.dictionary(forKey: storeKey) as? [String:String]) ?? [:]
        dict[storageKey(for: loc)] = color.rawValue
        UserDefaults.standard.set(dict, forKey: storeKey)
    }

    // （全量が必要なとき用の補助。使わなくてもOK）
    static func load() -> [String: SlotColorKey] {
        guard let raw = UserDefaults.standard.dictionary(forKey: storeKey) as? [String:String] else { return [:] }
        var out: [String: SlotColorKey] = [:]
        for (k, v) in raw { if let c = SlotColorKey(rawValue: v) { out[k] = c } }
        return out
    }
    static func save(_ dict: [String: SlotColorKey]) {
        UserDefaults.standard.set(dict.mapValues(\.rawValue), forKey: storeKey)
    }
}
