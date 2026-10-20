import UIKit

/// 録音中、1分ごとに文字になった内容を、チャットの一番下に出すカード。録音を止めたあとは、「ノートを作っています」に変わる。
final class LiveTranscriptCardView: UIView {
    private let dot = UIView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let textLabel = UILabel()
    private static let visibleCharacters = 1200

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 14
        accessibilityIdentifier = "live-transcript-card"

        dot.backgroundColor = .systemRed
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8)])

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label
        let titleRow = UIStackView(arrangedSubviews: [dot, titleLabel, UIView()])
        titleRow.axis = .horizontal; titleRow.spacing = 8; titleRow.alignment = .center

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0

        textLabel.font = .systemFont(ofSize: 15)
        textLabel.textColor = .label
        textLabel.numberOfLines = 0

        let column = UIStackView(arrangedSubviews: [titleRow, statusLabel, textLabel])
        column.axis = .vertical; column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 状態を、表示に反映する。
    func update(session: LiveRecordingSession) {
        let recording = session.state == "recording"
        dot.isHidden = !recording
        titleLabel.text = recording ? "録音中の文字起こし" : "ノートを作っています…"
        let done = session.segments.filter { $0.status == "done" }
        let pending = session.segments.filter { $0.status == "pending" }.count
        let failed = session.segments.filter { $0.status == "failed" }.count
        let coveredMinutes = Int((done.map(\.endSeconds).max() ?? 0) / 60)
        var status = recording ? "1分ごとに、ここへ文字が増えていきます" : "文字起こしを仕上げて、ノートにまとめています"
        if coveredMinutes > 0 { status += " ・ \(coveredMinutes)分ぶん文字になりました" }
        if pending > 0 { status += " ・ 文字にしています…" }
        if failed > 0 { status += " ・ 一部は文字にできませんでした" }
        statusLabel.text = status
        let text = LiveTranscriptFormatter.liveText(session)
        if text.isEmpty { textLabel.text = recording ? "最初の1分が終わると、ここに文字が出ます。" : "" }
        else if text.count > Self.visibleCharacters { textLabel.text = "…\n" + String(text.suffix(Self.visibleCharacters)) }
        else { textLabel.text = text }
        textLabel.textColor = text.isEmpty ? .secondaryLabel : .label
        textLabel.isHidden = !recording && text.isEmpty
        accessibilityLabel = titleLabel.text
    }
}
