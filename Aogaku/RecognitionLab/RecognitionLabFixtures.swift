#if DEBUG
import UIKit

enum RecognitionLabFixtures {
    enum Kind: String, CaseIterable { case slide = "普通のスライド", handwriting = "手書き注記", arrow = "矢印", enclosure = "囲み", diagram = "図＋テキスト" }
    static func image(_ kind: Kind) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 700)).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1000, height: 700))
            func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat = 38, _ color: UIColor = .black) {
                (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: size), .foregroundColor: color])
            }
            text("Recognition Lab・架空の講義資料", 50, 40, 36)
            switch kind {
            case .slide: text("遺伝の基礎", 80, 150); text("親から子へ特徴が伝わる", 80, 250); text("授業の重要語：親、子、遺伝", 80, 360)
            case .handwriting:
                text("細胞の構造", 80, 160); text("核：遺伝情報", 80, 270)
                ("ここが重要！" as NSString).draw(at: CGPoint(x: 510, y: 350), withAttributes: [.font: UIFont(name: "MarkerFelt-Wide", size: 40) ?? .italicSystemFont(ofSize: 40), .foregroundColor: UIColor.systemRed])
            case .arrow, .diagram:
                text("親", 170, 220, 64); text("子", 730, 220, 64); text("遺伝", 450, 360, 44)
                ctx.cgContext.setStrokeColor(UIColor.black.cgColor); ctx.cgContext.setLineWidth(6)
                ctx.cgContext.move(to: CGPoint(x: 270, y: 265)); ctx.cgContext.addLine(to: CGPoint(x: 690, y: 265)); ctx.cgContext.addLines(between: [CGPoint(x: 650, y: 240), CGPoint(x: 690, y: 265), CGPoint(x: 650, y: 290)])
                ctx.cgContext.move(to: CGPoint(x: 500, y: 345)); ctx.cgContext.addLine(to: CGPoint(x: 500, y: 275)); ctx.cgContext.addLines(between: [CGPoint(x: 480, y: 300), CGPoint(x: 500, y: 275), CGPoint(x: 520, y: 300)]); ctx.cgContext.strokePath()
                if kind == .diagram { ctx.cgContext.strokeEllipse(in: CGRect(x: 135, y: 195, width: 125, height: 140)); ctx.cgContext.strokeEllipse(in: CGRect(x: 700, y: 195, width: 125, height: 140)); text("矢印のラベルを関係として読む", 150, 500, 34) }
            case .enclosure:
                text("植物", 140, 240); text("動物", 490, 240); text("生物", 330, 150)
                ctx.cgContext.setStrokeColor(UIColor.black.cgColor); ctx.cgContext.setLineWidth(4); ctx.cgContext.stroke(CGRect(x: 100, y: 200, width: 640, height: 140))
                text("囲みは同じグループを表す", 100, 440, 34)
            }
        }
    }
}
#endif
