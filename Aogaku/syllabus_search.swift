import UIKit

final class syllabus_search: UIViewController {

    // 入出力
    var initialCategory: String?
    var initialDepartment: String?
    var initialCampus: String?
    var initialPlace: String?          // "対面" / "オンライン"
    var initialGrade: String?
    var initialDay: String?
    var initialPeriods: [Int]?
    var initialTimeSlots: [(String, Int)]?   // ★ 複数コマの復元用
    var onApply: ((SyllabusSearchCriteria) -> Void)?

    // Outlets
    @IBOutlet weak var keywordTextField: UITextField!
    @IBOutlet weak var facultyButton: UIButton!
    @IBOutlet weak var departmentButton: UIButton!
    @IBOutlet weak var campusSegmentedControl: UISegmentedControl!
    @IBOutlet weak var placeSegmentedControl: UISegmentedControl!
    @IBOutlet var slotButtons: [UIButton]!
    @IBOutlet weak var gridContainerView: UIView!

    // 内部状態
    private var selectedCategory: String?
    private var selectedDepartment: String?
    private var selectedCampus: String?
    private var selectedPlace: String?
    private var selectedGrade: String?

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
        "教育人間科学部": ["指定なし","教育学科","心理学科"],
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

    // 一度だけやる系
    private var didAssignTags = false
    private var didApplyInitialSelection = false
    private var didBuildGridConstraints = false

    override func viewDidLoad() {
        super.viewDidLoad()

        selectedCategory   = initialCategory
        selectedDepartment = initialDepartment
        selectedCampus     = initialCampus
        selectedPlace      = initialPlace
        selectedGrade      = initialGrade

        setupFacultyMenu()
        setupDepartmentMenu(initial: selectedCategory ?? "指定なし")

        // 学部
        if let cat = selectedCategory, cat != "指定なし" {
            facultyButton.setTitle(cat, for: .normal); setButtonTitleColor(facultyButton, .black)
        } else {
            facultyButton.setTitle("学部", for: .normal); setButtonTitleColor(facultyButton, .lightGray)
            selectedCategory = nil
        }
        // 学科
        if let dept = selectedDepartment,
           let list = departments[selectedCategory ?? "指定なし"], list.contains(dept) {
            departmentButton.setTitle(dept, for: .normal); setButtonTitleColor(departmentButton, .black)
        } else {
            departmentButton.setTitle("学科", for: .normal); setButtonTitleColor(departmentButton, .lightGray)
            selectedDepartment = nil
        }

        // キャンパス
        let campuses = ["指定なし","青山","相模原"]
        campusSegmentedControl.removeAllSegments()
        for (i, t) in campuses.enumerated() { campusSegmentedControl.insertSegment(withTitle: t, at: i, animated: false) }
        campusSegmentedControl.selectedSegmentIndex = indexFor(value: selectedCampus, in: campuses)
        campusSegmentedControl.setTitleTextAttributes([.foregroundColor: UIColor.gray], for: .normal)
        campusSegmentedControl.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)

        // 形態
        let places = ["指定なし","対面","オンライン"]
        placeSegmentedControl.removeAllSegments()
        for (i, t) in places.enumerated() { placeSegmentedControl.insertSegment(withTitle: t, at: i, animated: false) }
        placeSegmentedControl.selectedSegmentIndex = indexFor(value: selectedPlace, in: places)
        placeSegmentedControl.setTitleTextAttributes([.foregroundColor: UIColor.gray], for: .normal)
        placeSegmentedControl.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)

        configureSlotButtons()
        // グリッド制約/タグ採番/初期選択は viewDidLayoutSubviews で
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        assignTagsIfNeeded()
        buildGridConstraintsIfNeeded()
        applyInitialSelectionIfNeeded()
    }

    // Actions
    @IBAction func campusChanged(_ sender: UISegmentedControl) {
        let title = sender.titleForSegment(at: sender.selectedSegmentIndex) ?? "指定なし"
        selectedCampus = (title == "指定なし") ? nil : title
    }
    @IBAction func placeChanged(_ sender: UISegmentedControl) {
        let title = sender.titleForSegment(at: sender.selectedSegmentIndex) ?? "指定なし"
        selectedPlace = (title == "指定なし") ? nil : title
    }
    @IBAction func slotTapped(_ sender: UIButton) {
        sender.isSelected.toggle()
        let idx = sender.tag
        if selectedStates.indices.contains(idx) { selectedStates[idx] = sender.isSelected }
    }
    @IBAction func didTapClose(_ sender: Any) { dismiss(animated: true) }

    // 検索ボタン
    @IBAction func didTapApply(_ sender: Any) {
        var campusValue: String? = nil
        if let t = campusSegmentedControl.titleForSegment(at: campusSegmentedControl.selectedSegmentIndex),
           t != "指定なし" { campusValue = t }

        var placeValue: String? = nil
        if let t = placeSegmentedControl.titleForSegment(at: placeSegmentedControl.selectedSegmentIndex),
           t != "指定なし" { placeValue = t }

        let slots = deriveTimeSlots()
        let (day, ps) = deriveSingleDayAndPeriods()

        let criteria = SyllabusSearchCriteria(
            keyword: keywordTextField?.text,
            category: selectedCategory,
            department: selectedDepartment,
            campus: campusValue,
            place: placeValue,
            grade: selectedGrade,
            day: day,
            periods: ps,
            timeSlots: slots
        )
        let handler = self.onApply
        dismiss(animated: true) { handler?(criteria) }
    }

    // メニュー
    private func setupFacultyMenu() {
        let actions = faculties.map { name in
            UIAction(title: name) { [weak self] act in
                guard let self = self else { return }
                if act.title == "指定なし" {
                    self.selectedCategory = nil
                    self.facultyButton.setTitle("学部", for: .normal)
                    self.setButtonTitleColor(self.facultyButton, .lightGray)
                } else {
                    self.selectedCategory = act.title
                    self.facultyButton.setTitle(act.title, for: .normal)
                    self.setButtonTitleColor(self.facultyButton, .black)
                }
                self.selectedDepartment = nil
                self.departmentButton.setTitle("学科", for: .normal)
                self.setButtonTitleColor(self.departmentButton, .lightGray)
                self.setupDepartmentMenu(initial: act.title)
            }
        }
        facultyButton.menu = UIMenu(children: actions)
        facultyButton.showsMenuAsPrimaryAction = true
    }

    private func setupDepartmentMenu(initial faculty: String) {
        let list = departments[faculty] ?? ["指定なし"]
        let actions = list.map { dept in
            UIAction(title: dept) { [weak self] act in
                guard let self = self else { return }
                if act.title == "指定なし" {
                    self.selectedDepartment = nil
                    self.departmentButton.setTitle("学科", for: .normal)
                    self.setButtonTitleColor(self.departmentButton, .lightGray)
                } else {
                    self.selectedDepartment = act.title
                    self.departmentButton.setTitle(act.title, for: .normal)
                    self.setButtonTitleColor(self.departmentButton, .black)
                }
            }
        }
        departmentButton.menu = UIMenu(children: actions)
        departmentButton.showsMenuAsPrimaryAction = true
    }

    // --- グリッド関連 ---
    private func assignTagsIfNeeded() {
        guard !didAssignTags, let slotButtons else { return }
        // AutoLayout後の座標で上→下、左→右に並べ替え
        let sorted = slotButtons.sorted {
            if abs($0.frame.minY - $1.frame.minY) > 0.5 { return $0.frame.minY < $1.frame.minY }
            return $0.frame.minX < $1.frame.minX
        }
        for (idx, btn) in sorted.enumerated() { btn.tag = idx } // 0...24
        didAssignTags = true
    }

    private func buildGridConstraintsIfNeeded() {
        guard !didBuildGridConstraints, let slotButtons else { return }
        gridContainerView.translatesAutoresizingMaskIntoConstraints = false
        slotButtons.forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        let buttons = slotButtons.sorted { $0.tag < $1.tag }
        for idx in 0..<buttons.count {
            let btn = buttons[idx]
            let row = idx / 5, col = idx % 5
            if col == 0 { btn.leadingAnchor.constraint(equalTo: gridContainerView.leadingAnchor).isActive = true }
            else {
                let left = buttons[idx - 1]
                btn.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: spacing).isActive = true
                btn.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
            }
            if col == 4 { btn.trailingAnchor.constraint(equalTo: gridContainerView.trailingAnchor).isActive = true }
            if row == 0 { btn.topAnchor.constraint(equalTo: gridContainerView.topAnchor).isActive = true }
            else {
                let above = buttons[(row - 1) * 5 + col]
                btn.topAnchor.constraint(equalTo: above.bottomAnchor, constant: spacing).isActive = true
                btn.heightAnchor.constraint(equalTo: above.heightAnchor).isActive = true
            }
            if row == 4 { btn.bottomAnchor.constraint(equalTo: gridContainerView.bottomAnchor).isActive = true }
        }
        didBuildGridConstraints = true
    }

    // ★ 初期選択の復元（複数コマが来ていればそれを優先）
    private func applyInitialSelectionIfNeeded() {
        guard !didApplyInitialSelection else { return }
        defer { didApplyInitialSelection = true }

        if let slots = initialTimeSlots, !slots.isEmpty {
            for (dayName, period) in slots {
                guard let col = days.firstIndex(of: dayName) else { continue }
                let row = period - 1
                let idx = row * 5 + col
                if (0..<selectedStates.count).contains(idx) {
                    selectedStates[idx] = true
                    slotButtons.first(where: { $0.tag == idx })?.isSelected = true
                }
            }
            return
        }

        if let d = initialDay, let ps = initialPeriods, let col = days.firstIndex(of: d) {
            for p in ps {
                let row = p - 1, idx = row * 5 + col
                if (0..<selectedStates.count).contains(idx) {
                    selectedStates[idx] = true
                    slotButtons.first(where: { $0.tag == idx })?.isSelected = true
                }
            }
        }
    }

    // 見た目更新
    private func configureSlotButtons() {
        guard let slotButtons else { return }
        for b in slotButtons {
            var cfg = b.configuration ?? .plain()
            cfg.baseBackgroundColor = .white
            cfg.baseForegroundColor = .lightGray
            b.configuration = cfg
            b.configurationUpdateHandler = { btn in
                var c = btn.configuration
                if btn.isSelected {
                    c?.baseBackgroundColor = .systemGreen
                    c?.baseForegroundColor = .white
                } else {
                    c?.baseBackgroundColor = .white
                    c?.baseForegroundColor = .lightGray
                }
                btn.configuration = c
            }
        }
    }

    // ヘルパ
    private func setButtonTitleColor(_ button: UIButton, _ color: UIColor) {
        if var cfg = button.configuration { cfg.baseForegroundColor = color; button.configuration = cfg }
        else { button.setTitleColor(color, for: .normal) }
    }
    private func indexFor(value: String?, in list: [String]) -> Int {
        guard let v = value, let i = list.firstIndex(of: v) else { return 0 }
        return i
    }

    // 選択セル→配列
    private func deriveTimeSlots() -> [(String, Int)]? {
        var out: [(String, Int)] = []
        for idx in 0..<selectedStates.count where selectedStates[idx] {
            let row = idx / 5, col = idx % 5
            out.append((days[col], periods[row])) // periodは1始まり
        }
        return out.isEmpty ? nil : out
    }

    // 単一曜日なら day/periods を返す（最適化）
    private func deriveSingleDayAndPeriods() -> (String?, [Int]?) {
        var pairs: [(dayIndex: Int, period: Int)] = []
        for idx in 0..<selectedStates.count where selectedStates[idx] {
            let row = idx / 5, col = idx % 5
            pairs.append((dayIndex: col, period: periods[row]))
        }
        guard !pairs.isEmpty else { return (nil, nil) }
        let first = pairs.first!.dayIndex
        guard pairs.allSatisfy({ $0.dayIndex == first }) else { return (nil, nil) }
        let ps = pairs.map { $0.period }.sorted()
        return (days[first], ps)
    }
}
