import UIKit
import FirebaseFirestore

/// 友だちの時間割（学期トグル／モーダル詳細／色反映）
final class FriendTimetableViewController: UIViewController {

    // MARK: - Public
    init(friendUid: String, friendName: String?) {
        self.friendUid = friendUid
        self.friendName = friendName
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Props
    private let friendUid: String
    private let friendName: String?

    // 学年は「3月から次年度」に切り替える（例：2026/03〜は 2026）
    private var year: Int = FriendTimetableViewController.academicYear(for: Date())
    private var semester: FriendSemester = .latest()   // 10月〜は後期

    private var courses: [GridCell] = []
    private var maxDay: Int = 4
    private var maxPeriod: Int = 5

    private var cellMap: [Int: GridCell] = [:]
    private var nextTag: Int = 1000

    // MARK: - UI
    private let scroll = UIScrollView()
    private let content = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .large)

    // スリムなピル型トグル
    private let termSegment = UISegmentedControl(items: [FriendSemester.first.jp, FriendSemester.second.jp])

    // MARK: - Layout
    private enum Layout {
        static let afterWeekHeaderSpacing: CGFloat = 18
        static let leftColumnWidth: CGFloat = 30
        static let minBadgeHeight: CGFloat = 4
        static let interItemSpacing: CGFloat = 6
        static let rowSpacing: CGFloat = 6
        static let contentMargins = UIEdgeInsets(top: 8, left: 8, bottom: 16, right: 8)
        static let periodTimeGap: CGFloat = 2
        static let sectionSpacing: CGFloat = 12
        /// 自分の時間割の periodRowMinHeight (timetable.swift) と揃える
        static let courseMinHeight: CGFloat = 105
    }

    // MARK: - Lifecycle
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ScreenTracker.shared.appear("友だちの時間割")
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        ScreenTracker.shared.disappear("友だちの時間割")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HackColors.background
        title = friendName.map { "\($0) の時間割" } ?? "友だちの時間割"

        // 学期の保存値（友だち＋年度）を復元
        let key = Self.prefKey(uid: friendUid, year: year)
        if let saved = UserDefaults.standard.string(forKey: key) {
            semester = (saved == FriendSemester.second.rawValue) ? .second : .first
        }

        setupUI()
        scroll.backgroundColor = .clear
        content.backgroundColor = .clear
        termSegment.selectedSegmentIndex = (semester == .first) ? 0 : 1

        spinner.startAnimating()
        loadAndBuild(for: year, semester: semester)

        setupBackButtonIfNeeded()

    }

    private func setupBackButtonIfNeeded() {
        let isModalRoot = (presentingViewController != nil) &&
                          (navigationController?.viewControllers.first === self)
        guard isModalRoot else { return }

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "戻る",
            style: .plain,
            target: self,
            action: #selector(closeSelf)
        )
    }

    @objc private func closeSelf() {
        dismiss(animated: true)
    }


    // MARK: - UI
    private func setupUI() {
        // スクロール & スタック
        content.axis = .vertical
        content.alignment = .fill
        content.spacing = Layout.rowSpacing
        content.layoutMargins = Layout.contentMargins
        content.isLayoutMarginsRelativeArrangement = true

        view.addSubview(scroll)
        scroll.addSubview(content)
        view.addSubview(spinner)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            content.topAnchor.constraint(equalTo: scroll.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.widthAnchor),

            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        // スリムなピル型セグメント（幅制約は貼らない＝スタックが横いっぱいにしてくれる）
        termSegment.selectedSegmentTintColor = .label.withAlphaComponent(0.08)
        termSegment.backgroundColor = .secondarySystemBackground
        termSegment.setTitleTextAttributes([.foregroundColor: UIColor.label,
                                            .font: UIFont.systemFont(ofSize: 13, weight: .semibold)], for: .normal)
        termSegment.setTitleTextAttributes([.foregroundColor: UIColor.label,
                                            .font: UIFont.systemFont(ofSize: 13, weight: .bold)], for: .selected)
        termSegment.addTarget(self, action: #selector(didChangeSemester(_:)), for: .valueChanged)

        let segContainer = UIView()
        segContainer.translatesAutoresizingMaskIntoConstraints = false
        segContainer.layoutMargins = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        segContainer.addSubview(termSegment)
        termSegment.translatesAutoresizingMaskIntoConstraints = false

        // 先にスタックへ追加 → その後で termSegment の制約を有効化（共通祖先の問題を避ける）
        content.addArrangedSubview(segContainer)
        NSLayoutConstraint.activate([
            termSegment.leadingAnchor.constraint(equalTo: segContainer.layoutMarginsGuide.leadingAnchor),
            termSegment.trailingAnchor.constraint(equalTo: segContainer.layoutMarginsGuide.trailingAnchor),
            termSegment.topAnchor.constraint(equalTo: segContainer.topAnchor),
            termSegment.bottomAnchor.constraint(equalTo: segContainer.bottomAnchor),
            termSegment.heightAnchor.constraint(equalToConstant: 30)
        ])
        termSegment.layer.cornerRadius = 15
        termSegment.layer.masksToBounds = true

        content.setCustomSpacing(Layout.sectionSpacing, after: segContainer)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        buildGrid()  // ダーク/ライト切替時にセル色を再描画
    }

    private func buildGrid() {
        // 先頭（セグメント）以外をクリア
        content.arrangedSubviews.dropFirst().forEach { $0.removeFromSuperview() }
        cellMap.removeAll(); nextTag = 1000

        let weekTitles = ["月","火","水","木","金","土"]
        let columns = min(maxDay + 1, weekTitles.count)

        let headerRow = makeWeekHeader(columns: columns, titles: weekTitles)
        content.addArrangedSubview(headerRow)
        content.setCustomSpacing(Layout.afterWeekHeaderSpacing, after: headerRow)

        for p in 1...maxPeriod {
            content.addArrangedSubview(makeRow(period: p, columns: columns))
        }

        // オンデマンド（period == 0）行
        let hasOnline = courses.contains(where: { $0.period == 0 })
        if hasOnline {
            content.setCustomSpacing(Layout.sectionSpacing, after: content.arrangedSubviews.last!)
            content.addArrangedSubview(makeOnlineRow(columns: columns))
        }
    }

    private func makeWeekHeader(columns: Int, titles: [String]) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .fill
        row.spacing = Layout.interItemSpacing

        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: Layout.leftColumnWidth).isActive = true
        row.addArrangedSubview(spacer)

        let cols = UIStackView()
        cols.axis = .horizontal
        cols.alignment = .top
        cols.distribution = .fillEqually
        cols.spacing = Layout.interItemSpacing

        for d in 0..<columns {
            let lbl = UILabel()
            lbl.text = titles[d]
            lbl.font = .systemFont(ofSize: 13, weight: .semibold)
            lbl.textAlignment = .center
            lbl.textColor = .secondaryLabel
            let wrapper = UIView()
            wrapper.addSubview(lbl)
            lbl.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                lbl.topAnchor.constraint(equalTo: wrapper.topAnchor),
                lbl.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor)
            ])
            cols.addArrangedSubview(wrapper)
        }

        row.addArrangedSubview(cols)
        return row
    }

    private func makeRow(period: Int, columns: Int) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .fill
        row.spacing = Layout.interItemSpacing

        row.addArrangedSubview(makePeriodBadge(period: period))

        let cols = UIStackView()
        cols.axis = .horizontal
        cols.alignment = .fill
        cols.distribution = .fillEqually
        cols.spacing = Layout.interItemSpacing

        for day in 0..<columns {
            let cellView = makeCourseCell()
            if let course = courses.first(where: { $0.day == day && $0.period == period }) {
                apply(course: course, to: cellView)
                let tag = nextTag; nextTag += 1
                cellMap[tag] = course
                cellView.tag = tag
                let tap = UITapGestureRecognizer(target: self, action: #selector(didTapCell(_:)))
                cellView.isUserInteractionEnabled = true
                cellView.addGestureRecognizer(tap)
            }
            cols.addArrangedSubview(cellView)
        }
        row.addArrangedSubview(cols)
        return row
    }

    /// オンデマンド（period == 0）を曜日ごとにまとめて表示
    private func makeOnlineRow(columns: Int) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .fill
        row.spacing = Layout.interItemSpacing

        row.addArrangedSubview(makeOnlineBadge())

        let cols = UIStackView()
        cols.axis = .horizontal
        cols.alignment = .fill
        cols.distribution = .fillEqually
        cols.spacing = Layout.interItemSpacing

        for day in 0..<columns {
            let dayCourses = courses
                .filter { $0.day == day && $0.period == 0 }
                .sorted { $0.title < $1.title }

            let cellView: UIView
            if dayCourses.isEmpty {
                cellView = makeCourseCell()
            } else if dayCourses.count == 1 {
                // 1件のみ: 通常セルと同じレイアウトでタイトルをフル表示
                let cell = makeCourseCell()
                apply(course: dayCourses[0], to: cell, truncateTitle: false)
                let tag = nextTag; nextTag += 1
                cellMap[tag] = dayCourses[0]
                cell.tag = tag
                let tap = UITapGestureRecognizer(target: self, action: #selector(didTapCell(_:)))
                cell.isUserInteractionEnabled = true
                cell.addGestureRecognizer(tap)
                cellView = cell
            } else {
                cellView = makeMultiCourseCell(courses: dayCourses)
            }
            cols.addArrangedSubview(cellView)
        }

        row.addArrangedSubview(cols)
        return row
    }

    private func makeOnlineBadge() -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.translatesAutoresizingMaskIntoConstraints = false

        let mid = UILabel()
        mid.text = "オン\nデマ"
        mid.numberOfLines = 2
        mid.font = .systemFont(ofSize: 13, weight: .bold)
        mid.textColor = .secondaryLabel
        mid.textAlignment = .center
        mid.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(mid)

        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: Layout.leftColumnWidth),
            mid.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            mid.centerYAnchor.constraint(equalTo: v.centerYAnchor)
        ])
        return v
    }

    /// 1マス内に複数授業を縦積みで表示（最大3件＋残りは「＋n」）
    private func makeMultiCourseCell(courses list: [GridCell]) -> UIView {
        let base = makeCourseCell()
        base.subviews.forEach { $0.removeFromSuperview() }

        base.layer.cornerRadius = 8
        base.layer.borderWidth = 0.5
        base.layer.borderColor = HackColors.gridLine.resolvedColor(with: traitCollection).cgColor
        base.backgroundColor = HackColors.emptyCellBg

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.distribution = .fillEqually
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        base.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: base.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: base.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: base.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: base.bottomAnchor, constant: -8)
        ])

        let show = Array(list.prefix(3))
        for c in show {
            let chip = makeChip(for: c)
            stack.addArrangedSubview(chip)
        }
        if list.count > 3 {
            let more = UILabel()
            more.text = "＋\(list.count - 3)"
            more.font = .systemFont(ofSize: 12, weight: .semibold)
            more.textColor = .secondaryLabel
            more.textAlignment = .center
            stack.addArrangedSubview(more)
        }
        return base
    }

    private func makeChip(for course: GridCell) -> UIView {
        let v = UIView()
        v.layer.cornerRadius = 6
        v.layer.masksToBounds = true

        // 自分の時間割と同じパステル混色
        let colorKey = course.colorKey.flatMap { SlotColorKey(rawValue: $0) } ?? .teal
        v.backgroundColor = UIColor { trait in
            let base = colorKey.uiColor.resolvedColor(with: trait)
            if trait.userInterfaceStyle == .dark {
                return base.mixed(with: UIColor(white: 0.18, alpha: 1), ratio: 0.15)
            } else {
                return base.mixed(with: .white, ratio: 0.50)
            }
        }

        let lbl = UILabel()
        lbl.text = course.title
        lbl.font = .systemFont(ofSize: 12, weight: .semibold)
        lbl.textColor = .white
        lbl.numberOfLines = 2
        lbl.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.topAnchor.constraint(equalTo: v.topAnchor, constant: 6),
            lbl.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6),
            lbl.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
            lbl.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -6)
        ])

        // タップで詳細へ（セル1つ=1授業扱い）
        let tag = nextTag; nextTag += 1
        cellMap[tag] = course
        v.tag = tag
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTapCell(_:)))
        v.isUserInteractionEnabled = true
        v.addGestureRecognizer(tap)

        return v
    }

    private func makePeriodBadge(period: Int) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.translatesAutoresizingMaskIntoConstraints = false

        let top = UILabel()
        top.text = periodTimes(period)?.start ?? ""
        top.font = .systemFont(ofSize: 11)
        top.textColor = .secondaryLabel
        top.textAlignment = .center
        top.translatesAutoresizingMaskIntoConstraints = false

        let mid = UILabel()
        mid.text = "\(period)"
        mid.font = .systemFont(ofSize: 18, weight: .bold)
        mid.textColor = .label
        mid.textAlignment = .center
        mid.setContentCompressionResistancePriority(.required, for: .vertical)
        mid.translatesAutoresizingMaskIntoConstraints = false

        let bottom = UILabel()
        bottom.text = periodTimes(period)?.end ?? ""
        bottom.font = .systemFont(ofSize: 11)
        bottom.textColor = .secondaryLabel
        bottom.textAlignment = .center
        bottom.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(top); v.addSubview(mid); v.addSubview(bottom)

        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: Layout.leftColumnWidth),
            v.heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.minBadgeHeight),

            mid.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            mid.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            mid.trailingAnchor.constraint(equalTo: v.trailingAnchor),

            top.bottomAnchor.constraint(equalTo: mid.topAnchor, constant: -Layout.periodTimeGap),
            bottom.topAnchor.constraint(equalTo: mid.bottomAnchor, constant: Layout.periodTimeGap),

            top.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            bottom.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: v.trailingAnchor),

            top.topAnchor.constraint(greaterThanOrEqualTo: v.topAnchor, constant: 2),
            bottom.bottomAnchor.constraint(lessThanOrEqualTo: v.bottomAnchor, constant: -2),
        ])
        top.setContentCompressionResistancePriority(.required, for: .vertical)
        bottom.setContentCompressionResistancePriority(.required, for: .vertical)
        return v
    }

    private func makeCourseCell() -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = HackColors.emptyCellBg
        container.layer.cornerRadius = 8
        container.layer.masksToBounds = true
        container.layer.borderWidth = 0.5
        container.layer.borderColor = HackColors.gridLine
            .resolvedColor(with: traitCollection).cgColor

        // 自分の時間割と同じコンテンツビュー（タイトル＋教室ピル）
        let content = TimetableCellContentView()
        content.tag = 99
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: Layout.courseMinHeight),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)
        ])
        return container
    }

    private func periodTimes(_ p: Int) -> (start: String, end: String)? {
        let map: [Int: (String, String)] = [
            1: ("9:00",  "10:30"),
            2: ("11:00", "12:30"),
            3: ("13:20", "14:50"),
            4: ("15:05", "16:35"),
            5: ("16:50", "18:20"),
            6: ("18:30", "20:00"),
            7: ("20:10", "21:40")
        ]
        return map[p]
    }

    private func apply(course: GridCell, to view: UIView, truncateTitle: Bool = true) {
        guard let content = view.viewWithTag(99) as? TimetableCellContentView else { return }

        // タイトル（通常は最大16文字、truncateTitle=false のときはフル表示）
        let titleText = course.title
        content.titleLabel.text = (truncateTitle && titleText.count > 16) ? String(titleText.prefix(16)) : titleText
        content.titleLabel.textColor = .white

        // 教室（最初の5文字）
        let roomRaw = (course.room ?? "").trimmingCharacters(in: .whitespaces)
        content.setRoom(roomRaw.isEmpty ? "" : String(roomRaw.prefix(5)))

        // 自分の時間割と同じパステル混色
        let colorKey = course.colorKey.flatMap { SlotColorKey(rawValue: $0) } ?? .teal
        let bg = UIColor { trait in
            let base = colorKey.uiColor.resolvedColor(with: trait)
            if trait.userInterfaceStyle == .dark {
                return base.mixed(with: UIColor(white: 0.18, alpha: 1), ratio: 0.15)
            } else {
                return base.mixed(with: .white, ratio: 0.50)
            }
        }
        view.backgroundColor = bg
        view.layer.borderWidth = 0
    }

    // MARK: - Actions
    @objc private func didChangeSemester(_ sender: UISegmentedControl) {
        semester = (sender.selectedSegmentIndex == 0) ? .first : .second

        // 学期を保存（友だち＋年度）
        UserDefaults.standard.set(semester.rawValue, forKey: Self.prefKey(uid: friendUid, year: year))

        spinner.startAnimating()
        loadAndBuild(for: year, semester: semester)
    }

    // MARK: - タップ → 詳細（モーダル）
    @objc private func didTapCell(_ gr: UITapGestureRecognizer) {
        guard let v = gr.view, let cell = cellMap[v.tag] else { return }

        let course = Course(
            id: (cell.regNumber ?? cell.docID ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            title: cell.title,
            room: cell.room ?? "",
            teacher: cell.teacher ?? "",
            credits: nil,
            campus: nil,
            category: nil,
            syllabusURL: cell.syllabusURL,
            term: semester.jp
        )
        let vc = CourseDetailViewController(
            course: course,
            location: SlotLocation(day: cell.day, period: max(1, cell.period)),
            term: termKeyForCurrentSelection(),
            showsAttendanceControls: false,
            allowsCourseManagement: false,
            showsEnrolledFriends: false,
            showsMoodleAssignments: false
        )
        vc.modalPresentationStyle = .pageSheet

        if let sheet = vc.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(vc, animated: true)
    }

    private func termKeyForCurrentSelection() -> TermKey {
        TermKey(year: year, semester: semester == .first ? .spring : .fall)
    }

    // MARK: - Firestore 読み込み
    private func loadAndBuild(for year: Int, semester: FriendSemester) {
        // 2 形式をフォールバックで試す
        let idA = "assignedCourses.\(year)_\(semester.jp)"
        let idB = "assignedCourses.\(year).\(semester.jp)"

        func handle(_ data: [String: Any]?) {
            self.spinner.stopAnimating()
            guard let data else {
                self.courses = []; self.maxDay = 4; self.maxPeriod = 5
                self.buildGrid(); return
            }

            var parsed: [GridCell] = []

            // 1) ネスト形式 { cells: { d0: { p1: {...} } } }
            if let cells = data["cells"] as? [String: Any] {
                for (k, v) in cells {
                    if let dict = v as? [String: Any],
                       let gc = self.gridCell(fromKey: k, value: dict) {
                        parsed.append(gc)
                    } else if let dict = v as? [String: Any],
                              let day = k.firstMatch(#"d(\d+)"#).flatMap({ Int($0[1]) }) {
                        for (pk, pv) in dict {
                            if let pd = pk.firstMatch(#"p(\d+)"#).flatMap({ Int($0[1]) }),
                               let inner = pv as? [String: Any],
                               let title = inner["title"] as? String, !title.isEmpty {
                                parsed.append(
                                    GridCell(
                                        day: day,
                                        period: pd,
                                        title: title,
                                        teacher: inner["teacher"] as? String,
                                        room: inner["room"] as? String,
                                        docID: (inner["docID"] as? String) ?? (inner["id"] as? String),
                                        syllabusURL: (inner["syllabusURL"] as? String) ?? (inner["url"] as? String),
                                        regNumber: inner["id"] as? String,
                                        colorKey: inner["colorKey"] as? String
                                    )
                                )
                            }
                        }
                    }
                }
            }

            // 2) フラット形式 "cells.d0p1": {..}
            if parsed.isEmpty {
                for (rawKey, value) in data {
                    guard rawKey.hasPrefix("cells."),
                          let dict = value as? [String: Any] else { continue }
                    let subkey = String(rawKey.dropFirst("cells.".count))
                    if let gc = self.gridCell(fromKey: subkey, value: dict) {
                        parsed.append(gc)
                    }
                }
            }

            self.courses = parsed
            if let maxD = self.courses.map(\.day).max() { self.maxDay = max(4, maxD) } else { self.maxDay = 4 }
            if let maxP = self.courses.map(\.period).max() { self.maxPeriod = max(5, maxP) } else { self.maxPeriod = 5 }

            self.buildGrid()
        }

        let ref = Firestore.firestore()
            .collection("users")
            .document(friendUid)
            .collection("timetable")

        // まず A、ダメなら B
        ref.document(idA).getDocument { [weak self] snap, err in
            guard let self else { return }
            if err == nil, let d = snap?.data() { handle(d); return }
            ref.document(idB).getDocument { [weak self] snap2, _ in
                guard let self else { return }
                handle(snap2?.data())
            }
        }
    }

    /// key 文字列や値の day/period を見て GridCell を復元
    private func gridCell(fromKey key: String, value: [String: Any]) -> GridCell? {
        // d..p / p..d
        if let cap = key.firstMatch(#"d(\d+).*p(\d+)|p(\d+).*d(\d+)"#) {
            let d = Int(cap[1]) ?? Int(cap[4]) ?? 0
            let p = Int(cap[2]) ?? Int(cap[3]) ?? 1
            let title = (value["title"] as? String) ?? ""
            if title.isEmpty { return nil }
            return GridCell(
                day: d,
                period: p,
                title: title,
                teacher: value["teacher"] as? String,
                room: value["room"] as? String,
                docID: (value["docID"] as? String) ?? (value["id"] as? String),
                syllabusURL: (value["syllabusURL"] as? String) ?? (value["url"] as? String),
                regNumber: value["id"] as? String,
                colorKey: value["colorKey"] as? String
            )
        }
        // 値に day / period がある
        let day = (value["day"] as? Int) ?? (value["weekday"] as? Int) ?? (value["d"] as? Int) ?? (value["w"] as? Int)
        let per = (value["period"] as? Int) ?? (value["p"] as? Int)
        if let d = day, let p = per {
            let title = (value["title"] as? String) ?? ""
            if title.isEmpty { return nil }
            return GridCell(
                day: d,
                period: p,
                title: title,
                teacher: value["teacher"] as? String,
                room: value["room"] as? String,
                docID: (value["docID"] as? String) ?? (value["id"] as? String),
                syllabusURL: (value["syllabusURL"] as? String) ?? (value["url"] as? String),
                regNumber: value["id"] as? String,
                colorKey: value["colorKey"] as? String
            )
        }
        return nil
    }

    // MARK: - Helpers

    /// 3月から次年度として扱う学年
    private static func academicYear(for date: Date) -> Int {
        let cal = Calendar(identifier: .gregorian)
        let y = cal.component(.year, from: date)
        let m = cal.component(.month, from: date)
        return (m >= 3) ? y : (y - 1)
    }

    /// 学期保存キー（友だち＋年度）
    private static func prefKey(uid: String, year: Int) -> String {
        "friendTerm.\(uid).\(year)"
    }
}

// MARK: - Models / Helpers
private struct GridCell {
    let day: Int
    let period: Int
    let title: String
    let teacher: String?
    let room: String?
    let docID: String?
    let syllabusURL: String?
    let regNumber: String?
    let colorKey: String?

    init(day: Int, period: Int, title: String,
         teacher: String?, room: String?,
         docID: String?, syllabusURL: String? = nil,
         regNumber: String? = nil, colorKey: String? = nil) {
        self.day = day
        self.period = period
        self.title = title
        self.teacher = teacher
        self.room = room
        self.docID = docID
        self.syllabusURL = syllabusURL
        self.regNumber = regNumber
        self.colorKey = colorKey
    }
}

/// 他所の `Semester` と衝突しない固有名
private enum FriendSemester: String, Equatable {
    case first, second
    var jp: String { self == .first ? "前期" : "後期" }
    static func latest(date: Date = Date()) -> FriendSemester {
        // 10月〜 は後期、それ以外は前期（表示開始の目安）
        let m = Calendar(identifier: .gregorian).component(.month, from: date)
        return (m >= 10) ? .second : .first
    }
}

// 正規表現 1st マッチのキャプチャ配列
private extension String {
    func firstMatch(_ pattern: String) -> [String]? {
        guard let r = try? NSRegularExpression(pattern: pattern) else { return nil }
        guard let m = r.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        var caps: [String] = []
        for i in 0..<m.numberOfRanges {
            let range = m.range(at: i)
            if let r = Range(range, in: self) { caps.append(String(self[r])) }
        }
        return caps.count > 1 ? caps : nil
    }
}
