import UIKit
import FirebaseAuth
import FirebaseFirestore   // ListenerRegistration

// MARK: - Avatar付きセル
final class FriendListCell: UITableViewCell {
    static let reuseID = "FriendListCell"

    private let avatarView = UIImageView()
    private let nameLabel = UILabel()
    private let idLabel = UILabel()


    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setupUI() }

    private func setupUI() {
        selectionStyle = .none
        accessoryType = .disclosureIndicator

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = 28
        avatarView.backgroundColor = .secondarySystemFill

        nameLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        idLabel.font   = .systemFont(ofSize: 13)
        idLabel.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [nameLabel, idLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(avatarView)
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 56),
            avatarView.heightAnchor.constraint(equalToConstant: 56),

            stack.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16)
        ])
    }

    func configure(name: String, id: String, photoURL: String?) {
        nameLabel.text = name
        idLabel.text = "@\(id)"
        let placeholder = UIImage(systemName: "person.crop.circle.fill")
        if let url = photoURL, !url.isEmpty {
            ImageLoader.shared.load(urlString: url, into: avatarView, placeholder: placeholder)
        } else {
            avatarView.image = placeholder
        }
    }
}

// MARK: - FriendList
final class FriendListViewController: UITableViewController, UISearchBarDelegate {

    private var allFriends: [Friend] = []        // 取得結果の全件
    private var friends: [Friend] = []           // 表示用（検索で絞り込み）
    private var badgeListener: ListenerRegistration?
    private var profileCache: [String: (name: String, id: String, photoURL: String?)] = [:]
    private let db = Firestore.firestore() // すでにあれば重複不要

    // 右上：通知バッジ＆追加ボタン
    private let bellButton = BadgeButton(type: .system)
    private lazy var addButtonItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "person.badge.plus"),
            style: .plain,
            target: self,
            action: #selector(openFind)
        )
        return item
    }()

    // 検索バー（友だちリストのローカルフィルタ）
    private let searchBar = UISearchBar(frame: .zero)

    private var loginAlertShown = false
    private var listenerIsActive = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "友だち"

        // テーブル外観
        tableView.register(FriendListCell.self, forCellReuseIdentifier: FriendListCell.reuseID)
        tableView.rowHeight = 80

        // 右上：ベル + 追加
        bellButton.addTarget(self, action: #selector(openRequests), for: .touchUpInside)
        let bellItem = UIBarButtonItem(customView: bellButton)
        navigationItem.rightBarButtonItems = [addButtonItem, bellItem]

        // 検索バー（ローカルフィルタ）
        searchBar.placeholder = "ユーザー名、IDから検索"
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.delegate = self
        searchBar.showsCancelButton = true
        let header = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 52))
        searchBar.frame = CGRect(x: 0, y: 4, width: header.bounds.width, height: 44)
        header.addSubview(searchBar)
        tableView.tableHeaderView = header

        // 下部「友だちを探す」緑ボタン
        tableView.tableFooterView = makeFindFriendsFooter()

        // friendsDidChange 通知を受けて一覧更新
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleFriendsDidChange),
                                               name: .friendsDidChange,
                                               object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard ensureLoggedInOrRedirect() else { return }
        startListenersIfNeeded()
        reload()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        badgeListener?.remove()
        badgeListener = nil
        listenerIsActive = false
    }

    deinit { badgeListener?.remove() }

    @objc private func handleFriendsDidChange() { reload() }

    // MARK: - Login Gate
    @discardableResult
    private func ensureLoggedInOrRedirect() -> Bool {
        if Auth.auth().currentUser != nil { return true }

        if loginAlertShown { return false }
        loginAlertShown = true

        friends.removeAll()
        allFriends.removeAll()
        tableView.reloadData()
        bellButton.setBadgeVisible(false)

        let ac = UIAlertController(
            title: "ログインが必要です",
            message: "フレンド機能はログイン状態でのみ使用可能です。",
            preferredStyle: .alert
        )
        ac.addAction(UIAlertAction(title: "閉じる", style: .cancel, handler: { _ in
            self.loginAlertShown = false
        }))
        ac.addAction(UIAlertAction(title: "設定へ", style: .default, handler: { _ in
            self.loginAlertShown = false
            self.tabBarController?.selectedIndex = 2
        }))
        present(ac, animated: true)
        return false
    }

    private func startListenersIfNeeded() {
        guard !listenerIsActive, Auth.auth().currentUser != nil else { return }
        badgeListener = FriendService.shared.watchIncomingRequestCount { [weak self] count in
            self?.bellButton.setBadgeVisible(count > 0)
        }
        listenerIsActive = true
    }

    // MARK: - Data
    private func reload() {
        guard ensureLoggedInOrRedirect() else { return }
        FriendService.shared.fetchFriends { [weak self] result in
            guard let self = self else { return }
            if case .success(let list) = result {
                self.allFriends = list
                self.applyFilter(text: self.searchBar.text)
            }
        }
    }

    // MARK: - UI Builders
    private func makeFindFriendsFooter() -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 100))
        let button = UIButton(type: .system)
        button.setTitle("友だちを探す", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .bold)
        button.tintColor = .white
        button.backgroundColor = UIColor.systemGreen
        button.layer.cornerRadius = 14
        button.contentEdgeInsets = UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        button.addTarget(self, action: #selector(openFind), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            button.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            button.heightAnchor.constraint(equalToConstant: 56)
        ])
        return container
    }

    // MARK: - Navigation
    @objc private func openFind() {
        guard ensureLoggedInOrRedirect() else { return }
        navigationController?.pushViewController(FindFriendsViewController(), animated: true)
    }

    @objc private func openRequests() {
        guard ensureLoggedInOrRedirect() else { return }
        navigationController?.pushViewController(FriendRequestsViewController(), animated: true)
    }

    // MARK: - Search (friends ローカルフィルタ)
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        applyFilter(text: searchText)
    }
    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchBar.text = nil
        applyFilter(text: nil)
        view.endEditing(true)
    }
    private func applyFilter(text: String?) {
        let q = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            friends = allFriends
        } else {
            friends = allFriends.filter { f in
                f.friendName.lowercased().contains(q) || f.friendId.lowercased().contains(q)
            }
        }
        tableView.reloadData()
    }

    // MARK: - TableView
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { friends.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let f = friends[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: FriendListCell.reuseID, for: indexPath) as! FriendListCell

        // まずは friends ドキュメントにある情報で描画（photoURL は通常 nil）
        cell.configure(name: f.friendName, id: f.friendId, photoURL: nil)

        // キャッシュにあれば即反映
        if let p = profileCache[f.friendUid] {
            cell.configure(name: p.name.isEmpty ? f.friendName : p.name,
                           id: p.id.isEmpty ? f.friendId : p.id,
                           photoURL: p.photoURL)
            return cell
        }

        // 無ければ users/{uid} を一度だけ取得 → 可視セルだけを更新
        db.collection("users").document(f.friendUid).getDocument { [weak self, weak tableView] snap, _ in
            guard let self = self, let tableView = tableView else { return }
            let data = snap?.data()
            let name = (data?["name"] as? String) ?? f.friendName
            let id   = (data?["id"] as? String) ?? f.friendId
            let url  = data?["photoURL"] as? String
            self.profileCache[f.friendUid] = (name, id, url)

            // まだ表示中の同じ行ならだけ更新
            if let visible = tableView.cellForRow(at: indexPath) as? FriendListCell {
                visible.configure(name: name, id: id, photoURL: url)
            }
        }

        return cell
    }


    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        let act = UIContextualAction(style: .destructive, title: "削除") { [weak self] _,_,done in
            guard let self = self else { done(false); return }
            guard self.ensureLoggedInOrRedirect() else { done(false); return }
            let uid = self.friends[indexPath.row].friendUid
            FriendService.shared.removeFriend(uid) { _ in
                self.reload(); done(true)
            }
        }
        return UISwipeActionsConfiguration(actions: [act])
    }
}
