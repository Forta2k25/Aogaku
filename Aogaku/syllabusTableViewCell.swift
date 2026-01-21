import UIKit

final class syllabusTableViewCell: UITableViewCell {
    @IBOutlet weak var class_name: UILabel!
    @IBOutlet weak var teacher_name: UILabel!
    @IBOutlet weak var time: UILabel!
    @IBOutlet weak var campus: UILabel!
    @IBOutlet weak var grade: UILabel!
    @IBOutlet weak var category: UILabel!
    @IBOutlet weak var credit: UILabel!      // ← ここに eval_method を出す
    @IBOutlet weak var termLabel: UILabel!
    @IBOutlet weak var eval_method: UILabel!

    private var didAddSafetyConstraints = false
    private var minHeightConstraint: NSLayoutConstraint?

    override func awakeFromNib() {
        super.awakeFromNib()

        // タイトルと評価方法は複数行OK
        class_name.numberOfLines = 0
        class_name.lineBreakMode = .byWordWrapping
        eval_method.numberOfLines = 0
        eval_method.lineBreakMode = .byWordWrapping

        // === 追加：どのラベルが最下段になっても高さが伸びる安全ネット ===
        let bottoms: [UIView?] = [class_name, teacher_name, time, campus, grade, category, termLabel, credit, eval_method]
        for v in bottoms.compactMap({ $0 }) {
            v.translatesAutoresizingMaskIntoConstraints = false
            let c = contentView.bottomAnchor.constraint(greaterThanOrEqualTo: v.bottomAnchor, constant: 12)
            c.priority = .required
            c.isActive = true
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
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
        eval_method.text = nil
    }

    private func addSafetyConstraintsIfNeeded() {
        guard !didAddSafetyConstraints else { return }
        didAddSafetyConstraints = true

        class_name.translatesAutoresizingMaskIntoConstraints = false
        credit.translatesAutoresizingMaskIntoConstraints = false

        // ① タイトルTop ≥ contentView.Top
        let top = class_name.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 12)
        top.isActive = true

        // ② タイトル右端 ≤ 右ラベル左端 − 8
        let titleToCredit = class_name.trailingAnchor.constraint(lessThanOrEqualTo: credit.leadingAnchor, constant: -8)
        titleToCredit.isActive = true

        // ③ タイトル最終行の下にサブ行の天井ガイド
        let subTopGuide = UILayoutGuide()
        contentView.addLayoutGuide(subTopGuide)
        NSLayoutConstraint.activate([
            subTopGuide.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            subTopGuide.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            subTopGuide.topAnchor.constraint(equalTo: class_name.lastBaselineAnchor, constant: 12)
        ])

        let subLabels: [UIView] = [termLabel, teacher_name, time, campus, grade, category].compactMap { $0 }
        if let first = subLabels.first {
            first.translatesAutoresizingMaskIntoConstraints = false
            first.topAnchor.constraint(equalTo: subTopGuide.topAnchor).isActive = true
        }
        for v in subLabels.dropFirst() {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.topAnchor.constraint(greaterThanOrEqualTo: subTopGuide.topAnchor).isActive = true
        }

        // ④ 下端の確保：サブラベル群 と 右ラベル（eval_method）の両方を守る
        let bottom1 = contentView.bottomAnchor.constraint(greaterThanOrEqualTo: ( [category, grade, campus, time, teacher_name, termLabel, class_name].compactMap { $0 } ).last!.bottomAnchor, constant: 12)
        bottom1.isActive = true
        let bottom2 = contentView.bottomAnchor.constraint(greaterThanOrEqualTo: credit.bottomAnchor, constant: 12)
        bottom2.isActive = true

        // ⑤ 最小高さ（保険）
        if minHeightConstraint == nil {
            minHeightConstraint = contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 88)
            minHeightConstraint?.priority = .defaultHigh
            minHeightConstraint?.isActive = true
        }
        let bottomEval = contentView.bottomAnchor.constraint(
                greaterThanOrEqualTo: eval_method.bottomAnchor, constant: 12
            )
            bottomEval.priority = .required
            bottomEval.isActive = true
    }
}
