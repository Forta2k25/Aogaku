import UIKit
import FirebaseFirestore   // ListenerRegistration

final class FriendListViewController: UITableViewController, UISearchBarDelegate {
    private var friends: [Friend] = []
    private var badgeListener: ListenerRegistration?
    private let bellButton = BadgeButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "友だち"
                tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")

                // 右上ベル
                bellButton.addTarget(self, action: #selector(openRequests), for: .touchUpInside)
                navigationItem.rightBarButtonItem = UIBarButtonItem(customView: bellButton)

                // 🔎 一覧の“ダミー検索バー”（タップ→検索画面へ）
                let sb = UISearchBar(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 44))
                sb.placeholder = "ユーザー名、IDから検索"
                sb.delegate = self
                tableView.tableHeaderView = sb

                // 下部ボタン（既存）
                let button = UIButton(type: .system)
                button.setTitle("友だちを探す", for: .normal)
                button.addTarget(self, action: #selector(openFind), for: .touchUpInside)
                button.frame.size.height = 48
                tableView.tableFooterView = button

                reload()
                badgeListener = FriendService.shared.watchIncomingRequestCount { [weak self] count in
                    self?.bellButton.setBadgeVisible(count > 0)
                }
    }

    deinit { badgeListener?.remove() }

    private func reload() {
        FriendService.shared.fetchFriends { [weak self] result in
            if case .success(let list) = result { self?.friends = list; self?.tableView.reloadData() }
        }
    }

    @objc private func openFind() { navigationController?.pushViewController(FindFriendsViewController(), animated: true) }
    @objc private func openRequests() { navigationController?.pushViewController(FriendRequestsViewController(), animated: true) }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { friends.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let f = friends[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var cfg = cell.defaultContentConfiguration()
        cfg.text = f.friendName
        cfg.secondaryText = "@\(f.friendId)"
        cell.contentConfiguration = cfg
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        let act = UIContextualAction(style: .destructive, title: "削除") { [weak self] _,_,done in
            guard let uid = self?.friends[indexPath.row].friendUid else { done(false); return }
            FriendService.shared.removeFriend(uid) { _ in self?.reload(); done(true) }
        }
        return UISwipeActionsConfiguration(actions: [act])
    }
    
    func searchBarShouldBeginEditing(_ searchBar: UISearchBar) -> Bool {
            openFind()
            return false
        }
    
}
