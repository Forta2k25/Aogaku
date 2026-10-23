import XCTest
import UIKit
@testable import Aogaku

@MainActor
final class TimetableAskBarTests: XCTestCase {
    private func course(_ id: String) -> Course {
        Course(id: id, title: id, room: "", teacher: "", credits: 2, campus: nil, category: nil, syllabusURL: nil, term: nil)
    }

    // MARK: マスの番号 → 授業とコマ
    func testGridIndexMapsToTheCourseAndItsSlot() {
        // 5列(月〜金)。番号 = 曜日 + (時限 - 1) × 5。火曜2限 = 1 + 1×5 = 6。
        var assigned = [Course?](repeating: nil, count: 25)
        assigned[6] = course("reading"); assigned[17] = course("bible")   // 17 = 水(2) + 3×5 → 水4限
        let reading = TimetableAskSelection.entry(at: 6, assigned: assigned, columns: 5)
        XCTAssertEqual(reading?.course.id, "reading"); XCTAssertEqual(reading?.location, SlotLocation(day: 1, period: 2))
        let bible = TimetableAskSelection.entry(at: 17, assigned: assigned, columns: 5)
        XCTAssertEqual(bible?.location, SlotLocation(day: 2, period: 4))
        XCTAssertNil(TimetableAskSelection.entry(at: 0, assigned: assigned, columns: 5), "空きのマスは、選べない")
        XCTAssertNil(TimetableAskSelection.entry(at: 99, assigned: assigned, columns: 5), "範囲外は、選べない(設定変更の直後の古い番号)")
        XCTAssertNil(TimetableAskSelection.entry(at: -1, assigned: assigned, columns: 5))
        XCTAssertNil(TimetableAskSelection.entry(at: 6, assigned: assigned, columns: 0))
        // 土曜が入って6列になったとき
        var six = [Course?](repeating: nil, count: 30); six[7] = course("sat")
        XCTAssertEqual(TimetableAskSelection.entry(at: 7, assigned: six, columns: 6)?.location, SlotLocation(day: 1, period: 2))
    }

    // MARK: 入力欄
    func testBarStartsAsAnAskButtonAndSwitchesToSelectingAndBack() {
        let bar = TimetableAskBar(frame: CGRect(x: 0, y: 0, width: 358, height: 48))
        XCTAssertEqual(bar.mode, .idle)
        XCTAssertEqual(bar.accessibilityLabel, "AIに質問する")
        XCTAssertTrue(bar.accessibilityTraits.contains(.button))
        XCTAssertEqual(bar.accessibilityIdentifier, "timetable-ask-bar")
        bar.setMode(.selecting)
        XCTAssertEqual(bar.mode, .selecting)
        XCTAssertTrue(bar.accessibilityLabel?.contains("時間割から選んで") ?? false, "選ぶ状態では、何をすればよいかを読み上げる")
        XCTAssertTrue(bar.accessibilityHint?.contains("やめます") ?? false)
        bar.setMode(.idle)
        XCTAssertEqual(bar.accessibilityLabel, "AIに質問する")
    }

    func testBarSendsATapAndNudgeDoesNotBreakIt() {
        let bar = TimetableAskBar(frame: CGRect(x: 0, y: 0, width: 358, height: 48))
        final class Target: NSObject { var taps = 0; @objc func tapped() { taps += 1 } }
        let target = Target()
        bar.addTarget(target, action: #selector(Target.tapped), for: .touchUpInside)
        bar.sendActions(for: .touchUpInside)
        XCTAssertEqual(target.taps, 1)
        bar.nudge()
        XCTAssertNotNil(bar.layer.animation(forKey: "nudge"))
        bar.sendActions(for: .touchUpInside)
        XCTAssertEqual(target.taps, 2)
    }

    func testBarFitsInOneLineOnAnIdleScreenAndTwoWhenSelecting() {
        let bar = TimetableAskBar(frame: CGRect(x: 0, y: 0, width: 358, height: 48))
        bar.layoutIfNeeded()
        func labels(_ view: UIView) -> [UILabel] { view.subviews.flatMap { ($0 as? UILabel).map { [$0] } ?? [] + labels($0) } }
        let label = labels(bar).first
        XCTAssertEqual(label?.text, "AIに質問する")
        bar.setMode(.selecting); bar.layoutIfNeeded()
        XCTAssertTrue(label?.text?.contains("コマ") ?? false)
        XCTAssertLessThanOrEqual(label?.numberOfLines ?? 9, 2, "長い案内文は、2行まで(幅が狭い画面でも、バーからはみ出さない)")
    }
}
