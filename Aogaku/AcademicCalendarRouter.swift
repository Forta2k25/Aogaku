//
//  AcademicCalendarRouter.swift
//  Aogaku
//
//  Created by 米沢怜生 on 2026/02/09.
//

import Foundation

/// 2025年度（2025/4〜2026/3）と 2026年度（2026/4〜2027/3）を切り替えるルータ
final class AcademicCalendarRouter {

    private let cal = Calendar(identifier: .gregorian)
    private let tz = TimeZone(identifier: "Asia/Tokyo")!

    private let y2025 = AcademicCalendar2025()
    private let y2026 = AcademicCalendar2026()

    private func isIn2026AcademicYear(_ date: Date) -> Bool {
        // 2026/4/1〜2027/3/31 を 2026年度とみなす
        let c = cal.dateComponents(in: tz, from: date)
        guard let y = c.year, let m = c.month else { return false }
        if y == 2026 { return m >= 4 }
        if y == 2027 { return m <= 3 }
        return false
    }

    func gridDays(for monthFirst: Date) -> [Date] {
        if isIn2026AcademicYear(monthFirst) { return y2026.gridDays(for: monthFirst) }
        return y2025.gridDays(for: monthFirst)
    }

    func category(of date: Date, campus: Campus) -> DayCategory {
        if isIn2026AcademicYear(date) { return y2026.category(of: date, campus: campus) }
        return y2025.category(of: date, campus: campus)
    }
}
