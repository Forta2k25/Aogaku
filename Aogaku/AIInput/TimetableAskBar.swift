import UIKit

/// 時間割の画面の下の、「AIに質問する」入力欄。押すだけの入力欄(文字は、チャット画面で打つ)。
/// 押すと、時間割から、聞きたい授業のコマを選ぶ状態(selecting)になる。もう一度押すか、右端の×で、やめられる。
final class TimetableAskBar: UIControl {
    enum Mode { case idle, selecting }

    private static let green = UIColor(red: 0.04, green: 0.42, blue: 0.28, alpha: 1)
    private static let darkGreen = UIColor(red: 0.04, green: 0.31, blue: 0.21, alpha: 1)
    private let iconView = UIImageView(image: UIImage(systemName: "sparkles"))
    private let label = UILabel()
    private let trailingIcon = UIImageView()
    private let trailingBackground = UIView()
    private(set) var mode: Mode = .idle

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 24
        layer.borderWidth = 1
        accessibilityIdentifier = "timetable-ask-bar"
        isAccessibilityElement = true
        accessibilityTraits = .button

        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        label.font = .systemFont(ofSize: 16)
        label.numberOfLines = 2
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.85
        trailingBackground.layer.cornerRadius = 16
        trailingBackground.isUserInteractionEnabled = false
        trailingIcon.contentMode = .scaleAspectFit
        trailingBackground.addSubview(trailingIcon)
        [iconView, label, trailingBackground].forEach { $0.isUserInteractionEnabled = false; $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        trailingIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20), iconView.heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingBackground.leadingAnchor, constant: -8),
            trailingBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trailingBackground.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingBackground.widthAnchor.constraint(equalToConstant: 32), trailingBackground.heightAnchor.constraint(equalToConstant: 32),
            trailingIcon.centerXAnchor.constraint(equalTo: trailingBackground.centerXAnchor),
            trailingIcon.centerYAnchor.constraint(equalTo: trailingBackground.centerYAnchor),
            trailingIcon.widthAnchor.constraint(equalToConstant: 16), trailingIcon.heightAnchor.constraint(equalToConstant: 16)
        ])
        apply()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setMode(_ newMode: Mode) { mode = newMode; apply() }

    private func apply() {
        switch mode {
        case .idle:
            backgroundColor = .systemBackground
            layer.borderColor = UIColor.separator.cgColor
            iconView.tintColor = Self.green
            label.text = "AIに質問する"
            label.textColor = .secondaryLabel
            trailingBackground.backgroundColor = Self.green
            trailingIcon.image = UIImage(systemName: "arrow.up")
            trailingIcon.tintColor = .white
            accessibilityLabel = "AIに質問する"
            accessibilityHint = "押すと、時間割から、聞きたい授業を選べます"
        case .selecting:
            backgroundColor = UIColor(red: 0.89, green: 0.94, blue: 0.91, alpha: 1)
            layer.borderColor = Self.green.cgColor
            iconView.tintColor = Self.darkGreen
            label.text = "聞きたい授業のコマを選んでください"
            label.textColor = Self.darkGreen
            trailingBackground.backgroundColor = .clear
            trailingIcon.image = UIImage(systemName: "xmark.circle.fill")
            trailingIcon.tintColor = Self.darkGreen
            accessibilityLabel = "聞きたい授業のコマを、時間割から選んでください"
            accessibilityHint = "押すと、選ぶのをやめます"
        }
    }

    /// 授業が無いマスを押したときなど、「そこではない」ことを、小さく揺れて伝える。
    func nudge() {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -6, 6, -4, 4, 0]; animation.duration = 0.3
        layer.add(animation, forKey: "nudge")
    }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.7 : 1 } }
}
