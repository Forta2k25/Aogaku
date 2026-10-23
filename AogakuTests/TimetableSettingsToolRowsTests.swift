import XCTest
import UIKit
@testable import Aogaku

@MainActor
final class TimetableSettingsToolRowsTests: XCTestCase {
    func testSettingsToolRowsAreCreditsAndCalendar() {
        final class Target: NSObject { var taps: [String] = []; @objc func a() { taps.append("a") }; @objc func b() { taps.append("b") } }
        let target = Target()
        let rows = [TimetableSettingsViewController.toolRow(symbol: "graduationcap", title: "単位", subtitle: "s", target: target, action: #selector(Target.a)),
                    TimetableSettingsViewController.toolRow(symbol: "calendar", title: "学事暦", subtitle: "s", target: target, action: #selector(Target.b))]
        XCTAssertEqual(rows.map(\.accessibilityIdentifier), ["timetable-settings-graduationcap", "timetable-settings-calendar"])
        rows.compactMap { $0 as? UIButton }.forEach { $0.sendActions(for: .touchUpInside) }
        XCTAssertEqual(target.taps, ["a", "b"], "それぞれ、別の動作につながっている")
        XCTAssertEqual((rows[0] as? UIButton)?.configuration?.title, "単位")
    }
}
