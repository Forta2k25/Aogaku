import Foundation

/// 時間割のマス(の番号)から、授業とコマを取り出す。マスの番号は、曜日 + (時限 - 1) × 列の数。授業が無いマスは、nil。
enum TimetableAskSelection {
    static func entry(at index: Int, assigned: [Course?], columns: Int) -> QuickAskCourse? {
        guard columns > 0, assigned.indices.contains(index), let course = assigned[index] else { return nil }
        return QuickAskCourse(course: course, location: SlotLocation(day: index % columns, period: index / columns + 1))
    }
}

/// 時間割の1コマ(授業と、その曜日・時限)。
struct QuickAskCourse: Equatable {
    let course: Course
    let location: SlotLocation
}

/// 時間割から質問するときの、ルールの部分。画面や通信には依存しない。
/// - いまの授業(の付近: 始まる15分前から、終わって60分後まで)を見つけて、時間割のコマを目立たせる(自動では選ばない)。
/// - 選ばれた授業の、どの回のチャットを開くか(今日が授業日なら今日、そうでなければ直近の回)を決める。
enum QuickAskRouting {
    /// 各限の開始・終了(0時からの分)。時間割の表示(9:00-10:30, 11:00-12:30, …)と同じ。
    static let periodMinutes: [(start: Int, end: Int)] = [(540, 630), (660, 750), (800, 890), (905, 995), (1010, 1100), (1110, 1200), (1210, 1300)]
    static let minutesBeforeStart = 15
    static let minutesAfterEnd = 60

    static let jst: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return calendar
    }()

    enum Phase: Equatable { case inSession, startingSoon, justEnded }
    struct TimeMatch: Equatable {
        let entry: QuickAskCourse
        let phase: Phase
    }

    /// 日付(日本時間)を、1970年からの日数にする(授業回の識別に使う dayID と同じ)。
    static func dayID(of date: Date) -> Int {
        Int(floor((date.timeIntervalSince1970 + TimeInterval(jst.timeZone.secondsFromGMT(for: date))) / 86400))
    }
    /// 月=0 … 日=6。
    static func weekdayIndex(of date: Date) -> Int { (jst.component(.weekday, from: date) + 5) % 7 }
    private static func minutes(of date: Date) -> Int { jst.component(.hour, from: date) * 60 + jst.component(.minute, from: date) }

    /// いま(の付近)に授業がある時間割のコマ。授業中を最優先にし、無ければ、いちばん近いもの。休講の日は、除く。
    static func timeMatch(_ entries: [QuickAskCourse], now: Date, isCancelled: (QuickAskCourse, Int) -> Bool = { _, _ in false }) -> TimeMatch? {
        let day = weekdayIndex(of: now), nowMinutes = minutes(of: now), today = dayID(of: now)
        var best: (match: TimeMatch, distance: Int)?
        for entry in entries where entry.location.day == day && (1...periodMinutes.count).contains(entry.location.period) {
            if isCancelled(entry, today) { continue }
            let period = periodMinutes[entry.location.period - 1]
            let phase: Phase, distance: Int
            if nowMinutes >= period.start && nowMinutes <= period.end { phase = .inSession; distance = 0 }
            else if nowMinutes < period.start, period.start - nowMinutes <= minutesBeforeStart { phase = .startingSoon; distance = period.start - nowMinutes }
            else if nowMinutes > period.end, nowMinutes - period.end <= minutesAfterEnd { phase = .justEnded; distance = nowMinutes - period.end }
            else { continue }
            if best == nil || distance < best!.distance { best = (TimeMatch(entry: entry, phase: phase), distance) }
        }
        return best?.match
    }

    /// どの授業回のチャットに入れるか。今日が授業の日(補講を含む。休講は除く)なら、今日の回。そうでなければ、直近の回。
    static func sessionDayID(classDayIDs: Set<Int>, extras: Set<Int>, cancelled: Set<Int>, now: Date) -> Int {
        let today = dayID(of: now)
        let days = classDayIDs.union(extras).subtracting(cancelled)
        if days.contains(today) { return today }
        return days.filter { $0 <= today }.max() ?? days.min() ?? today
    }

    /// 時間割と学事暦から、この授業の回(日付)を集めて、回を決める。休講・補講は、授業ノートの設定(端末内)に従う。
    static func sessionDayID(for entry: QuickAskCourse, term: TermKey, now: Date, defaults: UserDefaults = .standard) -> Int {
        let tomorrow = jst.date(byAdding: .day, value: 1, to: now) ?? now
        let dates = LectureSessionNumbering.sessionDates(upTo: tomorrow, weekday: entry.location.day, term: term,
                                                         campus: LectureSessionNumbering.campus(for: entry.course))
        let extras = Set((defaults.array(forKey: "note.extra.\(entry.course.id)") as? [Int]) ?? [])
        let cancelled = Set((defaults.array(forKey: "note.cancelled.\(entry.course.id)") as? [Int]) ?? [])
        return sessionDayID(classDayIDs: Set(dates.map(dayID(of:))), extras: extras, cancelled: cancelled, now: now)
    }
}
