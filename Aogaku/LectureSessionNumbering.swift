//
//  LectureSessionNumbering.swift
//  Aogaku
//
//  授業ノート(AI)機能: 学事暦と照合して「第N回」を判定する
//

import Foundation

enum LectureSessionNumbering {

    /// 指定した曜日・学期・キャンパスにおいて、date が学期開始から数えて何回目の授業日にあたるかを返す。
    /// 休講日・補講日・試験期間・長期休業などは学事暦(AcademicCalendarRouter)の判定に従って除外する。
    static func sessionNumber(for date: Date, weekday: Int, term: TermKey, campus: Campus) -> Int? {
        guard let termStart = termStartDate(for: term) else { return nil }

        let cal = Calendar(identifier: .gregorian)
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        var calWithTZ = cal
        calWithTZ.timeZone = tz

        // SlotLocation.day: 0=月...5=土 → Calendar.weekday: 1=日...7=土 (月=2)
        let targetWeekday = weekday + 2
        let startWeekday = calWithTZ.component(.weekday, from: termStart)
        let offset = (targetWeekday - startWeekday + 7) % 7
        guard var cursor = calWithTZ.date(byAdding: .day, value: offset, to: termStart) else { return nil }

        let targetDay = calWithTZ.startOfDay(for: date)
        let router = AcademicCalendarRouter()
        var count = 0

        for _ in 0..<30 {   // 最大30週分(1年度)まで探索すれば十分
            let day = calWithTZ.startOfDay(for: cursor)
            if day > targetDay { break }
            if router.category(of: day, campus: campus) == .classDay {
                count += 1
            }
            if calWithTZ.isDate(day, inSameDayAs: targetDay) {
                return count
            }
            guard let next = calWithTZ.date(byAdding: .day, value: 7, to: cursor) else { break }
            cursor = next
        }
        return count > 0 ? count : nil
    }

    static func campus(for course: Course) -> Campus {
        (course.campus?.contains("相模") == true) ? .sagamihara : .aoyama
    }

    private static func termStartDate(for term: TermKey) -> Date? {
        let cal = Calendar(identifier: .gregorian)
        let isFront = term.semester == .spring
        var comps = DateComponents()
        comps.year = term.year

        if let k = TermStore.knownTermStartDays[term.year] {
            comps.month = isFront ? k.springMonth : k.fallMonth
            comps.day = isFront ? k.springDay : k.fallDay
        } else {
            // 未登録年度: 4/1 または 9/7 以降の最初の月曜を推計(currentSyllabusWeekと同じ近似)
            comps.month = isFront ? 4 : 9
            comps.day = isFront ? 1 : 7
            guard let anchor = cal.date(from: comps) else { return nil }
            let wd = cal.component(.weekday, from: anchor)
            let shift = (9 - wd) % 7
            guard let est = cal.date(byAdding: .day, value: shift, to: anchor) else { return nil }
            let ec = cal.dateComponents([.month, .day], from: est)
            comps.month = ec.month ?? comps.month
            comps.day = ec.day ?? comps.day
        }
        return cal.date(from: comps)
    }
}
