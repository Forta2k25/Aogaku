import UIKit

final class CircleFilterViewController: UIViewController {

    var onApply: ((CircleFilters) -> Void)?
    var onReset: (() -> Void)?

    private var filters: CircleFilters

    init(current: CircleFilters) {
        self.filters = current
        super.init(nibName: nil, bundle: nil)
        title = "絞り込み"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // UI
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    // Fee
    private let feeLabel = UILabel()
    private let feeMinSlider = UISlider()
    private let feeMaxSlider = UISlider()

    // ✅ カテゴリを3グループで管理
    private let categoryGroups: [(title: String, options: [String])] = [
        ("サークル", ["スポーツ","音楽","文化・芸術","ダンス・演劇","アウトドア","国際・語学","IT・ビジネス","ボランティア","イベント"]),
        ("部活",     ["体育会","文化"]),
        ("その他",   ["学生団体","外部連携団体","プロジェクト"])
    ]

    private let targetOptions = ["青学生のみ","新入生のみ","インカレ"]
    private let weekdayOptions = ["月","火","水","木","金","土","日","不定期"]
    private let moodOptions = ["ゆるめ","ふつう","ガチめ"]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "リセット", style: .plain, target: self, action: #selector(didTapReset))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(didTapClose))

        buildUI()
        applyInitialStateToUI()
        updateFeeLabel()
    }

    private func buildUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 18
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
        ])

        // ✅ カテゴリ（折りたたみ）
        contentStack.addArrangedSubview(makeCategoryCollapsibleSection())

        contentStack.addArrangedSubview(makeSection(title: "対象", options: targetOptions, selected: filters.targets) { [weak self] value, isOn in
            guard let self else { return }
            if isOn { self.filters.targets.insert(value) } else { self.filters.targets.remove(value) }
        })

        // Fee
        contentStack.addArrangedSubview(makeFeeSection())

        contentStack.addArrangedSubview(makeSection(title: "曜日", options: weekdayOptions, selected: filters.weekdays) { [weak self] value, isOn in
            guard let self else { return }
            if isOn { self.filters.weekdays.insert(value) } else { self.filters.weekdays.remove(value) }
        })

        contentStack.addArrangedSubview(makeSingleChoiceSection(title: "兼サー可否",
                                                                left: "兼サーOK", right: "兼サー不可",
                                                                current: filters.canDouble) { [weak self] v in
            self?.filters.canDouble = v
        })

        contentStack.addArrangedSubview(makeSingleChoiceSection(title: "選考",
                                                                left: "選考なし", right: "選考あり",
                                                                current: filters.hasSelection) { [weak self] v in
            self?.filters.hasSelection = v
        })

        contentStack.addArrangedSubview(makeSection(title: "雰囲気", options: moodOptions, selected: filters.moods) { [weak self] value, isOn in
            guard let self else { return }
            if isOn { self.filters.moods.insert(value) } else { self.filters.moods.remove(value) }
        })

        // Apply button
        let apply = UIButton(type: .system)
        apply.translatesAutoresizingMaskIntoConstraints = false
        apply.setTitle("この条件で探す", for: .normal)
        apply.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        apply.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.85)
        apply.setTitleColor(.white, for: .normal)
        apply.layer.cornerRadius = 14
        apply.heightAnchor.constraint(equalToConstant: 52).isActive = true
        apply.addTarget(self, action: #selector(didTapApply), for: .touchUpInside)

        contentStack.addArrangedSubview(apply)
    }

    // MARK: - Category collapsible

    private func makeCategoryCollapsibleSection() -> UIView {
        let container = UIView()
        let v = UIStackView()
        v.axis = .vertical
        v.spacing = 10
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)

        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // ✅ 「カテゴリ」ヘッダーをタップ可能に
        let header = CollapsibleHeaderView(title: "カテゴリ", isExpanded: true)
        v.addArrangedSubview(header)

        // ✅ この stack に「サークル/部活/その他」を入れてまとめて隠す
        let groupsStack = UIStackView()
        groupsStack.axis = .vertical
        groupsStack.spacing = 10
        groupsStack.translatesAutoresizingMaskIntoConstraints = false
        v.addArrangedSubview(groupsStack)

        // 3グループ（各グループは今まで通り個別に▼で折りたたみ可能）
        for (idx, g) in categoryGroups.enumerated() {
            let expandedDefault = (idx == 0)
            let sec = CollapsibleChipsSectionView(
                title: g.title,
                options: g.options,
                selected: filters.categories,
                isExpanded: expandedDefault
            ) { [weak self] value, isOn in
                guard let self else { return }
                if isOn { self.filters.categories.insert(value) } else { self.filters.categories.remove(value) }
            }
            groupsStack.addArrangedSubview(sec)
        }

        // ✅ 「カテゴリ」タップで groupsStack を開閉
        header.onToggle = { [weak groupsStack] expanded in
            guard let groupsStack else { return }
            let changes = {
                groupsStack.isHidden = !expanded
            }
            UIView.animate(withDuration: 0.2, animations: changes)
        }

        // 初期表示（開いておく）
        groupsStack.isHidden = false

        return container
    }


    // MARK: - Common sections

    private func makeSection(title: String,
                             options: [String],
                             selected: Set<String>,
                             onToggle: @escaping (String, Bool) -> Void) -> UIView {
        let container = UIView()
        let v = UIStackView()
        v.axis = .vertical
        v.spacing = 10
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)

        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let header = UILabel()
        header.text = title
        header.font = .systemFont(ofSize: 16, weight: .bold)
        v.addArrangedSubview(header)

        let flow = ChipsFlowView(options: options, selected: selected) { value, isOn in
            onToggle(value, isOn)
        }
        v.addArrangedSubview(flow)
        return container
    }

    private func makeFeeSection() -> UIView {
        let container = UIView()
        let v = UIStackView()
        v.axis = .vertical
        v.spacing = 10
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)

        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let header = UILabel()
        header.text = "費用（年額目安）"
        header.font = .systemFont(ofSize: 16, weight: .bold)

        feeLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        feeLabel.textColor = .secondaryLabel

        feeMinSlider.minimumValue = 0
        feeMinSlider.maximumValue = 50000
        feeMaxSlider.minimumValue = 0
        feeMaxSlider.maximumValue = 50000

        feeMinSlider.addTarget(self, action: #selector(feeChanged), for: .valueChanged)
        feeMaxSlider.addTarget(self, action: #selector(feeChanged), for: .valueChanged)

        v.addArrangedSubview(header)
        v.addArrangedSubview(feeLabel)
        v.addArrangedSubview(feeMinSlider)
        v.addArrangedSubview(feeMaxSlider)

        return container
    }

    private func makeSingleChoiceSection(title: String,
                                         left: String,
                                         right: String,
                                         current: Bool?,
                                         onChange: @escaping (Bool?) -> Void) -> UIView {
        let container = UIView()
        let v = UIStackView()
        v.axis = .vertical
        v.spacing = 10
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)

        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let header = UILabel()
        header.text = title
        header.font = .systemFont(ofSize: 16, weight: .bold)
        v.addArrangedSubview(header)

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .center

        let leftBtn = ChipButton(title: left)
        let rightBtn = ChipButton(title: right)

        if let c = current {
            leftBtn.setSelected(c == true)
            rightBtn.setSelected(c == false)
        }

        leftBtn.onTap = { isOn in
            rightBtn.setSelected(false)
            onChange(isOn ? true : nil)
        }
        rightBtn.onTap = { isOn in
            leftBtn.setSelected(false)
            onChange(isOn ? false : nil)
        }

        row.addArrangedSubview(leftBtn)
        row.addArrangedSubview(rightBtn)
        v.addArrangedSubview(row)

        return container
    }

    private func applyInitialStateToUI() {
        let minV = Float(filters.feeMin ?? 0)
        let maxV = Float(filters.feeMax ?? 50000)
        feeMinSlider.value = minV
        feeMaxSlider.value = maxV
    }

    @objc private func feeChanged() {
        if feeMinSlider.value > feeMaxSlider.value {
            let mid = (feeMinSlider.value + feeMaxSlider.value) / 2
            feeMinSlider.value = mid
            feeMaxSlider.value = mid
        }

        let minY = Int(feeMinSlider.value.rounded())
        let maxY = Int(feeMaxSlider.value.rounded())

        filters.feeMin = (minY <= 0) ? nil : minY
        filters.feeMax = (maxY >= 50000) ? nil : maxY

        updateFeeLabel()
    }

    private func updateFeeLabel() {
        let minText = filters.feeMin.map { "\(formatYen($0))円" } ?? "0円"
        let maxText = filters.feeMax.map { "\(formatYen($0))円" } ?? "50,000円以上"
        feeLabel.text = "\(minText)〜\(maxText)"
    }

    private func formatYen(_ v: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        return nf.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    @objc private func didTapApply() {
        onApply?(filters)
        dismiss(animated: true)
    }

    @objc private func didTapReset() {
        filters = CircleFilters()
        onReset?()

        feeMinSlider.value = 0
        feeMaxSlider.value = 50000
        updateFeeLabel()

        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buildUI()
    }

    @objc private func didTapClose() {
        dismiss(animated: true)
    }
}

// MARK: - Collapsible chips section (▼)

final class CollapsibleChipsSectionView: UIView {

    private var isExpanded: Bool
    private let onToggle: (String, Bool) -> Void

    private let headerButton = UIButton(type: .system)
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down"))
    private let chipsView: ChipsFlowView

    init(title: String,
         options: [String],
         selected: Set<String>,
         isExpanded: Bool,
         onToggle: @escaping (String, Bool) -> Void) {

        self.isExpanded = isExpanded
        self.onToggle = onToggle
        self.chipsView = ChipsFlowView(options: options, selected: selected, onToggle: onToggle)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build(title: title)
        setExpanded(isExpanded, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build(title: String) {
        let v = UIStackView()
        v.axis = .vertical
        v.spacing = 10
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)

        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor),
            v.leadingAnchor.constraint(equalTo: leadingAnchor),
            v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // header row
        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.setTitle(title, for: .normal)
        headerButton.setTitleColor(.label, for: .normal)
        headerButton.contentHorizontalAlignment = .left
        headerButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        headerButton.addTarget(self, action: #selector(toggle), for: .touchUpInside)

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = .secondaryLabel
        chevron.contentMode = .scaleAspectFit

        let headerRow = UIView()
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addSubview(headerButton)
        headerRow.addSubview(chevron)

        NSLayoutConstraint.activate([
            headerButton.topAnchor.constraint(equalTo: headerRow.topAnchor),
            headerButton.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor),
            headerButton.bottomAnchor.constraint(equalTo: headerRow.bottomAnchor),

            chevron.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor),
            chevron.leadingAnchor.constraint(greaterThanOrEqualTo: headerButton.trailingAnchor, constant: 8),
            chevron.widthAnchor.constraint(equalToConstant: 14),
            chevron.heightAnchor.constraint(equalToConstant: 14),
        ])

        v.addArrangedSubview(headerRow)
        v.addArrangedSubview(chipsView)
    }

    @objc private func toggle() {
        setExpanded(!isExpanded, animated: true)
    }

    private func setExpanded(_ expanded: Bool, animated: Bool) {
        isExpanded = expanded
        let angle: CGFloat = expanded ? .pi : 0

        let changes = {
            self.chipsView.isHidden = !expanded
            self.chevron.transform = CGAffineTransform(rotationAngle: angle)
            self.layoutIfNeeded()
        }

        if animated {
            UIView.animate(withDuration: 0.2, animations: changes)
        } else {
            changes()
        }
    }
}

// MARK: - Chips UI

final class ChipsFlowView: UIView {
    private let options: [String]
    private var selected: Set<String>
    private let onToggle: (String, Bool) -> Void

    private let stack = UIStackView()

    init(options: [String], selected: Set<String>, onToggle: @escaping (String, Bool) -> Void) {
        self.options = options
        self.selected = selected
        self.onToggle = onToggle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        var row = makeRow()
        stack.addArrangedSubview(row)

        var currentWidth: CGFloat = 0
        let maxWidth: CGFloat = UIScreen.main.bounds.width - 32

        for opt in options {
            let chip = ChipButton(title: opt)
            chip.setSelected(selected.contains(opt))
            chip.onTap = { [weak self] isOn in
                guard let self else { return }
                if isOn { self.selected.insert(opt) } else { self.selected.remove(opt) }
                self.onToggle(opt, isOn)
            }

            chip.layoutIfNeeded()
            let w = chip.intrinsicContentSize.width + 10
            if currentWidth + w > maxWidth {
                row = makeRow()
                stack.addArrangedSubview(row)
                currentWidth = 0
            }
            row.addArrangedSubview(chip)
            currentWidth += w
        }
    }

    private func makeRow() -> UIStackView {
        let r = UIStackView()
        r.axis = .horizontal
        r.spacing = 10
        r.alignment = .center
        return r
    }
}

final class ChipButton: UIButton {
    var onTap: ((Bool) -> Void)?
    private(set) var isOn: Bool = false

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setTitle(title, for: .normal)
        titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        layer.cornerRadius = 16
        contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        setSelected(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSelected(_ on: Bool) {
        isOn = on
        if on {
            backgroundColor = UIColor.systemGreen.withAlphaComponent(0.12)
            setTitleColor(.systemGreen, for: .normal)
            layer.borderWidth = 1
            layer.borderColor = UIColor.systemGreen.withAlphaComponent(0.35).cgColor
        } else {
            backgroundColor = .systemGray6
            setTitleColor(.label, for: .normal)
            layer.borderWidth = 1
            layer.borderColor = UIColor.black.withAlphaComponent(0.08).cgColor
        }
    }

    @objc private func tapped() {
        setSelected(!isOn)
        onTap?(isOn)
    }
}

final class CollapsibleHeaderView: UIView {

    var onToggle: ((Bool) -> Void)?

    private(set) var isExpanded: Bool
    private let button = UIButton(type: .system)
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down"))

    init(title: String, isExpanded: Bool) {
        self.isExpanded = isExpanded
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build(title: title)
        setExpanded(isExpanded, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build(title: String) {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 24)
        ])

        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.setTitleColor(.label, for: .normal)
        button.contentHorizontalAlignment = .left
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = .secondaryLabel
        chevron.contentMode = .scaleAspectFit

        row.addSubview(button)
        row.addSubview(chevron)

        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: row.topAnchor),
            button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            button.bottomAnchor.constraint(equalTo: row.bottomAnchor),

            chevron.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            chevron.leadingAnchor.constraint(greaterThanOrEqualTo: button.trailingAnchor, constant: 8),
            chevron.widthAnchor.constraint(equalToConstant: 14),
            chevron.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    @objc private func tapped() {
        setExpanded(!isExpanded, animated: true)
        onToggle?(isExpanded)
    }

    private func setExpanded(_ expanded: Bool, animated: Bool) {
        isExpanded = expanded
        let angle: CGFloat = expanded ? .pi : 0
        let changes = {
            self.chevron.transform = CGAffineTransform(rotationAngle: angle)
            self.layoutIfNeeded()
        }
        if animated {
            UIView.animate(withDuration: 0.2, animations: changes)
        } else {
            changes()
        }
    }
}
