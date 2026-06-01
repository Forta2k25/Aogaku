
//
//  Created by shu m on 2025/08/31.
//
//
//  DonutChartView.swift
//  Aogaku

/// ドーナツ（円環）
/// - セグメントごとに「必修総量(required)」を確保し、その弧の中で
///   ・濃い色: earned（取得済み）
///   ・薄い色: planned（今学期の取得予定）
///   を内側から順に描画します。全体のグレーは「未取得」。//
//  DonutChartView.swift
//  Aogaku
//
import UIKit

public struct DonutSegment {
    public let color: UIColor
    public let earned: CGFloat   // 取得済み
    public let planned: CGFloat  // 今期予定
    public let required: CGFloat // そのカテゴリーの必要数
    public init(color: UIColor, earned: CGFloat, planned: CGFloat, required: CGFloat) {
        self.color = color
        self.earned = earned
        self.planned = planned
        self.required = required
    }
}

/// 中央が空いたドーナツ。required を基準に「薄=planned」「濃=earned」を描画。
public final class DonutChartView: UIView {
    public var lineWidth: CGFloat = 24
    private var segments: [DonutSegment] = []

    // MARK: - Animation
    private var animProgress: CGFloat = 0.0          // 0 → 1 でアニメーション倍率
    private var displayLink: CADisplayLink?
    private var animStartTime: CFTimeInterval = 0
    private var animDuration: CFTimeInterval = 1.0

    public func configure(segments: [DonutSegment]) {
        self.segments = segments
        setNeedsDisplay()
    }

    /// earned / planned を 0 から現在値まで伸ばすアニメーションを開始する。
    public func animateIn(duration: TimeInterval = 1.0) {
        displayLink?.invalidate()
        animProgress = 0
        animDuration = duration
        animStartTime = CACurrentMediaTime()
        setNeedsDisplay()
        let link = CADisplayLink(target: self, selector: #selector(tickAnimation))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tickAnimation() {
        let elapsed = CACurrentMediaTime() - animStartTime
        let t = min(elapsed / animDuration, 1.0)
        // ease-out cubic
        animProgress = 1 - pow(1 - CGFloat(t), 3)
        setNeedsDisplay()
        if t >= 1.0 {
            displayLink?.invalidate()
            displayLink = nil
            animProgress = 1.0
        }
    }
    // 追加: 透過
    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    private func commonInit() {
        backgroundColor = .clear     // 背景透過
        isOpaque = false             // 透過を有効化
    }
    private func makeShapeLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor   // 塗りつぶし無し
        layer.lineCap = .round
        return layer
    }

    public override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        // 背景の灰リング
        let size = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = (size - lineWidth) / 2.0
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.butt)
        UIColor.systemGray5.setStroke()
        ctx.addArc(center: center,
                   radius: radius,
                   startAngle: -.pi/2,
                   endAngle: 1.5 * .pi,
                   clockwise: false)
        ctx.strokePath()

        let totalRequired = segments.reduce(0) { $0 + max($1.required, 0) }
        guard totalRequired > 0 else { return }

        ctx.setLineCap(.butt)
        var start: CGFloat = -CGFloat.pi / 2

        for seg in segments {
            // required に対する比率
            let sweep = (seg.required / totalRequired) * 2 * .pi
            guard sweep.isFinite, sweep > 0 else { continue }

            // アニメーション倍率を掛けた値で描画
            let earnedA  = seg.earned  * animProgress
            let plannedA = seg.planned * animProgress

            // 予定（薄）
            let plannedRatio = seg.required == 0 ? 0 : min(1, (earnedA + plannedA) / seg.required)
            if plannedRatio > 0 {
                let end = start + sweep * plannedRatio
                seg.color.withAlphaComponent(0.35).setStroke()
                ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
                ctx.strokePath()
            }

            // 取得済み（濃）
            let earnedRatio = seg.required == 0 ? 0 : min(1, earnedA / seg.required)
            if earnedRatio > 0 {
                let end = start + sweep * earnedRatio
                seg.color.setStroke()
                ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
                ctx.strokePath()
            }

            start += sweep
        }
    }
}



