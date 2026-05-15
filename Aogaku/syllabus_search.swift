import UIKit
import GoogleMobileAds

@inline(__always)
private func makeAdaptiveAdSize(width: CGFloat) -> AdSize {
    return currentOrientationAnchoredAdaptiveBanner(width: width)
}

final class syllabus_search: UIViewController, BannerViewDelegate {

    // ===== 入出力 =====
    var initialCategory: String?
    var initialDepartment: String?
    var initialCampus: String?
    var initialPlace: String?
    var initialGrade: String?
    var initialDay: String?
    var initialPeriods: [Int]?
    var initialTimeSlots: [(String, Int)]?
    var initialTerm: String?
    var initialRegistrationType: String?
    var onApply: ((SyllabusSearchCriteria) -> Void)?
    var term: String?

    // ===== AdMob =====
    private let adContainer = UIView()
    private var bannerView: BannerView?
    private var adContainerHeight: NSLayoutConstraint?
    private var lastBannerWidth: CGFloat = 0
    private var didLoadBannerOnce = false
    private let bannerBottomOffset: CGFloat = 45

    // ===== UI =====
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let applyButton = UIButton(type: .system)

    private let buttonRow = UIStackView()
    private let facultyButton = UIButton(type: .system)
    private let departmentButton = UIButton(type: .system)

    private let campusSegmentedControl = UISegmentedControl()
    private let termSegmentedControl = UISegmentedControl()
    private let placeSegmentedControl = UISegmentedControl()
    private let registrationSegmentedControl = UISegmentedControl()

    private let gridContainerView = UIView()
    private var slotButtons: [UIButton] = []

    // ===== 内部状態 =====
    private var selectedCategory: String?
    private var selectedDepartment: String?
    private var selectedCampus: String?
    private var selectedPlace: String?
    private var selectedGrade: String?
    private var selectedTerm: String?
    private var selectedRegistrationType: String?

    private var selectedStates = Array(repeating: false, count: 25)
    private let days = ["月","火","水","木","金"]
    private let periods = [1,2,3,4,5]
    private let spacing: CGFloat = 0

    private let faculties = [
        "指定なし","文学部","教育人間科学部","経済学部","法学部","経営学部",
        "国際政治経済学部","総合文化政策学部","理工学部",
        "コミュニティ人間科学部","社会情報学部","地球社会共生学部",
        "青山スタンダード科目","教職課程科目"
    ]
    private let departments: [String: [String]] = [
        "指定なし": ["指定なし"],
        "文学部": ["指定なし","英米文学科","フランス文学科","日本文学科","史学科","比較芸術学科"],
        "教育人間科学部": ["指定なし","教育学科","心理学科","外国語科目"],
        "経済学部": ["指定なし","経済学科","現代経済デザイン学科"],
        "法学部": ["指定なし","法学科","ヒューマンライツ学科"],
        "経営学部": ["指定なし","経営学科","マーケティング学科"],
        "国際政治経済学部": ["指定なし","国際政治学科","国際経済学科","国際コミュニケーション学科"],
        "総合文化政策学部": ["指定なし","総合文化政策学科"],
        "理工学部": ["指定なし","物理科学科","数理サイエンス学科","化学・生命科学科","電気電子工学科","機械創造工学科","経営システム工学科","情報テクノロジー学科"],
        "コミュニティ人間科学部": ["指定なし","コミュニティ人間科学科"],
        "社会情報学部": ["指定なし","社会情報学科"],
        "地球社会共生学部": ["指定なし","地球社会共生学科"],
        "青山スタンダード科目": ["指定なし"],
        "教職課程科目": ["指定なし"]
    ]

    override func viewDidLoad() {
        super.viewDidLoad()

        selectedCategory = initialCategory
        selectedDepartment = initialDepartment
        selectedCampus = initialCampus
        selectedPlace = initialPlace
        selectedGrade = initialGrade
        selectedTerm = initialTerm
        selectedRegistrationType = initialRegistrationType

        // ナビバー
        title = "絞り込み"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(didTapClose))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "リセット", style: .plain, target: self, action: #selector(didTapReset))

        buildUI()
        setupFacultyMenu()
        setupDepartmentMenu(initial: selectedCategory ?? "指定なし")
        configureInitialSelections()
        configureSlotButtons()
        setupAdBanner()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(onAdMobReady),
                                               name: .adMobReady,
                                               object: nil)
    }

    @objc private func didTapClose() { dismiss(animated: true) }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        loadBannerIfNeeded()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyTheme()
        }
    }

    @objc private func onAdMobReady() {
        loadBannerIfNeeded()
    }

    private func buildUI() {
        view.backgroundColor = searchBGColor(for: traitCollection)

        // MARK: スクロールエリア
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 12

        // MARK: 下部の「この条件で検索」ボタン
        var applyCfg = UIButton.Configuration.filled()
        applyCfg.title = "この条件で検索"
        applyCfg.cornerStyle = .large
        applyCfg.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 0, bottom: 16, trailing: 0)
        applyCfg.baseBackgroundColor = UIColor(red: 0/255, green: 120/255, blue: 87/255, alpha: 1)
        applyCfg.baseForegroundColor = .white
        applyCfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var b = a; b.font = .systemFont(ofSize: 16, weight: .bold); return b
        }
        applyButton.configuration = applyCfg
        applyButton.translatesAutoresizingMaskIntoConstraints = false
        applyButton.addTarget(self, action: #selector(didTapApply), for: .touchUpInside)

        let bottomBar = UIView()
        bottomBar.backgroundColor = searchBGColor(for: traitCollection)
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(applyButton)

        view.addSubview(bottomBar)
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            applyButton.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 12),
            applyButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            applyButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
            applyButton.bottomAnchor.constraint(equalTo: bottomBar.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32)
        ])

        // MARK: 学期
        contentStack.addArrangedSubview(makeSectionCard(
            label: "学期",
            content: makeSegmentRow(termSegmentedControl, items: ["指定なし", "前期", "後期"])
        ))
        termSegmentedControl.addTarget(self, action: #selector(termChanged(_:)), for: .valueChanged)

        // MARK: キャンパス
        contentStack.addArrangedSubview(makeSectionCard(
            label: "キャンパス",
            content: makeSegmentRow(campusSegmentedControl, items: ["指定なし", "青山", "相模原"])
        ))
        campusSegmentedControl.addTarget(self, action: #selector(campusChanged(_:)), for: .valueChanged)

        // MARK: 形式
        contentStack.addArrangedSubview(makeSectionCard(
            label: "形式",
            content: makeSegmentRow(placeSegmentedControl, items: ["指定なし", "対面", "オンライン"])
        ))
        placeSegmentedControl.addTarget(self, action: #selector(placeChanged(_:)), for: .valueChanged)

        // MARK: 曜日・時限グリッド
        gridContainerView.translatesAutoresizingMaskIntoConstraints = false
        gridContainerView.heightAnchor.constraint(equalTo: gridContainerView.widthAnchor, multiplier: 0.78).isActive = true
        contentStack.addArrangedSubview(makeSectionCard(label: "曜日・時限", content: gridContainerView))
        buildSlotGrid()

        // MARK: 学部・学科
        buttonRow.axis = .horizontal
        buttonRow.spacing = 8
        buttonRow.distribution = .fillEqually
        configureMenuButton(facultyButton, title: "学部")
        configureMenuButton(departmentButton, title: "学科")
        buttonRow.addArrangedSubview(facultyButton)
        buttonRow.addArrangedSubview(departmentButton)
        contentStack.addArrangedSubview(makeSectionCard(label: "学部・学科", content: buttonRow))

        applyTheme()
    }

    // カード形式のセクションを生成
    private func makeSectionCard(label: String, content: UIView) -> UIView {
        let lbl = UILabel()
        lbl.text = label
        lbl.font = .systemFont(ofSize: 13, weight: .semibold)
        lbl.textColor = .secondaryLabel

        let inner = UIStackView(arrangedSubviews: [lbl, content])
        inner.axis = .vertical
        inner.spacing = 8
        inner.translatesAutoresizingMaskIntoConstraints = false

        let card = UIView()
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 14
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.04
        card.layer.shadowOffset = CGSize(width: 0, height: 1)
        card.layer.shadowRadius = 4
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])
        return card
    }

    private func configureMenuButton(_ button: UIButton, title: String) {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = .systemBackground
        config.baseForegroundColor = .lightGray
        config.cornerStyle = .medium
        config.titleAlignment = .center
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        button.configuration = config
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.heightAnchor.constraint(equalToConstant: 46).isActive = true
    }

    private func makeSegmentRow(_ control: UISegmentedControl, items: [String]) -> UIView {
        control.translatesAutoresizingMaskIntoConstraints = false
        control.removeAllSegments()
        for (idx, item) in items.enumerated() {
            control.insertSegment(withTitle: item, at: idx, animated: false)
        }
        control.selectedSegmentIndex = 0
        restyleSegmented(control)
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(control)
        NSLayoutConstraint.activate([
            control.topAnchor.constraint(equalTo: container.topAnchor),
            control.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            control.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            control.heightAnchor.constraint(equalToConstant: 44)
        ])
        return container
    }

    private func buildSlotGrid() {
        slotButtons = []
        let gap: CGFloat = 5
        for row in 0..<5 {
            for col in 0..<5 {
                let button = UIButton(type: .system)
                button.translatesAutoresizingMaskIntoConstraints = false
                button.tag = row * 5 + col
                let title = "\(days[col])\(periods[row])"
                var config = UIButton.Configuration.plain()
                config.title = title
                config.baseForegroundColor = .secondaryLabel
                config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                    var outgoing = incoming
                    outgoing.font = .systemFont(ofSize: 14, weight: .medium)
                    return outgoing
                }
                var bg = UIBackgroundConfiguration.clear()
                bg.backgroundColor = slotNormalBGColor(for: traitCollection)
                bg.cornerRadius = 10
                config.background = bg
                button.configuration = config
                button.addTarget(self, action: #selector(slotTapped(_:)), for: .touchUpInside)
                slotButtons.append(button)
                gridContainerView.addSubview(button)
            }
        }

        for idx in 0..<slotButtons.count {
            let btn = slotButtons[idx]
            let row = idx / 5
            let col = idx % 5
            if col == 0 {
                btn.leadingAnchor.constraint(equalTo: gridContainerView.leadingAnchor).isActive = true
            } else {
                let left = slotButtons[idx - 1]
                btn.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: gap).isActive = true
                btn.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
            }
            if col == 4 {
                btn.trailingAnchor.constraint(equalTo: gridContainerView.trailingAnchor).isActive = true
            }
            if row == 0 {
                btn.topAnchor.constraint(equalTo: gridContainerView.topAnchor).isActive = true
            } else {
                let above = slotButtons[(row - 1) * 5 + col]
                btn.topAnchor.constraint(equalTo: above.bottomAnchor, constant: gap).isActive = true
                btn.heightAnchor.constraint(equalTo: above.heightAnchor).isActive = true
            }
            if row == 4 {
                btn.bottomAnchor.constraint(equalTo: gridContainerView.bottomAnchor).isActive = true
            }
        }
    }

    private func configureInitialSelections() {
        selectedCategory = initialCategory
        selectedDepartment = initialDepartment
        if let cat = selectedCategory, cat != "指定なし" {
            setButtonTitleAndColor(facultyButton, title: cat, color: .black)
        } else {
            setButtonTitleAndColor(facultyButton, title: "学部", color: .lightGray)
            selectedCategory = initialCategory
        }

        if let title = departmentDisplayTitle(for: selectedCategory, stored: selectedDepartment) {
            setButtonTitleAndColor(departmentButton, title: title, color: .black)
        } else {
            setButtonTitleAndColor(departmentButton, title: "学科", color: .lightGray)
            selectedDepartment = initialDepartment
        }

        campusSegmentedControl.selectedSegmentIndex = indexFor(value: selectedCampus, in: ["指定なし","青山","相模原"])
        placeSegmentedControl.selectedSegmentIndex = indexFor(value: selectedPlace, in: ["指定なし","対面","オンライン"])
        termSegmentedControl.selectedSegmentIndex = indexFor(value: selectedTerm, in: ["指定なし","前期","後期"])

        if let slots = initialTimeSlots, !slots.isEmpty {
            for (dayName, period) in slots {
                guard let col = days.firstIndex(of: dayName) else { continue }
                let row = period - 1
                let idx = row * 5 + col
                if selectedStates.indices.contains(idx) {
                    selectedStates[idx] = true
                }
            }
        } else if let d = initialDay, let ps = initialPeriods, let col = days.firstIndex(of: d) {
            for p in ps {
                let row = p - 1
                let idx = row * 5 + col
                if selectedStates.indices.contains(idx) {
                    selectedStates[idx] = true
                }
            }
        }

        for button in slotButtons where selectedStates.indices.contains(button.tag) {
            button.isSelected = selectedStates[button.tag]
            button.configurationUpdateHandler?(button)
        }
    }

    private func registrationDisplayValue(for raw: String?) -> String? {
        switch raw {
        case "required": return "必修"
        case "lottery": return "抽選"
        case "selectable": return "選択"
        default: return nil
        }
    }

    private func searchBGColor(for trait: UITraitCollection) -> UIColor {
        (trait.userInterfaceStyle == .dark) ? .systemGray5 : .systemGray6
    }

    private func slotNormalBGColor(for trait: UITraitCollection) -> UIColor {
        if trait.userInterfaceStyle == .dark {
            return .systemGray3
        } else {
            return UIColor(white: 0.96, alpha: 1.0)
        }
    }

    private func restyleSegmented(_ sc: UISegmentedControl) {
        let isDark = (traitCollection.userInterfaceStyle == .dark)
        sc.backgroundColor = isDark ? .systemGray5 : UIColor(white: 0.95, alpha: 1.0)
        sc.selectedSegmentTintColor = isDark ? .systemGray2 : UIColor(white: 1.0, alpha: 1.0)
        sc.setTitleTextAttributes([.foregroundColor: UIColor.secondaryLabel, .font: UIFont.systemFont(ofSize: 17, weight: .medium)], for: .normal)
        sc.setTitleTextAttributes([.foregroundColor: UIColor.label, .font: UIFont.systemFont(ofSize: 17, weight: .semibold)], for: .selected)
        sc.layer.cornerRadius = 12
        sc.layer.masksToBounds = true
    }

    private func applyTheme() {
        let bg = searchBGColor(for: traitCollection)
        view.backgroundColor = bg
        scrollView.backgroundColor = bg
        contentStack.backgroundColor = .clear
        adContainer.backgroundColor = bg
        [campusSegmentedControl, termSegmentedControl, placeSegmentedControl].forEach(restyleSegmented)
        configureSlotButtons()
    }

    private func configureSlotButtons() {
        let green = UIColor(red: 0/255, green: 120/255, blue: 87/255, alpha: 1)
        for button in slotButtons {
            button.configurationUpdateHandler = { [weak self] btn in
                guard let self = self else { return }
                var config = btn.configuration ?? .plain()
                config.baseForegroundColor = btn.isSelected ? .white : .secondaryLabel
                var bg = config.background ?? UIBackgroundConfiguration.clear()
                bg.cornerRadius = 10
                bg.backgroundColor = btn.isSelected ? green : self.slotNormalBGColor(for: self.traitCollection)
                config.background = bg
                btn.configuration = config
            }
            button.configurationUpdateHandler?(button)
        }
    }

    private func setupFacultyMenu() {
        let actions = faculties.map { name in
            UIAction(title: name) { [weak self] action in
                guard let self = self else { return }
                if action.title == "指定なし" {
                    self.selectedCategory = nil
                    self.setButtonTitleAndColor(self.facultyButton, title: "学部", color: .lightGray)
                } else {
                    self.selectedCategory = action.title
                    self.setButtonTitleAndColor(self.facultyButton, title: action.title, color: .black)
                }
                self.selectedDepartment = nil
                self.setButtonTitleAndColor(self.departmentButton, title: "学科", color: .lightGray)
                self.setupDepartmentMenu(initial: action.title)
            }
        }
        facultyButton.menu = UIMenu(children: actions)
        facultyButton.showsMenuAsPrimaryAction = true
    }

    private func setupDepartmentMenu(initial faculty: String) {
        let list = departments[faculty] ?? ["指定なし"]
        let actions = list.map { dept in
            UIAction(title: dept) { [weak self] action in
                guard let self = self else { return }
                if action.title == "指定なし" {
                    self.selectedDepartment = nil
                    self.setButtonTitleAndColor(self.departmentButton, title: "学科", color: .lightGray)
                } else {
                    if faculty == "教育人間科学部" {
                        self.selectedDepartment = "教育人間　\(action.title)"
                    } else if faculty == "理工学部" {
                        self.selectedDepartment = self.mapScienceDeptToCategory(deptDisplay: action.title)
                    } else {
                        self.selectedDepartment = action.title
                    }
                    self.setButtonTitleAndColor(self.departmentButton, title: action.title, color: .black)
                }
            }
        }
        departmentButton.menu = UIMenu(children: actions)
        departmentButton.showsMenuAsPrimaryAction = true
    }

    private func departmentDisplayTitle(for faculty: String?, stored: String?) -> String? {
        guard let stored else { return nil }
        guard faculty == "教育人間科学部" else { return stored }
        for value in ["教育学科", "心理学科", "外国語科目"] {
            if stored == "教育人間　\(value)" || stored == "教育人間 \(value)" {
                return value
            }
        }
        return nil
    }

    private func mapScienceDeptToCategory(deptDisplay: String) -> String {
        switch deptDisplay {
        case "物理科学科", "物理数学科", "物理・数理学科": return "物理・数理"
        case "数理サイエンス学科": return "数理サイエンス"
        case "化学・生命科学科": return "化学・生命"
        case "電気電子工学科": return "電気電子工学科"
        case "機械創造工学科": return "機械創造"
        case "経営システム工学科": return "経営システム"
        case "情報テクノロジー学科": return "情報テクノロジー"
        default: return deptDisplay
        }
    }

    private func setButtonTitleAndColor(_ button: UIButton, title: String, color: UIColor) {
        var config = button.configuration ?? .filled()
        config.title = title
        config.baseForegroundColor = color
        config.baseBackgroundColor = .systemBackground
        button.configuration = config
    }

    private func indexFor(value: String?, in list: [String]) -> Int {
        guard let value, let index = list.firstIndex(of: value) else { return 0 }
        return index
    }

    @objc private func campusChanged(_ sender: UISegmentedControl) {
        let title = sender.titleForSegment(at: sender.selectedSegmentIndex) ?? "指定なし"
        selectedCampus = (title == "指定なし") ? nil : title
    }

    @objc private func placeChanged(_ sender: UISegmentedControl) {
        let title = sender.titleForSegment(at: sender.selectedSegmentIndex) ?? "指定なし"
        selectedPlace = (title == "指定なし") ? nil : title
    }

    @objc private func termChanged(_ sender: UISegmentedControl) {
        let title = sender.titleForSegment(at: sender.selectedSegmentIndex) ?? "指定なし"
        selectedTerm = (title == "指定なし") ? nil : title
    }

    @objc private func registrationTypeChanged(_ sender: UISegmentedControl) {
        let title = sender.titleForSegment(at: sender.selectedSegmentIndex) ?? "指定なし"
        switch title {
        case "必修": selectedRegistrationType = "required"
        case "抽選": selectedRegistrationType = "lottery"
        case "選択": selectedRegistrationType = "selectable"
        default: selectedRegistrationType = nil
        }
    }

    @objc private func slotTapped(_ sender: UIButton) {
        sender.isSelected.toggle()
        if selectedStates.indices.contains(sender.tag) {
            selectedStates[sender.tag] = sender.isSelected
        }
    }

    @objc private func didTapApply() {
        var campusValue: String?
        if let title = campusSegmentedControl.titleForSegment(at: campusSegmentedControl.selectedSegmentIndex), title != "指定なし" {
            campusValue = title
        }
        var placeValue: String?
        if let title = placeSegmentedControl.titleForSegment(at: placeSegmentedControl.selectedSegmentIndex), title != "指定なし" {
            placeValue = title
        }
        let slots = deriveTimeSlots()
        let (day, ps) = deriveSingleDayAndPeriods()

        let criteria = SyllabusSearchCriteria(
            keyword: nil,
            category: selectedCategory,
            department: selectedDepartment,
            campus: campusValue,
            place: placeValue,
            grade: selectedGrade,
            day: day,
            periods: ps,
            timeSlots: slots,
            term: selectedTerm,
            undecided: nil,
           // registrationType: selectedRegistrationType
        )

        let handler = onApply
        dismiss(animated: true) { handler?(criteria) }
    }

    @objc private func didTapReset() {
        selectedCategory = initialCategory
        selectedDepartment = initialDepartment
        selectedCampus = nil
        selectedPlace = nil
        selectedGrade = nil
        selectedTerm = nil
        selectedRegistrationType = nil
        selectedStates = Array(repeating: false, count: selectedStates.count)

        setButtonTitleAndColor(facultyButton, title: "学部", color: .lightGray)
        setButtonTitleAndColor(departmentButton, title: "学科", color: .lightGray)
        campusSegmentedControl.selectedSegmentIndex = 0
        placeSegmentedControl.selectedSegmentIndex = 0
        termSegmentedControl.selectedSegmentIndex = 0
        slotButtons.forEach { $0.isSelected = false; $0.configurationUpdateHandler?($0) }
        view.endEditing(true)

        let criteria = SyllabusSearchCriteria(keyword: nil,
                                              category: nil,
                                              department: nil,
                                              campus: nil,
                                              place: nil,
                                              grade: nil,
                                              day: nil,
                                              periods: nil,
                                              timeSlots: nil,
                                              term: nil,
                                              undecided: nil,
                                             // registrationType: nil
        )
        onApply?(criteria)
    }

    private func deriveTimeSlots() -> [(String, Int)]? {
        var result: [(String, Int)] = []
        for idx in 0..<selectedStates.count where selectedStates[idx] {
            let row = idx / 5
            let col = idx % 5
            result.append((days[col], periods[row]))
        }
        return result.isEmpty ? nil : result
    }

    private func deriveSingleDayAndPeriods() -> (String?, [Int]?) {
        var pairs: [(dayIndex: Int, period: Int)] = []
        for idx in 0..<selectedStates.count where selectedStates[idx] {
            let row = idx / 5
            let col = idx % 5
            pairs.append((dayIndex: col, period: periods[row]))
        }
        guard !pairs.isEmpty else { return (nil, nil) }
        let first = pairs[0].dayIndex
        guard pairs.allSatisfy({ $0.dayIndex == first }) else { return (nil, nil) }
        return (days[first], pairs.map { $0.period }.sorted())
    }

    // ===== Ad =====
    private func setupAdBanner() {
        adContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(adContainer)

        adContainerHeight = adContainer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            adContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            adContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            adContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: bannerBottomOffset),
            adContainerHeight!
        ])

        guard AdsConfig.enabled else {
            adContainer.isHidden = true
            adContainerHeight?.constant = 0
            return
        }

        let banner = BannerView()
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.adUnitID = AdsConfig.bannerUnitID
        banner.rootViewController = self
        banner.adSize = AdSizeBanner
        banner.delegate = self
        adContainer.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: adContainer.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: adContainer.trailingAnchor),
            banner.topAnchor.constraint(equalTo: adContainer.topAnchor),
            banner.bottomAnchor.constraint(equalTo: adContainer.bottomAnchor)
        ])
        bannerView = banner
    }

    private func loadBannerIfNeeded() {
        guard let bannerView else { return }
        let safeWidth = view.safeAreaLayoutGuide.layoutFrame.width
        if safeWidth <= 0 { return }
        let useWidth = max(320, floor(safeWidth))
        if abs(useWidth - lastBannerWidth) < 0.5 { return }
        lastBannerWidth = useWidth
        let size = makeAdaptiveAdSize(width: useWidth)
        adContainerHeight?.constant = size.size.height
        additionalSafeAreaInsets.bottom = max(0, size.size.height - bannerBottomOffset)
        view.layoutIfNeeded()
        guard size.size.height > 0 else { return }
        if !CGSizeEqualToSize(bannerView.adSize.size, size.size) { bannerView.adSize = size }
        if !didLoadBannerOnce {
            didLoadBannerOnce = true
            bannerView.load(Request())
        }
    }

    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        let height = bannerView.adSize.size.height
        adContainerHeight?.constant = height
        additionalSafeAreaInsets.bottom = max(0, height - bannerBottomOffset)
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
    }

    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        adContainerHeight?.constant = 0
        additionalSafeAreaInsets.bottom = 0
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
        print("Ad failed:", error.localizedDescription)
    }
}
