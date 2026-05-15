import UIKit
import GoogleMobileAds
import UserNotifications

// タップジェスチャーにクロージャを持たせる小さなヘルパー
private final class ClosureTapGesture: UITapGestureRecognizer {
    private let action: () -> Void
    init(action: @escaping () -> Void) {
        self.action = action
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(fire))
    }
    @objc private func fire() { action() }
}

@inline(__always)
private func makeAdaptiveAdSize(width: CGFloat) -> AdSize {
    return currentOrientationAnchoredAdaptiveBanner(width: width)
}

private let moodleGreen = UIColor(red: 0/255, green: 150/255, blue: 108/255, alpha: 1)

// MARK: - Cell

private final class MoodleEventCell: UITableViewCell {
    static let reuseID = "MoodleEventCell"

    private let timeLbl   = UILabel()   // 左：HH:mm
    private let iconView  = UIImageView()
    private let titleLbl  = UILabel()   // 緑・太字
    private let subLbl    = UILabel()   // グレー・小

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        // 時間
        timeLbl.font          = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLbl.textColor     = .secondaryLabel
        timeLbl.textAlignment = .right
        timeLbl.translatesAutoresizingMaskIntoConstraints = false
        timeLbl.setContentHuggingPriority(.required, for: .horizontal)
        timeLbl.setContentCompressionResistancePriority(.required, for: .horizontal)

        // アイコン
        let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .light)
        iconView.image               = UIImage(systemName: "square.and.arrow.up", withConfiguration: cfg)
        iconView.tintColor           = .tertiaryLabel
        iconView.contentMode         = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        // タイトル
        titleLbl.font         = .systemFont(ofSize: 15, weight: .semibold)
        titleLbl.textColor    = moodleGreen
        titleLbl.numberOfLines = 2
        titleLbl.translatesAutoresizingMaskIntoConstraints = false

        // サブ
        subLbl.font         = .systemFont(ofSize: 12)
        subLbl.textColor    = .secondaryLabel
        subLbl.numberOfLines = 1
        subLbl.translatesAutoresizingMaskIntoConstraints = false

        let textStack = UIStackView(arrangedSubviews: [titleLbl, subLbl])
        textStack.axis    = .vertical
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let leftStack = UIStackView(arrangedSubviews: [timeLbl, iconView])
        leftStack.axis      = .vertical
        leftStack.spacing   = 4
        leftStack.alignment = .trailing
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(leftStack)
        contentView.addSubview(textStack)

        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            leftStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            leftStack.widthAnchor.constraint(equalToConstant: 40),

            textStack.leadingAnchor.constraint(equalTo: leftStack.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            textStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(with event: MoodleEvent, courseTitle: String?, isSubmitted: Bool) {
        let isCustom = event.uid.hasPrefix("custom:")
        if isSubmitted {
            timeLbl.text = ""
            let cfg2 = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            iconView.image     = UIImage(systemName: "checkmark.circle.fill", withConfiguration: cfg2)
            iconView.tintColor = .systemGreen
            iconView.alpha     = 1.0
            titleLbl.text      = event.cleanTitle
            titleLbl.textColor = .secondaryLabel
            subLbl.text        = "提出済み"
            subLbl.textColor   = .systemGreen
            subLbl.alpha       = 1.0
        } else {
            if let date = event.dueDate {
                let tf = DateFormatter()
                tf.locale = Locale(identifier: "ja_JP"); tf.dateFormat = "HH:mm"
                timeLbl.text = tf.string(from: date)
            } else { timeLbl.text = "" }
            let cfg2 = UIImage.SymbolConfiguration(pointSize: 15, weight: isCustom ? .regular : .light)
            let iconName = isCustom ? "pencil.circle" : "square.and.arrow.up"
            iconView.image     = UIImage(systemName: iconName, withConfiguration: cfg2)
            iconView.tintColor = isCustom ? .systemOrange : .tertiaryLabel
            titleLbl.text      = event.cleanTitle
            let activeColor: UIColor = isCustom ? .systemOrange : moodleGreen
            titleLbl.textColor = event.isPast ? .systemGray3 : activeColor
            if let title = courseTitle, !title.isEmpty {
                subLbl.text = title; subLbl.textColor = .secondaryLabel
            } else if isCustom {
                subLbl.text = "手動追加"; subLbl.textColor = .tertiaryLabel
            } else {
                subLbl.text = "授業を選択 ›"; subLbl.textColor = .systemOrange
            }
            let alpha: CGFloat = event.isPast ? 0.4 : 1.0
            iconView.alpha = alpha; subLbl.alpha = alpha
        }
    }
}

// MARK: - ViewController

final class AssignmentListViewController: UITableViewController, BannerViewDelegate {

    // MARK: - Course title lookup  (登録番号 → 授業名)
    private var courseTitleById: [String: String] = [:]
    // 詳細画面のピッカー用：非数字IDの授業のみ（必修・抽選など手動選択が必要なもの）
    private var pickerTitles: [String] = []

    // MARK: - Data
    // 日付セクション（未来・当日）
    private var upcomingSections: [(date: Date, dateStr: String, events: [MoodleEvent])] = []
    // 期限切れ（折りたたみ）
    private var pastEvents: [MoodleEvent] = []
    private var isPastExpanded = false

    // MARK: - Setup overlay
    private let setupOverlay = UIView()
    private var setupShown   = false

    // MARK: - AdMob
    private let adContainer       = UIView()
    private var bannerView: BannerView?
    private var adContainerHeight: NSLayoutConstraint?
    private var lastBannerWidth: CGFloat = 0
    private var didLoadBannerOnce = false
    private let bannerTopPadding: CGFloat = 0

    // MARK: - Calendar mode
    private var isCalendarMode: Bool {
        get { UserDefaults.standard.bool(forKey: "assignment.calendarMode") }
        set { UserDefaults.standard.set(newValue, forKey: "assignment.calendarMode") }
    }
    private weak var calendarHostView: UIView?
    private var selectedCalendarComponents: DateComponents =
        Calendar.current.dateComponents([.year, .month, .day], from: Date())

    // MARK: - Init
    init() {
        super.init(style: .insetGrouped)
        title = "課題・イベント"
    }
    convenience init(courseTitleById: [String: String],
                     pickerTitles: [String] = []) {
        self.init()
        self.courseTitleById = courseTitleById
        self.pickerTitles    = pickerTitles
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Lifecycle

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ScreenTracker.shared.appear("課題リスト")
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        ScreenTracker.shared.disappear("課題リスト")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(MoodleEventCell.self, forCellReuseIdentifier: MoodleEventCell.reuseID)
        tableView.rowHeight          = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.separatorInset     = UIEdgeInsets(top: 0, left: 68, bottom: 0, right: 0)

        buildNavMenu()
        buildCalendarToggleButton()
        if isCalendarMode { installCalendarHeader() }

        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(pullRefresh), for: .valueChanged)

        setupAdBanner()
        NotificationCenter.default.addObserver(self, selector: #selector(onAdMobReady),
                                               name: .adMobReady, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onSubmittedChanged),
                                               name: .moodleSubmittedStateChanged, object: nil)
        #if DEBUG
        NotificationCenter.default.addObserver(self, selector: #selector(onAdsEnabledDidChange),
                                               name: .adsEnabledDidChange, object: nil)
        #endif
        loadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: false)
        // 時間割の登録授業 + CourseStore からピッカー用タイトルを毎回再構築
        let termCourses   = TermStore.loadAssigned(for: TermStore.loadSelected())
        let customCourses = CourseStore.load()
        var byId: [String: String] = [:]
        var allTitles: Set<String> = []
        for c in (termCourses + customCourses) {
            let key = c.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            byId[key] = c.title
            allTitles.insert(c.title)
        }
        courseTitleById = byId
        pickerTitles    = allTitles.sorted()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        setupOverlay.frame = view.bounds
        loadBannerIfNeeded()
        // カレンダーヘッダーの横幅を画面幅に追従させる
        if let cv = calendarHostView, cv.frame.width != tableView.bounds.width {
            var f = cv.frame
            f.size.width = tableView.bounds.width
            cv.frame = f
            tableView.tableHeaderView = cv  // サイズ変更を tableView に通知
        }
    }

    // MARK: - Nav menu

    private func buildNavMenu() {
        let refresh = UIAction(title: "更新",
                               image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
            self?.fetchFromNetwork()
        }
        let changeURL = UIAction(title: "URLを変更",
                                 image: UIImage(systemName: "link")) { [weak self] _ in
            self?.presentURLAlert()
        }
        let reset = UIAction(title: "初期化",
                             image: UIImage(systemName: "trash"),
                             attributes: .destructive) { [weak self] _ in
            MoodleService.shared.icalURL = nil
            UserDefaults.standard.removeObject(forKey: "moodle.cachedEvents")
            self?.upcomingSections = []
            self?.pastEvents       = []
            self?.tableView.reloadData()
            self?.showSetupOverlay()
        }
        let menuChildren: [UIMenuElement] = [refresh, changeURL, reset]
        let menuBtn = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"),
                                      menu: UIMenu(children: menuChildren))
        let bellImg = MoodleService.shared.globalNotifHours.isEmpty ? "bell" : "bell.badge.fill"
        let bellBtn = UIBarButtonItem(image: UIImage(systemName: bellImg),
                                      style: .plain, target: self,
                                      action: #selector(notifSettingsTapped))
        navigationItem.rightBarButtonItems = [menuBtn, bellBtn]
    }

    @objc private func notifSettingsTapped() { presentNotifSettings() }

    private func refreshBellButton() {
        let img = MoodleService.shared.globalNotifHours.isEmpty ? "bell" : "bell.badge.fill"
        navigationItem.rightBarButtonItems?.last?.image = UIImage(systemName: img)
    }

    // MARK: - Notif settings

    private func presentNotifSettings() {
        let vc = AssignmentNotifSettingsViewController()
        vc.onSave = { [weak self] offsets in
            guard let self else { return }
            self.refreshBellButton()
            if !offsets.isEmpty {
                UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert,.badge,.sound]) { _, _ in
                        DispatchQueue.main.async { self.rescheduleGlobalNotifications() }
                    }
            } else {
                MoodleService.shared.cancelAllGlobalNotifications()
            }
        }
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .pageSheet
        if let sp = nav.sheetPresentationController {
            sp.detents = [.medium(), .large()]
            sp.prefersGrabberVisible = true; sp.preferredCornerRadius = 16
        }
        present(nav, animated: true)
    }

    func rescheduleGlobalNotifications() {
        let all = upcomingSections.flatMap { $0.events } + pastEvents
        MoodleService.shared.scheduleGlobalNotifications(
            for: all,
            courseResolver: { [weak self] ev in self?.resolvedTitle(for: ev) })
    }

    // MARK: - Data

    private func loadData() {
        let cached = MoodleService.shared.cachedEvents()
        if !cached.isEmpty { applyEvents(cached) }

        if MoodleService.shared.icalURL == nil {
            showSetupOverlay()
        } else {
            fetchFromNetwork()
        }
    }

    @objc private func pullRefresh() {
        guard MoodleService.shared.icalURL != nil else {
            refreshControl?.endRefreshing()
            showSetupOverlay()
            return
        }
        fetchFromNetwork()
    }

    private func fetchFromNetwork() {
        MoodleService.shared.fetchEvents { [weak self] result in
            DispatchQueue.main.async {
                self?.refreshControl?.endRefreshing()
                switch result {
                case .success(let events):
                    self?.hideSetupOverlay()
                    self?.applyEvents(events)
                case .failure(let err):
                    if self?.upcomingSections.isEmpty == true && self?.pastEvents.isEmpty == true {
                        self?.showError(err.localizedDescription)
                    }
                }
            }
        }
    }

    private func applyEvents(_ moodleEvents: [MoodleEvent]) {
        // カスタム課題を Moodle イベントにマージ
        let customEvents = MoodleService.shared.customAssignments().map { $0.toMoodleEvent() }
        let events = (moodleEvents + customEvents).sorted {
            ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture)
        }

        let now = Date()
        let cal = Calendar.current

        // 過去と未来に分離
        let future = events.filter { ($0.dueDate ?? .distantFuture) >= now }
        pastEvents  = events.filter { ($0.dueDate ?? .distantFuture) < now }
            .sorted { ($0.dueDate ?? .distantPast) > ($1.dueDate ?? .distantPast) } // 新しい順

        // 未来を日付ごとにグループ化
        var grouped: [Date: [MoodleEvent]] = [:]
        for e in future {
            guard let d = e.dueDate else { continue }
            let day = cal.startOfDay(for: d)
            grouped[day, default: []].append(e)
        }

        let df = DateFormatter()
        df.locale     = Locale(identifier: "ja_JP")
        df.dateFormat = "yyyy年 MM月 d日(EEEE)"

        upcomingSections = grouped.keys.sorted().map { date in
            let evs = grouped[date]!.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
            return (date: date, dateStr: df.string(from: date), events: evs)
        }

        tableView.reloadData()
        updateEmptyState()
        rescheduleGlobalNotifications()
        if #available(iOS 16.0, *), let cv = calendarHostView as? UICalendarView {
            cv.reloadDecorations(forDateComponents: datesWithEvents(), animated: true)
        }
    }

    private func updateEmptyState() {
        guard !setupShown else { return }
        if upcomingSections.isEmpty && pastEvents.isEmpty {
            let lbl = UILabel()
            lbl.text          = "課題・イベントはありません"
            lbl.textColor     = .secondaryLabel
            lbl.textAlignment = .center
            lbl.font          = .systemFont(ofSize: 15)
            tableView.backgroundView = lbl
        } else {
            tableView.backgroundView = nil
        }
    }

    // MARK: - Past section index

    private var pastSectionIndex: Int { upcomingSections.count }
    private var hasPastSection: Bool  { !pastEvents.isEmpty }

    // MARK: - TableView

    override func numberOfSections(in tableView: UITableView) -> Int {
        if isCalendarMode { return 1 }
        return upcomingSections.count + (hasPastSection ? 1 : 0)
    }

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int {
        if isCalendarMode { return eventsForSelectedDate().count }
        if section < upcomingSections.count {
            return upcomingSections[section].events.count
        }
        // 期限切れセクション
        return isPastExpanded ? pastEvents.count : 0
    }

    // MARK: Section header

    override func tableView(_ tableView: UITableView,
                            viewForHeaderInSection section: Int) -> UIView? {
        let container = UIView()
        container.backgroundColor = .systemGroupedBackground

        let lbl = UILabel()
        lbl.font          = .systemFont(ofSize: 13, weight: .bold)
        lbl.translatesAutoresizingMaskIntoConstraints = false

        if isCalendarMode {
            let events = eventsForSelectedDate()
            let df = DateFormatter()
            df.locale = Locale(identifier: "ja_JP"); df.dateFormat = "M月d日(EEEE)"
            let dateStr: String
            if let date = Calendar.current.date(from: selectedCalendarComponents) {
                dateStr = df.string(from: date)
            } else { dateStr = "選択中の日付" }
            lbl.text      = events.isEmpty ? "\(dateStr)　課題なし" : "\(dateStr)　\(events.count)件"
            lbl.textColor = .secondaryLabel
            container.addSubview(lbl)
            NSLayoutConstraint.activate([
                lbl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                lbl.centerYAnchor.constraint(equalTo: container.centerYAnchor)
            ])
            return container
        }

        if section < upcomingSections.count {
            let sec = upcomingSections[section]
            lbl.text      = sec.dateStr
            lbl.textColor = .label
            container.addSubview(lbl)

            let isToday = Calendar.current.isDateInToday(sec.date)
            if isToday {
                let todayBadge = UILabel()
                todayBadge.text            = "今日"
                todayBadge.font            = .systemFont(ofSize: 11, weight: .bold)
                todayBadge.textColor       = .white
                todayBadge.backgroundColor = moodleGreen
                todayBadge.textAlignment   = .center
                todayBadge.layer.cornerRadius   = 8
                todayBadge.layer.masksToBounds  = true
                todayBadge.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(todayBadge)
                NSLayoutConstraint.activate([
                    lbl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                    lbl.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                    todayBadge.leadingAnchor.constraint(equalTo: lbl.trailingAnchor, constant: 8),
                    todayBadge.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                    todayBadge.widthAnchor.constraint(equalToConstant: 36),
                    todayBadge.heightAnchor.constraint(equalToConstant: 18)
                ])
            } else {
                NSLayoutConstraint.activate([
                    lbl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                    lbl.centerYAnchor.constraint(equalTo: container.centerYAnchor)
                ])
            }
        } else {
            // 期限切れトグル
            let arrow = UIImageView(image: UIImage(systemName: isPastExpanded ? "chevron.up" : "chevron.down"))
            arrow.tintColor    = .tertiaryLabel
            arrow.contentMode  = .scaleAspectFit
            arrow.translatesAutoresizingMaskIntoConstraints = false

            lbl.text      = "期限切れ（\(pastEvents.count)件）"
            lbl.textColor = .tertiaryLabel

            container.addSubview(lbl)
            container.addSubview(arrow)
            NSLayoutConstraint.activate([
                lbl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                lbl.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                arrow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
                arrow.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                arrow.widthAnchor.constraint(equalToConstant: 14)
            ])

            let tap = ClosureTapGesture { [weak self] in self?.togglePastSection() }
            container.addGestureRecognizer(tap)
            container.isUserInteractionEnabled = true
        }
        return container
    }

    override func tableView(_ tableView: UITableView,
                            heightForHeaderInSection section: Int) -> CGFloat { 36 }

    override func tableView(_ tableView: UITableView,
                            viewForFooterInSection section: Int) -> UIView? { UIView() }
    override func tableView(_ tableView: UITableView,
                            heightForFooterInSection section: Int) -> CGFloat { 8 }

    // MARK: Cells

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell
        = tableView.dequeueReusableCell(withIdentifier: MoodleEventCell.reuseID,
                                                 for: indexPath) as! MoodleEventCell
        let event = eventAt(indexPath)
        cell.configure(with: event, courseTitle: resolvedTitle(for: event),
                       isSubmitted: MoodleService.shared.isSubmitted(uid: event.uid))
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let event = eventAt(indexPath)

        // カスタム課題はアクションシートで操作
        if event.uid.hasPrefix("custom:") {
            presentCustomAssignmentActions(for: event, at: indexPath)
            return
        }

        let detail = MoodleEventDetailViewController(
            event: event,
            courseTitle: resolvedTitle(for: event),
            pickerTitles: pickerTitles
        )
        detail.onCourseChanged = { [weak self] _ in
            self?.reloadRows(withCategoryCode: event.courseCode)
        }
        detail.onSubmittedChanged = { [weak self] in
            self?.tableView.reloadData()
            self?.rescheduleGlobalNotifications()
        }
        navigationController?.pushViewController(detail, animated: true)
    }

    private func presentCustomAssignmentActions(for event: MoodleEvent, at indexPath: IndexPath) {
        let isSubmitted = MoodleService.shared.isSubmitted(uid: event.uid)
        let sheet = UIAlertController(title: event.cleanTitle, message: nil,
                                      preferredStyle: .actionSheet)
        let toggleTitle = isSubmitted ? "提出済みを取り消す" : "提出済みにする"
        let toggleIcon  = isSubmitted ? "xmark.circle" : "checkmark.circle"
        sheet.addAction(UIAlertAction(title: toggleTitle, style: .default) { [weak self] _ in
            MoodleService.shared.toggleSubmitted(uid: event.uid)
            self?.tableView.reloadData()
            self?.rescheduleGlobalNotifications()
        })
        sheet.addAction(UIAlertAction(title: "削除", style: .destructive) { [weak self] _ in
            let id = String(event.uid.dropFirst("custom:".count))
            MoodleService.shared.deleteCustomAssignment(id: id)
            self?.reloadWithCustom()
        })
        sheet.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        // iPad popover
        if let ppc = sheet.popoverPresentationController,
           let cell = tableView.cellForRow(at: indexPath) {
            ppc.sourceView = cell; ppc.sourceRect = cell.bounds
        }
        present(sheet, animated: true)
    }

    // MARK: - 授業名解決

    private func eventAt(_ indexPath: IndexPath) -> MoodleEvent {
        if isCalendarMode { return eventsForSelectedDate()[indexPath.row] }
        if indexPath.section < upcomingSections.count {
            return upcomingSections[indexPath.section].events[indexPath.row]
        }
        return pastEvents[indexPath.row]
    }

    /// 自動変換 → 手動マッピングの順で授業名を解決する
    private func resolvedTitle(for event: MoodleEvent) -> String? {
        // カスタム課題: eventDescription に科目名を格納している
        if event.uid.hasPrefix("custom:") {
            return event.eventDescription.isEmpty ? nil : event.eventDescription
        }
        // ① 登録番号の計算式で自動マッチ
        if let regNum = MoodleService.shared.registrationNumber(from: event.courseCode),
           let title = courseTitleById[regNum] {
            return title
        }
        // ② 手動マッピング
        return MoodleService.shared.manualCourseMapping[event.courseCode]
    }

    private func reloadRows(withCategoryCode code: String) {
        var paths: [IndexPath] = []
        for (s, sec) in upcomingSections.enumerated() {
            for (r, ev) in sec.events.enumerated() where ev.courseCode == code {
                paths.append(IndexPath(row: r, section: s))
            }
        }
        if isPastExpanded {
            for (r, ev) in pastEvents.enumerated() where ev.courseCode == code {
                paths.append(IndexPath(row: r, section: pastSectionIndex))
            }
        }
        tableView.reloadRows(at: paths, with: .automatic)
    }

    // MARK: - Calendar mode

    private func buildCalendarToggleButton() {
        let imgName = isCalendarMode ? "list.bullet" : "calendar"
        let calBtn = UIBarButtonItem(image: UIImage(systemName: imgName),
                                    style: .plain, target: self,
                                    action: #selector(calendarToggleTapped))
        let addBtn = UIBarButtonItem(image: UIImage(systemName: "plus"),
                                    style: .plain, target: self,
                                    action: #selector(addCustomAssignmentTapped))
        navigationItem.leftBarButtonItems = [calBtn, addBtn]
    }

    // MARK: - カスタム課題追加

    @objc private func addCustomAssignmentTapped() {
        let vc = AddCustomAssignmentViewController()
        vc.onSave = { [weak self] item in
            MoodleService.shared.addCustomAssignment(item)
            self?.reloadWithCustom()
        }
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .pageSheet
        if let sp = nav.sheetPresentationController {
            sp.detents = [.medium(), .large()]
            sp.prefersGrabberVisible = true
            sp.preferredCornerRadius = 16
        }
        present(nav, animated: true)
    }

    /// キャッシュ済み Moodle イベント＋カスタム課題を再適用する
    private func reloadWithCustom() {
        let cached = MoodleService.shared.cachedEvents()
        applyEvents(cached)
    }

    // MARK: - スワイプ削除（カスタム課題のみ）

    override func tableView(_ tableView: UITableView,
                            canEditRowAt indexPath: IndexPath) -> Bool {
        return eventAt(indexPath).uid.hasPrefix("custom:")
    }

    override func tableView(_ tableView: UITableView,
                            commit editingStyle: UITableViewCell.EditingStyle,
                            forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let event = eventAt(indexPath)
        guard event.uid.hasPrefix("custom:") else { return }
        let id = String(event.uid.dropFirst("custom:".count))
        MoodleService.shared.deleteCustomAssignment(id: id)
        reloadWithCustom()
    }

    @objc private func calendarToggleTapped() {
        isCalendarMode.toggle()
        buildCalendarToggleButton()
        if isCalendarMode {
            installCalendarHeader()
        } else {
            removeCalendarHeader()
        }
        tableView.reloadData()
    }

    private func installCalendarHeader() {
        guard #available(iOS 16.0, *) else { return }

        let cv = UICalendarView()
        cv.calendar   = .current
        cv.locale     = Locale(identifier: "ja_JP")
        cv.tintColor  = moodleGreen
        cv.delegate   = self

        let sel = UICalendarSelectionSingleDate(delegate: self)
        sel.selectedDate = selectedCalendarComponents
        cv.selectionBehavior = sel

        let width = tableView.bounds.width > 0 ? tableView.bounds.width : UIScreen.main.bounds.width
        cv.frame = CGRect(x: 0, y: 0, width: width, height: 370)
        tableView.tableHeaderView = cv
        calendarHostView = cv
    }

    private func removeCalendarHeader() {
        tableView.tableHeaderView = nil
        calendarHostView = nil
    }

    /// 選択中の日付に対応するイベント一覧（未来 + 期限切れ両方）
    private func eventsForSelectedDate() -> [MoodleEvent] {
        guard let date = Calendar.current.date(from: selectedCalendarComponents) else { return [] }
        let cal = Calendar.current
        let upcoming = upcomingSections
            .first { cal.isDate($0.date, inSameDayAs: date) }?.events ?? []
        let past = pastEvents.filter {
            guard let d = $0.dueDate else { return false }
            return cal.isDate(d, inSameDayAs: date)
        }
        return upcoming + past
    }

    /// 課題が存在する全日付（カレンダー装飾用）
    private func datesWithEvents() -> [DateComponents] {
        let cal = Calendar.current
        var result: [DateComponents] = []
        for sec in upcomingSections {
            result.append(cal.dateComponents([.year, .month, .day], from: sec.date))
        }
        for ev in pastEvents {
            if let d = ev.dueDate {
                result.append(cal.dateComponents([.year, .month, .day], from: d))
            }
        }
        return result
    }

    // MARK: - Past section toggle

    @objc private func togglePastSection() {
        isPastExpanded.toggle()
        let idx = IndexSet(integer: pastSectionIndex)
        tableView.reloadSections(idx, with: .automatic)
    }

    // MARK: - Setup Overlay

    private func showSetupOverlay() {
        guard !setupShown else { return }
        setupShown = true
        tableView.backgroundView = nil

        setupOverlay.backgroundColor = .systemGroupedBackground
        setupOverlay.frame = view.bounds
        view.addSubview(setupOverlay)

        let iconCfg  = UIImage.SymbolConfiguration(pointSize: 40, weight: .light)
        let iconView = UIImageView(image: UIImage(systemName: "calendar.badge.plus",
                                                  withConfiguration: iconCfg))
        iconView.tintColor   = moodleGreen
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLbl = UILabel()
        titleLbl.text          = "Moodle 課題を連携"
        titleLbl.font          = .systemFont(ofSize: 20, weight: .semibold)
        titleLbl.textAlignment = .center
        titleLbl.translatesAutoresizingMaskIntoConstraints = false

        func makeStep(number: String, text: String, action: (() -> Void)? = nil) -> UIView {
            let numLbl = UILabel()
            numLbl.text                    = number
            numLbl.font                    = .systemFont(ofSize: 13, weight: .bold)
            numLbl.textColor               = .white
            numLbl.textAlignment           = .center
            numLbl.backgroundColor         = moodleGreen
            numLbl.layer.cornerRadius      = 11
            numLbl.layer.masksToBounds     = true
            numLbl.translatesAutoresizingMaskIntoConstraints = false
            numLbl.widthAnchor.constraint(equalToConstant: 22).isActive  = true
            numLbl.heightAnchor.constraint(equalToConstant: 22).isActive = true

            let textLbl = UILabel()
            textLbl.text          = text
            textLbl.font          = .systemFont(ofSize: 14)
            textLbl.textColor     = action != nil ? moodleGreen : .label
            textLbl.numberOfLines = 0
            textLbl.translatesAutoresizingMaskIntoConstraints = false

            let row = UIStackView(arrangedSubviews: [numLbl, textLbl])
            row.axis      = .horizontal
            row.spacing   = 10
            row.alignment = .center
            row.translatesAutoresizingMaskIntoConstraints = false

            if let action {
                let tap = ClosureTapGesture(action: action)
                row.addGestureRecognizer(tap)
                row.isUserInteractionEnabled = true
                let arrow = UIImageView(image: UIImage(systemName: "arrow.up.right"))
                arrow.tintColor   = moodleGreen
                arrow.contentMode = .scaleAspectFit
                arrow.translatesAutoresizingMaskIntoConstraints = false
                arrow.widthAnchor.constraint(equalToConstant: 14).isActive = true
                row.addArrangedSubview(arrow)
            }
            return row
        }

        let step1 = makeStep(number: "1", text: "Moodle カレンダーエクスポートページを開く") {
            if let url = URL(string: "https://agulms45.aim.aoyama.ac.jp/calendar/export.php") {
                UIApplication.shared.open(url)
            }
        }
        let step2 = makeStep(number: "2",
                             text: "イベント「すべてのイベント」・期間「今週」を選び、「カレンダーURLを取得する」をコピー")
        let step3 = makeStep(number: "3", text: "コピーしたURLを下のボタンで貼り付け")

        let stepsStack = UIStackView(arrangedSubviews: [step1, step2, step3])
        stepsStack.axis      = .vertical
        stepsStack.spacing   = 14
        stepsStack.alignment = .fill
        stepsStack.translatesAutoresizingMaskIntoConstraints = false

        let noteLbl = UILabel()
        noteLbl.text          = "※ 期間は「今週」で構いません。アプリ側で自動的に全期間を取得するため、URLの再設定は不要です。"
        noteLbl.font          = .systemFont(ofSize: 11)
        noteLbl.textColor     = .tertiaryLabel
        noteLbl.numberOfLines = 0
        noteLbl.textAlignment = .left
        noteLbl.translatesAutoresizingMaskIntoConstraints = false

        let btn = UIButton(type: .system)
        btn.setTitle("URLを貼り付けて設定する", for: .normal)
        btn.titleLabel?.font    = .systemFont(ofSize: 15, weight: .semibold)
        btn.backgroundColor     = moodleGreen
        btn.setTitleColor(.white, for: .normal)
        btn.layer.cornerRadius  = 12
        btn.layer.masksToBounds = true
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(setupBtnTapped), for: .touchUpInside)

        let vStack = UIStackView(arrangedSubviews: [iconView, titleLbl, stepsStack, noteLbl, btn])
        vStack.axis      = .vertical
        vStack.spacing   = 20
        vStack.alignment = .center
        vStack.translatesAutoresizingMaskIntoConstraints = false
        setupOverlay.addSubview(vStack)

        NSLayoutConstraint.activate([
            iconView.heightAnchor.constraint(equalToConstant: 52),
            stepsStack.widthAnchor.constraint(equalToConstant: 300),
            noteLbl.widthAnchor.constraint(equalToConstant: 300),
            btn.widthAnchor.constraint(equalToConstant: 260),
            btn.heightAnchor.constraint(equalToConstant: 46),
            vStack.centerXAnchor.constraint(equalTo: setupOverlay.centerXAnchor),
            vStack.centerYAnchor.constraint(equalTo: setupOverlay.centerYAnchor, constant: -20),
            vStack.leadingAnchor.constraint(greaterThanOrEqualTo: setupOverlay.leadingAnchor, constant: 24),
            vStack.trailingAnchor.constraint(lessThanOrEqualTo: setupOverlay.trailingAnchor, constant: -24)
        ])
    }

    private func hideSetupOverlay() {
        guard setupShown else { return }
        setupShown = false
        setupOverlay.removeFromSuperview()
    }

    @objc private func setupBtnTapped() { presentURLAlert() }

    // MARK: - URL Alert

    private func presentURLAlert() {
        let alert = UIAlertController(title: "iCal URLを入力",
                                      message: "Moodleのカレンダーエクスポートページから取得したURLを貼り付けてください",
                                      preferredStyle: .alert)
        alert.addTextField { tf in
            tf.text                   = MoodleService.shared.icalURL
            tf.placeholder            = "https://agulms45.aim.aoyama.ac.jp/calendar/..."
            tf.clearButtonMode        = .always
            tf.autocorrectionType     = .no
            tf.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存して取得", style: .default) { [weak self] _ in
            guard let url = alert.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { return }
            MoodleService.shared.icalURL = url
            self?.hideSetupOverlay()
            self?.fetchFromNetwork()
        })
        present(alert, animated: true)
    }

    // MARK: - Helpers

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "取得エラー", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }


    // MARK: - AdMob

    @objc private func onAdMobReady() { loadBannerIfNeeded() }

    #if DEBUG
    @objc private func onAdsEnabledDidChange() {
        let show = AdsConfig.enabled
        adContainer.isHidden = !show
        adContainerHeight?.constant = show ? (bannerView?.adSize.size.height ?? 0) + bannerTopPadding : 0
        updateBottomInset(show ? (adContainerHeight?.constant ?? 0) : 0)
        UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() }
    }
    #endif

    @objc private func onSubmittedChanged() {
        tableView.reloadData()
        rescheduleGlobalNotifications()
    }

    private func setupAdBanner() {
        adContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(adContainer)
        adContainerHeight = adContainer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            adContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            adContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            adContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            adContainerHeight!
        ])

        guard AdsConfig.enabled else {
            adContainer.isHidden = true
            adContainerHeight?.constant = 0
            updateBottomInset(0)
            return
        }

        let bv = BannerView()
        bv.translatesAutoresizingMaskIntoConstraints = false
        bv.adUnitID           = AdsConfig.bannerUnitID
        bv.rootViewController = self
        bv.adSize             = AdSizeBanner
        bv.delegate           = self
        adContainer.addSubview(bv)
        NSLayoutConstraint.activate([
            bv.leadingAnchor.constraint(equalTo: adContainer.leadingAnchor),
            bv.trailingAnchor.constraint(equalTo: adContainer.trailingAnchor),
            bv.bottomAnchor.constraint(equalTo: adContainer.bottomAnchor),
            bv.topAnchor.constraint(equalTo: adContainer.topAnchor, constant: bannerTopPadding)
        ])
        let w = max(320, floor(view.safeAreaLayoutGuide.layoutFrame.width))
        adContainerHeight?.constant = makeAdaptiveAdSize(width: w).size.height + bannerTopPadding
        bannerView = bv
    }

    private func loadBannerIfNeeded() {
        guard let bv = bannerView else { return }
        let w = max(320, floor(view.safeAreaLayoutGuide.layoutFrame.width))
        guard w > 0, abs(w - lastBannerWidth) >= 0.5 else { return }
        lastBannerWidth = w
        let size = makeAdaptiveAdSize(width: w)
        adContainerHeight?.constant = size.size.height + bannerTopPadding
        view.layoutIfNeeded()
        guard size.size.height > 0 else { return }
        if !CGSizeEqualToSize(bv.adSize.size, size.size) { bv.adSize = size }
        if !didLoadBannerOnce { didLoadBannerOnce = true; bv.load(Request()) }
    }

    private func updateBottomInset(_ h: CGFloat) {
        tableView.contentInset.bottom          = h
        tableView.scrollIndicatorInsets.bottom = h
    }

    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        let h = bannerView.adSize.size.height
        adContainerHeight?.constant = h + bannerTopPadding
        updateBottomInset(h + bannerTopPadding)
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
    }

    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        adContainerHeight?.constant = 0
        updateBottomInset(0)
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
    }
}

// MARK: - UICalendarViewDelegate

@available(iOS 16.0, *)
extension AssignmentListViewController: UICalendarViewDelegate {
    func calendarView(_ calendarView: UICalendarView,
                      decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
        guard let date = Calendar.current.date(from: dateComponents) else { return nil }
        let cal = Calendar.current
        let hasUpcoming = upcomingSections.contains { cal.isDate($0.date, inSameDayAs: date) }
        let hasPast     = pastEvents.contains {
            guard let d = $0.dueDate else { return false }
            return cal.isDate(d, inSameDayAs: date)
        }
        guard hasUpcoming || hasPast else { return nil }
        return .default(color: moodleGreen, size: .small)
    }
}

// MARK: - UICalendarSelectionSingleDateDelegate

@available(iOS 16.0, *)
extension AssignmentListViewController: UICalendarSelectionSingleDateDelegate {
    func dateSelection(_ selection: UICalendarSelectionSingleDate,
                       didSelectDate dateComponents: DateComponents?) {
        guard let dc = dateComponents else { return }
        selectedCalendarComponents = dc
        tableView.reloadData()
    }
}

// MARK: - AddCustomAssignmentViewController
// UITableViewController ベースで Auto Layout ループを回避する

private final class AddCustomAssignmentViewController: UITableViewController {

    var onSave: ((CustomAssignment) -> Void)?

    // Section 0: 課題名 / 科目名テキストフィールド
    private let titleField  = UITextField()
    private let courseField = UITextField()
    // Section 1: 日時ピッカー（.compact = ボタン表示でレイアウト安全）
    private let datePicker  = UIDatePicker()

    // Section 1 のピッカー行をインラインで展開するための状態
    private var isPickerExpanded = false

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "課題を追加"

        navigationItem.leftBarButtonItem  = UIBarButtonItem(
            title: "キャンセル", style: .plain, target: self, action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "追加", style: .done, target: self, action: #selector(saveTapped))
        navigationItem.rightBarButtonItem?.isEnabled = false

        setupFields()
        setupDatePicker()

        tableView.keyboardDismissMode = .onDrag
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        titleField.becomeFirstResponder()
    }

    // MARK: - Setup

    private func setupFields() {
        titleField.placeholder         = "課題名（必須）"
        titleField.font                = .systemFont(ofSize: 16)
        titleField.clearButtonMode     = .whileEditing
        titleField.returnKeyType       = .next
        titleField.autocorrectionType  = .no
        titleField.autocapitalizationType = .none
        titleField.addTarget(self, action: #selector(titleChanged), for: .editingChanged)
        titleField.delegate = self

        courseField.placeholder           = "科目名（任意）"
        courseField.font                  = .systemFont(ofSize: 16)
        courseField.clearButtonMode       = .whileEditing
        courseField.returnKeyType         = .done
        courseField.autocorrectionType    = .no
        courseField.autocapitalizationType = .none
        courseField.delegate = self
    }

    private func setupDatePicker() {
        // .wheels はセルの中で高さが確定していてレイアウトループが起きない
        datePicker.datePickerMode = .dateAndTime
        datePicker.preferredDatePickerStyle = .wheels
        datePicker.locale     = Locale(identifier: "ja_JP")
        datePicker.tintColor  = moodleGreen
        // デフォルト: 翌日 23:59
        let cal = Calendar.current
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) {
            var c = cal.dateComponents([.year, .month, .day], from: tomorrow)
            c.hour = 23; c.minute = 59
            datePicker.date = cal.date(from: c) ?? tomorrow
        }
        datePicker.minimumDate = Date()
    }

    // MARK: - TableView

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 2 : (isPickerExpanded ? 2 : 1)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? nil : nil
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch (indexPath.section, indexPath.row) {

        case (0, 0):   // 課題名
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            titleField.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(titleField)
            NSLayoutConstraint.activate([
                titleField.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
                titleField.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
                titleField.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 11),
                titleField.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -11)
            ])
            return cell

        case (0, 1):   // 科目名
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            courseField.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(courseField)
            NSLayoutConstraint.activate([
                courseField.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
                courseField.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
                courseField.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 11),
                courseField.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -11)
            ])
            return cell

        case (1, 0):   // 日付ラベル行（タップで展開）
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = "期日"
            let df = DateFormatter()
            df.locale = Locale(identifier: "ja_JP")
            df.dateFormat = "M月d日(E) HH:mm"
            cell.detailTextLabel?.text = df.string(from: datePicker.date)
            cell.detailTextLabel?.textColor = isPickerExpanded ? moodleGreen : .secondaryLabel
            cell.accessoryType = .none
            return cell

        default:       // (1, 1) ピッカー本体
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            datePicker.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(datePicker)
            NSLayoutConstraint.activate([
                datePicker.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                datePicker.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
                datePicker.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                datePicker.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor)
            ])
            // 日付変更 → ラベル行を更新
            datePicker.addTarget(self, action: #selector(dateChanged), for: .valueChanged)
            return cell
        }
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1, indexPath.row == 0 else { return }
        titleField.resignFirstResponder()
        courseField.resignFirstResponder()
        isPickerExpanded.toggle()
        tableView.performBatchUpdates({
            tableView.reloadRows(at: [IndexPath(row: 0, section: 1)], with: .none)
            if isPickerExpanded {
                tableView.insertRows(at: [IndexPath(row: 1, section: 1)], with: .fade)
            } else {
                tableView.deleteRows(at: [IndexPath(row: 1, section: 1)], with: .fade)
            }
        })
    }

    override func tableView(_ tableView: UITableView,
                            heightForRowAt indexPath: IndexPath) -> CGFloat {
        if indexPath.section == 1, indexPath.row == 1 {
            return 216   // UIDatePicker wheels の標準高さ
        }
        return 44
    }

    // MARK: - Actions

    @objc private func cancelTapped() { dismiss(animated: true) }

    @objc private func saveTapped() {
        guard let title = titleField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return }
        let course = courseField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let item = CustomAssignment(id: UUID().uuidString,
                                    title: title,
                                    courseName: course,
                                    dueDate: datePicker.date)
        onSave?(item)
        dismiss(animated: true)
    }

    @objc private func titleChanged() {
        let filled = !(titleField.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        navigationItem.rightBarButtonItem?.isEnabled = filled
    }

    @objc private func dateChanged() {
        // ラベル行の日付表示を更新
        tableView.reloadRows(at: [IndexPath(row: 0, section: 1)], with: .none)
    }
}

extension AddCustomAssignmentViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField == titleField {
            courseField.becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
        }
        return true
    }
}

// MARK: - Tab host

/// 「課題」タブ用 NavigationController。
/// AssignmentListViewController は init?(coder:) 非対応のため
/// storyboard の rootViewController segue を使わず、
/// viewWillAppear(初回のみ) で programmatically にルートを設定する。
final class AssignmentListNavController: UINavigationController {

    private var didSetupRoot = false

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !didSetupRoot else { return }
        didSetupRoot = true

        let termCourses   = TermStore.loadAssigned(for: TermStore.loadSelected())
        let customCourses = CourseStore.load()
        var courseTitleById: [String: String] = [:]
        var allTitles: Set<String> = []
        for c in (termCourses + customCourses) {
            let key = c.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            courseTitleById[key] = c.title
            allTitles.insert(c.title)
        }
        let vc = AssignmentListViewController(
            courseTitleById: courseTitleById,
            pickerTitles: allTitles.sorted()
        )
        setViewControllers([vc], animated: false)
    }
}
