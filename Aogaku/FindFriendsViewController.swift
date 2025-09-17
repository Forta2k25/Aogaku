import UIKit
import FirebaseAuth
import FirebaseFirestore

final class FindFriendsViewController: UITableViewController, UISearchBarDelegate {

    // 一覧データ
    private var allUsers: [UserPublic] = []   // 初期表示用（自分以外）
    private var results: [UserPublic] = []    // 現在表示（検索結果 or allUsers）

    // ボタン状態用
    private var outgoing = Set<String>()      // 申請済みUID
    private var friends  = Set<String>()      // 既に友だちUID

    private let searchBar = UISearchBar()
    private let db = Firestore.firestore()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "友だちを探す"
        tableView.register(UserListCell.self, forCellReuseIdentifier: UserListCell.reuseID)
        tableView.rowHeight = 68

        // 検索バー（タイトルビュー）
        searchBar.placeholder = "ユーザー名、IDから検索（@id 可）"
        searchBar.delegate = self
        navigationItem.titleView = searchBar

        // 引っ張って更新
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(reloadAll), for: .valueChanged)

        reloadAll()
    }

    // MARK: - 初期ロード & 更新
    @objc private func reloadAll() {
        guard let me = Auth.auth().currentUser?.uid else { return }
        let group = DispatchGroup()

        // 1) users を取得（自分以外、createdAt順）
        group.enter()
        db.collection("users")
          .order(by: "createdAt", descending: true) // 任意。無ければ削ってOK
          .limit(to: 50)
          .getDocuments { [weak self] snap, _ in
            guard let self = self else { return }
            let users = snap?.documents.compactMap { doc -> UserPublic? in
                if doc.documentID == me { return nil }
                let d = doc.data()
                let idStr = (d["id"] as? String) ?? ""        // ← id は必須
                guard !idStr.isEmpty else { return nil }
                let name  = (d["name"] as? String) ?? ""      // ← name が無ければ id を表示名に
                let display = name.isEmpty ? "@\(idStr)" : name
                return UserPublic(uid: doc.documentID,
                                  idString: idStr,
                                  name: display,
                                  photoURL: d["photoURL"] as? String)
            } ?? []
            self.allUsers = users
            group.leave()
        }

        // 2) 自分の申請済み
        group.enter()
        db.collection("users").document(me).collection("requestsOutgoing").getDocuments { [weak self] snap, _ in
            self?.outgoing = Set(snap?.documents.map { $0.documentID } ?? [])
            group.leave()
        }

        // 3) 自分の友だち
        group.enter()
        db.collection("users").document(me).collection("friends").getDocuments { [weak self] snap, _ in
            self?.friends = Set(snap?.documents.map { $0.documentID } ?? [])
            group.leave()
        }

        group.notify(queue: .main) {
            self.results = self.allUsers
            self.tableView.reloadData()
            self.refreshControl?.endRefreshing()
        }
    }

    // MARK: - 検索
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        let keyword = searchBar.text ?? ""
        FriendService.shared.searchUsers(keyword: keyword) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let users):
                self.results = users
                self.tableView.reloadData()
            case .failure:
                self.results = []
                self.tableView.reloadData()
            }
        }
        view.endEditing(true)
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        // 空文字に戻ったら初期一覧に戻す
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results = allUsers
            tableView.reloadData()
        }
    }

    // MARK: - TableView
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        results.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let u = results[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: UserListCell.reuseID, for: indexPath) as! UserListCell

        let placeholder = UIImage(systemName: "person.crop.circle.fill")
        let isFriend = friends.contains(u.uid)
        let isOutgoing = outgoing.contains(u.uid)
        cell.configure(user: u, isFriend: isFriend, isOutgoing: isOutgoing, placeholder: placeholder)

        // ボタン動作（未申請 & 未フレンドのときのみ上書き）
        if !isFriend && !isOutgoing {
            cell.actionButton.removeTarget(nil, action: nil, for: .allEvents)
            cell.actionButton.addAction(UIAction { [weak self] _ in
                guard let self = self else { return }
                // 確認アラート
                let alert = UIAlertController(
                    title: "友だち申請",
                    message: "\(u.name) に友だち申請を送りますか？",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
                alert.addAction(UIAlertAction(title: "送信する", style: .default, handler: { _ in
                    FriendService.shared.sendRequest(to: u) { [weak self] _ in
                        guard let self = self else { return }
                        self.outgoing.insert(u.uid)
                        // 対象行だけ更新
                        if let r = self.results.firstIndex(where: { $0.uid == u.uid }) {
                            self.tableView.reloadRows(at: [IndexPath(row: r, section: 0)], with: .automatic)
                        }
                    }
                }))
                self.present(alert, animated: true)
            }, for: .touchUpInside)
        }

        return cell
    }
}
