//
//  DonutChartView.swift
//  Aogaku
//
//  Created by shu m on 2025/08/31.
//
// DonutChartView.swift
import UIKit

public final class DonutChartView: UIView {

    public struct Ring {
        public let required: CGFloat   // そのカテゴリの必要単位
        public let got: CGFloat        // 取得済み
        public let bgColor: UIColor    // 薄い下地の色
        public let fgColor: UIColor    // 実績（濃い）色
        public let name: String        // 任意（凡例用など）

        public init(required: CGFloat, got: CGFloat, bgColor: UIColor, fgColor: UIColor, name: String) {
            self.required = required
            self.got = got
            self.bgColor = bgColor
            self.fgColor = fgColor
            self.name = name
        }
    }

    // 中央テキスト（大・小）
    public let centerBig = UILabel()
    public let centerSmall = UILabel()

    public var totalRequired: CGFloat = 0 { didSet { setNeedsLayout() } }
    public var rings: [Ring] = [] { didSet { setNeedsLayout() } }

    // 見た目パラメータ
    private let startAngle: CGFloat = -.pi/2   // 上から時計回り
    public var lineWidth: CGFloat = 26 { didSet { setNeedsLayout() } }
    public var gapAngle: CGFloat = 0 { didSet { setNeedsLayout() } }// 枠同士の隙間が欲しければここを増やす

    // ついでに“度”指定がしやすいヘルパーを追加しておくと便利
    public func setGap(degrees: CGFloat) {
        gapAngle = degrees * .pi / 180
    }
    

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        setupLabels()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isOpaque = false
        setupLabels()
    }

    private func setupLabels() {
        [centerBig, centerSmall].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        centerBig.font = UIFont.systemFont(ofSize: 48, weight: .black)
        centerBig.textColor = .label
        centerBig.textAlignment = .center
        centerBig.adjustsFontSizeToFitWidth = true
        centerBig.minimumScaleFactor = 0.5

        centerSmall.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        centerSmall.textColor = .secondaryLabel
        centerSmall.textAlignment = .center

        NSLayoutConstraint.activate([
            centerBig.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerBig.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),

            centerSmall.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerSmall.topAnchor.constraint(equalTo: centerBig.bottomAnchor, constant: 8)
        ])
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        drawDonut()
    }

    private func drawDonut() {
        assert(Thread.isMainThread)

        // 既存の描画を安全にクリア（走査しながら消さない）
        let copy = (layer.sublayers ?? []).filter { $0.name == "donut-arc" }
        copy.forEach { $0.removeFromSuperlayer() }

        guard totalRequired > 0, !rings.isEmpty else { return }

        let rect = bounds.insetBy(dx: 6, dy: 6)
        let radius = min(rect.width, rect.height)/2 - lineWidth/2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        var angle = startAngle

        for r in rings {
            let req = max(0, r.required)
            let got = min(max(0, r.got), req)

            let reqRatio = req / totalRequired
            let gotRatio = (req > 0) ? (got / totalRequired) : 0

            let reqSweep = max(0.0001, (2 * .pi - gapAngle * CGFloat(rings.count)) * reqRatio)
            let gotSweep = max(0, min(reqSweep, (2 * .pi - gapAngle * CGFloat(rings.count)) * gotRatio))

            // 下地（必要枠）
            let bg = shapeLayer(center: center, radius: radius, start: angle, sweep: reqSweep, color: r.bgColor.withAlphaComponent(0.25))
            layer.addSublayer(bg)

            // 実績
            if gotSweep > 0 {
                let fg = shapeLayer(center: center, radius: radius, start: angle, sweep: gotSweep, color: r.fgColor)
                layer.addSublayer(fg)
            }

            angle += reqSweep + gapAngle
        }
    }

    private func shapeLayer(center: CGPoint, radius: CGFloat, start: CGFloat, sweep: CGFloat, color: UIColor) -> CAShapeLayer {
        let path = UIBezierPath(arcCenter: center,
                                radius: radius,
                                startAngle: start,
                                endAngle: start + sweep,
                                clockwise: true)
        let s = CAShapeLayer()
        s.name = "donut-arc"
        s.path = path.cgPath
        s.fillColor = UIColor.clear.cgColor
        s.strokeColor = color.cgColor
        s.lineWidth = lineWidth
        s.lineCap = .round
        return s
    }
}
