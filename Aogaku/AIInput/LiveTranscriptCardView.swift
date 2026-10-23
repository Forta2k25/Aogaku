import UIKit

/// 録音中・文字にしている間だけ、チャットの一番下に出す、小さな状態の表示。文字そのものは、止めたあとに、入力欄へ入る。
final class LiveTranscriptCardView: UIView {
    private let dot = UIView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()

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

        let column = UIStackView(arrangedSubviews: [titleRow, statusLabel])
        column.axis = .vertical; column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(session: LiveRecordingSession) {
        let recording = session.state == "recording"
        dot.isHidden = !recording
        titleLabel.text = recording ? "録音中" : "文字にしています…"
        let done = session.segments.filter { $0.status == "done" }
        let pending = session.segments.filter { $0.status == "pending" }.count
        let failed = session.segments.filter { $0.status == "failed" }.count
        let minutes = Int((done.map(\.endSeconds).max() ?? 0) / 60)
        var status = recording ? "1分ごとに、裏で文字にしています。止めると、文字が入力欄に入ります" : "もうすぐ、文字が入力欄に入ります"
        if minutes > 0 { status += " ・ \(minutes)分ぶん文字になりました" }
        if pending > 1, !recording { status += " ・ 残り\(pending)区間" }
        if failed > 0 { status += " ・ 一部は文字にできませんでした" }
        statusLabel.text = status
        accessibilityLabel = (titleLabel.text ?? "") + "。" + status
    }
}
