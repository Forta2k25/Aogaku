import XCTest
import UIKit
@testable import Aogaku

@MainActor final class AISuggestionLayoutTests: XCTestCase {
    private func allButtons(in view: UIView) -> [UIView] {
        var found: [UIView] = []
        func walk(_ v: UIView) { if v.accessibilityIdentifier == "ai-suggestion" { found.append(v) }; v.subviews.forEach(walk) }
        walk(view); return found
    }

    func testLongSuggestionsStayInsideTheBubbleWidth() {
        let width: CGFloat = 340
        // 実際の画面と同じように、吹き出しの幅は外から(画面の幅で)決まる。
        let host = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 800))
        let bubble = AIReplyBubbleView()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(bubble)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: host.topAnchor),
            bubble.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bubble.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        bubble.showReply("平常点と試験が50%ずつの配分になっています。", metrics: nil, usdJPY: nil)
        bubble.setSuggestions(["別のスライドも解説して", "この記号の意味をもっと詳しく、日常の例えを使って教えてください", "問2も解いて"])
        host.layoutIfNeeded()
        let buttons = allButtons(in: host)
        XCTAssertEqual(buttons.count, 3)
        for button in buttons {
            let frame = button.convert(button.bounds, to: host)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "左で見切れない")
            XCTAssertLessThanOrEqual(frame.maxX, width + 0.5, "右で見切れない: \(frame)")
            XCTAssertGreaterThanOrEqual(button.bounds.height, 30)
        }
        XCTAssertGreaterThan(buttons[1].bounds.height, buttons[0].bounds.height, "長い候補は折り返して高くなる")
    }

    func testShortSuggestionsSitSideBySideInOneRow() {
        let width: CGFloat = 340
        let host = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 800))
        let bubble = AIReplyBubbleView()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(bubble)
        NSLayoutConstraint.activate([bubble.topAnchor.constraint(equalTo: host.topAnchor), bubble.leadingAnchor.constraint(equalTo: host.leadingAnchor), bubble.trailingAnchor.constraint(equalTo: host.trailingAnchor)])
        bubble.showReply("答えです。", metrics: nil, usdJPY: nil)
        bubble.setSuggestions(["途中式だけ", "問2も解いて", "類題を出して"])
        host.layoutIfNeeded()
        let chips = allButtons(in: host).sorted { $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX }
        XCTAssertEqual(chips.count, 3)
        let frames = chips.map { $0.convert($0.bounds, to: host) }
        XCTAssertEqual(Set(frames.map { $0.minY.rounded() }).count, 1, "短い候補は、横に1列に並ぶ(縦に積まない)")
        XCTAssertTrue(zip(frames, frames.dropFirst()).allSatisfy { $0.maxX < $1.minX }, "左から順に、重ならず並ぶ")
        XCTAssertLessThanOrEqual(frames.last!.maxX, width + 0.5)
    }

    func testWhenTheRowIsFullTheNextChipWrapsToTheNextRowInsteadOfBeingCut() {
        let width: CGFloat = 300
        let host = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 800))
        let bubble = AIReplyBubbleView()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(bubble)
        NSLayoutConstraint.activate([bubble.topAnchor.constraint(equalTo: host.topAnchor), bubble.leadingAnchor.constraint(equalTo: host.leadingAnchor), bubble.trailingAnchor.constraint(equalTo: host.trailingAnchor)])
        bubble.showReply("答えです。", metrics: nil, usdJPY: nil)
        bubble.setSuggestions(["この式の意味を日常の例えで教えて", "Show me a similar exercise please", "問2"])
        host.layoutIfNeeded()
        let frames = allButtons(in: host).map { $0.convert($0.bounds, to: host) }
        XCTAssertEqual(frames.count, 3)
        XCTAssertTrue(frames.allSatisfy { $0.minX >= -0.5 && $0.maxX <= width + 0.5 }, "どれも、端で切れない: \(frames)")
        XCTAssertGreaterThan(Set(frames.map { $0.minY.rounded() }).count, 1, "入りきらないものは、次の行へ折り返す")
    }
}
