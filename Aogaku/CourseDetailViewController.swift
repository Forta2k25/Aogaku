
import UIKit
import WebKit

// すでに別所で定義済みなら削除OK
struct AttendanceCounts: Codable {
    var attended: Int
    var late: Int
    var absent: Int
}

protocol CourseDetailViewControllerDelegate: AnyObject {
    func courseDetail(_ vc: CourseDetailViewController,
                      requestEditFor course: Course,
                      at location: SlotLocation)
    func courseDetail(_ vc: CourseDetailViewController,
                      requestDelete course: Course,
                      at location: SlotLocation)
    func courseDetail(_ vc: CourseDetailViewController,
                      didUpdate counts: AttendanceCounts,
                      for course: Course,
                      at location: SlotLocation)
    func courseDetail(_ vc: CourseDetailViewController,
                      didChangeColor key: SlotColorKey,
                      at location: SlotLocation)
}

final class CourseDetailViewController: UIViewController {

    // MARK: - Inputs
    weak var delegate: CourseDetailViewControllerDelegate?
    private let course: Course
    private let location: SlotLocation

    // MARK: - Color Picker
    private let colorKeys: [SlotColorKey] = [.blue, .green, .yellow, .red, .teal, .gray]
    private var colorButtons: [UIButton] = []

    // MARK: - UI
    private let scroll = UIScrollView()
    private let stack  = UIStackView()

    private let titleLabel = UILabel()
    private let infoLabel  = UILabel()

    private let summaryRow = UIStackView()
    private let metaCard   = UIView()
    private let creditsLabel = UILabel()
    private let idLabel      = UILabel()

    private let countersRow = UIStackView()
    private let attendBtn = UIButton(type: .system)
    private let lateBtn   = UIButton(type: .system)
    private let absentBtn = UIButton(type: .system)

    private let webView = WKWebView()
    private let webContainer = UIView()          // ← プロパティのコンテナを使う（ローカルで再定義しない）
    private var webHeightConstraint: NSLayoutConstraint!

    private let bottomBar = UIView()
    private let editButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let bottomBarHeight: CGFloat = 76

    // MARK: - Attendance
    private var counts = AttendanceCounts(attended: 0, late: 0, absent: 0)
    private var attendanceKey: String { "attendance.\(course.id)" }

    // MARK: - Init
    init(course: Course, location: SlotLocation) {
        self.course = course
        self.location = location
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle
    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let sheet = sheetPresentationController {
            sheet.prefersGrabberVisible = true
        }
        buildLayout()
        loadCounts()
        updateCounterButtons()
        loadSyllabus()         // URL検証つき読込
        buildColorPickerRow()  // タイトル直下に設置
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 下固定バー分のインセット
        scroll.contentInset.bottom = bottomBarHeight + 16
        scroll.verticalScrollIndicatorInsets.bottom = bottomBarHeight
    }

    // MARK: - Layout
    private func buildLayout() {
        // スクロール + 縦スタック
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor)
        ])

        // タイトル
        titleLabel.text = course.title
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.numberOfLines = 0
        stack.addArrangedSubview(titleLabel)

        // 概要（曜日・限・教室・担当）
        infoLabel.text = "\(location.dayName) \(location.period)限\n教室: \(course.room)\n担当: \(course.teacher)"
        infoLabel.font = .systemFont(ofSize: 18, weight: .medium)
        infoLabel.numberOfLines = 0
        stack.addArrangedSubview(infoLabel)

        // 右側の小カードを入れる横並び行（将来の拡張に備え左側を空けておく）
        summaryRow.axis = .horizontal
        summaryRow.alignment = .top
        summaryRow.spacing = 16
        summaryRow.distribution = .fill
        stack.addArrangedSubview(summaryRow)

        // メタ情報カード
        metaCard.backgroundColor = .secondarySystemBackground
        metaCard.layer.cornerRadius = 12
        metaCard.layer.borderWidth = 0.5
        metaCard.layer.borderColor = UIColor.separator.cgColor
        metaCard.translatesAutoresizingMaskIntoConstraints = false
        metaCard.setContentHuggingPriority(.required, for: .horizontal)
        metaCard.setContentCompressionResistancePriority(.required, for: .horizontal)
        summaryRow.addArrangedSubview(metaCard)

        let metaStack = UIStackView()
        metaStack.axis = .vertical
        metaStack.alignment = .leading
        metaStack.spacing = 6
        metaStack.translatesAutoresizingMaskIntoConstraints = false
        metaCard.addSubview(metaStack)

        creditsLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        idLabel.font      = .systemFont(ofSize: 13, weight: .regular)
        creditsLabel.text = "単位: \(courseCreditsText() ?? "–")"
        idLabel.text      = "登録番号: \(course.id)"

        metaStack.addArrangedSubview(creditsLabel)
        metaStack.addArrangedSubview(idLabel)

        NSLayoutConstraint.activate([
            metaStack.topAnchor.constraint(equalTo: metaCard.topAnchor, constant: 12),
            metaStack.leadingAnchor.constraint(equalTo: metaCard.leadingAnchor, constant: 12),
            metaStack.trailingAnchor.constraint(equalTo: metaCard.trailingAnchor, constant: -12),
            metaStack.bottomAnchor.constraint(equalTo: metaCard.bottomAnchor, constant: -12),
            metaCard.widthAnchor.constraint(greaterThanOrEqualToConstant: 140)
        ])

        // 出欠カウンター
        countersRow.axis = .horizontal
        countersRow.alignment = .center
        countersRow.distribution = .equalSpacing
        countersRow.spacing = 16
        stack.addArrangedSubview(countersRow)

        setupCounterButton(attendBtn, tag: 0, label: "出席")
        setupCounterButton(lateBtn,   tag: 1, label: "遅刻")
        setupCounterButton(absentBtn, tag: 2, label: "欠席")
        countersRow.addArrangedSubview(attendBtn)
        countersRow.addArrangedSubview(lateBtn)
        countersRow.addArrangedSubview(absentBtn)

        // WebView（プロパティの webContainer を使用）
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webContainer.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor)
        ])
        webHeightConstraint = webContainer.heightAnchor.constraint(equalToConstant: 600)
        webHeightConstraint.isActive = true
        stack.addArrangedSubview(webContainer)

        // 下部固定バー
        buildBottomBar()
    }

    // MARK: - Color Picker Row（タイトル直下に挿入）
    private func buildColorPickerRow() {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.distribution = .equalSpacing  // ← 伸ばさない
        row.spacing = 12
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = .init(top: 4, left: 8, bottom: 8, right: 8)

        colorButtons = colorKeys.enumerated().map { (i, key) in
            let b = UIButton(type: .system)
            b.tag = i
            b.backgroundColor = key.uiColor
            b.setTitle("", for: .normal)
            b.layer.cornerRadius = 18
            b.layer.borderWidth = 1
            b.layer.borderColor = UIColor.separator.cgColor
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 36).isActive = true
            b.heightAnchor.constraint(equalToConstant: 36).isActive = true
            
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.setContentCompressionResistancePriority(.required, for: .horizontal)

            
            b.addTarget(self, action: #selector(colorTapped(_:)), for: .touchUpInside)
            row.addArrangedSubview(b)
            return b
        }

        if let idx = stack.arrangedSubviews.firstIndex(of: titleLabel) {
            stack.insertArrangedSubview(row, at: idx + 1)
        } else {
            stack.addArrangedSubview(row)
        }
        if let current = SlotColorStore.color(for: location) {
            updateSelectedColorUI(selected: current)
        }
    }

    @objc private func colorTapped(_ sender: UIButton) {
        let key = colorKeys[sender.tag]
        let name: String = {
            switch key {
            case .blue: return "青"
            case .green: return "緑"
            case .yellow: return "黄"
            case .red: return "赤"
            case .teal: return "エメラルドグリーン"
            case .gray: return "グレー"
            }
        }()

        let ac = UIAlertController(
            title: "色の変更",
            message: "このコマの色を「\(name)」に変更しますか？",
            preferredStyle: .alert
        )
        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        ac.addAction(UIAlertAction(title: "OK", style: .default, handler: { [weak self] _ in
            guard let self = self else { return }
            // 時間割へ通知（裏のセル色が即時変わる）
            self.delegate?.courseDetail(self, didChangeColor: key, at: self.location)
            // 自身のUI（選択リング）も更新
            self.updateSelectedColorUI(selected: key)
        }))
        present(ac, animated: true)
    }
    
    

    private func updateSelectedColorUI(selected: SlotColorKey) {
        for (i, b) in colorButtons.enumerated() {
            b.layer.borderWidth = (colorKeys[i] == selected) ? 3 : 1
        }
    }

    // MARK: - Web
    private func loadSyllabus() {
        guard
            let s = course.syllabusURL?.trimmingCharacters(in: .whitespacesAndNewlines),
            let url = URL(string: s),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            webContainer.isHidden = true
            return
        }
        webContainer.isHidden = false
        webView.isHidden = false
        webView.load(URLRequest(url: url))
    }

    // MARK: - Bottom Bar
    private func buildBottomBar() {
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.backgroundColor = .secondarySystemBackground
        view.addSubview(bottomBar)

        let hair = UIView()
        hair.backgroundColor = UIColor.separator
        hair.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(hair)

        let hStack = UIStackView()
        hStack.axis = .horizontal
        hStack.alignment = .center
        hStack.distribution = .fillEqually
        hStack.spacing = 16
        hStack.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(hStack)

        var editCfg = UIButton.Configuration.filled()
        editCfg.title = "編集"
        editCfg.baseBackgroundColor = .systemBlue.withAlphaComponent(0.15)
        editCfg.baseForegroundColor = .systemBlue
        editCfg.cornerStyle = .large
        editButton.configuration = editCfg
        editButton.addTarget(self, action: #selector(editTapped), for: .touchUpInside)

        var delCfg = UIButton.Configuration.filled()
        delCfg.title = "削除"
        delCfg.baseBackgroundColor = .systemRed.withAlphaComponent(0.15)
        delCfg.baseForegroundColor = .systemRed
        delCfg.cornerStyle = .large
        deleteButton.configuration = delCfg
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)

        hStack.addArrangedSubview(editButton)
        hStack.addArrangedSubview(deleteButton)

        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: bottomBarHeight),

            hair.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            hair.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            hair.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            hair.heightAnchor.constraint(equalToConstant: 0.5),

            hStack.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            hStack.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
            hStack.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            hStack.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    // MARK: - Counters
    private func setupCounterButton(_ b: UIButton, tag: Int, label: String) {
        b.tag = tag
        b.layer.cornerRadius = 44
        b.layer.masksToBounds = true
        b.layer.borderWidth = 1
        b.layer.borderColor = UIColor.separator.cgColor
        b.backgroundColor = .systemGray6
        b.widthAnchor.constraint(equalToConstant: 88).isActive = true
        b.heightAnchor.constraint(equalToConstant: 88).isActive = true

        b.addTarget(self, action: #selector(counterTapped(_:)), for: .touchUpInside)

        let lp = UILongPressGestureRecognizer(target: self, action: #selector(counterLongPressed(_:)))
        lp.minimumPressDuration = 0.5
        b.addGestureRecognizer(lp)

        setCounterButtonTitle(b, count: 0, label: label)
    }

    private func setCounterButtonTitle(_ b: UIButton, count: Int, label: String) {
        let num = NSAttributedString(
            string: "\(count)\n",
            attributes: [.font: UIFont.systemFont(ofSize: 32, weight: .semibold)]
        )
        let cap = NSAttributedString(
            string: label,
            attributes: [.font: UIFont.systemFont(ofSize: 14, weight: .regular)]
        )
        let s = NSMutableAttributedString(attributedString: num)
        s.append(cap)
        var cfg = UIButton.Configuration.plain()
        cfg.attributedTitle = AttributedString(s)
        cfg.titleAlignment = .center
        cfg.contentInsets = .init(top: 8, leading: 8, bottom: 8, trailing: 8)
        b.configuration = cfg
    }

    private func updateCounterButtons() {
        setCounterButtonTitle(attendBtn, count: counts.attended, label: "出席")
        setCounterButtonTitle(lateBtn,   count: counts.late,     label: "遅刻")
        setCounterButtonTitle(absentBtn, count: counts.absent,   label: "欠席")
    }

    @objc private func counterTapped(_ sender: UIButton) {
        switch sender.tag {
        case 0: counts.attended += 1
        case 1: counts.late     += 1
        default: counts.absent  += 1
        }
        saveCounts()
        updateCounterButtons()
        delegate?.courseDetail(self, didUpdate: counts, for: course, at: location)
    }

    @objc private func counterLongPressed(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began, let b = gr.view as? UIButton else { return }

        let current: Int
        let title: String
        switch b.tag {
        case 0: current = counts.attended; title = "出席を調整"
        case 1: current = counts.late;     title = "遅刻を調整"
        default: current = counts.absent;  title = "欠席を調整"
        }

        let ac = UIAlertController(title: title, message: "現在 \(current) 回", preferredStyle: .actionSheet)
        ac.addAction(UIAlertAction(title: "+1", style: .default, handler: { _ in
            self.counterTapped(b)
        }))
        ac.addAction(UIAlertAction(title: "−1", style: .default, handler: { _ in
            switch b.tag {
            case 0: self.counts.attended = max(0, self.counts.attended - 1)
            case 1: self.counts.late     = max(0, self.counts.late - 1)
            default: self.counts.absent  = max(0, self.counts.absent - 1)
            }
            self.saveCounts()
            self.updateCounterButtons()
            self.delegate?.courseDetail(self, didUpdate: self.counts, for: self.course, at: self.location)
        }))
        ac.addAction(UIAlertAction(title: "リセット", style: .destructive, handler: { _ in
            switch b.tag {
            case 0: self.counts.attended = 0
            case 1: self.counts.late     = 0
            default: self.counts.absent  = 0
            }
            self.saveCounts()
            self.updateCounterButtons()
            self.delegate?.courseDetail(self, didUpdate: self.counts, for: self.course, at: self.location)
        }))
        ac.addAction(UIAlertAction(title: "数を入力…", style: .default, handler: { _ in
            self.promptManualInput(for: b.tag, current: current)
        }))
        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        present(ac, animated: true)
    }

    private func promptManualInput(for tag: Int, current: Int) {
        let ac = UIAlertController(title: "回数を入力", message: nil, preferredStyle: .alert)
        ac.addTextField { tf in
            tf.keyboardType = .numberPad
            tf.text = "\(current)"
        }
        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        ac.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
            let v = Int(ac.textFields?.first?.text ?? "") ?? current
            switch tag {
            case 0: self.counts.attended = max(0, v)
            case 1: self.counts.late     = max(0, v)
            default: self.counts.absent  = max(0, v)
            }
            self.saveCounts()
            self.updateCounterButtons()
            self.delegate?.courseDetail(self, didUpdate: self.counts, for: self.course, at: self.location)
        }))
        present(ac, animated: true)
    }

    // MARK: - Edit / Delete Buttons
    @objc private func editTapped() {
        delegate?.courseDetail(self, requestEditFor: course, at: location)
    }

    @objc private func deleteTapped() {
        let ac = UIAlertController(
            title: "削除しますか？",
            message: "\(location.dayName) \(location.period)限の「\(course.title)」を削除します。",
            preferredStyle: .alert
        )
        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        ac.addAction(UIAlertAction(title: "削除", style: .destructive, handler: { _ in
            self.delegate?.courseDetail(self, requestDelete: self.course, at: self.location)
        }))
        present(ac, animated: true)
    }

    // MARK: - Persistence
    private func saveCounts() {
        let array = [counts.attended, counts.late, counts.absent]
        UserDefaults.standard.set(array, forKey: attendanceKey)
    }

    private func loadCounts() {
        if let array = UserDefaults.standard.array(forKey: attendanceKey) as? [Int], array.count == 3 {
            counts = AttendanceCounts(attended: array[0], late: array[1], absent: array[2])
        }
    }

    // MARK: - Helpers
    private func courseCreditsText() -> String? {
        let m = Mirror(reflecting: course)
        if let child = m.children.first(where: { $0.label == "credits" }) {
            if let n = child.value as? Int    { return "\(n)" }
            if let s = child.value as? String { return s }
        }
        return nil
    }
}


/*
差し替え前
import UIKit
import WebKit

// 出欠カウントを持ち回るための軽量構造体
struct AttendanceCounts: Codable {
    var attended: Int
    var late: Int
    var absent: Int
}

protocol CourseDetailViewControllerDelegate: AnyObject {
    func courseDetail(_ vc: CourseDetailViewController,
                      requestEditFor course: Course,
                      at location: SlotLocation)
    func courseDetail(_ vc: CourseDetailViewController,
                      requestDelete course: Course,
                      at location: SlotLocation)
    func courseDetail(_ vc: CourseDetailViewController,
                      didUpdate counts: AttendanceCounts,
                      for course: Course,
                      at location: SlotLocation)
    func courseDetail(_ vc: CourseDetailViewController, didChangeColor key: SlotColorKey, at location: SlotLocation)
}

final class CourseDetailViewController: UIViewController {

    weak var delegate: CourseDetailViewControllerDelegate?

    private let course: Course
    private let location: SlotLocation
    
    private let colorKeys: [SlotColorKey] = [.blue, .green, .yellow, .red, .teal, .gray]
    private var colorButtons: [UIButton] = []
    

    // MARK: - UI
    private let scroll = UIScrollView()
    private let stack  = UIStackView()
    private let titleLabel = UILabel()
    private let infoLabel  = UILabel()
    // 追加: カウンター右側の「メタ情報」用
    private let summaryRow = UIStackView()
    private let metaCard   = UIView()
    private let creditsLabel = UILabel()
    private let idLabel      = UILabel()


    // 出欠カウンター
    private let countersRow = UIStackView()
    private let attendBtn = UIButton(type: .system) // 出席
    private let lateBtn   = UIButton(type: .system) // 遅刻
    private let absentBtn = UIButton(type: .system) // 欠席

    // シラバス
    private let webView = WKWebView()
    private let webContainer = UIView() // あなたのUIに合わせて既存のコンテナ名でOK
    private var webHeightConstraint: NSLayoutConstraint!

    // 下部固定バー
    private let bottomBar = UIView()
    private let editButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private var bottomBarHeight: CGFloat = 76

    // 出欠の保存
    private var counts = AttendanceCounts(attended: 0, late: 0, absent: 0)
    private var attendanceKey: String { "attendance.\(course.id)" }
    
    // 追加: Course に credits がある場合だけ取り出す（Int / String 両対応）
    private func courseCreditsText() -> String? {
        let m = Mirror(reflecting: course)
        if let child = m.children.first(where: { $0.label == "credits" }) {
            if let n = child.value as? Int    { return "\(n)" }
            if let s = child.value as? String { return s }
        }
        return nil
    }


    // MARK: - Init
    init(course: Course, location: SlotLocation) {
        self.course   = course
        self.location = location
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // UIView をコードで用意（Storyboardは使わない）
    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        

        if let sheet = sheetPresentationController {
            sheet.prefersGrabberVisible = true
        }
        
        loadSyllabusIfAvailable()
        buildLayout()
        loadCounts()
        updateCounterButtons()

        loadSyllabus()   // ← これを追加
        
        buildColorPickerRow()
    }
    private func buildColorPickerRow() {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)

        // 置き場所：タイトル下あたりに固定（必要に応じて調整）
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            row.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])

        colorButtons = colorKeys.enumerated().map { (i, key) in
            let b = UIButton(type: .system)
            b.tag = i
            b.backgroundColor = key.uiColor
            b.setTitle("", for: .normal)
            b.layer.cornerRadius = 18
            b.layer.borderWidth = 1
            b.layer.borderColor = UIColor.separator.cgColor
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 36).isActive = true
            b.heightAnchor.constraint(equalToConstant: 36).isActive = true
            b.addTarget(self, action: #selector(colorTapped(_:)), for: .touchUpInside)
            row.addArrangedSubview(b)
            return b
        }
    }
    
    @objc private func colorTapped(_ sender: UIButton) {
        let key = colorKeys[sender.tag]
        // （見た目の選択リングを付けたい時はここで sender.layer.borderWidth = 3 など）
        delegate?.courseDetail(self, didChangeColor: key, at: location)
    }
    
    private func loadSyllabusIfAvailable() {
        guard let s = course.syllabusURL,
              let url = URL(string: s) else { return }
        webView.load(URLRequest(url: url))
    }
    
    private func loadSyllabus() {
        // String? → URL へ安全に変換
        guard let s = course.syllabusURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: s),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            // URL がなければ Web 表示を隠す
            webContainer.isHidden = true
            return
        }

        webContainer.isHidden = false
        webView.isHidden = false
        webView.load(URLRequest(url: url))
    }


    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 下部バーのぶんだけスクロールインセットを足して、隠れないようにする
        scroll.contentInset.bottom = bottomBarHeight + 16
        scroll.verticalScrollIndicatorInsets.bottom = bottomBarHeight
    }

    // MARK: - Layout
    private func buildLayout() {
        // スクロール + 縦スタック
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor)
        ])

        // タイトル
        titleLabel.text = course.title
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.numberOfLines = 0

        // 概要（曜日・限・教室・担当）
        infoLabel.text = "\(location.dayName) \(location.period)限\n教室: \(course.room)\n担当: \(course.teacher)"
        infoLabel.font = .systemFont(ofSize: 18, weight: .medium)
        infoLabel.numberOfLines = 0

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(infoLabel)
        
        summaryRow.axis = .horizontal
        summaryRow.alignment = .top
        summaryRow.spacing = 16
        summaryRow.distribution = .fill
        stack.addArrangedSubview(summaryRow)

        // 出欠カウンター
        countersRow.axis = .horizontal
        countersRow.alignment = .center
        countersRow.distribution = .equalSpacing
        countersRow.spacing = 16
        stack.addArrangedSubview(countersRow)

        setupCounterButton(attendBtn, tag: 0, label: "出席")
        setupCounterButton(lateBtn,   tag: 1, label: "遅刻")
        setupCounterButton(absentBtn, tag: 2, label: "欠席")
        countersRow.addArrangedSubview(attendBtn)
        countersRow.addArrangedSubview(lateBtn)
        countersRow.addArrangedSubview(absentBtn)
        
        // 右側の小カード
        metaCard.backgroundColor = .secondarySystemBackground
        metaCard.layer.cornerRadius = 12
        metaCard.layer.borderWidth = 0.5
        metaCard.layer.borderColor = UIColor.separator.cgColor
        metaCard.translatesAutoresizingMaskIntoConstraints = false
        metaCard.setContentHuggingPriority(.required, for: .horizontal)
        metaCard.setContentCompressionResistancePriority(.required, for: .horizontal)
        summaryRow.addArrangedSubview(metaCard)
        
        // カード内の縦スタック
        let metaStack = UIStackView()
        metaStack.axis = .vertical
        metaStack.alignment = .leading
        metaStack.spacing = 6
        metaStack.translatesAutoresizingMaskIntoConstraints = false
        metaCard.addSubview(metaStack)
        creditsLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        idLabel.font      = .systemFont(ofSize: 13, weight: .regular)
        creditsLabel.text = "単位: \(courseCreditsText() ?? "–")"
        idLabel.text      = "登録番号: \(course.id)"
        
        metaStack.addArrangedSubview(creditsLabel)
        metaStack.addArrangedSubview(idLabel)

        // カードの内側余白＆幅（お好みで調整）
        NSLayoutConstraint.activate([
            metaStack.topAnchor.constraint(equalTo: metaCard.topAnchor, constant: 12),
            metaStack.leadingAnchor.constraint(equalTo: metaCard.leadingAnchor, constant: 12),
            metaStack.trailingAnchor.constraint(equalTo: metaCard.trailingAnchor, constant: -12),
            metaStack.bottomAnchor.constraint(equalTo: metaCard.bottomAnchor, constant: -12),
            metaCard.widthAnchor.constraint(greaterThanOrEqualToConstant: 140) // 120〜160くらいが目安
        ])

        // WebView（高さは適度に確保）
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        let webContainer = UIView()
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor)
        ])
        webHeightConstraint = webContainer.heightAnchor.constraint(equalToConstant: 600) // 必要に応じて調整
        webHeightConstraint.isActive = true
        stack.addArrangedSubview(webContainer)

        // 下部固定バー
        buildBottomBar()
    }

    private func buildBottomBar() {
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.backgroundColor = .secondarySystemBackground
        view.addSubview(bottomBar)

        // うっすら境界線
        let hair = UIView()
        hair.backgroundColor = UIColor.separator
        hair.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(hair)

        let hStack = UIStackView()
        hStack.axis = .horizontal
        hStack.alignment = .center
        hStack.distribution = .fillEqually
        hStack.spacing = 16
        hStack.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(hStack)

        // 編集ボタン
        var editCfg = UIButton.Configuration.filled()
        editCfg.title = "編集"
        editCfg.baseBackgroundColor = .systemBlue.withAlphaComponent(0.15)
        editCfg.baseForegroundColor = .systemBlue
        editCfg.cornerStyle = .large
        editButton.configuration = editCfg
        editButton.addTarget(self, action: #selector(editTapped), for: .touchUpInside)

        // 削除ボタン
        var delCfg = UIButton.Configuration.filled()
        delCfg.title = "削除"
        delCfg.baseBackgroundColor = .systemRed.withAlphaComponent(0.15)
        delCfg.baseForegroundColor = .systemRed
        delCfg.cornerStyle = .large
        deleteButton.configuration = delCfg
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)

        hStack.addArrangedSubview(editButton)
        hStack.addArrangedSubview(deleteButton)

        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: bottomBarHeight),

            hair.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            hair.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            hair.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            hair.heightAnchor.constraint(equalToConstant: 0.5),

            hStack.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            hStack.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
            hStack.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            hStack.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    // MARK: - Counter Buttons
    private func setupCounterButton(_ b: UIButton, tag: Int, label: String) {
        b.tag = tag
        b.layer.cornerRadius = 44
        b.layer.masksToBounds = true
        b.layer.borderWidth = 1
        b.layer.borderColor = UIColor.separator.cgColor
        b.backgroundColor = .systemGray6
        b.widthAnchor.constraint(equalToConstant: 88).isActive = true
        b.heightAnchor.constraint(equalToConstant: 88).isActive = true

        // タップで +1
        b.addTarget(self, action: #selector(counterTapped(_:)), for: .touchUpInside)
        // 長押しで調整メニュー
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(counterLongPressed(_:)))
        lp.minimumPressDuration = 0.5
        b.addGestureRecognizer(lp)

        // 初期表示
        setCounterButtonTitle(b, count: 0, label: label)
    }

    private func setCounterButtonTitle(_ b: UIButton, count: Int, label: String) {
        let num = NSAttributedString(
            string: "\(count)\n",
            attributes: [.font: UIFont.systemFont(ofSize: 32, weight: .semibold)]
        )
        let cap = NSAttributedString(
            string: label,
            attributes: [.font: UIFont.systemFont(ofSize: 14, weight: .regular)]
        )
        let s = NSMutableAttributedString(attributedString: num)
        s.append(cap)
        var cfg = UIButton.Configuration.plain()
        cfg.attributedTitle = AttributedString(s)
        cfg.titleAlignment = .center
        cfg.contentInsets = .init(top: 8, leading: 8, bottom: 8, trailing: 8)
        b.configuration = cfg
    }

    private func updateCounterButtons() {
        setCounterButtonTitle(attendBtn, count: counts.attended, label: "出席")
        setCounterButtonTitle(lateBtn,   count: counts.late,     label: "遅刻")
        setCounterButtonTitle(absentBtn, count: counts.absent,   label: "欠席")
    }

    @objc private func counterTapped(_ sender: UIButton) {
        switch sender.tag {
        case 0: counts.attended += 1
        case 1: counts.late     += 1
        default: counts.absent  += 1
        }
        saveCounts()
        updateCounterButtons()
        delegate?.courseDetail(self, didUpdate: counts, for: course, at: location)
    }

    @objc private func counterLongPressed(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began, let b = gr.view as? UIButton else { return }

        let current: Int
        let title: String
        switch b.tag {
        case 0: current = counts.attended; title = "出席を調整"
        case 1: current = counts.late;     title = "遅刻を調整"
        default: current = counts.absent;  title = "欠席を調整"
        }

        let ac = UIAlertController(title: title, message: "現在 \(current) 回", preferredStyle: .actionSheet)
        ac.addAction(UIAlertAction(title: "+1", style: .default, handler: { _ in
            self.counterTapped(b)
        }))
        ac.addAction(UIAlertAction(title: "−1", style: .default, handler: { _ in
            switch b.tag {
            case 0: self.counts.attended = max(0, self.counts.attended - 1)
            case 1: self.counts.late     = max(0, self.counts.late - 1)
            default: self.counts.absent  = max(0, self.counts.absent - 1)
            }
            self.saveCounts()
            self.updateCounterButtons()
            self.delegate?.courseDetail(self, didUpdate: self.counts, for: self.course, at: self.location)
        }))
        ac.addAction(UIAlertAction(title: "リセット", style: .destructive, handler: { _ in
            switch b.tag {
            case 0: self.counts.attended = 0
            case 1: self.counts.late     = 0
            default: self.counts.absent  = 0
            }
            self.saveCounts()
            self.updateCounterButtons()
            self.delegate?.courseDetail(self, didUpdate: self.counts, for: self.course, at: self.location)
        }))
        ac.addAction(UIAlertAction(title: "数を入力…", style: .default, handler: { _ in
            self.promptManualInput(for: b.tag, current: current)
        }))
        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        present(ac, animated: true)
    }

    private func promptManualInput(for tag: Int, current: Int) {
        let ac = UIAlertController(title: "回数を入力", message: nil, preferredStyle: .alert)
        ac.addTextField { tf in
            tf.keyboardType = .numberPad
            tf.text = "\(current)"
        }
        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        ac.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
            let v = Int(ac.textFields?.first?.text ?? "") ?? current
            switch tag {
            case 0: self.counts.attended = max(0, v)
            case 1: self.counts.late     = max(0, v)
            default: self.counts.absent  = max(0, v)
            }
            self.saveCounts()
            self.updateCounterButtons()
            self.delegate?.courseDetail(self, didUpdate: self.counts, for: self.course, at: self.location)
        }))
        present(ac, animated: true)
    }

    // MARK: - Buttons (Edit / Delete)
    @objc private func editTapped() {
        delegate?.courseDetail(self, requestEditFor: course, at: location)
    }

    @objc private func deleteTapped() {
        let ac = UIAlertController(title: "削除しますか？",
                                   message: "\(location.dayName) \(location.period)限の「\(course.title)」を削除します。",
                                   preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        ac.addAction(UIAlertAction(title: "削除", style: .destructive, handler: { _ in
            self.delegate?.courseDetail(self, requestDelete: self.course, at: self.location)
        }))
        present(ac, animated: true)
    }

    // MARK: - Persistence
    private func saveCounts() {
        let array = [counts.attended, counts.late, counts.absent]
        UserDefaults.standard.set(array, forKey: attendanceKey)
    }
    private func loadCounts() {
        if let array = UserDefaults.standard.array(forKey: attendanceKey) as? [Int], array.count == 3 {
            counts = AttendanceCounts(attended: array[0], late: array[1], absent: array[2])
        }
    }
    
}
*/
