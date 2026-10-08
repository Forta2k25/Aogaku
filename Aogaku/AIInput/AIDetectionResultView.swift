import UIKit
import FirebaseRemoteConfig

/// Only retrieval text and measured usage; never renders provider JSON / raw responses.
@MainActor
final class AIDetectionResultView: UIStackView {
    private let body = UITextView(), detail = UILabel(), tokens = UILabel(), cost = UILabel()
    let selector = UIButton(type: .system), retryButton = UIButton(type: .system)
    override init(frame: CGRect) {
        super.init(frame: frame); axis = .vertical; spacing = 9; isHidden = true
        isLayoutMarginsRelativeArrangement = true; layoutMargins = UIEdgeInsets(top: 16, left: 14, bottom: 16, right: 14)
        backgroundColor = .secondarySystemBackground; layer.cornerRadius = 16
        accessibilityIdentifier = "ai-detection-result"
        let title = UILabel(); title.text = "検出結果"; title.font = .systemFont(ofSize: 16, weight: .semibold)
        addArrangedSubview(title)
        selector.contentHorizontalAlignment = .leading; selector.titleLabel?.font = .systemFont(ofSize: 12); selector.showsMenuAsPrimaryAction = true
        selector.accessibilityIdentifier = "ai-detection-source-selector"; addArrangedSubview(selector)
        body.font = .systemFont(ofSize: 15); body.isEditable = false; body.isSelectable = true
        body.backgroundColor = .clear; body.textContainerInset = .zero
        body.heightAnchor.constraint(equalToConstant: 210).isActive = true
        body.accessibilityIdentifier = "ai-detection-text"; addArrangedSubview(body)
        for label in [detail, tokens, cost] { label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabel; label.numberOfLines = 0; addArrangedSubview(label) }
        tokens.accessibilityIdentifier = "ai-detection-tokens"; cost.accessibilityIdentifier = "ai-detection-cost"
        retryButton.setTitle("再試行", for: .normal); addArrangedSubview(retryButton)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func showState(_ text: String, retry: Bool = false) {
        isHidden = false; body.text = text; detail.text = nil; tokens.text = nil; cost.text = nil; retryButton.isHidden = !retry
    }
    func show(_ result: AIDetectionResult) {
        isHidden = false; body.text = result.text; detail.text = result.detail; tokens.text = result.tokenSentence
        // Optional display-only Remote Config rate; no fixed FX value or server billing conversion.
        let rate = AppBackend.isOffline ? nil : RemoteConfig.remoteConfig()["ai_recognition_usd_jpy"].numberValue.doubleValue
        cost.text = result.costSentence(usdJPY: rate)
        if let date = result.recognition?.pricingAsOf { cost.text = (cost.text ?? "") + "\n料金基準: \(date)・請求額ではありません。" }
        retryButton.isHidden = true
    }
    func clear() { body.text = nil; detail.text = nil; tokens.text = nil; cost.text = nil; selector.menu = nil; isHidden = true }
#if DEBUG
    var displayedText: String { body.text ?? "" }
    var displayedDetail: String { detail.text ?? "" }
#endif
}
