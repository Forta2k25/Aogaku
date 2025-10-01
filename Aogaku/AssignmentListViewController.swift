import UIKit
import UserNotifications
import EventKit

/// MemoTaskViewController 側の保存形式に合わせた最小モデル
private struct SavedTask: Codable {
    var title: String
    var due: Date?
    var done: Bool
    var notificationIds: [String]?
    var calendarEventId: String?
}

/// 1行分に表示するための整形済みデータ（元の保存場所も保持）
private struct TaskRow {
    var title: String
    var due: Date?
    var courseId: String
    var courseTitle: String
    var done: Bool

    // 保存元の情報（トグル・削除用）
    var udKey: String
    var udIndex: Int
    var notificationIds: [String]?
    var calendarEventId: String?
}

final class AssignmentListViewController: UITableViewController {

    private let courseTitleById: [String: String]
    private var rows: [TaskRow] = []

    init(courseTitleById: [String:String]) {
        self.courseTitleById = courseTitleById
        super.init(style: .insetGrouped)
        self.title = "課題一覧"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")

        // 戻る（モーダルで開かれた場合のために Close を明示）
        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .close, target: self, action: #selector(closeTapped)
            )
        }

        loadAllTasks()
        applyEmptyStateIfNeeded()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 万一ナビゲーションバーが隠れている構成でも表示されるように
        navigationController?.setNavigationBarHidden(false, animated: false)
    }

    @objc private func closeTapped() {
        if let nav = navigationController, nav.viewControllers.first !== self {
            nav.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    // MARK: - Load / Save
    private func loadArray(forKey key: String) -> [SavedTask] {
        if let data = UserDefaults.standard.data(forKey: key),
           let arr = try? JSONDecoder().decode([SavedTask].self, from: data) { return arr }
        return []
    }
    private func saveArray(_ arr: [SavedTask], forKey key: String) {
        if let data = try? JSONEncoder().encode(arr) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func loadAllTasks() {
        rows.removeAll()

        let ud = UserDefaults.standard
        // すべてのキーから "tasks." で始まるものを抽出
        for (key, value) in ud.dictionaryRepresentation() {
            guard key.hasPrefix("tasks.") else { continue }
            guard let data = value as? Data,
                  let items = try? JSONDecoder().decode([SavedTask].self, from: data) else { continue }

            // courseId をキー名から推定
            // - 新: "tasks.<courseId>_yYYYY_tCODE_wX pY"
            // - 旧: "tasks.<courseId>"
            let raw = String(key.dropFirst("tasks.".count))
            let courseId: String = raw.split(separator: "_").first.map(String.init) ?? raw
            let courseTitle = courseTitleById[courseId] ?? courseId

            for (idx, t) in items.enumerated() {
                rows.append(TaskRow(title: t.title,
                                    due: t.due,
                                    courseId: courseId,
                                    courseTitle: courseTitle,
                                    done: t.done,
                                    udKey: key,
                                    udIndex: idx,
                                    notificationIds: t.notificationIds,
                                    calendarEventId: t.calendarEventId))
            }
        }

        // 期限の早い順（nil は最後）
        rows.sort { a, b in
            switch (a.due, b.due) {
            case let (x?, y?): return x < y
            case (_?, nil):     return true
            case (nil, _?):     return false
            case (nil, nil):    return a.title < b.title
            }
        }
        tableView.reloadData()
    }

    private func applyEmptyStateIfNeeded() {
        if rows.isEmpty {
            let label = UILabel()
            label.text = "課題は設定されていません"
            label.textColor = .secondaryLabel
            label.textAlignment = .center
            label.numberOfLines = 0
            label.font = .systemFont(ofSize: 15)
            tableView.backgroundView = label
        } else {
            tableView.backgroundView = nil
        }
    }

    // MARK: - Table
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let r = rows[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)

        var cfg = UIListContentConfiguration.subtitleCell()
        cfg.text = r.title
        if let d = r.due {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ja_JP")
            f.dateFormat = "M/d(E) HH:mm"
            cfg.secondaryText = "期限: \(f.string(from: d)) ・ \(r.courseTitle)"
        } else {
            cfg.secondaryText = r.courseTitle
        }
        cell.contentConfiguration = cfg
        cell.accessoryType = r.done ? .checkmark : .none
        return cell
    }

    // タップで完了トグル
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        var r = rows[indexPath.row]
        var arr = loadArray(forKey: r.udKey)
        guard r.udIndex < arr.count else { return }
        arr[r.udIndex].done.toggle()
        saveArray(arr, forKey: r.udKey)

        r.done = arr[r.udIndex].done
        rows[indexPath.row] = r
        tableView.reloadRows(at: [indexPath], with: .automatic)
    }

    // 右スワイプで削除（通知・カレンダーも掃除）
    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
                            -> UISwipeActionsConfiguration? {
        let action = UIContextualAction(style: .destructive, title: "削除") { [weak self] _,_,done in
            guard let self = self else { return }
            let r = self.rows[indexPath.row]
            var arr = self.loadArray(forKey: r.udKey)
            guard r.udIndex < arr.count else { done(false); return }

            let t = arr[r.udIndex]
            if let ids = t.notificationIds, !ids.isEmpty {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
            }
            if let eid = t.calendarEventId {
                let store = EKEventStore()
                if let ev = store.event(withIdentifier: eid) {
                    try? store.remove(ev, span: .thisEvent, commit: true)
                }
            }
            arr.remove(at: r.udIndex)
            self.saveArray(arr, forKey: r.udKey)

            // インデックスが変わるので再ロード
            self.loadAllTasks()
            self.applyEmptyStateIfNeeded()
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [action])
    }
}
