import Foundation
import UIKit

// MARK: - AssignmentNotifSettingsViewController

final class AssignmentNotifSettingsViewController: UITableViewController {

    private let options: [(label: String, hours: Int)] = [
        ("1時間前", 1), ("3時間前", 3), ("6時間前", 6),
        ("12時間前", 12), ("1日前", 24), ("3日前", 72), ("1週間前", 168)
    ]

    private var selectedHours: Set<Int>
    var onSave: (([Int]) -> Void)?

    init() {
        selectedHours = Set(MoodleService.shared.globalNotifHours)
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "全課題の通知設定"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(closeTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "適用", style: .done, target: self, action: #selector(saveTapped))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection s: Int) -> Int { options.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection s: Int) -> String? {
        "通知タイミング（複数選択可）"
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection s: Int) -> String? {
        "選択したタイミングで期限前の全課題に自動通知します。\n何も選ばないと通知なし。"
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let opt = options[indexPath.row]
        var cfg = UIListContentConfiguration.cell()
        cfg.text = opt.label
        cell.contentConfiguration = cfg
        cell.accessoryType = selectedHours.contains(opt.hours) ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let h = options[indexPath.row].hours
        if selectedHours.contains(h) { selectedHours.remove(h) } else { selectedHours.insert(h) }
        tableView.reloadRows(at: [indexPath], with: .none)
    }

    @objc private func closeTapped() { dismiss(animated: true) }

    @objc private func saveTapped() {
        let sorted = selectedHours.sorted()
        MoodleService.shared.globalNotifHours = sorted
        dismiss(animated: true) { [weak self] in self?.onSave?(sorted) }
    }
}

extension Notification.Name {
    /// 初回アイコン設定を促すための通知
    static let shouldPromptInitialAvatar = Notification.Name("ShouldPromptInitialAvatarV1")
    /// Moodle 課題の提出済み状態が変化した（object: uid: String）
    static let moodleSubmittedStateChanged = Notification.Name("MoodleSubmittedStateChanged")
    /// Google新規登録後にIDセットアップ画面を出すよう通知
    static let googleSignInNeedsIDSetup = Notification.Name("GoogleSignInNeedsIDSetup")
}
