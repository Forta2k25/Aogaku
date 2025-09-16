import UIKit

final class FindFriendsViewController: UITableViewController, UISearchBarDelegate {
    private var results: [UserPublic] = []
    private let searchBar = UISearchBar()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "友だちを探す"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")

        searchBar.placeholder = "ユーザー名、IDから検索（@id 可）"
        searchBar.delegate = self
        navigationItem.titleView = searchBar
        searchBar.becomeFirstResponder()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        FriendService.shared.searchUsers(keyword: searchBar.text ?? "") { [weak self] result in
            if case .success(let users) = result { self?.results = users; self?.tableView.reloadData() }
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { results.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let u = results[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var cfg = cell.defaultContentConfiguration()
        cfg.text = u.name
        cfg.secondaryText = "@\(u.idString)"
        cell.contentConfiguration = cfg

        let button = UIButton(type: .system)
        button.setTitle("追加", for: .normal)
        button.addAction(UIAction { [weak self] _ in
            FriendService.shared.sendRequest(to: u) { _ in
                button.setTitle("申請済", for: .normal); button.isEnabled = false
                self?.view.endEditing(true)
            }
        }, for: .touchUpInside)
        cell.accessoryView = button
        return cell
    }
}
