import Foundation
import UserNotifications

// MARK: - Models

enum MoodleEventType: String, Codable {
    case deadline   // 「...」の提出期限
    case start      // 「...」開始
    case end        // 「...」終了
    case other
}

struct MoodleEvent: Codable {
    let uid: String
    let summary: String        // 元のSUMMARY全文
    let cleanTitle: String     // 「」内を抽出したタイトル
    let dueDate: Date?         // DTSTART（UTC→ローカル変換済み）
    let eventDescription: String
    let eventURL: String?      // iCal の URL フィールド（イベントページへの直リンク）
    let courseCode: String     // CATEGORIES
    let eventType: MoodleEventType

    /// 期限切れかどうか
    var isPast: Bool {
        guard let d = dueDate else { return false }
        return d < Date()
    }
}

// MARK: - Service

final class MoodleService {
    static let shared = MoodleService()
    private init() {}

    private enum UDKey {
        static let icalURL           = "moodle.icalURL"
        static let cache             = "moodle.cachedEvents"
        static let submittedUIDs     = "moodle.submittedUIDs"
        static let globalNotifHours  = "moodle.globalNotifHours"   // [Int]
        static let globalNotifIds    = "moodle.globalNotifIds"     // [String:[String]]
    }

    // MARK: - URL 管理

    var icalURL: String? {
        get { UserDefaults.standard.string(forKey: UDKey.icalURL) }
        set { UserDefaults.standard.set(newValue, forKey: UDKey.icalURL) }
    }

    // MARK: - キャッシュ

    func cachedEvents() -> [MoodleEvent] {
        guard let data = UserDefaults.standard.data(forKey: UDKey.cache),
              let events = try? JSONDecoder().decode([MoodleEvent].self, from: data)
        else { return [] }
        return events
    }

    // MARK: - Fetch

    func fetchEvents(completion: @escaping (Result<[MoodleEvent], Error>) -> Void) {
        guard let rawURL = icalURL else {
            completion(.failure(MoodleError.noURL)); return
        }
        let normalizedString = normalizedURL(from: rawURL)
        guard let url = URL(string: normalizedString) else {
            completion(.failure(MoodleError.noURL)); return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            if let error = error { completion(.failure(error)); return }
            guard let data, let text = String(data: data, encoding: .utf8) else {
                completion(.failure(MoodleError.invalidData)); return
            }
            let events = self?.parseICS(text) ?? []
            if let encoded = try? JSONEncoder().encode(events) {
                UserDefaults.standard.set(encoded, forKey: UDKey.cache)
            }
            completion(.success(events))
        }.resume()
    }

    // MARK: - 提出済み管理

    var submittedUIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: UDKey.submittedUIDs) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: UDKey.submittedUIDs) }
    }

    @discardableResult
    func toggleSubmitted(uid: String) -> Bool {
        var uids = submittedUIDs
        let nowSubmitted = !uids.contains(uid)
        if nowSubmitted { uids.insert(uid) } else { uids.remove(uid) }
        submittedUIDs = uids
        return nowSubmitted
    }

    func isSubmitted(uid: String) -> Bool { submittedUIDs.contains(uid) }

    // MARK: - 手動マッピング（記号IDなど自動変換できない場合）
    // キー: CATEGORIESコード、値: 授業名

    private let manualMappingKey = "moodle.manualCourseMapping"

    var manualCourseMapping: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: manualMappingKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: manualMappingKey) }
    }

    func setManualCourse(categoryCode: String, title: String) {
        var m = manualCourseMapping
        m[categoryCode] = title
        manualCourseMapping = m
    }

    // MARK: - 全体通知設定

    var globalNotifHours: [Int] {
        get { UserDefaults.standard.array(forKey: UDKey.globalNotifHours) as? [Int] ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: UDKey.globalNotifHours) }
    }

    private var globalNotifIds: [String: [String]] {
        get { (UserDefaults.standard.dictionary(forKey: UDKey.globalNotifIds)
               as? [String: [String]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: UDKey.globalNotifIds) }
    }

    func cancelAllGlobalNotifications() {
        let ids = globalNotifIds.values.flatMap { $0 }
        guard !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        globalNotifIds = [:]
    }

    func scheduleGlobalNotifications(
            for events: [MoodleEvent],
            courseResolver: @escaping (MoodleEvent) -> String?) {
        cancelAllGlobalNotifications()
        let hrs = globalNotifHours
        guard !hrs.isEmpty else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] s in
            guard let self,
                  [.authorized,.provisional,.ephemeral].contains(s.authorizationStatus) else { return }
            let now = Date(); let df = DateFormatter()
            df.locale = Locale(identifier: "ja_JP"); df.dateFormat = "M/d(E) HH:mm"
            let ctr = UNUserNotificationCenter.current()
            var ids: [String: [String]] = [:]
            for ev in events {
                self.scheduleForEvent(ev, hrs: hrs, now: now, df: df, ctr: ctr,
                    course: courseResolver(ev) ?? "", ids: &ids)
            }
            self.globalNotifIds = ids
        }
    }

    func hourLabel(_ h: Int) -> String {
        switch h {
        case 1:   return "1時間前"
        case 3:   return "3時間前"
        case 6:   return "6時間前"
        case 12:  return "12時間前"
        case 24:  return "1日前"
        case 72:  return "3日前"
        case 168: return "1週間前"
        default:  return "\(h)時間前"
        }
    }

    private func scheduleForEvent(
            _ ev: MoodleEvent, hrs: [Int], now: Date,
            df: DateFormatter, ctr: UNUserNotificationCenter,
            course: String, ids: inout [String: [String]]) {
        guard let due = ev.dueDate, due > now, !isSubmitted(uid: ev.uid) else { return }
        var eids: [String] = []
        for h in hrs {
            guard let fire = Calendar.current.date(byAdding: .hour, value: -h, to: due),
                  fire > now else { continue }
            let comps = Calendar.current.dateComponents(
                [.year,.month,.day,.hour,.minute], from: fire)
            let id = "gn.\(ev.uid.prefix(32)).\(h)"
            let cnt = UNMutableNotificationContent()
            cnt.title = course.isEmpty ? "課題の締め切りが近づいています"
                : "【\(course)】締め切りが近づいています"
            cnt.body = "\(ev.cleanTitle) 期限:\(df.string(from:due)) (\(hourLabel(h)))"
            cnt.sound = .default
            if #available(iOS 15.0, *) { cnt.interruptionLevel = .timeSensitive }
            ctr.add(UNNotificationRequest(identifier: id, content: cnt,
                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
            eids.append(id)
        }
        if !eids.isEmpty { ids[ev.uid] = eids }
    }

    // MARK: - CATEGORIES → 登録番号変換
    // 形式: "XXXX_YYYYY" → 登録番号 = "XXXX" + YYYYYの3桁目(index 2)
    // 例: "1342_26101" → "1342" + "1" = "13421"

    func registrationNumber(from categories: String) -> String? {
        let parts = categories.split(separator: "_")
        guard parts.count == 2,
              parts[0].count == 4,
              parts[1].count == 5 else { return nil }
        let prefix = String(parts[0])
        let suffix = String(parts[1])
        let midIndex = suffix.index(suffix.startIndex, offsetBy: 2)
        return prefix + String(suffix[midIndex])
    }

    // MARK: - URL 正規化
    // ユーザーが貼ったURLのpreset_timeをカスタム範囲（過去30日〜5年後）に書き換える

    private func normalizedURL(from urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else { return urlString }

        let cal = Calendar.current
        let now = Date()
        let start = cal.date(byAdding: .day,  value: -30, to: now) ?? now
        let end   = cal.date(byAdding: .year, value:   5, to: now) ?? now

        let df = DateFormatter()
        df.locale     = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd"

        var items = (components.queryItems ?? [])
            .filter { !["preset_time", "preset_start", "preset_end"].contains($0.name) }
        items.append(URLQueryItem(name: "preset_time",  value: "custom"))
        items.append(URLQueryItem(name: "preset_start", value: df.string(from: start)))
        items.append(URLQueryItem(name: "preset_end",   value: df.string(from: end)))
        components.queryItems = items

        return components.url?.absoluteString ?? urlString
    }

    // MARK: - iCal パース

    private func parseICS(_ raw: String) -> [MoodleEvent] {
        // RFC 5545: CRLF + 空白 = 継続行 → 結合してからパース
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\n ", with: "")
        text = text.replacingOccurrences(of: "\n\t", with: "")

        var events: [MoodleEvent] = []
        var inEvent = false
        var block: [String: String] = [:]

        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t == "BEGIN:VEVENT" {
                inEvent = true; block = [:]
            } else if t == "END:VEVENT" {
                inEvent = false
                if let e = makeEvent(from: block) { events.append(e) }
            } else if inEvent, let idx = t.firstIndex(of: ":") {
                // セミコロン以降のパラメータを取り除いた純粋なキー（例 DTSTART;TZID=... → DTSTART）
                let rawKey = String(t[..<idx])
                let key    = rawKey.split(separator: ";").first.map(String.init) ?? rawKey
                let value  = String(t[t.index(after: idx)...])
                block[key] = value
            }
        }

        return events.sorted {
            switch ($0.dueDate, $1.dueDate) {
            case let (a?, b?): return a < b
            case (_?, nil):    return true
            default:           return false
            }
        }
    }

    private func makeEvent(from block: [String: String]) -> MoodleEvent? {
        guard let uid     = block["UID"],
              let summary = block["SUMMARY"] else { return nil }

        let dueDate = block["DTSTART"].flatMap { parseISODate($0) }
        let desc = (block["DESCRIPTION"] ?? "")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
        let eventURL   = block["URL"].flatMap { $0.isEmpty ? nil : $0 }
        let categories = block["CATEGORIES"] ?? ""

        let (cleanTitle, eventType) = classify(summary)
        return MoodleEvent(uid: uid, summary: summary, cleanTitle: cleanTitle,
                           dueDate: dueDate, eventDescription: desc,
                           eventURL: eventURL,
                           courseCode: categories, eventType: eventType)
    }

    private func classify(_ summary: String) -> (String, MoodleEventType) {
        let inner = extractQuoted(summary)
        if summary.contains("の提出期限") {
            return (inner ?? summary, .deadline)
        } else if summary.hasSuffix("」開始") || summary.hasSuffix("開始") {
            return (inner ?? summary, .start)
        } else if summary.hasSuffix("」終了") || summary.hasSuffix("終了") {
            return (inner ?? summary, .end)
        }
        return (inner ?? summary, .other)
    }

    /// 「...」の中身を取り出す
    private func extractQuoted(_ s: String) -> String? {
        guard let open  = s.firstIndex(of: "「"),
              let close = s.lastIndex(of: "」") else { return nil }
        let start = s.index(after: open)
        guard start < close else { return nil }
        return String(s[start..<close])
    }

    private func parseISODate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if s.hasSuffix("Z") {
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            f.timeZone   = TimeZone(abbreviation: "UTC")
        } else if s.count == 15 {
            f.dateFormat = "yyyyMMdd'T'HHmmss"
            f.timeZone   = TimeZone.current
        } else if s.count == 8 {
            f.dateFormat = "yyyyMMdd"
            f.timeZone   = TimeZone.current
        } else {
            return nil
        }
        return f.date(from: s)
    }

    // MARK: - Errors

    enum MoodleError: LocalizedError {
        case noURL, invalidData
        var errorDescription: String? {
            switch self {
            case .noURL:         return "iCal URLが未設定です"
            case .invalidData:   return "データの取得に失敗しました"
            }
        }
    }
}

