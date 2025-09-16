import UIKit
import FirebaseAuth
import FirebaseFirestore

final class FriendRequestsViewController: UITableViewController {
    private var items: [FriendRequest] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "友だち申請"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        reload()
    }

    private func reload() {
        FriendService.shared.fetchIncomingRequests { [weak self] result in
            if case .success(let list) = result { self?.items = list; self?.tableView.reloadData() }
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let r = items[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var cfg = cell.defaultContentConfiguration()
        cfg.text = r.fromName
        cfg.secondaryText = "@\(r.fromId)"
        cell.contentConfiguration = cfg

        let approve = UIButton(type: .system)
        approve.setTitle("承認", for: .normal)
        approve.addAction(UIAction { [weak self] _ in
            let user = UserPublic(uid: r.fromUid, idString: r.fromId, name: r.fromName, photoURL: nil)
            FriendService.shared.acceptRequest(from: user) { _ in self?.reload() }
        }, for: .touchUpInside)

        let deny = UIButton(type: .system)
        deny.setTitle("削除", for: .normal)
        deny.addAction(UIAction { [weak self] _ in
            guard let me = Auth.auth().currentUser?.uid else { return }
            Firestore.firestore().collection("users").document(me)
                .collection("requestsIncoming").document(r.fromUid).delete { _ in
                    self?.reload()
                }
        }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [approve, deny])
        stack.axis = .horizontal
        stack.spacing = 12
        cell.accessoryView = stack
        return cell
    }
}


