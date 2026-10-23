import Foundation

/// 時間割の1コマ(授業と、その曜日・時限)。
struct QuickAskCourse: Equatable {
    let course: Course
    let location: SlotLocation
}

/// 「いま聞いたことは、どの授業の、どの回のものか」を決める、ルールの部分。画面や通信には依存しない。
/// - 授業時間の付近(始まる15分前から、終わって60分後まで)なら、その授業に自動で振る。
/// - それ以外は、内容から予想して、候補を出して、ユーザーに選ばせる(予想は、別の処理)。
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

    /// 授業を選んでもらうときの並び順。予想した授業を先に(自信の高い順)、残りは、いまに近い順。同じ授業が複数のコマにあるときは、1つにまとめる。
    static func orderedForChoice(_ entries: [QuickAskCourse], predicted: [(id: String, confidence: Double)], now: Date) -> [QuickAskCourse] {
        let day = weekdayIndex(of: now), nowMinutes = minutes(of: now)
        func proximity(_ entry: QuickAskCourse) -> Int {
            guard (1...periodMinutes.count).contains(entry.location.period) else { return Int.max }
            let period = periodMinutes[entry.location.period - 1]
            let dayGap = (entry.location.day - day + 7) % 7   // 今日=0、明日=1、…
            let within = nowMinutes < period.start ? period.start - nowMinutes : (nowMinutes <= period.end ? 0 : 1440 + nowMinutes - period.end)
            return dayGap * 1440 + within
        }
        var seen = Set<String>(), result: [QuickAskCourse] = []
        for item in predicted.sorted(by: { $0.confidence > $1.confidence }) {
            if let entry = entries.first(where: { $0.course.id == item.id }), seen.insert(entry.course.id).inserted { result.append(entry) }
        }
        for entry in entries.sorted(by: { proximity($0) < proximity($1) }) where seen.insert(entry.course.id).inserted { result.append(entry) }
        return result
    }

    /// 通信できないとき用の、簡単な予想: 質問の中の言葉が、授業名・先生の名前に含まれる授業。
    static func localGuess(question: String, entries: [QuickAskCourse]) -> [QuickAskCourse] {
        let text = question.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "ja_JP"))
        var scored: [(QuickAskCourse, Int)] = []
        var seen = Set<String>()
        for entry in entries where seen.insert(entry.course.id).inserted {
            let words = (entry.course.title + " " + entry.course.teacher)
                .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "ja_JP"))
                .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).filter { $0.count >= 2 }
            let score = words.filter { text.contains($0) }.reduce(0) { $0 + $1.count }
            if score > 0 { scored.append((entry, score)) }
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }
}
