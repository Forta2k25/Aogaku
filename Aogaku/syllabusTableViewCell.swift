import UIKit

final class syllabusTableViewCell: UITableViewCell {
    @IBOutlet weak var class_name: UILabel!
    @IBOutlet weak var teacher_name: UILabel!
    @IBOutlet weak var time: UILabel!
    @IBOutlet weak var campus: UILabel!
    @IBOutlet weak var grade: UILabel!
    @IBOutlet weak var category: UILabel!
    @IBOutlet weak var credit: UILabel!
    @IBOutlet weak var termLabel: UILabel!

    // 重複追加防止
    private var didAddSafetyConstraints = false
    private var minHeightConstraint: NSLayoutConstraint?

    override func awakeFromNib() {
        super.awakeFromNib()

        // ─ 表示設定
        class_name.numberOfLines = 0
        class_name.lineBreakMode = .byWordWrapping

        // 横の優先度（右「◯単位」を守る）
        credit.setContentCompressionResistancePriority(.required, for: .horizontal)
        credit.setContentHuggingPriority(.required, for: .horizontal)
        class_name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        class_name.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // 縦の優先度（タイトルは潰さず伸びる）
        class_name.setContentCompressionResistancePriority(.required, for: .vertical)
        class_name.setContentHuggingPriority(.defaultHigh, for: .vertical)

        // サブ行は1行
        [teacher_name, time, campus, grade, category, termLabel].forEach { $0?.numberOfLines = 1 }

        addSafetyConstraintsIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 折り返し幅を更新（自己サイズ計算の安定化）
        class_name.preferredMaxLayoutWidth = class_name.bounds.width
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        class_name.text = nil
        teacher_name.text = nil
        time.text = nil
        campus.text = nil
        grade.text = nil
        category.text = nil
        credit.text = nil
        termLabel.text = nil
    }

    private func addSafetyConstraintsIfNeeded() {
        guard !didAddSafetyConstraints else { return }
        didAddSafetyConstraints = true

        class_name.translatesAutoresizingMaskIntoConstraints = false
        credit.translatesAutoresizingMaskIntoConstraints = false

        // ① タイトルTop ≥ contentView.Top（最低余白）
        let top = class_name.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 12)
        top.priority = .required
        top.isActive = true

        // ② タイトル右端 ≤ 「◯単位」左端 − 8（横の重なり防止）
        let titleToCredit = class_name.trailingAnchor.constraint(lessThanOrEqualTo: credit.leadingAnchor, constant: -8)
        titleToCredit.priority = .required
        titleToCredit.isActive = true

        // ③ ――ここを置き換え――
        // サブ行の共通の天井ガイド。タイトルの「最後のベースライン」から一定距離だけ下げる
        let subTopGuide = UILayoutGuide()
        contentView.addLayoutGuide(subTopGuide)
        NSLayoutConstraint.activate([
            subTopGuide.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            subTopGuide.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            // ★ lastBaselineAnchor を使うのがコツ。字下がり(アセンダ/ディセンダ)分まで考慮して確実に離す
            subTopGuide.topAnchor.constraint(equalTo: class_name.lastBaselineAnchor, constant: 12)
        ])

        // 画面に存在するサブラベルを列挙
        let subLabels: [UIView] = [termLabel, teacher_name, time, campus, grade, category].compactMap { $0 }

        // 先頭の1個はガイドに“ぴったり”合わせる（= で固定）
        if let first = subLabels.first {
            first.translatesAutoresizingMaskIntoConstraints = false
            let eq = first.topAnchor.constraint(equalTo: subTopGuide.topAnchor)
            eq.priority = .required
            eq.isActive = true
        }
        // 残りは“ガイド以上”に（≥）。ずり上がりを防止
        for v in subLabels.dropFirst() {
            v.translatesAutoresizingMaskIntoConstraints = false
            let ge = v.topAnchor.constraint(greaterThanOrEqualTo: subTopGuide.topAnchor)
            ge.priority = .required
            ge.isActive = true
        }

        // ④ 最下段ビューのBottom ≥ contentView.Bottom（下を閉じる）
        if let bottomView = ( [category, grade, campus, time, teacher_name, termLabel, class_name].compactMap { $0 } ).first {
            let bottom = contentView.bottomAnchor.constraint(greaterThanOrEqualTo: bottomView.bottomAnchor, constant: 12)
            bottom.priority = .required
            bottom.isActive = true
        }

        // ⑤ 最小高さ（保険）
        if minHeightConstraint == nil {
            minHeightConstraint = contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 88)
            minHeightConstraint?.priority = .defaultHigh
            minHeightConstraint?.isActive = true
        }
    }

}
