import XCTest
@testable import Aogaku

final class QuickAskRoutingTests: XCTestCase {
    private func course(_ id: String, _ title: String, teacher: String = "") -> Course {
        Course(id: id, title: title, room: "", teacher: teacher, credits: 2, campus: "青山", category: nil, syllabusURL: nil, term: nil)
    }
    private func entry(_ id: String, _ title: String, day: Int, period: Int, teacher: String = "") -> QuickAskCourse {
        QuickAskCourse(course: course(id, title, teacher: teacher), location: SlotLocation(day: day, period: period))
    }
    /// 日本時間の、指定の日時。2026-10-20 は火曜(day=1)。
    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var parts = DateComponents(); parts.year = 2026; parts.month = 10; parts.day = day; parts.hour = hour; parts.minute = minute
        return QuickAskRouting.jst.date(from: parts)!
    }
    private lazy var entries = [
        entry("reading", "Reading II", day: 1, period: 2),        // 火2限 11:00-12:30
        entry("bible", "旧約聖書と人間", day: 1, period: 3),        // 火3限 13:20-14:50
        entry("media", "メディアとアイデンティティ", day: 1, period: 4), // 火4限 15:05-16:35
        entry("writing", "Academic Writing", day: 3, period: 2)   // 木2限
    ]

    func testDuringAClassItIsThatClass() {
        let match = QuickAskRouting.timeMatch(entries, now: date(20, 11, 30))   // 火曜 11:30
        XCTAssertEqual(match?.entry.course.id, "reading"); XCTAssertEqual(match?.phase, .inSession)
        XCTAssertEqual(QuickAskRouting.timeMatch(entries, now: date(20, 12, 30))?.entry.course.id, "reading", "終了の時刻ちょうどまで")
    }
    func testJustBeforeAndJustAfterAClassStillCount() {
        let before = QuickAskRouting.timeMatch(entries, now: date(20, 10, 50))   // 始まる10分前
        XCTAssertEqual(before?.entry.course.id, "reading"); XCTAssertEqual(before?.phase, .startingSoon)
        let after = QuickAskRouting.timeMatch(entries, now: date(20, 12, 50))    // 終わって20分後(次の授業の前)
        XCTAssertEqual(after?.entry.course.id, "reading"); XCTAssertEqual(after?.phase, .justEnded)
        XCTAssertEqual(QuickAskRouting.timeMatch(entries, now: date(20, 13, 30))?.entry.course.id, "bible", "次の授業が始まっていれば、そちら(授業中が優先)")
    }
    func testOutsideTheWindowThereIsNoMatch() {
        XCTAssertNil(QuickAskRouting.timeMatch(entries, now: date(20, 10, 30)), "始まる30分前は、対象外(15分前から)")
        XCTAssertNil(QuickAskRouting.timeMatch(entries, now: date(20, 17, 45)), "4限が終わって70分後は、対象外(60分後まで)")
        XCTAssertNil(QuickAskRouting.timeMatch(entries, now: date(20, 22, 0)))
        XCTAssertNil(QuickAskRouting.timeMatch(entries, now: date(21, 11, 30)), "水曜は、授業なし")
        XCTAssertNil(QuickAskRouting.timeMatch([], now: date(20, 11, 30)))
    }
    func testBetweenTwoClassesTheNearerOneWins() {
        // 2限(終了12:30)と3限(開始13:20): 12:50 は、2限の終了から20分後・3限の開始まで30分。
        XCTAssertEqual(QuickAskRouting.timeMatch(entries, now: date(20, 12, 50))?.entry.course.id, "reading")
        // 13:10 は、2限の終了から40分後・3限の開始まで10分(15分以内)。近い3限。
        let m = QuickAskRouting.timeMatch(entries, now: date(20, 13, 10))
        XCTAssertEqual(m?.entry.course.id, "bible"); XCTAssertEqual(m?.phase, .startingSoon)
    }
    func testACancelledClassIsSkipped() {
        let match = QuickAskRouting.timeMatch(entries, now: date(20, 11, 30)) { entry, _ in entry.course.id == "reading" }
        XCTAssertNil(match, "休講の日は、その授業に振らない")
    }
    func testSessionIsTodayOnAClassDayElseTheLatestPastSession() {
        let now = date(20, 11, 30), today = QuickAskRouting.dayID(of: now)
        XCTAssertEqual(QuickAskRouting.sessionDayID(classDayIDs: [today - 14, today - 7, today], extras: [], cancelled: [], now: now), today)
        XCTAssertEqual(QuickAskRouting.sessionDayID(classDayIDs: [today - 14, today - 7], extras: [], cancelled: [], now: now), today - 7, "今日が授業日でなければ、直近の回")
        XCTAssertEqual(QuickAskRouting.sessionDayID(classDayIDs: [today - 14, today - 7, today], extras: [], cancelled: [today], now: now), today - 7, "今日が休講なら、直近の回")
        XCTAssertEqual(QuickAskRouting.sessionDayID(classDayIDs: [today - 14], extras: [today - 2], cancelled: [], now: now), today - 2, "補講も、回に数える")
        XCTAssertEqual(QuickAskRouting.sessionDayID(classDayIDs: [today + 7], extras: [], cancelled: [], now: now), today + 7, "学期の前なら、最初の回")
        XCTAssertEqual(QuickAskRouting.sessionDayID(classDayIDs: [], extras: [], cancelled: [], now: now), today)
    }
    func testSessionFromTheRealAcademicCalendar() {
        let defaults = UserDefaults(suiteName: "quickask-test-\(UUID().uuidString)")!
        let term = TermKey(year: 2026, semester: .fall)
        let tuesday = entry("reading", "Reading II", day: 1, period: 2)
        let now = date(20, 11, 30)
        let day = QuickAskRouting.sessionDayID(for: tuesday, term: term, now: now, defaults: defaults)
        XCTAssertLessThanOrEqual(day, QuickAskRouting.dayID(of: now))
        XCTAssertGreaterThan(day, QuickAskRouting.dayID(of: now) - 8, "直近の火曜(授業日)になる")
        // 休講にすると、その日は選ばれない
        defaults.set([day], forKey: "note.cancelled.reading")
        XCTAssertNotEqual(QuickAskRouting.sessionDayID(for: tuesday, term: term, now: now, defaults: defaults), day)
    }
}
