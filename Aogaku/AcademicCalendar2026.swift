//
//  AcademicCalendar2026.swift
//  Aogaku
//
//  Created by 米沢怜生 on 2026/02/09.
//

import Foundation

final class AcademicCalendar2026 {

    private let cal = Calendar(identifier: .gregorian)
    private let tz = TimeZone(identifier: "Asia/Tokyo")!

    // MARK: - Helpers
    private func d(_ y: Int, _ m: Int, _ day: Int) -> Date {
        cal.date(from: DateComponents(timeZone: tz, year: y, month: m, day: day))!
    }

    private func inRange(_ date: Date, _ start: Date, _ end: Date) -> Bool {
        // inclusive
        return date >= start && date <= end
    }

    // MARK: - Periods (from PDF)
    // 前期授業：2026/4/6 開始
    private lazy var springTermStart = d(2026, 4, 6)

    // 前期試験：2026/7/24〜7/31
    private lazy var springExamStart = d(2026, 7, 24)
    private lazy var springExamEnd   = d(2026, 7, 31)

    // 夏期休業：2026/8/1〜9/12
    private lazy var summerBreakStart = d(2026, 8, 1)
    private lazy var summerBreakEnd   = d(2026, 9, 12)

    // 後期授業開始：2026/9/14
    private lazy var autumnTermStart = d(2026, 9, 14)

    // 冬期休業：2026/12/23〜2027/1/7
    private lazy var winterBreakStart = d(2026, 12, 23)
    private lazy var winterBreakEnd   = d(2027, 1, 7)

    // 後期授業再開：2027/1/8
    private lazy var autumnResume = d(2027, 1, 8)

    // 後期試験：2027/1/26〜2/2
    private lazy var autumnExamStart = d(2027, 1, 26)
    private lazy var autumnExamEnd   = d(2027, 2, 2)

    // 春期休業：2027/2/3〜3/27
    private lazy var springBreakStart = d(2027, 2, 3)
    private lazy var springBreakEnd   = d(2027, 3, 27)

    // MARK: - Special Days (from PDF notes)

    // 補講日
    private lazy var makeupBoth: Set<Date> = [
        d(2026, 7, 23),
        d(2027, 1, 21),
    ]

    private lazy var makeupSagamiharaOnly: Set<Date> = [
        d(2027, 1, 22) // 相模原のみ補講日（青山は通常授業日）
    ]

    // 学事上の休講日（キャンパス共通）
    private lazy var kyukoBoth: Set<Date> = [
        // 青山祭期間（両キャンパス休講）
        d(2026, 10, 30), d(2026, 10, 31), d(2026, 11, 1),
        // 11/2 は授業休講（両キャンパス）
        d(2026, 11, 2),
    ]

    // 学事上の休講日（青山のみ）
    private lazy var kyukoAoyamaOnly: Set<Date> = [
        // 大学入学共通テスト準備日・実施日（1/15・1/16 青山のみ休講）
        d(2027, 1, 15),
        d(2027, 1, 16),
    ]

    // 学事上の休講日（相模原のみ）
    private lazy var kyukoSagamiharaOnly: Set<Date> = [
        // 相模原祭期間（10日(土) は相模原のみ休講）
        d(2026, 10, 10),
    ]

    // 休日だけど授業実施日（PDFに「授業実施日」と明記）
    // ※ここは「祝日セットより優先」して必ず classDay にする
    private lazy var holidayButClassDays: Set<Date> = [
        d(2026, 4, 29),  // 昭和の日：授業実施日
        d(2026, 7, 20),  // 海の日：授業実施日
        d(2026, 9, 21),  // 敬老の日：授業実施日
        d(2026, 10, 12), // スポーツの日：授業実施日
        d(2026, 11, 16), // 創立記念日：授業実施日（祝日ではないがここで明示しておく）
    ]

    // 国民の祝日（基本：休講扱い）
    // ※「授業実施日」と明記されている祝日は holidayButClassDays 側で classDay にする
    private lazy var kyukoNationalHolidays: Set<Date> = [
        // 2026
        d(2026, 5, 3),   // 憲法記念日（日）
        d(2026, 5, 4),   // みどりの日（月）
        d(2026, 5, 5),   // こどもの日（火）
        d(2026, 5, 6),   // 振替休日（水）
        d(2026, 8, 11),  // 山の日（火）※夏休み中だが一応登録
        d(2026, 9, 22),  // 国民の休日（火）
        d(2026, 9, 23),  // 秋分の日（水）
        d(2026, 11, 3),  // 文化の日（火）
        d(2026, 11, 23), // 勤労感謝の日（月）

        // 2027（2026年度の後半）
        d(2027, 1, 1),   // 元日（金）
        d(2027, 1, 11),  // 成人の日（月）
        d(2027, 2, 11),  // 建国記念の日（木）
        d(2027, 2, 23),  // 天皇誕生日（火）
        // 2027/3/21 は日曜なので .sunday が優先される
        d(2027, 3, 22),  // 春分の日（振替休日）
    ]

    // MARK: - Public API (match AcademicCalendar2025)
    func gridDays(for monthFirst: Date) -> [Date] {
        // monthFirst を含む 6週×7日（42マス）を返す
        let monthStart = firstDay(of: monthFirst)

        // 月曜始まり（UIが「月〜日」前提）
        let weekday = cal.component(.weekday, from: monthStart) // Sun=1 ... Sat=7
        let diffToMonday: Int = {
            // Monday=2
            if weekday == 1 { return -6 } // Sun -> back 6
            return -(weekday - 2)
        }()

        let gridStart = cal.date(byAdding: .day, value: diffToMonday, to: monthStart)!
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
    }

    func category(of date: Date, campus: Campus) -> DayCategory {
        // 1) 日曜
        if cal.component(.weekday, from: date) == 1 { return .sunday }

        // 2) 長期休業
        if inRange(date, summerBreakStart, summerBreakEnd) { return .summerBreak }
        if inRange(date, winterBreakStart, winterBreakEnd) { return .winterBreak }
        if inRange(date, springBreakStart, springBreakEnd) { return .springBreak }

        // 3) 試験期間
        if inRange(date, springExamStart, springExamEnd) { return .exam }
        if inRange(date, autumnExamStart, autumnExamEnd) { return .exam }

        // 4) 補講日（キャンパス別）
        if makeupBoth.contains(date) { return .makeup }
        if campus == .sagamihara && makeupSagamiharaOnly.contains(date) { return .makeup }

        // 5) 休日だけど授業実施日（PDFに明記） → 必ず classDay
        if holidayButClassDays.contains(date) { return .classDay }

        // 6) 休講日（学事上 + 国民の祝日 + キャンパス別）
        if kyukoBoth.contains(date) { return .kyuko }
        if kyukoNationalHolidays.contains(date) { return .kyuko }
        if campus == .aoyama && kyukoAoyamaOnly.contains(date) { return .kyuko }
        if campus == .sagamihara && kyukoSagamiharaOnly.contains(date) { return .kyuko }

        // 7) 授業実施期間（前期・後期）
        // 前期：4/6〜7/23（7/24から試験）
        let springTermEnd = d(2026, 7, 23)

        // 後期：9/14〜12/22、再開 1/8〜1/25（1/26から試験）
        let autumnTermEndBeforeBreak = d(2026, 12, 22)
        let autumnTermEndAfterResume = d(2027, 1, 25)

        if inRange(date, springTermStart, springTermEnd) { return .classDay }
        if inRange(date, autumnTermStart, autumnTermEndBeforeBreak) { return .classDay }
        if inRange(date, autumnResume, autumnTermEndAfterResume) { return .classDay }

        // それ以外は学事上の授業日ではない扱い
        return .kyuko
    }

    // MARK: - Private
    private func firstDay(of date: Date) -> Date {
        let c = cal.dateComponents(in: tz, from: date)
        return cal.date(from: DateComponents(timeZone: tz, year: c.year, month: c.month, day: 1))!
    }
}

