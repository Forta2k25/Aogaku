import Foundation

enum Campus: String, CaseIterable, Hashable {
    case aoyama, sagamihara
}

enum DayCategory {
    case classDay          // 授業実施日
    case sunday            // 日曜（授業なし）
    case kyuko             // 休講日（指定日）
    case makeup            // 補講日（通常授業なし）
    case exam              // 定期試験期間
    case summerBreak       // 夏季休業
    case winterBreak       // 冬季休業
    case springBreak       // 春季休業
}

struct AcademicCalendar2025 {
    private let cal = Calendar(identifier: .gregorian)
    private let tz = TimeZone(identifier: "Asia/Tokyo")!

    // 便宜: 日付生成
    private func d(_ y: Int, _ m: Int, _ day: Int) -> Date {
        var dc = DateComponents()
        dc.timeZone = tz
        dc.year = y; dc.month = m; dc.day = day
        return cal.date(from: dc)!
    }

    private var summerBreak: (Date, Date) { (d(2025,8,1),  d(2025,9,18)) }
    private var winterBreak: (Date, Date) { (d(2025,12,23), d(2026,1,3)) }
    private var springBreak: (Date, Date) { (d(2026,2,4),  d(2026,3,31)) }
    

    // === 定期試験期間 ===
    private var examSpring: (Date, Date) { (d(2025,7,24), d(2025,7,31)) }
    private var examAutumn: (Date, Date) { (d(2026,1,27), d(2026,2,3)) }

    // === 休講日（共通） ===
    // 5/3, 5/5, 5/6, 9/23, 10/31, 11/1, 11/3, 11/24, 1/12
    private var kyukoCommon: Set<Date> {
        [d(2025,5,3), d(2025,5,5), d(2025,5,6),
         d(2025,9,23),
         d(2025,10,31),
         d(2025,11,1), d(2025,11,3), d(2025,11,24),
         d(2026,1,12)]
    }
    // 休講日（相模原のみ）: 10/11
    private var kyukoSagamiharaOnly: Set<Date> { [d(2025,10,11)] }
    // 休講日（青山のみ）: 1/16, 1/17
    private var kyukoAoyamaOnly: Set<Date> { [d(2026,1,16), d(2026,1,17)] }

    // === 補講日（通常授業なし） ===
    // 共通：7/23, 1/21, 1/22／相模原のみ：1/23
    private var makeupCommon: Set<Date> { [d(2025,7,23), d(2026,1,21), d(2026,1,22)] }
    private var makeupSagamiharaOnly: Set<Date> { [d(2026,1,23)] }

    // ヘルパー
    private func inRange(_ date: Date, _ range: (Date, Date)) -> Bool {
        date >= range.0 && date <= range.1
    }
    private func isSunday(_ date: Date) -> Bool {
        cal.component(.weekday, from: date) == 1 // Sun=1
    }

    // 分類（ユーザー指定ルールに準拠）
    func category(of date: Date, campus: Campus) -> DayCategory {
        if isSunday(date) { return .sunday }

        // 休業期間
        if inRange(date, summerBreak) { return .summerBreak }
        if inRange(date, winterBreak) { return .winterBreak }
        if inRange(date, springBreak) { return .springBreak }

        // 定期試験期間
        if inRange(date, examSpring) || inRange(date, examAutumn) { return .exam }

        // 休講日（キャンパス別を考慮）
        if kyukoCommon.contains(date) { return .kyuko }
        switch campus {
        case .aoyama:
            if kyukoAoyamaOnly.contains(date) { return .kyuko }
        case .sagamihara:
            if kyukoSagamiharaOnly.contains(date) { return .kyuko }
        }

        // 補講日（キャンパス別）
        if makeupCommon.contains(date) { return .makeup }
        if campus == .sagamihara && makeupSagamiharaOnly.contains(date) { return .makeup }

        // それ以外（言及なし & 日曜以外）はすべて授業実施日
        return .classDay
    }

    // 旧インターフェイスも維持（UIが使っている想定）
    func isClassDay(_ date: Date, campus: Campus) -> Bool {
        return category(of: date, campus: campus) == .classDay
    }

    // 指定月の日付（6行×7列）
    func gridDays(for month: Date) -> [Date] {
        let comps = cal.dateComponents(in: tz, from: month)
        let first = cal.date(from: DateComponents(timeZone: tz, year: comps.year, month: comps.month, day: 1))!
        let firstWeekday = cal.component(.weekday, from: first) // 1=Sun
        let leading = (firstWeekday + 5) % 7 // 月曜起点（0..6）

        let range = cal.range(of: .day, in: .month, for: first)!
        let daysInMonth = range.count

        var days: [Date] = []
        // 前月の余白
        if let prevMonth = cal.date(byAdding: .month, value: -1, to: first) {
            let prevCount = cal.range(of: .day, in: .month, for: prevMonth)!.count
            for i in 0..<leading {
                let day = prevCount - (leading - 1 - i)
                days.append(cal.date(from: DateComponents(timeZone: tz,
                                                          year: cal.component(.year, from: prevMonth),
                                                          month: cal.component(.month, from: prevMonth),
                                                          day: day))!)
            }
        }
        // 当月
        for day in 1...daysInMonth {
            days.append(cal.date(from: DateComponents(timeZone: tz, year: comps.year, month: comps.month, day: day))!)
        }
        // 末尾の余白
        while days.count % 7 != 0 {
            if let next = cal.date(byAdding: .day, value: 1, to: days.last!) {
                days.append(next)
            } else { break }
        }
        // 6行に揃える
        while days.count < 42 {
            if let next = cal.date(byAdding: .day, value: 1, to: days.last!) {
                days.append(next)
            } else { break }
        }
        return days
    }
}
