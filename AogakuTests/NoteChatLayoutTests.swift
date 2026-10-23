import XCTest
@testable import Aogaku

final class NoteChatLayoutTests: XCTestCase {
    func testInsetCoversTheSafeAreaWhenThereIsNoAdAndNoKeyboard() {
        // 広告もキーボードも無いとき、入力バーは、ホームバーの安全領域(34)の上、8に置かれる。余白は、そのぶんを含む。
        let inset = NoteChatLayout.bottomInset(adHeight: 0, keyboardOverlap: 0, safeAreaBottom: 34, barHeight: 46, barVisible: true)
        XCTAssertEqual(inset, 34 + 8 + 46 + 12)
    }
    func testInsetWithAnAdOnlyAddsTheGapBetweenAdAndBar() {
        // 広告(60)が安全領域より高いとき、メッセージ欄は、広告の上端まで。入力バーは、そのすぐ上(8)。広告の高さは、二重に数えない。
        let inset = NoteChatLayout.bottomInset(adHeight: 60, keyboardOverlap: 0, safeAreaBottom: 34, barHeight: 46, barVisible: true)
        XCTAssertEqual(inset, 8 + 46 + 12)
    }
    func testInsetFollowsTheKeyboardAndTheGrowingInputBar() {
        let oneLine = NoteChatLayout.bottomInset(adHeight: 0, keyboardOverlap: 336, safeAreaBottom: 34, barHeight: 46, barVisible: true)
        XCTAssertEqual(oneLine, 336 + 8 + 46 + 12)
        let sixLines = NoteChatLayout.bottomInset(adHeight: 0, keyboardOverlap: 336, safeAreaBottom: 34, barHeight: 46 + 5 * 18, barVisible: true)
        XCTAssertEqual(sixLines - oneLine, 5 * 18, "入力欄が広がったぶん、余白も増える")
        let withAd = NoteChatLayout.bottomInset(adHeight: 60, keyboardOverlap: 336, safeAreaBottom: 34, barHeight: 46, barVisible: true)
        XCTAssertEqual(withAd, (336 - 60) + 8 + 46 + 12, "キーボードが広告より高いとき、広告の分は、すでにメッセージ欄の外")
    }
    func testWithoutTheInputBarOnlyTheAdOrKeyboardCounts() {
        XCTAssertEqual(NoteChatLayout.bottomInset(adHeight: 60, keyboardOverlap: 0, safeAreaBottom: 34, barHeight: 46, barVisible: false), 60)
        XCTAssertEqual(NoteChatLayout.bottomInset(adHeight: 0, keyboardOverlap: 300, safeAreaBottom: 34, barHeight: 46, barVisible: false), 300)
    }
    func testTheLastMessageAlwaysEndsAboveTheBarWithAGap() {
        // どの条件でも、「余白 - 入力バーの上端までの距離」が、12(最新のメッセージとの間)になる。
        for (ad, keyboard) in [(0.0, 0.0), (60.0, 0.0), (0.0, 336.0), (60.0, 336.0), (90.0, 0.0)] as [(CGFloat, CGFloat)] {
            let bar: CGFloat = 80, safe: CGFloat = 34
            let inset = NoteChatLayout.bottomInset(adHeight: ad, keyboardOverlap: keyboard, safeAreaBottom: safe, barHeight: bar, barVisible: true)
            let barTopFromScreenBottom = max(ad, max(keyboard, safe)) + 8 + bar
            XCTAssertEqual(inset - (barTopFromScreenBottom - ad), 12, "ad=\(ad) keyboard=\(keyboard)")
        }
    }
}
