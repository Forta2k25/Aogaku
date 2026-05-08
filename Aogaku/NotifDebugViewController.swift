#if DEBUG
import UIKit
import UserNotifications

// MARK: - NotifDebugViewController
// 開発者用：通知機能の動作確認画面
// AssignmentListViewController の「…」メニュー（DEBUG時のみ）から開く

final class NotifDebugViewController: UITableViewController {

    // MARK: - モデル

    private enum Section: Int, CaseIterable {
        case status, scheduled, actions
        var title: String {
            switch self {
            case .status:    return "通知ステータス"
            case .scheduled: return "スケジュール済み通知"
            case .actions:   return "アクション"
            }
        }
    }

    private struct StatusRow { let label: String; let value: String; let ok: Bool }
    private struct PendingRow { let id: String; let title: String; let body: String; let fireDate: String }

    private var statusRows:  [StatusRow]  = []
    private var pendingRows: [PendingRow] = []

    private let actionTitles = [
        "5秒後にテスト通知を送信",
        "スケジュール済み通知を全キャンセル",
        "データを再読み込み",
    ]

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "🔔 通知デバッグ"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .refresh, target: self, action: #selector(reload))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.register(SubtitleCell.self, forCellReuseIdentifier: "subtitle")
        reload()
    }

    // MARK: - データ収集

    @objc private func reload() {
        collectStatus { [weak self] in
            self?.collectPending {
                self?.tableView.reloadData()
            }
        }
    }

    private func collectStatus(completion: @escaping () -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let self else { return }
            let authLabel: String
            let authOK: Bool
            switch settings.authorizationStatus {
            case .authorized:   authLabel = "✅ 許可済み"; authOK = true
            case .provisional:  authLabel = "⚠️ Provisional"; authOK = true
            case .ephemeral:    authLabel = "⚠️ Ephemeral"; authOK = true
            case .denied:       authLabel = "❌ 拒否"; authOK = false
            case .notDetermined:authLabel = "⏳ 未決定"; authOK = false
            @unknown default:   authLabel = "不明"; authOK = false
            }

            let hrs = MoodleService.shared.globalNotifHours
            let hrsLabel = hrs.isEmpty
                ? "未設定（通知OFF）"
                : hrs.map { MoodleService.shared.hourLabel($0) }.joined(separator: ", ")

            DispatchQueue.main.async {
                self.statusRows = [
                    StatusRow(label: "権限ステータス",    value: authLabel,  ok: authOK),
                    StatusRow(label: "アラート",          value: settings.alertSetting == .enabled ? "✅ ON" : "❌ OFF", ok: settings.alertSetting == .enabled),
                    StatusRow(label: "サウンド",          value: settings.soundSetting == .enabled ? "✅ ON" : "❌ OFF", ok: settings.soundSetting == .enabled),
                    StatusRow(label: "設定中のタイミング", value: hrsLabel,   ok: !hrs.isEmpty),
                ]
                completion()
            }
        }
    }

    private func collectPending(completion: @escaping () -> Void) {
        UNUserNotificationCenter.current().getPendingNotificationRequests { [weak self] requests in
            guard let self else { return }
            let df = DateFormatter()
            df.locale = Locale(identifier: "ja_JP")
            df.dateFormat = "M/d(E) HH:mm"

            let rows: [PendingRow] = requests
                .filter { $0.identifier.hasPrefix("gn.") }
                .sorted {
                    let d0 = ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantFuture
                    let d1 = ($1.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantFuture
                    return d0 < d1
                }
                .map { req in
                    let fireDate: String
                    if let cal = req.trigger as? UNCalendarNotificationTrigger,
                       let date = cal.nextTriggerDate() {
                        fireDate = df.string(from: date)
                    } else {
                        fireDate = "不明"
                    }
                    return PendingRow(
                        id:       req.identifier,
                        title:    req.content.title,
                        body:     req.content.body,
                        fireDate: fireDate
                    )
                }

            DispatchQueue.main.async {
                self.pendingRows = rows
                completion()
            }
        }
    }

    // MARK: - TableView

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .status:    return statusRows.count
        case .scheduled: return max(pendingRows.count, 1)
        case .actions:   return actionTitles.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let s = Section(rawValue: section)!
        if s == .scheduled { return "\(s.title)（\(pendingRows.count)件）" }
        return s.title
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {

        case .status:
            let row = statusRows[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
            var cfg = UIListContentConfiguration.valueCell()
            cfg.text             = row.label
            cfg.secondaryText    = row.value
            cfg.secondaryTextProperties.color = row.ok ? .systemGreen : .systemRed
            cell.contentConfiguration = cfg
            cell.selectionStyle = .none
            return cell

        case .scheduled:
            if pendingRows.isEmpty {
                let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
                var cfg = UIListContentConfiguration.cell()
                cfg.text = "スケジュール済み通知なし"
                cfg.textProperties.color = .secondaryLabel
                cell.contentConfiguration = cfg
                cell.selectionStyle = .none
                return cell
            }
            let row  = pendingRows[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: "subtitle", for: indexPath) as! SubtitleCell
            cell.configure(title: "[\(row.fireDate)]  \(row.title)", subtitle: row.body)
            cell.selectionStyle = .none
            return cell

        case .actions:
            let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
            var cfg = UIListContentConfiguration.cell()
            cfg.text = actionTitles[indexPath.row]
            let isDestruct = indexPath.row == 1
            cfg.textProperties.color = isDestruct ? .systemRed : .systemBlue
            cell.contentConfiguration = cfg
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .actions else { return }
        switch indexPath.row {
        case 0: sendTestNotification()
        case 1: cancelAll()
        case 2: reload()
        default: break
        }
    }

    // MARK: - アクション

    private func sendTestNotification() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else {
                DispatchQueue.main.async {
                    self.showAlert("権限がありません", "設定アプリから通知を許可してください。")
                }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "【テスト】締め切りが近づいています"
            content.body  = "線形代数学 期限:明日 12:00 (1日前) ← これはテスト通知です"
            content.sound = .default
            if #available(iOS 15.0, *) { content.interruptionLevel = .timeSensitive }

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            let request = UNNotificationRequest(identifier: "notif.debug.test.\(Date().timeIntervalSince1970)",
                                                content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request) { error in
                DispatchQueue.main.async {
                    if let error {
                        self.showAlert("送信失敗", error.localizedDescription)
                    } else {
                        self.showAlert("送信完了 ✅", "5秒後に通知が届きます。\nアプリをバックグラウンドにしてください。")
                    }
                }
            }
        }
    }

    private func cancelAll() {
        let alert = UIAlertController(title: "全通知をキャンセル", message: "スケジュール済みの通知を全件削除しますか？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "削除", style: .destructive) { [weak self] _ in
            MoodleService.shared.cancelAllGlobalNotifications()
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            self?.reload()
        })
        present(alert, animated: true)
    }

    private func showAlert(_ title: String, _ message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in self?.reload() })
        present(a, animated: true)
    }
}

// MARK: - SubtitleCell（2行表示用）

private final class SubtitleCell: UITableViewCell {
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, subtitle: String) {
        textLabel?.text          = title
        textLabel?.font          = .systemFont(ofSize: 13, weight: .medium)
        textLabel?.numberOfLines = 0
        detailTextLabel?.text    = subtitle
        detailTextLabel?.font    = .systemFont(ofSize: 12)
        detailTextLabel?.numberOfLines = 0
        detailTextLabel?.textColor = .secondaryLabel
    }
}
#endif
