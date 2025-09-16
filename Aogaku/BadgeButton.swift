import UIKit

final class BadgeButton: UIButton {
    private let dot = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame); configure()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder); configure()
    }

    private func configure() {
        setImage(UIImage(systemName: "bell"), for: .normal)
        contentEdgeInsets = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)

        dot.backgroundColor = .systemRed
        dot.isUserInteractionEnabled = false
        dot.isHidden = true
        addSubview(dot)
        // 円形は layoutSubviews でサイズ確定後に設定
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s: CGFloat = 10
        // 右上に小さな赤丸を配置（AutoLayout不使用）
        dot.frame = CGRect(x: bounds.width - s - 2, y: 2, width: s, height: s)
        dot.layer.cornerRadius = s / 2
    }

    func setBadgeVisible(_ visible: Bool) {
        dot.isHidden = !visible
    }
}
