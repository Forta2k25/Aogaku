import UIKit
import FirebaseRemoteConfig

/// Only retrieval text and measured usage; never renders provider JSON / raw responses.
@MainActor
final class AIDetectionResultView: UIStackView {
    private let body = UITextView(), detail = UILabel(), pipeline = UILabel(), tokens = UILabel(), cost = UILabel(), routes = UILabel(), diagnostics = UITextView()
    let selector = UIButton(type: .system), retryButton = UIButton(type: .system)
    private let metadataButton = UIButton(type: .system)
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
        for label in [pipeline, detail, tokens, cost] { label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabel; label.numberOfLines = 0; addArrangedSubview(label) }
        pipeline.accessibilityIdentifier = "ai-detection-pipeline"
        tokens.accessibilityIdentifier = "ai-detection-tokens"; cost.accessibilityIdentifier = "ai-detection-cost"
        routes.font = .systemFont(ofSize: 12); routes.numberOfLines = 0; routes.accessibilityIdentifier = "ai-routing-summary"; addArrangedSubview(routes)
        diagnostics.font = .monospacedSystemFont(ofSize: 11, weight: .regular); diagnostics.isEditable = false
        diagnostics.heightAnchor.constraint(equalToConstant: 160).isActive = true; diagnostics.accessibilityIdentifier = "ai-routing-diagnostics"; diagnostics.isHidden = true; addArrangedSubview(diagnostics)
        metadataButton.setTitle("ページ別処理情報", for: .normal); metadataButton.accessibilityIdentifier = "ai-routing-metadata-toggle"
        metadataButton.addTarget(self, action: #selector(toggleMetadata), for: .touchUpInside); metadataButton.isHidden = true; addArrangedSubview(metadataButton)
        retryButton.setTitle("再試行", for: .normal); addArrangedSubview(retryButton)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func showState(_ text: String, retry: Bool = false) {
        isHidden = false; body.text = text; detail.text = nil; pipeline.text = nil; tokens.text = nil; cost.text = nil; routes.text = nil; diagnostics.text = nil; diagnostics.isHidden = true; metadataButton.isHidden = true; retryButton.isHidden = !retry
    }
    func show(_ result: AIDetectionResult) {
        isHidden = false; body.text = result.text; detail.text = result.previewProgress == nil ? result.detail : "処理中。完了したページの本文を先に表示しています。"; pipeline.text = result.pipelineLabel; tokens.text = result.previewProgress == nil ? result.tokenSentence : "全体のusage / costは解析完了後に表示します。"
        // Optional display-only Remote Config rate; no fixed FX value or server billing conversion.
        let rate = AppBackend.isOffline ? nil : RemoteConfig.remoteConfig()["ai_recognition_usd_jpy"].numberValue.doubleValue
        cost.text = result.previewProgress == nil ? result.costSentence(usdJPY: rate) : nil
        if result.previewProgress == nil, let date = result.recognition?.pricingAsOf { cost.text = (cost.text ?? "") + "\n料金基準: \(date)・請求額ではありません。" }
        routes.text = result.previewProgress?.caption ?? result.routeSummary
        let diagnosticText = [result.routeDiagnostics, result.latency?.diagnosticText].compactMap { $0 }.joined(separator: "\n\n")
        metadataButton.isHidden = diagnosticText.isEmpty
        #if DEBUG
        diagnostics.text = diagnosticText; diagnostics.isHidden = diagnosticText.isEmpty
        #else
        diagnostics.text = diagnosticText; diagnostics.isHidden = ProcessInfo.processInfo.environment["AOGAKU_ROUTER_DIAGNOSTICS"] != "1" || diagnosticText.isEmpty
        #endif
        retryButton.isHidden = true
    }
    @objc private func toggleMetadata() { diagnostics.isHidden.toggle() }
    func clear() { body.text = nil; detail.text = nil; pipeline.text = nil; tokens.text = nil; cost.text = nil; routes.text = nil; diagnostics.text = nil; diagnostics.isHidden = true; metadataButton.isHidden = true; selector.menu = nil; isHidden = true }
#if DEBUG
    var displayedText: String { body.text ?? "" }
    var displayedDetail: String { detail.text ?? "" }
    var displayedPipeline: String { pipeline.text ?? "" }
#endif
}
