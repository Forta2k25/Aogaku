import UIKit

/// チャットの入力欄。改行でき、行が増えると、最大 maxLines 行まで、縦に広がる(それ以上は、中でスクロール)。
/// 以前の UITextField と同じ使い方(text / placeholder / addTarget(.editingChanged))ができる。
final class ChatInputTextView: UITextView {
    var placeholder: String? { didSet { placeholderLabel.text = placeholder } }
    /// 広がる最大の行数。
    var maxLines = 6
    /// 高さが変わったとき(入力欄の外の、余白の計算などを直す用)。
    var onHeightChange: (() -> Void)?

    private let placeholderLabel = UILabel()
    private var editingChangedTarget: (target: AnyObject, action: Selector)?
    private var lastHeight: CGFloat = 0
    private static let verticalInset: CGFloat = 8

    override var text: String! { didSet { refresh() } }
    override var attributedText: NSAttributedString! { didSet { refresh() } }
    override var font: UIFont? { didSet { placeholderLabel.font = font; invalidateIntrinsicContentSize() } }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        backgroundColor = .clear
        textContainerInset = UIEdgeInsets(top: Self.verticalInset, left: 0, bottom: Self.verticalInset, right: 0)
        self.textContainer.lineFragmentPadding = 0
        isScrollEnabled = false
        alwaysBounceVertical = false
        showsVerticalScrollIndicator = false
        returnKeyType = .default   // 送信ボタンで送る。Return は、改行
        placeholderLabel.numberOfLines = 1
        placeholderLabel.textColor = .secondaryLabel   // 読める濃さ(薄いグレーにしない)
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(handleTextDidChange), name: UITextView.textDidChangeNotification, object: self)
    }
    convenience init() { self.init(frame: .zero, textContainer: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }

    /// UITextField の `addTarget(_:action:for: .editingChanged)` の代わり。
    func addTarget(_ target: Any?, action: Selector, for event: UIControl.Event) {
        guard event == .editingChanged, let target = target as AnyObject? else { return }
        editingChangedTarget = (target, action)
    }

    @objc private func handleTextDidChange() {
        refresh()
        if let editingChangedTarget { _ = editingChangedTarget.target.perform(editingChangedTarget.action) }
    }

    private var lineHeight: CGFloat { (font ?? .systemFont(ofSize: 15)).lineHeight }
    private var minHeight: CGFloat { ceil(lineHeight) + Self.verticalInset * 2 }
    private var maxHeight: CGFloat { ceil(lineHeight) * CGFloat(maxLines) + Self.verticalInset * 2 }

    private func refresh() {
        placeholderLabel.isHidden = !(text ?? "").isEmpty
        invalidateIntrinsicContentSize()
        let wanted = contentHeight()
        let scrolls = wanted > maxHeight + 0.5
        if isScrollEnabled != scrolls { isScrollEnabled = scrolls }
        let height = min(max(wanted, minHeight), maxHeight)
        if abs(height - lastHeight) > 0.5 { lastHeight = height; onHeightChange?() }
        if scrolls, selectedRange.location >= (text ?? "").utf16.count - 1 { scrollRangeToVisible(NSRange(location: (text ?? "").utf16.count, length: 0)) }
    }

    private func contentHeight() -> CGFloat {
        let width = bounds.width > 0 ? bounds.width : 240
        return ceil(sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: min(max(contentHeight(), minHeight), maxHeight))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 幅が決まったあとで、折り返しの行数が変わるので、高さを計算し直す。
        let height = min(max(contentHeight(), minHeight), maxHeight)
        if abs(height - lastHeight) > 0.5 { lastHeight = height; invalidateIntrinsicContentSize(); onHeightChange?() }
        let scrolls = contentHeight() > maxHeight + 0.5
        if isScrollEnabled != scrolls { isScrollEnabled = scrolls }
    }
}
