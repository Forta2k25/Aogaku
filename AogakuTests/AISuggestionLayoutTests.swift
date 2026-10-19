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
}
