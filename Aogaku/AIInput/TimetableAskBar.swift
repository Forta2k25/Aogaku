import UIKit

/// 時間割の画面の下の、「AIに質問する」入力欄。押すだけの入力欄(文字は、チャット画面で打つ)。
/// 押すと、時間割から、聞きたい授業のコマを選ぶ状態(selecting)になる。もう一度押すか、右端の×で、やめられる。
final class TimetableAskBar: UIControl {
    enum Mode { case idle, selecting }

    private static let green = UIColor(red: 0.04, green: 0.42, blue: 0.28, alpha: 1)
    private static let darkGreen = UIColor(red: 0.04, green: 0.31, blue: 0.21, alpha: 1)
    private let iconView = UIImageView(image: UIImage(systemName: "sparkles"))
    private let label = UILabel()
    private let nextLabel = UILabel()      // 文字が入れ替わるとき、上から入ってくる次の文字
    private let hintClip = UIView()        // 文字が動く範囲(バーの中だけ。外にははみ出さない)
    private let trailingIcon = UIImageView()
    private let trailingBackground = UIView()
    private(set) var mode: Mode = .idle
    private static let hints = ["リアぺ書いて", "問題解いて", "授業解説して", "小テスト作って", "授業の評価方法は？"]
    private var hintIndex = 0
    private var hintTimer: Timer?

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
        label.clipsToBounds = true   // 文字が入れ替わる動きが、はみ出さないように
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.85
        trailingBackground.layer.cornerRadius = 16
        trailingBackground.isUserInteractionEnabled = false
        trailingIcon.contentMode = .scaleAspectFit
        trailingBackground.addSubview(trailingIcon)
        [iconView, hintClip, trailingBackground].forEach { $0.isUserInteractionEnabled = false; $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        trailingIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20), iconView.heightAnchor.constraint(equalToConstant: 20),
            hintClip.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            hintClip.topAnchor.constraint(equalTo: topAnchor),
            hintClip.bottomAnchor.constraint(equalTo: bottomAnchor),
            hintClip.trailingAnchor.constraint(equalTo: trailingBackground.leadingAnchor, constant: -8),
            trailingBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trailingBackground.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingBackground.widthAnchor.constraint(equalToConstant: 32), trailingBackground.heightAnchor.constraint(equalToConstant: 32),
            trailingIcon.centerXAnchor.constraint(equalTo: trailingBackground.centerXAnchor),
            trailingIcon.centerYAnchor.constraint(equalTo: trailingBackground.centerYAnchor),
            trailingIcon.widthAnchor.constraint(equalToConstant: 16), trailingIcon.heightAnchor.constraint(equalToConstant: 16)
        ])
        hintClip.clipsToBounds = true
        [label, nextLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            hintClip.addSubview($0)
            NSLayoutConstraint.activate([
                $0.leadingAnchor.constraint(equalTo: hintClip.leadingAnchor),
                $0.trailingAnchor.constraint(equalTo: hintClip.trailingAnchor),
                $0.centerYAnchor.constraint(equalTo: hintClip.centerYAnchor)
            ])
        }
        nextLabel.font = label.font
        nextLabel.numberOfLines = label.numberOfLines
        nextLabel.alpha = 0
        apply()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setMode(_ newMode: Mode) { mode = newMode; apply(); updateHintTimer() }

    /// 押す前は、2秒ごとに、聞けることの例を入れ替えて見せる。
    private func updateHintTimer() {
        hintTimer?.invalidate(); hintTimer = nil
        guard mode == .idle, window != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        hintTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.mode == .idle else { return }
            self.hintIndex = (self.hintIndex + 1) % Self.hints.count
            // 新しい文字が上から入ってきて、前の文字が下へ出ていく(バーの高さぶん動くので、間が十分にあく)。
            let distance = max(self.hintClip.bounds.height, 40)
            self.nextLabel.text = Self.hints[self.hintIndex]
            self.nextLabel.textColor = self.label.textColor
            self.nextLabel.alpha = 1
            self.nextLabel.transform = CGAffineTransform(translationX: 0, y: -distance)
            UIView.animate(withDuration: 0.45, delay: 0, options: .curveEaseInOut, animations: {
                self.label.transform = CGAffineTransform(translationX: 0, y: distance)
                self.nextLabel.transform = .identity
            }, completion: { _ in
                self.label.text = Self.hints[self.hintIndex]
                self.label.transform = .identity
                self.nextLabel.alpha = 0
            })
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateHintTimer()
    }

    private func apply() {
        switch mode {
        case .idle:
            backgroundColor = .systemBackground
            layer.borderColor = UIColor.separator.cgColor
            iconView.tintColor = Self.green
            label.text = Self.hints[hintIndex]
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
