import XCTest
import UIKit
@testable import Aogaku

/// 返信の数式(LaTeX)表示と、日本語に接した太字の表示を確かめる。
@MainActor final class MathTypesettingTests: XCTestCase {
    private func attachmentCount(_ s: NSAttributedString) -> Int {
        var n = 0
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { v, _, _ in if v != nil { n += 1 } }
        return n
    }
    private func isBold(_ s: NSAttributedString, _ needle: String) -> Bool {
        let range = (s.string as NSString).range(of: needle)
        guard range.location != NSNotFound, let font = s.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.traitBold)
    }

    func testInlineAndDisplayMathBecomeImages() {
        let text = "偏微分は $\\frac{\\partial L}{\\partial x} = 0$ です。\n\n$$L = f(x) + \\sum_{j=1}^{k} \\lambda_j [m_j - g_j(x)]$$\n\n以上。"
        let out = AIReplyBubbleView.markdown(text)
        XCTAssertEqual(attachmentCount(out), 2)
        XCTAssertFalse(out.string.contains("$"))
        XCTAssertFalse(out.string.contains("\\frac"))
        XCTAssertTrue(out.string.contains("です。"))
    }

    func testUnderscoresInsideMathAreNotItalicisedAndOutsideTextSurvives() {
        let out = AIReplyBubbleView.markdown("$x_1$ と $y_2$ と snake_case_name")
        XCTAssertEqual(attachmentCount(out), 2)
        XCTAssertTrue(out.string.contains("snake_case_name"))
    }

    func testCurrencyAndUnfinishedMathStayPlainText() {
        let out = AIReplyBubbleView.markdown("価格は $5 と $10 です。書きかけの $\\frac{a")
        XCTAssertEqual(attachmentCount(out), 0)
        XCTAssertTrue(out.string.contains("$5 と $10"))
    }

    func testInvalidLatexFallsBackToOriginalText() {
        let out = AIReplyBubbleView.markdown("これは $\\notacommand{$ です")
        XCTAssertTrue(out.string.contains("$") || attachmentCount(out) == 1)
    }

    func testBoldNextToJapaneseQuotesIsBold() {
        let out = AIReplyBubbleView.markdown("経済学では**「シャドウプライス(影の価格)」**と呼ばれます。")
        XCTAssertFalse(out.string.contains("*"))
        XCTAssertTrue(isBold(out, "シャドウプライス"))
        XCTAssertFalse(isBold(out, "と呼ばれます"))
    }

    func testHeadingAndPlainBoldStillWork() {
        let out = AIReplyBubbleView.markdown("## 見出し\n本文は**強調**です")
        XCTAssertFalse(out.string.contains("#"))
        XCTAssertTrue(isBold(out, "見出し"))
        XCTAssertTrue(isBold(out, "強調"))
        XCTAssertFalse(isBold(out, "本文は"))
    }

    func testCommonMacrosUnknownToSwiftMathAreNormalised() {
        let out = AIReplyBubbleView.markdown("$f(x_1, \\dots, x_n)$ と $\\boldsymbol{x}$ と $\\operatorname{argmax}_x f$")
        XCTAssertEqual(attachmentCount(out), 3)
    }

    func testBulletsBecomeDotsButHorizontalRulesAndBoldStarsDoNot() {
        let out = AIReplyBubbleView.markdown("* 一つ目\n- 二つ目\n  * 入れ子\n\n---\n**太字**")
        XCTAssertTrue(out.string.contains("• 一つ目"))
        XCTAssertTrue(out.string.contains("• 二つ目"))
        XCTAssertTrue(out.string.contains("  • 入れ子"))
        XCTAssertFalse(out.string.contains("---"))
        XCTAssertTrue(isBold(out, "太字"))
    }

    func testWideDisplayFormulaIsScaledToFit() {
        let out = AIReplyBubbleView.markdown("$$a_1 + a_2 + a_3 + a_4 + a_5 + a_6 + a_7 + a_8 + a_9 + a_{10} + a_{11} + a_{12} + a_{13} + a_{14} + a_{15} + a_{16} + a_{17} + a_{18}$$")
        var width: CGFloat = 0
        out.enumerateAttribute(.attachment, in: NSRange(location: 0, length: out.length)) { v, _, _ in width = (v as? NSTextAttachment)?.bounds.width ?? width }
        XCTAssertGreaterThan(width, 0)
        XCTAssertLessThanOrEqual(width, UIScreen.main.bounds.width)
    }

    func testStreamingHidesOnlyUnclosedMath() {
        XCTAssertEqual(AIReplyBubbleView.hidingOpenMath("答えは $x$ です"), "答えは $x$ です")
        XCTAssertEqual(AIReplyBubbleView.hidingOpenMath("まず\n$$\\sqrt{0} \\le"), "まず")
        XCTAssertEqual(AIReplyBubbleView.hidingOpenMath("閉じた $$a=b$$ のあと $y = "), "閉じた $$a=b$$ のあと")
        XCTAssertEqual(AIReplyBubbleView.hidingOpenMath("式 $$a=b$$ 完了"), "式 $$a=b$$ 完了")
        XCTAssertEqual(AIReplyBubbleView.hidingOpenMath("数式なし"), "数式なし")
    }
}
