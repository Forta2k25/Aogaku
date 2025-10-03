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
    @IBOutlet weak var detailFilterButton: UIButton!
    @IBOutlet weak var resetButton: UIButton!

    // ===== 内部状態 =====
    private var selectedCategory: String?
    private var selectedDepartment: String?
    private var selectedCampus: String?
    private var selectedPlace: String?
    private var selectedGrade: String?
    private var selectedTerm: String?    // ★ "前期" / "後期" / nil
    //リセットボタン関連 ===
    private weak var favoritesButtonDetected: UIButton?   // 既存の「ブックマーク」ボタンを自動検出
    private var didInstallResetButton = false
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
            setButtonTitleAndColor(facultyButton, title: cat, color: .black)
        } else {
            setButtonTitleAndColor(facultyButton, title: "学部", color: .lightGray)
            selectedCategory = nil
        }

        // 学科（★ 教育人間科学部だけ表示名↔クエリ名をマップ）
        if let title = departmentDisplayTitle(for: selectedCategory, stored: selectedDepartment) {
            departmentButton.setTitle(title, for: .normal)
            setButtonTitleColor(departmentButton, .black)
        } else {
            departmentButton.setTitle("学科", for: .normal)
            setButtonTitleColor(departmentButton, .lightGray)
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
        NotificationCenter.default.addObserver(self,
            selector: #selector(onAdMobReady),
            name: .adMobReady, object: nil)
    }
    @objc private func onAdMobReady() {
        loadBannerIfNeeded()
    }


    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        assignTagsIfNeeded()
        buildGridConstraintsIfNeeded()
        applyInitialSelectionIfNeeded()
        loadBannerIfNeeded()
    }
    
    // === 追加ブロック: ボタン設置・検索条件の全リセット ===
    private func installResetButtonIfPossible() {
        // 既存の「ブックマーク」ボタンを再帰的に探す（didTapFavorites: が紐づく UIButton）
        if favoritesButtonDetected == nil {
            favoritesButtonDetected = findFavoritesButton(in: view)
        }

        // 見つからなければ安全に右上へ設置（サイズは適度に）
        let anchorButton = favoritesButtonDetected

        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        // 見た目：ブックマークと同等サイズにするため、Configurationを真似る
        if let cfg = (anchorButton?.configuration) {
            var c = cfg
            c.image = UIImage(systemName: "arrow.counterclockwise")
            c.title = nil
            btn.configuration = c
        } else {
            // フォールバック（同程度の見た目）
            var c = UIButton.Configuration.filled()
            c.image = UIImage(systemName: "arrow.counterclockwise")
            c.baseBackgroundColor = .systemGray5
            c.baseForegroundColor = .label
            c.contentInsets = .init(top: 8, leading: 12, bottom: 8, trailing: 12)
            btn.configuration = c
        }
        btn.accessibilityLabel = "条件をリセット"
        btn.addTarget(self, action: #selector(didTapReset), for: .touchUpInside)
        view.addSubview(btn)
        self.resetButton = btn

        // 位置: 「ブックマーク」ボタンの**左**に、同サイズで並べる
        if let fav = anchorButton, let sv = fav.superview {
            sv.addSubview(btn)   // 同じコンテナに入れる
            NSLayoutConstraint.activate([
                btn.centerYAnchor.constraint(equalTo: fav.centerYAnchor),
                btn.trailingAnchor.constraint(equalTo: fav.leadingAnchor, constant: -8),
                btn.widthAnchor.constraint(equalTo: fav.widthAnchor),
                btn.heightAnchor.constraint(equalTo: fav.heightAnchor)
            ])
        } else {
            // フォールバック配置（右上固定）
            let sa = view.safeAreaLayoutGuide
            NSLayoutConstraint.activate([
                btn.topAnchor.constraint(equalTo: sa.topAnchor, constant: 12),
                btn.trailingAnchor.constraint(equalTo: sa.trailingAnchor, constant: -12),
                btn.widthAnchor.constraint(equalToConstant: 44),
                btn.heightAnchor.constraint(equalToConstant: 44)
            ])
        }
    }

    // didTapFavorites: を action に持つ UIButton を探索
    private func findFavoritesButton(in root: UIView) -> UIButton? {
        if let b = root as? UIButton {
            if b.allTargets.contains(self),
               (b.actions(forTarget: self, forControlEvent: .touchUpInside) ?? []).contains("didTapFavorites:") {
                return b
            }
        }
        for v in root.subviews {
            if let hit = findFavoritesButton(in: v) { return hit }
        }
        return nil
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
        // RCで広告を止めているときはUIも消す
        guard AdsConfig.enabled else {
            adContainer.isHidden = true
            adContainerHeight?.constant = 0
            return
        }
        let bv = BannerView()
        bv.translatesAutoresizingMaskIntoConstraints = false
        bv.adUnitID = AdsConfig.bannerUnitID     // ← RCの本番/テストIDを自動選択
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
    
    @IBAction func didTapReset(_ sender: Any) {
        // 内部状態
        selectedCategory = nil
        selectedDepartment = nil
        selectedCampus = nil
        selectedPlace = nil
        selectedGrade = nil
        selectedTerm = nil
        selectedStates = Array(repeating: false, count: selectedStates.count)

        // UI
        keywordTextField?.text = nil
        setButtonTitleAndColor(facultyButton, title: "学部", color: .lightGray)
        departmentButton.setTitle("学科", for: .normal)
        setButtonTitleColor(departmentButton, .lightGray)
        campusSegmentedControl.selectedSegmentIndex = 0
        placeSegmentedControl.selectedSegmentIndex = 0
        termSegmentedControl.selectedSegmentIndex = 0
        slotButtons?.forEach { $0.isSelected = false }
        view.endEditing(true)

        // 親へ即時反映
        let criteria = SyllabusSearchCriteria(
            keyword: nil, category: nil, department: nil,
            campus: nil, place: nil, grade: nil,
            day: nil, periods: nil, timeSlots: nil,
            term: nil, undecided: nil
        )
        onApply?(criteria)
    }

    // ===== Actions =====
    @IBAction func didTapDetailFilter(_ sender: Any) {
        let vc = SyllabusDetailFilterViewController()
        // 詳細画面 → この画面へ結果を返す
        vc.onApply = { [weak self] detail in
            guard let self = self else { return }

            // いまこの画面にある選択状態からベース条件を作成
            var campusValue: String? = nil
            if let t = self.campusSegmentedControl.titleForSegment(at: self.campusSegmentedControl.selectedSegmentIndex),
               t != "指定なし" { campusValue = t }

            var placeValue: String? = nil
            if let t = self.placeSegmentedControl.titleForSegment(at: self.placeSegmentedControl.selectedSegmentIndex),
               t != "指定なし" { placeValue = t }

            let slots = self.deriveTimeSlots()
            let (day, ps) = self.deriveSingleDayAndPeriods()

            var merged = SyllabusSearchCriteria(
                keyword: self.keywordTextField?.text,
                category: self.selectedCategory,
                department: self.selectedDepartment,
                campus: campusValue,
                place: placeValue,
                grade: self.selectedGrade,
                day: day,
                periods: ps,
                timeSlots: slots,
                term: self.selectedTerm,
                undecided: nil
            )

            if let d = detail.day { merged.day = d }
            if let p = detail.periods { merged.periods = p }
            if let t = detail.timeSlots { merged.timeSlots = t }
            if let term = detail.term { merged.term = term }          // ★ 学期を上書き
            merged.undecided = detail.undecided

            // ★ 詳細指定があれば、過去のグリッド選択（timeSlots）は解除して競合回避
            if detail.day != nil || detail.periods != nil || (detail.undecided ?? false) || detail.term != nil {
                merged.timeSlots = nil
            }

            self.onApply?(merged)


        }

        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

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
                    self.setButtonTitleAndColor(self.facultyButton, title: "学部", color: .lightGray)
                } else {
                    self.selectedCategory = act.title
                    self.setButtonTitleAndColor(self.facultyButton, title: act.title, color: .black)
                }


                // 学部が変わったので学科は毎回リセット
                self.selectedDepartment = nil
                self.departmentButton.setTitle("学科", for: .normal)
                self.setButtonTitleColor(self.departmentButton, .lightGray)

                // 学部に合わせて学科メニューを作り直し
                self.setupDepartmentMenu(initial: act.title)
            }
        }
        facultyButton.menu = UIMenu(children: actions)
        facultyButton.showsMenuAsPrimaryAction = true
    }
    
    /// 教育人間科学部の stored 部（完全カテゴリ名）→ ボタン表示用の短い名前に変換
    private func departmentDisplayTitle(for faculty: String?, stored: String?) -> String? {
        guard let s = stored else { return nil }
        guard let f = faculty, f == "教育人間科学部" else {
            // それ以外の学部は stored = 表示名 とみなす
            return s
        }
        // 受け取りは「教育人間　教育学科/心理学科/外国語科目」or 半角スペース版にも対応
        let pairs = ["教育学科", "心理学科", "外国語科目"]
        for v in pairs {
            if s == "教育人間　\(v)" || s == "教育人間 \(v)" { return v }
        }
        return nil
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
                    if faculty == "教育人間科学部" {
                        // 検索用に「教育人間　◯◯」（全角スペース）へ
                        self.selectedDepartment = "教育人間　\(act.title)"
                    } else if faculty == "理工学部" {
                        // ★ 追加：理工学部は学科→カテゴリ名へマップ
                        self.selectedDepartment = self.mapScienceDeptToCategory(deptDisplay: act.title)
                    } else {
                        self.selectedDepartment = act.title
                    }
                    // 表示は短い名前のまま
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
  /*  private func configureSlotButtons() {
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
    }*/
    // 置換後：角丸なしで四角いマスに固定
    // 角丸なしで四角に固定（エラー修正版）
    private func configureSlotButtons() {
        guard let slotButtons else { return }

        for b in slotButtons {
            // 念のためレイヤー側でも無効化
            b.layer.cornerRadius = 0
            b.clipsToBounds = true

            var cfg = b.configuration ?? .plain()
            cfg.cornerStyle = .fixed              // ← こちらは UIButton.Configuration のプロパティ

            var bg = cfg.background ?? UIBackgroundConfiguration.clear()
            bg.cornerRadius = 0                   // ← 背景の角丸を物理的に 0
            bg.backgroundColor = .white
            cfg.background = bg

            cfg.baseForegroundColor = .lightGray
            b.configuration = cfg

            b.configurationUpdateHandler = { btn in
                var c = btn.configuration ?? .plain()
                c.cornerStyle = .fixed            // 毎回固定

                var bg = c.background ?? UIBackgroundConfiguration.clear()
                bg.cornerRadius = 0
                bg.backgroundColor = btn.isSelected ? .systemGreen : .white
                c.background = bg

                c.baseForegroundColor = btn.isSelected ? .white : .lightGray
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
    
    /// UIButton の Configuration を考慮してタイトル＆色をまとめて更新
    private func setButtonTitleAndColor(_ button: UIButton, title: String, color: UIColor) {
        if var cfg = button.configuration {
            cfg.title = title
            cfg.baseForegroundColor = color
            button.configuration = cfg
        } else {
            button.setTitle(title, for: .normal)
            button.setTitleColor(color, for: .normal)
        }
    }

    /// 理工学部の学科表示名 → 検索用 category へ変換
    private func mapScienceDeptToCategory(deptDisplay: String) -> String {
        switch deptDisplay {
        case "物理科学科", "物理数学科", "物理・数理学科":
            return "物理・数理"
        case "数理サイエンス学科":
            return "数理サイエンス"
        case "化学・生命科学科":
            return "化学・生命"
        case "電気電子工学科":
            return "電気電子工学科"
        case "機械創造工学科":
            return "機械創造"
        case "経営システム工学科":
            return "経営システム"
        case "情報テクノロジー学科":
            return "情報テクノロジー"
        default:
            // 予期しない表示名はそのまま（後方互換）
            return deptDisplay
        }
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
