import UIKit
import Foundation

// MARK: - Slot

struct SlotLocation {
    let day: Int   // 0=月…5=土
    let period: Int   // 1..rows
    var dayName: String { ["月","火","水","木","金","土"][day] }
}

// MARK: - Controller

final class timetable: UIViewController,
                       CourseListViewControllerDelegate,
                       CourseDetailViewControllerDelegate {
    
    private let periodRowMinHeight: CGFloat = 120   // 時限行の最小高さ（好みで調整）

    // ===== Scroll root =====
    private let scrollView = UIScrollView()
    private let contentView = UIView()   // スクロールの中身

    // ===== Header =====
    private let headerBar = UIStackView()
    private let leftButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let rightStack = UIStackView()
    private let rightA = UIButton(type: .system)  // 単
    private let rightB = UIButton(type: .system)
    private let rightC = UIButton(type: .system)
    private var headerTopConstraint: NSLayoutConstraint!

    // ===== Grid =====
    private let gridContainerView = UIView()
    private var colGuides: [UILayoutGuide] = []  // 0列目=時限列, 1..=曜日列
    private var rowGuides: [UILayoutGuide] = []  // 0行目=ヘッダ行, 1..=各時限
    private(set) var slotButtons: [UIButton] = []

    // ===== Data / Settings =====
    private var registeredCourses: [Int: Course] = [:]
    private var bgObserver: NSObjectProtocol?

    // 1限〜7限までの開始・終了
    private let timePairs: [(start: String, end: String)] = [
        ("9:00",  "10:30"),
        ("11:00", "12:30"),
        ("13:20", "14:50"),
        ("15:05", "16:35"),
        ("16:50", "18:20"),
        ("18:30", "20:00"),
        ("20:10", "21:40")
    ]

    private var settings = TimetableSettings.load()
    private var dayLabels: [String] {
        settings.includeSaturday ? ["月","火","水","木","金","土"] : ["月","火","水","木","金"]
    }
    private var periodLabels: [String] { (1...settings.periods).map { "\($0)" } }

    // 直近の列数・行数（再構築時に使う）
    private var lastDaysCount = 5
    private var lastPeriodsCount = 5

    // “登録科目”（未登録は nil）
    private var assigned: [Course?] = Array(repeating: nil, count: 25)

    // MARK: Layout constants
    private let spacing: CGFloat = 6
    private let cellPadding: CGFloat = 4
    private let headerRowHeight: CGFloat = 36
    private let timeColWidth: CGFloat = 48
    private let topRatio: CGFloat = 0.02

    // MARK: - Persistence (UserDefaults)
    private let saveKey = "assignedCourses.v1"

    private func saveAssigned() {
        do {
            let data = try JSONEncoder().encode(assigned)
            UserDefaults.standard.set(data, forKey: saveKey)
        } catch {
            print("Save error:", error)
        }
    }

    private func loadAssigned() {
        guard let data = UserDefaults.standard.data(forKey: saveKey) else { return }
        do {
            let loaded = try JSONDecoder().decode([Course?].self, from: data)
            if loaded.count == assigned.count {
                assigned = loaded
            } else {
                for i in 0..<min(assigned.count, loaded.count) { assigned[i] = loaded[i] }
            }
        } catch { print("Load error:", error) }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        normalizeAssigned()
        loadAssigned()

        view.backgroundColor = .systemBackground
        buildHeader()
        layoutGridContainer()
        buildGridGuides()
        placeHeaders()
        placePlusButtons()

        NotificationCenter.default.addObserver(
            self, selector: #selector(onSettingsChanged),
            name: .timetableSettingsChanged, object: nil
        )
        bgObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.saveAssigned() }
    }

    deinit {
        if let bgObserver { NotificationCenter.default.removeObserver(bgObserver) }
        NotificationCenter.default.removeObserver(self, name: .timetableSettingsChanged, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safeHeight = view.safeAreaLayoutGuide.layoutFrame.height
        headerTopConstraint.constant = safeHeight * topRatio
        view.layoutIfNeeded()
    }

    // MARK: - Settings change

    @objc private func onSettingsChanged() {
        let oldDays = lastDaysCount
        let oldPeriods = lastPeriodsCount

        settings = TimetableSettings.load()
        assigned = remapAssigned(old: assigned,
                                 oldDays: oldDays, oldPeriods: oldPeriods,
                                 newDays: dayLabels.count, newPeriods: periodLabels.count)

        rebuildGrid()
        lastDaysCount = dayLabels.count
        lastPeriodsCount = periodLabels.count
    }

    private func remapAssigned(old: [Course?],
                               oldDays: Int, oldPeriods: Int,
                               newDays: Int, newPeriods: Int) -> [Course?] {
        var dst = Array(repeating: nil as Course?, count: newDays * newPeriods)
        let copyDays = min(oldDays, newDays)
        let copyPeriods = min(oldPeriods, newPeriods)
        for p in 0..<copyPeriods {
            for d in 0..<copyDays {
                dst[p * newDays + d] = old[p * oldDays + d]
            }
        }
        return dst
    }

    private func normalizeAssigned() {
        let need = periodLabels.count * dayLabels.count
        if assigned.count < need {
            assigned.append(contentsOf: Array(repeating: nil, count: need - assigned.count))
        } else if assigned.count > need {
            assigned = Array(assigned.prefix(need))
        }
    }

    private func rebuildGrid() {
        gridContainerView.subviews.forEach { $0.removeFromSuperview() }
        normalizeAssigned()
        slotButtons.forEach { $0.removeFromSuperview() }
        slotButtons.removeAll()
        colGuides.forEach { gridContainerView.removeLayoutGuide($0) }
        rowGuides.forEach { gridContainerView.removeLayoutGuide($0) }
        colGuides.removeAll()
        rowGuides.removeAll()

        buildGridGuides()
        placeHeaders()
        placePlusButtons()
        reloadAllButtons()
    }

    // MARK: - Header

    private func buildHeader() {
        headerBar.axis = .horizontal
        headerBar.alignment = .center
        headerBar.distribution = .fill
        headerBar.spacing = 8
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerBar)

        leftButton.setTitle("2025年前期", for: .normal)
        leftButton.addTarget(self, action: #selector(tapLeft), for: .touchUpInside)

        titleLabel.text = "時間割"
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        rightStack.axis = .horizontal
        rightStack.alignment = .center
        rightStack.spacing = 8
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.setContentHuggingPriority(.required, for: .horizontal)

        func styleIcon(_ b: UIButton, _ systemName: String? = nil, title: String? = nil) {
            if let systemName {
                var cfg = UIButton.Configuration.plain()
                cfg.image = UIImage(systemName: systemName)
                cfg.preferredSymbolConfigurationForImage =
                    UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
                cfg.baseForegroundColor = .label
                cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
                b.configuration = cfg
            } else if let title {
                b.setTitle(title, for: .normal)
                b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
                b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
            }
            b.backgroundColor = .secondarySystemBackground
            b.layer.cornerRadius = 8
            b.layer.borderWidth = 1
            b.layer.borderColor = UIColor.separator.cgColor
        }

        styleIcon(rightA, title: "単")
        let multiIcon: String
        if #available(iOS 16.0, *) {
            multiIcon = "point.3.connected.trianglepath.dotted"
        } else {
            multiIcon = "ellipsis.circle"
        }
        styleIcon(rightB, multiIcon)
        styleIcon(rightC, "gearshape.fill")

        rightA.addTarget(self, action: #selector(tapRightA), for: .touchUpInside)
        rightB.addTarget(self, action: #selector(tapRightB), for: .touchUpInside)
        rightC.addTarget(self, action: #selector(tapRightC), for: .touchUpInside)

        rightStack.addArrangedSubview(rightA)
        rightStack.addArrangedSubview(rightB)
        rightStack.addArrangedSubview(rightC)

        let spacerL = UIView(); spacerL.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let spacerR = UIView(); spacerR.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerBar.addArrangedSubview(leftButton)
        headerBar.addArrangedSubview(spacerL)
        headerBar.addArrangedSubview(titleLabel)
        headerBar.addArrangedSubview(spacerR)
        headerBar.addArrangedSubview(rightStack)

        // Layout
        [leftButton, titleLabel, rightStack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        headerBar.isLayoutMarginsRelativeArrangement = true
        headerBar.layoutMargins = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        headerBar.setContentHuggingPriority(.required, for: .vertical)
        headerBar.setContentCompressionResistancePriority(.required, for: .vertical)

        let clamp = headerBar.heightAnchor.constraint(equalTo: titleLabel.heightAnchor, constant: 16)
        clamp.priority = .required
        clamp.isActive = true

        NSLayoutConstraint.activate([
            leftButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            rightStack.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor)
        ])
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.centerXAnchor.constraint(equalTo: headerBar.centerXAnchor).isActive = true

        let g = view.safeAreaLayoutGuide
        headerTopConstraint = headerBar.topAnchor.constraint(equalTo: g.topAnchor, constant: 0)
        NSLayoutConstraint.activate([
            headerTopConstraint,
            headerBar.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            headerBar.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            headerBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    // MARK: - Grid container（縦スクロール）

    private func layoutGridContainer() {
        let g = view.safeAreaLayoutGuide

        // scrollView をヘッダーの下に敷く
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: g.bottomAnchor)
        ])

        // contentView を scroll の contentLayoutGuide に貼る
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])

        // gridContainer を contentView 内に配置
        gridContainerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(gridContainerView)
        NSLayoutConstraint.activate([
            gridContainerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            gridContainerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            gridContainerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            gridContainerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        ])
    }

    // MARK: - Guides

    private func buildGridGuides() {
        // 列（時限 + 曜日）
        let colCount = 1 + dayLabels.count
        colGuides.removeAll()
        for _ in 0..<colCount {
            let g = UILayoutGuide()
            gridContainerView.addLayoutGuide(g)
            colGuides.append(g)
            g.topAnchor.constraint(equalTo: gridContainerView.topAnchor).isActive = true
            g.bottomAnchor.constraint(equalTo: gridContainerView.bottomAnchor).isActive = true
        }
        colGuides[0].leadingAnchor.constraint(equalTo: gridContainerView.leadingAnchor).isActive = true
        colGuides[colCount-1].trailingAnchor.constraint(equalTo: gridContainerView.trailingAnchor).isActive = true
        colGuides[0].widthAnchor.constraint(equalToConstant: timeColWidth).isActive = true
        for i in 1..<colCount {
            colGuides[i].leadingAnchor.constraint(equalTo: colGuides[i-1].trailingAnchor, constant: spacing).isActive = true
            if i >= 2 { colGuides[i].widthAnchor.constraint(equalTo: colGuides[1].widthAnchor).isActive = true }
        }

        // 行（ヘッダ1 + 時限n）
        let rowCount = 1 + periodLabels.count
        rowGuides.removeAll()
        for _ in 0..<rowCount {
            let g = UILayoutGuide()
            gridContainerView.addLayoutGuide(g)
            rowGuides.append(g)
            g.leadingAnchor.constraint(equalTo: gridContainerView.leadingAnchor).isActive = true
            g.trailingAnchor.constraint(equalTo: gridContainerView.trailingAnchor).isActive = true
        }
        rowGuides[0].topAnchor.constraint(equalTo: gridContainerView.topAnchor).isActive = true
        rowGuides[rowCount-1].bottomAnchor.constraint(equalTo: gridContainerView.bottomAnchor).isActive = true
        rowGuides[0].heightAnchor.constraint(equalToConstant: headerRowHeight).isActive = true

        for i in 1..<rowCount {
            rowGuides[i].topAnchor.constraint(equalTo: rowGuides[i-1].bottomAnchor, constant: spacing).isActive = true
            if i >= 2 { rowGuides[i].heightAnchor.constraint(equalTo: rowGuides[1].heightAnchor).isActive = true }
        }
        // ★ ここがポイント：基準になる rowGuides[1] に最小高さを与える
        rowGuides[1].heightAnchor.constraint(greaterThanOrEqualToConstant: periodRowMinHeight).isActive = true
    }


    // MARK: - Headers / Time markers

    private func placeHeaders() {
        for i in 0..<dayLabels.count {
            let l = headerLabel(dayLabels[i])
            gridContainerView.addSubview(l)
            NSLayoutConstraint.activate([
                l.centerXAnchor.constraint(equalTo: colGuides[i+1].centerXAnchor),
                l.centerYAnchor.constraint(equalTo: rowGuides[0].centerYAnchor)
            ])
        }
        for r in 0..<periodLabels.count {
            let marker = makeTimeMarker(for: r + 1)
            gridContainerView.addSubview(marker)
            NSLayoutConstraint.activate([
                marker.centerXAnchor.constraint(equalTo: colGuides[0].centerXAnchor),  // ど真ん中
                marker.widthAnchor.constraint(equalToConstant: timeColWidth),
                marker.centerYAnchor.constraint(equalTo: rowGuides[r+1].centerYAnchor)
            ])
        }
    }

    private func headerLabel(_ text: String) -> UILabel {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.text = text
        l.font = .systemFont(ofSize: 16, weight: .regular)
        l.textAlignment = .center
        return l
    }

    private func makeTimeMarker(for period: Int) -> UIView {
        let v = UIStackView()
        v.axis = .vertical
        v.alignment = .center
        v.spacing = 2
        v.translatesAutoresizingMaskIntoConstraints = false

        let top = UILabel()
        top.font = .systemFont(ofSize: 11, weight: .regular)
        top.textColor = .secondaryLabel
        top.textAlignment = .center

        let mid = UILabel()
        mid.font = .systemFont(ofSize: 16, weight: .semibold)
        mid.textAlignment = .center
        mid.text = "\(period)"

        let bottom = UILabel()
        bottom.font = .systemFont(ofSize: 11, weight: .regular)
        bottom.textColor = .secondaryLabel
        bottom.textAlignment = .center

        if period-1 < timePairs.count {
            top.text    = timePairs[period-1].start
            bottom.text = timePairs[period-1].end
        } else {
            top.text = nil; bottom.text = nil
        }

        [top, mid, bottom].forEach { v.addArrangedSubview($0) }
        return v
    }

    // MARK: - Buttons (统一見た目)

    private func baseCellConfig(bg: UIColor, fg: UIColor,
                                stroke: UIColor? = nil, strokeWidth: CGFloat = 0) -> UIButton.Configuration {
        var cfg = UIButton.Configuration.filled()
        cfg.baseBackgroundColor = bg
        cfg.baseForegroundColor = fg
        cfg.contentInsets = .init(top: 8, leading: 10, bottom: 8, trailing: 10)
        cfg.background.cornerRadius = 12
        cfg.background.backgroundInsets = .zero   // ← 内側に縮まない
        cfg.background.strokeColor = stroke
        cfg.background.strokeWidth = strokeWidth
        return cfg
    }

    private func configureButton(_ b: UIButton, at idx: Int) {
        // layer / background は使わない（Configuration に集約）
        b.backgroundColor = .clear
        b.layer.borderWidth = 0
        b.layer.cornerRadius = 0

        guard assigned.indices.contains(idx), let course = assigned[idx] else {
            var cfg = baseCellConfig(bg: .secondarySystemBackground,
                                     fg: .systemBlue,
                                     stroke: UIColor.separator, strokeWidth: 1)
            cfg.title = "＋"
            cfg.titleAlignment = .center
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { inAttr in
                var out = inAttr
                out.font = .systemFont(ofSize: 22, weight: .semibold)
                let p = NSMutableParagraphStyle(); p.alignment = .center
                out.paragraphStyle = p
                return out
            }
            b.configuration = cfg
            return
        }

        // 登録済みセル
        let cols = dayLabels.count
        let row  = idx / cols
        let col  = idx % cols
        let loc  = SlotLocation(day: col, period: row + 1)
        let colorKey = SlotColorStore.color(for: loc) ?? .teal

        var cfg = baseCellConfig(bg: colorKey.uiColor, fg: .white)
        cfg.title = course.title
        cfg.subtitle = course.room
        cfg.titleAlignment = .center
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { inAttr in
            var out = inAttr
            out.font = .systemFont(ofSize: 10, weight: .semibold)
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            p.lineBreakMode = .byWordWrapping
            out.paragraphStyle = p
            return out
        }
        cfg.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { inAttr in
            var out = inAttr
            out.font = .systemFont(ofSize: 11, weight: .medium)
            let p = NSMutableParagraphStyle(); p.alignment = .center
            out.paragraphStyle = p
            return out
        }
        b.configuration = cfg
    }

    private func reloadAllButtons() {
        for b in slotButtons { configureButton(b, at: b.tag) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadAllButtons()
    }

    private func placePlusButtons() {
        let rows = periodLabels.count
        let cols = dayLabels.count
        for r in 0..<rows {
            for c in 0..<cols {
                let b = UIButton(type: .system)
                b.translatesAutoresizingMaskIntoConstraints = false
                // ここでは layer/background を触らない（Configuration で統一）
                gridContainerView.addSubview(b)

                let rowG = rowGuides[r+1], colG = colGuides[c+1]
                NSLayoutConstraint.activate([
                    b.topAnchor.constraint(equalTo: rowG.topAnchor, constant: cellPadding),
                    b.bottomAnchor.constraint(equalTo: rowG.bottomAnchor, constant: -cellPadding),
                    b.leadingAnchor.constraint(equalTo: colG.leadingAnchor, constant: cellPadding),
                    b.trailingAnchor.constraint(equalTo: colG.trailingAnchor, constant: -cellPadding)
                ])

                let idx = r * cols + c
                b.tag = idx
                b.addTarget(self, action: #selector(slotTapped(_:)), for: .touchUpInside)
                slotButtons.append(b)

                configureButton(b, at: idx)
            }
        }
    }

    private func gridIndex(for loc: SlotLocation) -> Int {
        let cols = dayLabels.count
        return loc.day + (loc.period - 1) * cols
    }

    // MARK: - Course detail / select

    private func presentCourseDetail(_ course: Course, at loc: SlotLocation) {
        let vc = CourseDetailViewController(course: course, location: loc)
        vc.delegate = self
        vc.modalPresentationStyle = .pageSheet

        if let sheet = vc.sheetPresentationController {
            if #available(iOS 16.0, *) {
                let id = UISheetPresentationController.Detent.Identifier("ninetyTwo")
                sheet.detents = [
                    .custom(identifier: id) { ctx in ctx.maximumDetentValue * 0.92 },
                    .large()
                ]
                sheet.selectedDetentIdentifier = id
            } else {
                sheet.detents = [.large()]
                sheet.selectedDetentIdentifier = .large
            }
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 16
        }
        present(vc, animated: true)
    }

    // MARK: - Actions

    @objc private func tapLeft()   { print("左ボタン") }

    @objc private func tapRightA() {
        let courses = uniqueCoursesInAssigned()
        let vc = CreditsFullViewController(courses: courses)
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }

    @objc private func tapRightB() { print("右B") }

    @objc private func tapRightC() {
        let vc = TimetableSettingsViewController()
        if let nav = navigationController {
            nav.pushViewController(vc, animated: true)
        } else {
            let nav = UINavigationController(rootViewController: vc)
            present(nav, animated: true)
        }
    }

    @objc private func slotTapped(_ sender: UIButton) {
        let cols = dayLabels.count
        let idx  = sender.tag
        let row  = sender.tag / cols
        let col  = sender.tag % cols

        let loc = SlotLocation(day: col, period: row + 1)

        if let course = assigned[idx] {
            presentCourseDetail(course, at: loc)
            return
        }

        let listVC = CourseListViewController(location: loc)
        listVC.delegate = self

        if let nav = navigationController {
            nav.pushViewController(listVC, animated: true)
        } else {
            let nav = UINavigationController(rootViewController: listVC)
            nav.modalPresentationStyle = .fullScreen
            present(nav, animated: true)
        }
    }

    // MARK: - CourseList delegate

    func courseList(_ vc: CourseListViewController, didSelect course: Course, at location: SlotLocation) {
        normalizeAssigned()
        let idx = (location.period - 1) * dayLabels.count + location.day
        assigned[idx] = course

        if let btn = slotButtons.first(where: { $0.tag == idx }) {
            configureButton(btn, at: idx)
        } else {
            reloadAllButtons()
        }
        saveAssigned()

        if let nav = vc.navigationController {
            if nav.viewControllers.first === vc { vc.dismiss(animated: true) }
            else { nav.popViewController(animated: true) }
        } else {
            vc.dismiss(animated: true)
        }
    }

    // MARK: - CourseDetail delegate

    func courseDetail(_ vc: CourseDetailViewController, didChangeColor key: SlotColorKey, at location: SlotLocation) {
        SlotColorStore.set(key, for: location)
        let idx = gridIndex(for: location)
        if (0..<slotButtons.count).contains(idx) {
            configureButton(slotButtons[idx], at: idx)
        } else {
            rebuildGrid()
        }
    }

    func courseDetail(_ vc: CourseDetailViewController, requestEditFor course: Course, at location: SlotLocation) {
        vc.dismiss(animated: true) {
            let listVC = CourseListViewController(location: location)
            listVC.delegate = self
            if let nav = self.navigationController {
                nav.pushViewController(listVC, animated: true)
            } else {
                let nav = UINavigationController(rootViewController: listVC)
                nav.modalPresentationStyle = .fullScreen
                self.present(nav, animated: true)
            }
        }
    }

    func courseDetail(_ vc: CourseDetailViewController, requestDelete course: Course, at location: SlotLocation) {
        let idx = (location.period - 1) * self.dayLabels.count + location.day
        self.assigned[idx] = nil
        if let btn = self.slotButtons.first(where: { $0.tag == idx }) {
            self.configureButton(btn, at: idx)
        } else {
            self.reloadAllButtons()
        }
        vc.dismiss(animated: true)
        saveAssigned()
    }

    func courseDetail(_ vc: CourseDetailViewController, didUpdate counts: AttendanceCounts, for course: Course, at location: SlotLocation) {
        // 将来サーバ保存などあればここで
    }

    func courseDetail(_ vc: CourseDetailViewController, didDeleteAt location: SlotLocation) {
        assigned[index(for: location)] = nil
        reloadAllButtons()
        saveAssigned()
    }

    func courseDetail(_ vc: CourseDetailViewController, didEdit course: Course, at location: SlotLocation) {
        assigned[index(for: location)] = course
        reloadAllButtons()
        saveAssigned()
    }

    // MARK: - Helpers

    private func index(for loc: SlotLocation) -> Int {
        (loc.period - 1) * dayLabels.count + loc.day
    }

    // 同じ登録番号のコマを重複カウントしない
    private func uniqueCoursesInAssigned() -> [Course] {
        var seen = Set<String>()
        var out: [Course] = []
        for c in assigned.compactMap({ $0 }) {
            // id が空/nil の場合のフォールバックも用意
            let key = (c.id.isEmpty ? "" : c.id) + "#" + c.title
            if seen.insert(key).inserted { out.append(c) }
        }
        return out
    }
}
