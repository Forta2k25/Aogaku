import UIKit

// 固定レイアウトのチェックボックス（改行・ズレ防止）
final class Checkbox: UIControl {
    private let icon = UIImageView()
    private let label = UILabel()
    var title: String { didSet { label.text = title } }
    override var isSelected: Bool { didSet { updateAppearance() } }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setup()
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false

        label.text = title
        label.font = .systemFont(ofSize: 16)
        label.textColor = .label
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        icon.contentMode = .scaleAspectFit
        icon.tintColor = .systemGray3

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(didTap))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true
    }

    @objc private func didTap() {
        isSelected.toggle()
        sendActions(for: .valueChanged)
    }

    private func updateAppearance() {
        let name = isSelected ? "checkmark.square.fill" : "square"
        icon.image = UIImage(systemName: name)
        icon.tintColor = isSelected ? .systemGreen : .systemGray3
    }
}

// MARK: - 本体 VC
final class SyllabusDetailFilterViewController: UIViewController {
    
    /// 詳細条件を親に返すためのコールバック
    var onApply: ((SyllabusSearchCriteria) -> Void)?


    private let grip: UIView = {
        let v = UIView()
        v.backgroundColor = .systemGray3
        v.layer.cornerRadius = 3
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    // 曜日・時限
    private let check6 = Checkbox(title: "6限")
    private let check7 = Checkbox(title: "7限")
    private let checkSat = Checkbox(title: "土曜日")
    private let checkUndecided = Checkbox(title: "不定")

    // 学期（日本語のみ）
    private let termOptions: [String] = [
        "指定なし","通年","前期","通年隔週第1週","通年隔週第2週",
        "前期隔週第1週","前期隔週第2週","通年集中","前期集中","夏休集中",
        "不定集中","前期前半","前期後半","後期","後期隔週第1週",
        "後期隔週第2週","後期集中","冬休集中","春休集中","後期前半","後期後半"
    ]

    private lazy var termField: UIButton = {
        let b = UIButton(type: .system)
        var cfg = UIButton.Configuration.filled()
        cfg.baseBackgroundColor = .systemGray6
        cfg.baseForegroundColor = .label
        cfg.cornerStyle = .large
        cfg.contentInsets = .init(top: 12, leading: 16, bottom: 12, trailing: 16)
        cfg.image = UIImage(systemName: "chevron.down")
        cfg.imagePlacement = .trailing
        cfg.imagePadding = 8
        cfg.title = termOptions.first ?? "指定なし"
        cfg.titleAlignment = .leading                     // ← 学期の文字を左詰め
        b.configuration = cfg
        b.contentHorizontalAlignment = .fill              // 文字は左、画像は後ろ側

        b.menu = UIMenu(children: termOptions.map { title in
            UIAction(title: title) { act in
                var c = b.configuration
                c?.title = act.title
                b.configuration = c
            }
        })
        b.showsMenuAsPrimaryAction = true
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return b
    }()

    // 開講講義
    private let englishCheck = Checkbox(title: "英語講義/English")

    // 履修形式（2×2グリッド）
    private let styleFree   = Checkbox(title: "自由")
    private let styleMust   = Checkbox(title: "必修")
    private let styleLottery = Checkbox(title: "抽選")
    private let styleScreen = Checkbox(title: "選考")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGray5

        title = "詳細設定"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "適用", style: .done, target: self, action: #selector(didTapApply)
        )

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(grip)
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)

        // 1) 曜日・時限（2段は左寄せ。土曜日と不定を交換）
        let dayGrid = makeTwoColumnGrid(
            left:  [check6, checkUndecided],  // ← 左列: 6限 / 不定
            right: [check7, checkSat]         // ← 右列: 7限 / 土曜日
        )
        let dayCard = makeCard(title: "曜日・時限", body: dayGrid)

        // 2) 学期
        let termCard = makeCard(title: "学期", body: termField)

        // 3) 開講講義
        let englishCard = makeCard(title: "開講講義", body: englishCheck)

        // 4) 履修形式（2×2・両列とも左寄せ）
        let styleGrid = makeTwoColumnGrid(
            left:  [styleFree, styleLottery],
            right: [styleMust, styleScreen]
        )
        let styleCard = makeCard(title: "履修形式", body: styleGrid)

        [dayCard, termCard, englishCard, styleCard].forEach { contentStack.addArrangedSubview($0) }

        NSLayoutConstraint.activate([
            grip.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            grip.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grip.widthAnchor.constraint(equalToConstant: 90),
            grip.heightAnchor.constraint(equalToConstant: 6),

            scrollView.topAnchor.constraint(equalTo: grip.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 8),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -8),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])
    }

    @objc private func didTapApply() {
        var day: String? = nil
        var periods: [Int]? = nil
        var slots: [(String, Int)]? = nil
        if checkSat.isSelected { day = "土" }

        var ps: [Int] = []
        if check6.isSelected { ps.append(6) }
        if check7.isSelected { ps.append(7) }
        if !ps.isEmpty { periods = ps }

        // ===== 学期 =====
        let title = termField.configuration?.title ?? "指定なし"
        var termValue: String? = nil
        var forceUndecided = false
        if title != "指定なし" {
            switch title {
            case "通年隔週第1週": termValue = "通年隔１"
            case "通年隔週第2週": termValue = "通年隔２"
            case "前期隔週第1週": termValue = "前期隔１"
            case "前期隔週第2週": termValue = "前期隔２"
            // （必要なら）後期も同様に：
            case "後期隔週第1週": termValue = "後期隔１"
            case "後期隔週第2週": termValue = "後期隔２"
            case "不定集中":
                termValue = "集中"
                forceUndecided = true   // 授業名に「不定」を含む条件も同時に付与
            default:
                termValue = title       // 例: 「通年」「前期」「後期」「夏休集中」などはそのまま
            }
        }

        // 「不定」チェック or 「不定集中」選択で true
        let undecided = (checkUndecided.isSelected || forceUndecided) ? true : nil

        let criteria = SyllabusSearchCriteria(
            keyword: nil,
            category: nil, department: nil,
            campus: nil, place: nil, grade: nil,
            day: day, periods: periods, timeSlots: slots,
            term: termValue,
            undecided: undecided
        )

        let handler = self.onApply
        dismiss(animated: true) { handler?(criteria) }
    }


    // MARK: - Builders

    /// 2列グリッド（両列とも左寄せ、列幅は等分）
    private func makeTwoColumnGrid(left: [UIView], right: [UIView]) -> UIView {
        let leftCol = vstack(left);  leftCol.alignment = .leading
        let rightCol = vstack(right); rightCol.alignment = .leading

        let grid = UIStackView(arrangedSubviews: [leftCol, rightCol])
        grid.axis = .horizontal
        grid.alignment = .fill
        grid.distribution = .fillEqually
        grid.spacing = 16
        return grid
    }

    private func makeCard(title: String, body: UIView) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = .white
        container.layer.cornerRadius = 16

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .boldSystemFont(ofSize: 16)

        let inner = UIStackView(arrangedSubviews: [titleLabel, body])
        inner.axis = .vertical
        inner.spacing = 12
        inner.isLayoutMarginsRelativeArrangement = true
        inner.layoutMargins = .init(top: 16, left: 16, bottom: 16, right: 16)
        inner.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: container.topAnchor),
            inner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            inner.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func vstack(_ views: [UIView]) -> UIStackView {
        let s = UIStackView(arrangedSubviews: views)
        s.axis = .vertical
        s.alignment = .fill
        s.spacing = 12
        return s
    }
}
