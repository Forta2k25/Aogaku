import UIKit
import GoogleMobileAds

@inline(__always)
private func makeAdaptiveAdSize(width: CGFloat) -> AdSize {
    return currentOrientationAnchoredAdaptiveBanner(width: width)
}

final class syllabus_search: UIViewController, BannerViewDelegate, UITextFieldDelegate {

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
    private let grabber = UIView()
    private let titleLabel = UILabel()
    private let headerButtonStack = UIStackView()
    private let resetButton = UIButton(type: .system)
    private let favoritesButton = UIButton(type: .system)

    private let searchRow = UIStackView()
    private let searchFieldContainer = UIView()
    private let searchIconView = UIImageView(image: UIImage(systemName: "magnifyingglass"))
    private let keywordTextField = UITextField()
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

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 8

        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 4),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -12),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32)
        ])

        let headerRow = UIStackView()
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = 8

        titleLabel.text = "シラバス検索"
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.textColor = .label

        headerButtonStack.axis = .horizontal
        headerButtonStack.spacing = 8
        headerButtonStack.alignment = .center

        configureTopIconButton(resetButton, systemName: "arrow.counterclockwise")
        configureTopIconButton(favoritesButton, systemName: "bookmark")
        resetButton.addTarget(self, action: #selector(didTapReset), for: .touchUpInside)
        favoritesButton.addTarget(self, action: #selector(didTapFavorites), for: .touchUpInside)
        headerButtonStack.addArrangedSubview(resetButton)
        headerButtonStack.addArrangedSubview(favoritesButton)

        headerRow.addArrangedSubview(titleLabel)
        headerRow.addArrangedSubview(UIView())
        headerRow.addArrangedSubview(headerButtonStack)
        contentStack.addArrangedSubview(headerRow)

        searchRow.axis = .horizontal
        searchRow.spacing = 8
        searchRow.alignment = .fill

        searchFieldContainer.translatesAutoresizingMaskIntoConstraints = false
        searchFieldContainer.layer.cornerRadius = 14
        searchFieldContainer.layer.masksToBounds = true
        searchFieldContainer.heightAnchor.constraint(equalToConstant: 52).isActive = true

        searchIconView.translatesAutoresizingMaskIntoConstraints = false
        searchIconView.tintColor = .secondaryLabel

        keywordTextField.translatesAutoresizingMaskIntoConstraints = false
        keywordTextField.borderStyle = .none
        keywordTextField.backgroundColor = .clear
        keywordTextField.placeholder = "授業名・教員名で検索"
        keywordTextField.font = .systemFont(ofSize: 15)
        keywordTextField.delegate = self
        keywordTextField.returnKeyType = .search

        searchFieldContainer.addSubview(searchIconView)
        searchFieldContainer.addSubview(keywordTextField)
        NSLayoutConstraint.activate([
            searchIconView.leadingAnchor.constraint(equalTo: searchFieldContainer.leadingAnchor, constant: 14),
            searchIconView.centerYAnchor.constraint(equalTo: searchFieldContainer.centerYAnchor),
            searchIconView.widthAnchor.constraint(equalToConstant: 20),
            searchIconView.heightAnchor.constraint(equalToConstant: 20),

            keywordTextField.leadingAnchor.constraint(equalTo: searchIconView.trailingAnchor, constant: 10),
            keywordTextField.trailingAnchor.constraint(equalTo: searchFieldContainer.trailingAnchor, constant: -12),
            keywordTextField.centerYAnchor.constraint(equalTo: searchFieldContainer.centerYAnchor),
            keywordTextField.heightAnchor.constraint(equalToConstant: 22)
        ])

        var applyConfig = UIButton.Configuration.filled()
        applyConfig.title = "検索"
        applyConfig.cornerStyle = .large
        applyConfig.baseBackgroundColor = .systemGreen
        applyConfig.baseForegroundColor = .white
        applyButton.configuration = applyConfig
        applyButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        applyButton.widthAnchor.constraint(equalToConstant: 96).isActive = true
        applyButton.heightAnchor.constraint(equalToConstant: 52).isActive = true
        applyButton.addTarget(self, action: #selector(didTapApply), for: .touchUpInside)

        searchRow.addArrangedSubview(searchFieldContainer)
        searchRow.addArrangedSubview(applyButton)
        contentStack.addArrangedSubview(searchRow)

        buttonRow.axis = .horizontal
        buttonRow.spacing = 8
        buttonRow.distribution = .fillEqually

        configureMenuButton(facultyButton, title: "学部")
        configureMenuButton(departmentButton, title: "学科")
        buttonRow.addArrangedSubview(facultyButton)
        buttonRow.addArrangedSubview(departmentButton)
        contentStack.addArrangedSubview(buttonRow)

        contentStack.addArrangedSubview(makeSegmentRow(campusSegmentedControl, items: ["指定なし","青山","相模原"]))
        contentStack.addArrangedSubview(makeSegmentRow(termSegmentedControl, items: ["指定なし","前期","後期"]))
        contentStack.addArrangedSubview(makeSegmentRow(placeSegmentedControl, items: ["指定なし","対面","オンライン"]))

        campusSegmentedControl.addTarget(self, action: #selector(campusChanged(_:)), for: .valueChanged)
        termSegmentedControl.addTarget(self, action: #selector(termChanged(_:)), for: .valueChanged)
        placeSegmentedControl.addTarget(self, action: #selector(placeChanged(_:)), for: .valueChanged)

        gridContainerView.translatesAutoresizingMaskIntoConstraints = false
        gridContainerView.heightAnchor.constraint(equalTo: gridContainerView.widthAnchor, multiplier: 0.82).isActive = true
        contentStack.addArrangedSubview(gridContainerView)

        buildSlotGrid()
        applyTheme()
    }

    private func configureTopIconButton(_ button: UIButton, systemName: String) {
        button.translatesAutoresizingMaskIntoConstraints = false
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: systemName)
        config.baseForegroundColor = .label
        config.background.backgroundColor = .systemBackground
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        button.configuration = config
        button.widthAnchor.constraint(equalToConstant: 48).isActive = true
        button.heightAnchor.constraint(equalToConstant: 48).isActive = true
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
        for row in 0..<5 {
            for col in 0..<5 {
                let button = UIButton(type: .system)
                button.translatesAutoresizingMaskIntoConstraints = false
                button.tag = row * 5 + col
                let title = "\(days[col])\(periods[row])"
                var config = UIButton.Configuration.plain()
                config.title = title
                config.baseForegroundColor = .lightGray
                config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                    var outgoing = incoming
                    outgoing.font = .systemFont(ofSize: 15, weight: .regular)
                    return outgoing
                }
                var bg = UIBackgroundConfiguration.clear()
                bg.backgroundColor = slotNormalBGColor(for: traitCollection)
                bg.cornerRadius = 0
                config.background = bg
                button.configuration = config
                button.layer.borderWidth = 1.0
                button.layer.borderColor = UIColor.black.cgColor
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
                btn.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: spacing).isActive = true
                btn.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
            }
            if col == 4 {
                btn.trailingAnchor.constraint(equalTo: gridContainerView.trailingAnchor).isActive = true
            }
            if row == 0 {
                btn.topAnchor.constraint(equalTo: gridContainerView.topAnchor).isActive = true
            } else {
                let above = slotButtons[(row - 1) * 5 + col]
                btn.topAnchor.constraint(equalTo: above.bottomAnchor, constant: spacing).isActive = true
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
        searchFieldContainer.backgroundColor = searchFieldBG(for: traitCollection)
        keywordTextField.textColor = (traitCollection.userInterfaceStyle == .dark) ? .black : .label
        keywordTextField.tintColor = keywordTextField.textColor
        let phColor: UIColor = (traitCollection.userInterfaceStyle == .dark) ? .systemGray2 : .placeholderText
        keywordTextField.attributedPlaceholder = NSAttributedString(string: "授業名・教員名で検索", attributes: [.foregroundColor: phColor])
        searchIconView.tintColor = (traitCollection.userInterfaceStyle == .dark) ? .black : .secondaryLabel
        [campusSegmentedControl, termSegmentedControl, placeSegmentedControl, registrationSegmentedControl].forEach(restyleSegmented)
        configureSlotButtons()
    }

    private func searchFieldBG(for trait: UITraitCollection) -> UIColor {
        (trait.userInterfaceStyle == .dark) ? .systemGray5 : .systemGray6
    }

    private func configureSlotButtons() {
        for button in slotButtons {
            button.configurationUpdateHandler = { [weak self] btn in
                guard let self = self else { return }
                var config = btn.configuration ?? .plain()
                config.baseForegroundColor = btn.isSelected ? .white : .lightGray
                var bg = config.background ?? UIBackgroundConfiguration.clear()
                bg.cornerRadius = 0
                bg.backgroundColor = btn.isSelected ? .systemGreen : self.slotNormalBGColor(for: self.traitCollection)
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
            keyword: keywordTextField.text,
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

        keywordTextField.text = nil
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

    @objc private func didTapFavorites() {
        let vc = FavoritesListViewController()
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
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

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        didTapApply()
        return true
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
