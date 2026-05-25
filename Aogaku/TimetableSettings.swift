import Foundation

struct TimetableSettings: Codable {
    var periods: Int            // 5 / 6 / 7
    var includeSaturday: Bool   // false = 平日のみ, true = 平日+土

    static let `default` = TimetableSettings(periods: 5, includeSaturday: false)
    private static let udKey = "tt.settings.v1"

    static func load() -> TimetableSettings {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: udKey),
           let s = try? JSONDecoder().decode(TimetableSettings.self, from: data) {
            return s
        }
        return .default
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.udKey)
        }
    }
}

extension Notification.Name {
    static let timetableSettingsChanged  = Notification.Name("timetableSettingsChanged")
    /// DEBUG: 指定学期の登録授業をローカル＋Firestore から全削除する
    static let timetableCoursesDidReset  = Notification.Name("timetableCoursesDidReset")
}
