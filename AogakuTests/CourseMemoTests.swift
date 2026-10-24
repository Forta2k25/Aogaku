import XCTest
@testable import Aogaku

final class CourseMemoTests: XCTestCase {
    func testMemoIsSeparatePerCourseAndEmptyDeletes() {
        let a = "test-course-A-\(UUID().uuidString)", b = "test-course-B-\(UUID().uuidString)"
        defer { AICourseMemoStore.save("", courseKey: a); AICourseMemoStore.save("", courseKey: b) }
        XCTAssertEqual(AICourseMemoStore.load(courseKey: a), "")
        AICourseMemoStore.save("  先生は配布プリントから出す \n", courseKey: a)
        XCTAssertEqual(AICourseMemoStore.load(courseKey: a), "先生は配布プリントから出す")
        XCTAssertEqual(AICourseMemoStore.load(courseKey: b), "", "別の授業のメモは混ざらない")
        AICourseMemoStore.save("   ", courseKey: a)
        XCTAssertEqual(AICourseMemoStore.load(courseKey: a), "")
    }

    func testMemoIsClippedToLimit() {
        let key = "test-course-clip-\(UUID().uuidString)"
        defer { AICourseMemoStore.save("", courseKey: key) }
        AICourseMemoStore.save(String(repeating: "あ", count: AICourseMemoStore.maxCharacters + 500), courseKey: key)
        XCTAssertEqual(AICourseMemoStore.load(courseKey: key).count, AICourseMemoStore.maxCharacters)
    }

    func testSyllabusSummaryUsesKnownFieldsAndSkipsMissing() {
        let text = AISyllabusSummary.make(fields: [
            "__授業科目名": "経済数学", "__教員名": "山田", "__単位": "2",
            "成績評価": "期末試験\t70\t筆記\n小テスト\t30\t毎回", "授業計画": "1\t導入\n2\t微分",
            "不明な項目": "出ない"])
        XCTAssertTrue(text.contains("科目: 経済数学"))
        XCTAssertTrue(text.contains("【成績評価】"))
        XCTAssertTrue(text.contains("期末試験 / 70 / 筆記"), "タブは区切りに直す")
        XCTAssertTrue(text.contains("【授業計画】"))
        XCTAssertFalse(text.contains("授業の概要"), "無い項目は出さない")
        XCTAssertFalse(text.contains("不明な項目"))
        XCTAssertEqual(AISyllabusSummary.make(fields: [:]), "")
    }

    func testSyllabusSummaryIsBounded() {
        let big = String(repeating: "計画\n", count: 5000)
        XCTAssertLessThanOrEqual(AISyllabusSummary.make(fields: ["授業計画": big, "__講義概要": big, "成績評価": big]).count, 3500)
    }
}
