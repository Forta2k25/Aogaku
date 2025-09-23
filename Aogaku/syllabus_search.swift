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
    var initialPlace: String?          // "対面" / "オンライン"
    var initialGrade: String?
    var initialDay: String?
    var initialPeriods: [Int]?
    var initialTimeSlots: [(String, Int)]?   // ★ 複数コマの復元用
    var initialTerm: String?                 // ★ 追加: "前期" / "後期" / nil
    var onApply: ((SyllabusSearchCriteria) -> Void)?
    var term: String?

    // ===== AdMob (Banner) =====
    private let adContainer = UIView()
    private var bannerView: BannerView?
    private var adContainerHeight: NSLayoutConstraint?
    private var lastBannerWidth: CGFloat = 0
    private var didLoadBannerOnce = false
    private let bannerBottomOffset: CGFloat = 45   // ← 下へ 8pt ずらす（好みで調整）

    // ===== Outlets =====
    @IBOutlet weak var keywordTextField: UITextField!
    @IBOutlet weak var facultyButton: UIButton!
    @IBOutlet weak var departmentButton: UIButton!
    @IBOutlet weak var campusSegmentedControl: UISegmentedControl!
    @IBOutlet weak var placeSegmentedControl: UISegmentedControl!
    @IBOutlet weak var termSegmentedControl: UISegmentedControl!    // ★ 追加: 前期/後期
    @IBOutlet var slotButtons: [UIButton]!
    @IBOutlet weak var gridContainerView: UIView!

    // ===== 内部状態 =====
    private var selectedCategory: String?
    private var selectedDepartment: String?
    private var selectedCampus: String?
    private var selectedPlace: String?
    private var selectedGrade: String?
    private var selectedTerm: String?    // ★ "前期" / "後期" / nil

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

    // ===== ライフサイクル =====
    override func viewDidLoad() {
        super.viewDidLoad()

        selectedCategory   = initialCategory
        selectedDepartment = initialDepartment
        selectedCampus     = initialCampus
        selectedPlace      = initialPlace
        selectedGrade      = initialGrade
        selectedTerm       = initialTerm   // ★ 追加

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

        // ★ 学期（前期/後期）
        let terms = ["指定なし","前期","後期"]
        termSegmentedControl.removeAllSegments()
        for (i, t) in terms.enumerated() { termSegmentedControl.insertSegment(withTitle: t, at: i, animated: false) }
        termSegmentedControl.selectedSegmentIndex = indexFor(value: selectedTerm, in: terms)
        termSegmentedControl.setTitleTextAttributes([.foregroundColor: UIColor.gray], for: .normal)
        termSegmentedControl.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)

        configureSlotButtons()
        // グリッド制約/タグ採番/初期選択は viewDidLayoutSubviews で

        setupAdBanner()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        assignTagsIfNeeded()
        buildGridConstraintsIfNeeded()
        applyInitialSelectionIfNeeded()
        loadBannerIfNeeded()
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

        let bv = BannerView()
        bv.translatesAutoresizingMaskIntoConstraints = false
        bv.adUnitID = "ca-app-pub-3940256099942544/2934735716" // テストID
        bv.rootViewController = self
        bv.adSize = AdSizeBanner  // 仮サイズ
        bv.delegate = self

        adContainer.addSubview(bv)
        NSLayoutConstraint.activate([
            bv.leadingAnchor.constraint(equalTo: adContainer.leadingAnchor),
            bv.trailingAnchor.constraint(equalTo: adContainer.trailingAnchor),
            bv.topAnchor.constraint(equalTo: adContainer.topAnchor),
            bv.bottomAnchor.constraint(equalTo: adContainer.bottomAnchor)
        ])
        bannerView = bv
    }

    private func loadBannerIfNeeded() {
        guard let bv = bannerView else { return }
        let safeWidth = view.safeAreaLayoutGuide.layoutFrame.width
        if safeWidth <= 0 { return }

        let useWidth = max(320, floor(safeWidth))
        if abs(useWidth - lastBannerWidth) < 0.5 { return } // 無駄な再ロード防止
        lastBannerWidth = useWidth

        let size = makeAdaptiveAdSize(width: useWidth)

        // 先に高さを確保し、重なりを避けるため Safe Area を広げる
        adContainerHeight?.constant = size.size.height
        additionalSafeAreaInsets.bottom = max(0, size.size.height - bannerBottomOffset)
        view.layoutIfNeeded()

        guard size.size.height > 0 else { return }
        if !CGSizeEqualToSize(bv.adSize.size, size.size) { bv.adSize = size }
        if !didLoadBannerOnce {
            didLoadBannerOnce = true
            bv.load(Request())
        }
    }

    // MARK: - BannerViewDelegate
    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        let h = bannerView.adSize.size.height
        adContainerHeight?.constant = h
        additionalSafeAreaInsets.bottom = max(0, h - bannerBottomOffset)  // ← 修正
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
    }

    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        adContainerHeight?.constant = 0
        additionalSafeAreaInsets.bottom = 0
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
        print("Ad failed:", error.localizedDescription)
    }

    // ===== Actions =====
    @IBAction func campusChanged(_ sender: UISegmentedControl) {
        let title = sender.titleForSegment(at: sender.selectedSegmentIndex) ?? "指定なし"
        selectedCampus = (title == "指定なし") ? nil : title
    }
    @IBAction func placeChanged(_ sender: UISegmentedControl) {
        let title = sender.titleForSegment(at: sender.selectedSegmentIndex) ?? "指定なし"
        selectedPlace = (title == "指定なし") ? nil : title
    }
    @IBAction func termChanged(_ sender: UISegmentedControl) {   // ★ 追加
        let title = sender.titleForSegment(at: sender.selectedSegmentIndex) ?? "指定なし"
        selectedTerm = (title == "指定なし") ? nil : title       // "前期" / "後期" / nil
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

        let termValue = selectedTerm   // ★ "前期" / "後期" / nil

        let slots = deriveTimeSlots()
        let (day, ps) = deriveSingleDayAndPeriods()

        // ★ 学期を criteria に渡す（SyllabusSearchCriteria に semester: がある想定）
        let criteria = SyllabusSearchCriteria(
            keyword: keywordTextField?.text,
            category: selectedCategory,
            department: selectedDepartment,
            campus: campusValue,
            place: placeValue,
            grade: selectedGrade,
            day: day,
            periods: ps,
            timeSlots: slots,
            term: termValue           // ← ここが今回の要。フィールド名が `term` の場合は置換してください
        )

        let handler = self.onApply
        dismiss(animated: true) { handler?(criteria) }
    }

    @IBAction func didTapFavorites(_ sender: Any) {
        let vc = FavoritesListViewController()
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
        // または navigationController?.pushViewController(vc, animated: true)
    }

    // ===== メニュー =====
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

    // ===== グリッド関連 =====
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

    // ===== 見た目更新 =====
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

    // ===== ヘルパ =====
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
