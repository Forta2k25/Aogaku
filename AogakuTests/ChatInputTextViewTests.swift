import XCTest
import UIKit
@testable import Aogaku

@MainActor
final class ChatInputTextViewTests: XCTestCase {
    private final class Target: NSObject { var count = 0; @objc func changed() { count += 1 } }

    private var windows: [UIWindow] = []
    /// 実際の画面と同じように、ウィンドウの中に置く(ウィンドウの外では、中身の大きさの変化が、レイアウトに伝わらない)。
    private func makeView(width: CGFloat = 280) -> (host: UIView, field: ChatInputTextView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 600))
        windows.append(window)
        let host = UIView(frame: window.bounds)
        window.addSubview(host); window.isHidden = false
        let field = ChatInputTextView()
        field.font = .systemFont(ofSize: 15)
        field.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(field)
        NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: host.leadingAnchor), field.trailingAnchor.constraint(equalTo: host.trailingAnchor), field.topAnchor.constraint(equalTo: host.topAnchor)])
        host.layoutIfNeeded()
        return (host, field)
    }

    func testGrowsWithNewlinesAndStopsAtTheMaximumNumberOfLines() {
        let (host, field) = makeView()
        let oneLine = field.bounds.height
        XCTAssertEqual(oneLine, ceil(UIFont.systemFont(ofSize: 15).lineHeight) + 16, accuracy: 1, "1行のときの高さ")
        field.text = "1行目\n2行目\n3行目"
        host.layoutIfNeeded()
        XCTAssertGreaterThan(field.bounds.height, oneLine + 30, "改行すると、広がる")
        XCTAssertFalse(field.isScrollEnabled)
        field.text = (1...20).map { "\($0)行目" }.joined(separator: "\n")
        host.layoutIfNeeded()
        let maxHeight = ceil(UIFont.systemFont(ofSize: 15).lineHeight) * 6 + 16
        XCTAssertEqual(field.bounds.height, maxHeight, accuracy: 1, "6行より上には、広がらない")
        XCTAssertTrue(field.isScrollEnabled, "それ以上は、中でスクロールする")
        field.text = ""
        host.layoutIfNeeded()
        XCTAssertEqual(field.bounds.height, oneLine, accuracy: 1, "空にすると、元の高さに戻る")
        XCTAssertFalse(field.isScrollEnabled)
    }

    func testLongTextWrapsIntoMoreLinesWithoutNewlines() {
        let (host, field) = makeView(width: 200)
        let oneLine = field.bounds.height
        field.text = String(repeating: "長い文章です。", count: 20)
        host.layoutIfNeeded()
        XCTAssertGreaterThan(field.bounds.height, oneLine * 2, "折り返しても、広がる")
    }

    func testPlaceholderShowsOnlyWhenEmpty() {
        let (_, field) = makeView()
        field.placeholder = "質問を書く"
        let label = field.subviews.compactMap { $0 as? UILabel }.first
        XCTAssertEqual(label?.text, "質問を書く")
        XCTAssertFalse(label?.isHidden ?? true)
        field.text = "あ"
        XCTAssertTrue(label?.isHidden ?? false)
        field.text = ""
        XCTAssertFalse(label?.isHidden ?? true)
    }

    func testEditingChangedTargetIsCalledWhenTheUserTypes() {
        let (_, field) = makeView()
        let target = Target()
        field.addTarget(target, action: #selector(Target.changed), for: .editingChanged)
        NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: field)
        XCTAssertEqual(target.count, 1)
        field.text = "プログラムからの変更では、呼ばない"   // 以前の UITextField と同じ
        XCTAssertEqual(target.count, 1)
    }

    func testReportsHeightChangesSoTheSurroundingLayoutCanFollow() {
        let (host, field) = makeView()
        var changes = 0
        field.onHeightChange = { changes += 1 }
        field.text = "1\n2\n3"
        host.layoutIfNeeded()
        XCTAssertGreaterThan(changes, 0)
        let before = changes
        field.text = "1\n2\n4"   // 行数が同じなら、通知しない
        host.layoutIfNeeded()
        XCTAssertEqual(changes, before)
    }

    func testReturnKeyInsertsANewlineInsteadOfSending() {
        XCTAssertEqual(ChatInputTextView().returnKeyType, .default)
    }
}
