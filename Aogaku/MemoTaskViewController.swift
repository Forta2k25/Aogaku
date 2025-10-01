//
//  MemoTaskViewController.swift
//  Aogaku
//
//  Created by shu m on 2025/10/01.
//
import UIKit
import UserNotifications
import EventKit

fileprivate struct TaskItem: Codable {
    var title: String
    var due: Date?
    var done: Bool
    // 追加: 通知IDとカレンダーイベントID（後で削除・更新に使う）
    var notificationIds: [String]?   // UNNotificationRequest identifiers
    var calendarEventId: String?     // EKEvent.eventIdentifier
}

final class MemoTaskViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    // MARK: Inputs
    private let courseId: String
    private let courseTitle: String

    // MARK: Storage Keys
    private var memoKey: String { "memo.\(courseId)" }
    private var tasksKey: String { "tasks.\(courseId)" }

    // MARK: UI
    private let scroll = UIScrollView()
    private let stack  = UIStackView()
    private let memoLabel = UILabel()
    private let memoView  = UITextView()
    private let addTaskButton = UIButton(type: .system)
    private let table = UITableView(frame: .zero, style: .insetGrouped)

    // MARK: Model
    private var tasks: [TaskItem] = []

    // MARK: Calendar
    private let eventStore = EKEventStore()

    // MARK: Init
    init(courseId: String, courseTitle: String) {
        self.courseId = courseId
        self.courseTitle = courseTitle
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "メモ・課題"

        // モーダル始まりなら閉じるボタン
        if presentingViewController != nil && navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .close, target: self, action: #selector(closeSelf)
            )
        }

        setupLayout()
        loadMemo()
        loadTasks()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveMemo() // 自動保存
    }

    // MARK: UI Build
    private func setupLayout() {
        // Scroll + Stack
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
        ])

        // メモラベル
        memoLabel.text = "メモ（\(courseTitle)）"
        memoLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(memoLabel)

        // メモ
        memoView.font = .systemFont(ofSize: 16)
        memoView.backgroundColor = .secondarySystemBackground
        memoView.layer.cornerRadius = 12
        memoView.isScrollEnabled = false
        memoView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        stack.addArrangedSubview(memoView)
        memoView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        // 「課題を追加」ボタン
        var addCfg = UIButton.Configuration.filled()
        addCfg.title = "課題を追加"
        addCfg.cornerStyle = .large
        addCfg.contentInsets = .init(top: 10, leading: 14, bottom: 10, trailing: 14)
        addTaskButton.configuration = addCfg
        addTaskButton.addTarget(self, action: #selector(addTaskTapped), for: .touchUpInside)
        stack.addArrangedSubview(addTaskButton)

        // 課題テーブル
        table.dataSource = self
        table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        table.isScrollEnabled = false
        table.layer.cornerRadius = 12
        stack.addArrangedSubview(table)
        table.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
    }

    // MARK: Actions
    @objc private func closeSelf() { dismiss(animated: true) }

    @objc private func addTaskTapped() {
        let ac = UIAlertController(title: "課題を追加", message: nil, preferredStyle: .alert)
        ac.addTextField { tf in
            tf.placeholder = "タイトル（例: レポート提出）"
        }
        // 期日ピッカー
        let picker = UIDatePicker()
        picker.datePickerMode = .dateAndTime
        if #available(iOS 13.4, *) { picker.preferredDatePickerStyle = .wheels }
        ac.view.addSubview(picker)
        picker.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: ac.view.topAnchor, constant: 90),
            picker.leadingAnchor.constraint(equalTo: ac.view.leadingAnchor, constant: 16),
            picker.trailingAnchor.constraint(equalTo: ac.view.trailingAnchor, constant: -16),
            picker.bottomAnchor.constraint(equalTo: ac.view.bottomAnchor, constant: -60)
        ])

        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        ac.addAction(UIAlertAction(title: "次へ", style: .default, handler: { [weak self, weak ac] _ in
            guard let self = self else { return }
            let title = ac?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return }
            let due = picker.date
            self.presentReminderAndCalendarOptions(taskTitle: title, due: due)
        }))
        present(ac, animated: true)
    }

    // 2段目のUI: カスタムのボトムシートで表示（はみ出し回避＆下部固定ボタン）
    private func presentReminderAndCalendarOptions(taskTitle: String, due: Date) {
        let sheetVC = ReminderOptionsSheet(due: due)
        sheetVC.title = "通知とカレンダー"

        sheetVC.onSkip = { [weak self] in
            self?.finalizeAddTask(title: taskTitle, due: due, notificationIds: [], calendarEventId: nil)
        }

        sheetVC.onDone = { [weak self] result in
            guard let self = self else { return }
            // 通知予約
            self.requestNotificationPermissionIfNeeded { granted in
                var ids: [String] = []
                if granted {
                    ids = self.scheduleNotifications(
                        courseTitle: self.courseTitle,
                        taskTitle: taskTitle,
                        due: due,
                        dayOffsets: result.dayOffsets,
                        sameDayTime: result.sameDayTime
                    )
                }
                // カレンダー
                if result.addToCalendar {
                    self.addToCalendar(title: taskTitle, due: due) { eventId in
                        self.finalizeAddTask(title: taskTitle, due: due, notificationIds: ids, calendarEventId: eventId)
                    }
                } else {
                    self.finalizeAddTask(title: taskTitle, due: due, notificationIds: ids, calendarEventId: nil)
                }
            }
        }

        let nav = UINavigationController(rootViewController: sheetVC)
        nav.modalPresentationStyle = .pageSheet
        if let sp = nav.sheetPresentationController {
            if #available(iOS 16.0, *) {
                sp.detents = [.medium(), .large()]
                sp.selectedDetentIdentifier = .medium
            } else {
                sp.detents = [.medium()]
            }
            sp.prefersGrabberVisible = true
            sp.preferredCornerRadius = 16
        }
        present(nav, animated: true)
    }


    private func finalizeAddTask(title: String, due: Date, notificationIds: [String], calendarEventId: String?) {
        var item = TaskItem(title: title, due: due, done: false, notificationIds: notificationIds, calendarEventId: calendarEventId)
        tasks.append(item)
        saveTasks()
        reloadTableHeight()
    }

    // MARK: Notifications
    private func requestNotificationPermissionIfNeeded(completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                completion(true)
            case .denied:
                completion(false)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                    completion(granted)
                }
            @unknown default:
                completion(false)
            }
        }
    }

    /// 選択されたオフセットでローカル通知を登録し、作成したidentifierを返す
    private func scheduleNotifications(courseTitle: String,
                                       taskTitle: String,
                                       due: Date,
                                       dayOffsets: [Int],
                                       sameDayTime: Date?) -> [String] {
        let center = UNUserNotificationCenter.current()
        var createdIds: [String] = []
        let now = Date()

        // 期限の表示用
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d(E) HH:mm"

        func schedule(at fireDate: Date, subtitle: String) {
            guard fireDate > now else { return }
            let content = UNMutableNotificationContent()
            // ← タイトルに「科目名 + 追加した課題名」、本文に期限表示
            content.title = "【\(courseTitle)】\(taskTitle)"
            content.body  = "期限: \(f.string(from: due))（\(subtitle)）"
            content.sound = .default
            if #available(iOS 15.0, *) { content.interruptionLevel = .timeSensitive }

            let comps = Calendar.current.dateComponents([.year,.month,.day,.hour,.minute,.second], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let id = "task.\(courseId).\(UUID().uuidString)"
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            center.add(request, withCompletionHandler: nil)
            createdIds.append(id)
        }

        // 1週間前/3日前/1日前（締切と同時刻）
        for d in dayOffsets {
            if let fire = Calendar.current.date(byAdding: .day, value: -d, to: due) {
                schedule(at: fire, subtitle: d == 7 ? "1週間前" : "\(d)日前")
            }
        }

        // 当日（選択時刻）
        if let tp = sameDayTime {
            var day = Calendar.current.dateComponents([.year,.month,.day], from: due)
            let t = Calendar.current.dateComponents([.hour,.minute], from: tp)
            day.hour = t.hour
            day.minute = t.minute
            if let fire = Calendar.current.date(from: day) {
                schedule(at: fire, subtitle: "当日")
            }
        }
        return createdIds
    }


    // MARK: Calendar (EventKit)
    private func addToCalendar(title: String, due: Date, completion: @escaping (String?) -> Void) {
        eventStore.requestAccess(to: .event) { [weak self] granted, _ in
            guard granted, let self = self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // 書き込み可能なカレンダーを確実に取得（デフォルト → 書き込み可の先頭）
            var targetCalendar: EKCalendar?
            if let def = self.eventStore.defaultCalendarForNewEvents, def.allowsContentModifications {
                targetCalendar = def
            } else {
                targetCalendar = self.eventStore
                    .calendars(for: .event)
                    .first(where: { $0.allowsContentModifications && $0.type != .birthday })
            }
            guard let calendar = targetCalendar else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let event = EKEvent(eventStore: self.eventStore)
            event.calendar  = calendar
            event.title     = "【\(self.courseTitle)】\(title) 締切"
            event.startDate = due.addingTimeInterval(-3600) // 1時間前〜
            event.endDate   = due
            event.notes     = "Aogaku で追加"

            do {
                try self.eventStore.save(event, span: .thisEvent, commit: true)
                DispatchQueue.main.async { completion(event.eventIdentifier) }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }


    private func deleteCalendarEventIfNeeded(id: String?) {
        guard let id, let event = eventStore.event(withIdentifier: id) else { return }
        do { try eventStore.remove(event, span: .thisEvent, commit: true) } catch { }
    }

    private func cancelNotificationsIfNeeded(ids: [String]?) {
        guard let ids, !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: Table
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tasks.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = tasks[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var cfg = UIListContentConfiguration.valueCell()
        cfg.text = item.title
        if let d = item.due {
            let f = DateFormatter()
            f.dateFormat = "M/d(E) HH:mm"
            cfg.secondaryText = "期限: " + f.string(from: d)
        } else {
            cfg.secondaryText = nil
        }
        cell.contentConfiguration = cfg
        cell.accessoryType = item.done ? .checkmark : .none
        return cell
    }

    // タップで完了トグル
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        tasks[indexPath.row].done.toggle()
        saveTasks()
        tableView.reloadRows(at: [indexPath], with: .automatic)
    }

    // 左スワイプで削除（通知・カレンダーの片付けも）
    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
                   -> UISwipeActionsConfiguration? {
        let del = UIContextualAction(style: .destructive, title: "削除") { [weak self] _,_,done in
            guard let self = self else { return }
            let item = self.tasks[indexPath.row]
            self.cancelNotificationsIfNeeded(ids: item.notificationIds)
            self.deleteCalendarEventIfNeeded(id: item.calendarEventId)
            self.tasks.remove(at: indexPath.row)
            self.saveTasks()
            self.reloadTableHeight()
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [del])
    }

    // テーブル高さを中身に合わせて更新
    private func reloadTableHeight() {
        table.reloadData()
        table.layoutIfNeeded()
        let h = min(max(table.contentSize.height, 120), 600)
        if let c = (table.constraints.first { $0.firstAttribute == .height }) {
            c.constant = h
        }
    }

    // MARK: Persistence
    private func saveMemo() {
        let text = memoView.text ?? ""
        UserDefaults.standard.set(text, forKey: memoKey)
    }
    private func loadMemo() {
        memoView.text = UserDefaults.standard.string(forKey: memoKey) ?? ""
    }
    private func saveTasks() {
        let data = try? JSONEncoder().encode(tasks)
        UserDefaults.standard.set(data, forKey: tasksKey)
    }
    private func loadTasks() {
        if let data = UserDefaults.standard.data(forKey: tasksKey),
           let arr = try? JSONDecoder().decode([TaskItem].self, from: data) {
            tasks = arr
        }
        reloadTableHeight()
    }
}
// MARK: - ReminderOptionsSheet (bottom sheet)
private final class ReminderOptionsSheet: UIViewController {

    struct Result {
        let dayOffsets: [Int]       // 7, 3, 1
        let sameDayTime: Date?      // 当日通知の時刻（任意）
        let addToCalendar: Bool
    }

    // callbacks
    var onDone: ((Result) -> Void)?
    var onSkip: (() -> Void)?

    // inputs
    private let due: Date

    // UI
    private let scroll = UIScrollView()
    private let content = UIStackView()
    private let oneWeekBtn = makeToggle(title: "1週間前")
    private let threeDaysBtn = makeToggle(title: "3日前")
    private let oneDayBtn = makeToggle(title: "1日前")
    private let sameDayBtn = makeToggle(title: "当日")
    private let timeLabel: UILabel = {
        let l = UILabel()
        l.text = "当日の通知時刻"
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        return l
    }()
    private let timePicker: UIDatePicker = {
        let p = UIDatePicker()
        p.datePickerMode = .time
        if #available(iOS 13.4, *) { p.preferredDatePickerStyle = .wheels }
        p.isEnabled = false
        return p
    }()
    private let calendarRow = UIStackView()
    private let calendarSwitch = UISwitch()

    // 下部固定ボタン
    private let skipButton = UIButton(type: .system)
    private let okButton = UIButton(type: .system)
    private let bottomBar = UIStackView()

    init(due: Date) {
        self.due = due
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // ナビのキャンセル
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(closeTapped))

        buildLayout()
        timePicker.date = due
    }

    private func buildLayout() {
        // スクロール + 縦積み
        content.axis = .vertical
        content.spacing = 12
        content.alignment = .fill

        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(content)

        // トグル群
        let toggles = UIStackView(arrangedSubviews: [oneWeekBtn, threeDaysBtn, oneDayBtn, sameDayBtn])
        toggles.axis = .vertical
        toggles.spacing = 8

        // 当日ONで時刻有効
        sameDayBtn.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            self.timePicker.isEnabled = self.sameDayBtn.isSelected
        }, for: .primaryActionTriggered)

        // カレンダーRow
        calendarRow.axis = .horizontal
        calendarRow.alignment = .center
        calendarRow.spacing = 8
        let calLabel = UILabel()
        calLabel.text = "カレンダーに追加"
        calLabel.font = .systemFont(ofSize: 15)
        calendarRow.addArrangedSubview(calLabel)
        calendarRow.addArrangedSubview(UIView()) // spacer
        calendarRow.addArrangedSubview(calendarSwitch)

        // ← これを追加：ONにしたら即座に権限確認＆要求
        calendarSwitch.addTarget(self, action: #selector(calendarSwitchChanged(_:)), for: .valueChanged)
        
        // 上コンテンツに追加
        content.addArrangedSubview(toggles)
        content.addArrangedSubview(timeLabel)
        content.addArrangedSubview(timePicker)
        content.addArrangedSubview(calendarRow)

        // 下部固定バー（はみ出し防止のため別レイヤ）
        bottomBar.axis = .horizontal
        bottomBar.spacing = 12
        bottomBar.distribution = .fillEqually
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBar)

        // ボタン設定
        var skipCfg = UIButton.Configuration.gray()
        skipCfg.title = "設定しないで追加"
        skipCfg.cornerStyle = .large
        skipButton.configuration = skipCfg
        skipButton.addTarget(self, action: #selector(skipTapped), for: .touchUpInside)

        var okCfg = UIButton.Configuration.filled()
        okCfg.title = "通知を設定して追加"
        okCfg.cornerStyle = .large
        okButton.configuration = okCfg
        okButton.addTarget(self, action: #selector(okTapped), for: .touchUpInside)

        bottomBar.addArrangedSubview(skipButton)
        bottomBar.addArrangedSubview(okButton)

        // レイアウト制約
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            // スクロールは下部バーの上まで
            scroll.topAnchor.constraint(equalTo: guide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),

            // 下部固定バー
            bottomBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            bottomBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            bottomBar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12)
        ])
    }

    @objc private func closeTapped() { dismiss(animated: true) }
    @objc private func skipTapped() {
        dismiss(animated: true) { [weak self] in self?.onSkip?() }
    }
    @objc private func okTapped() {
        var offsets: [Int] = []
        if oneWeekBtn.isSelected { offsets.append(7) }
        if threeDaysBtn.isSelected { offsets.append(3) }
        if oneDayBtn.isSelected { offsets.append(1) }
        let result = Result(
            dayOffsets: offsets,
            sameDayTime: sameDayBtn.isSelected ? timePicker.date : nil,
            addToCalendar: calendarSwitch.isOn
        )
        dismiss(animated: true) { [weak self] in self?.onDone?(result) }
    }
    @objc private func calendarSwitchChanged(_ sw: UISwitch) {
        guard sw.isOn else { return }
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized, .fullAccess: // iOS18では .fullAccess が返る場合あり
            return // そのまま使える
        case .notDetermined:
            EKEventStore().requestAccess(to: .event) { granted, _ in
                DispatchQueue.main.async {
                    if !granted {
                        sw.setOn(false, animated: true)
                        self.showCalendarDeniedAlert()
                    }
                }
            }
        case .denied, .restricted, .writeOnly:
            sw.setOn(false, animated: true)
            showCalendarDeniedAlert()
        @unknown default:
            sw.setOn(false, animated: true)
            showCalendarDeniedAlert()
        }
    }

    private func showCalendarDeniedAlert() {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                     ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                     ?? "このApp"
        let ac = UIAlertController(
            title: "カレンダーにアクセスできません",
            message: "「設定」> \(appName) > カレンダー をオンにしてください。",
            preferredStyle: .alert
        )
        ac.addAction(UIAlertAction(title: "設定を開く", style: .default, handler: { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }))
        ac.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(ac, animated: true)
    }


    // 選択トグル用の共通ボタン
    private static func makeToggle(title: String) -> UIButton {
        var cfg = UIButton.Configuration.tinted()
        cfg.title = title
        cfg.contentInsets = .init(top: 8, leading: 10, bottom: 8, trailing: 10)
        cfg.cornerStyle = .large
        let b = UIButton(configuration: cfg)
        b.changesSelectionAsPrimaryAction = true
        return b
    }
}
