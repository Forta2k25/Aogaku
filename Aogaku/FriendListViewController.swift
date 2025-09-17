import UIKit
import FirebaseAuth
import FirebaseFirestore
import GoogleMobileAds

@inline(__always)
private func makeAdaptiveAdSize(width: CGFloat) -> AdSize {
    return currentOrientationAnchoredAdaptiveBanner(width: width)
}

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

        let vStack = UIStackView(arrangedSubviews: [nameLabel, idLabel])
        vStack.axis = .vertical
        vStack.spacing = 2
        vStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(avatarView)
        contentView.addSubview(vStack)

        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 56),
            avatarView.heightAnchor.constraint(equalToConstant: 56),

            vStack.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
            vStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            vStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16)
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
final class FriendListViewController: UITableViewController, UISearchBarDelegate, BannerViewDelegate{

    private let db = Firestore.firestore()

    private var allFriends: [Friend] = []
    private var friends: [Friend] = []
    private var profileCache: [String: (name: String, id: String, photoURL: String?)] = [:]

    private var badgeListener: ListenerRegistration?
    private var listenerIsActive = false

    private let bellButton = BadgeButton(type: .system)
    
    // ===== AdMob: ここを追加 =====
    private let adContainer = UIView()                           // [ADD]
    private var bannerView: BannerView?                          // [ADD]
    private var adContainerHeight: NSLayoutConstraint?           // [ADD]
    private var lastBannerWidth: CGFloat = 0                     // [ADD]
    private var didLoadBannerOnce = false                        // [ADD]


    // 左：QR + 追加
    private lazy var qrItem: UIBarButtonItem = {
        UIBarButtonItem(image: UIImage(systemName: "qrcode.viewfinder"),
                        style: .plain,
                        target: self,
                        action: #selector(openQR))
    }()
    private lazy var addItem: UIBarButtonItem = {
        UIBarButtonItem(image: UIImage(systemName: "person.badge.plus"),
                        style: .plain,
                        target: self,
                        action: #selector(openFind))
    }()

    // 検索バー（既存フレンドのローカル検索）
    private let searchBar = UISearchBar(frame: .zero)

    // 未ログインガード
    private var loginAlertShown = false

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "友だち"
        tableView.register(FriendListCell.self, forCellReuseIdentifier: FriendListCell.reuseID)
        tableView.rowHeight = 80

        // 右：ベル
        bellButton.addTarget(self, action: #selector(openRequests), for: .touchUpInside)
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: bellButton)

        // 左：QR + 追加
        navigationItem.leftBarButtonItems = [qrItem, addItem]

        // 検索バー
        searchBar.placeholder = "ユーザー名、IDから検索"
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.delegate = self
        searchBar.showsCancelButton = true
        let header = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 52))
        searchBar.frame = CGRect(x: 0, y: 4, width: header.bounds.width, height: 44)
        header.addSubview(searchBar)
        tableView.tableHeaderView = header

        // 下部「友だちを探す」ボタン（暗めの緑）
        tableView.tableFooterView = makeFindFriendsFooter()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleFriendsDidChange),
                                               name: .friendsDidChange,
                                               object: nil)
        
        setupAdBanner()            // [ADDED]
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        loadBannerIfNeeded()       // [ADDED]
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

    // MARK: - Login Gate
    @discardableResult
    private func ensureLoggedInOrRedirect() -> Bool {
        guard Auth.auth().currentUser != nil else {
            if !loginAlertShown {
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
            }
            return false
        }
        return true
    }

    private func startListenersIfNeeded() {
        guard !listenerIsActive, Auth.auth().currentUser != nil else { return }
        badgeListener = FriendService.shared.watchIncomingRequestCount { [weak self] count in
            self?.bellButton.setBadgeVisible(count > 0)
        }
        listenerIsActive = true
    }
    
    //Admob
    // [ADDED]
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

        let bv = BannerView()
        bv.translatesAutoresizingMaskIntoConstraints = false
        bv.adUnitID = "ca-app-pub-3940256099942544/2934735716" // テストID [ADDED]
        bv.rootViewController = self
        bv.adSize = AdSizeBanner
        bv.delegate = self   // ← delegate に準拠させる（下の extension を追加）

        adContainer.addSubview(bv)
        NSLayoutConstraint.activate([
            bv.leadingAnchor.constraint(equalTo: adContainer.leadingAnchor),
            bv.trailingAnchor.constraint(equalTo: adContainer.trailingAnchor),
            bv.topAnchor.constraint(equalTo: adContainer.topAnchor),
            bv.bottomAnchor.constraint(equalTo: adContainer.bottomAnchor)
        ])

        bannerView = bv
    }

    
    private func loadBannerIfNeeded() {
        guard let bv = bannerView else { return }
        let safeWidth = view.safeAreaLayoutGuide.layoutFrame.width
        if safeWidth <= 0 { return }

        let useWidth = max(320, floor(safeWidth))
        if abs(useWidth - lastBannerWidth) < 0.5 { return } // 連続ロード抑止
        lastBannerWidth = useWidth

        // 1) 幅からサイズ算出
        let size = makeAdaptiveAdSize(width: useWidth)

        // 2) 先にコンテナの高さを確保（0 回避）
        adContainerHeight?.constant = size.size.height
        updateInsetsForBanner(height: size.size.height)  // テーブル下に余白
        view.layoutIfNeeded()

        // 3) 高さ 0 は不正 → ロードしない
        guard size.size.height > 0 else { return }

        // 4) サイズ反映（同一ならスキップ）
        if !CGSizeEqualToSize(bv.adSize.size, size.size) {
            bv.adSize = size
        }

        // 5) 初回だけロード
        if !didLoadBannerOnce {
            didLoadBannerOnce = true
            bv.load(Request())
        }
    }
    private func updateInsetsForBanner(height: CGFloat) {
        var inset = tableView.contentInset
        inset.bottom = height
        tableView.contentInset = inset
        tableView.verticalScrollIndicatorInsets.bottom = height
    }
    
    // MARK: - BannerViewDelegate                        // [ADD]
    func bannerViewDidReceiveAd(_ banner: BannerView) {
            // 表示済みなので特別なことは不要（必要ならフェードイン等）
    }
    func bannerView(_ banner: BannerView, didFailToReceiveAdWithError error: Error) {
            // 失敗時は高さを 0 に
        adContainerHeight?.constant = 0
    }


    // MARK: - Data
    private func reload() {
        guard ensureLoggedInOrRedirect() else { return }
        FriendService.shared.fetchFriends { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let list):
                self.allFriends = list
                self.applyFilter(text: self.searchBar.text)
            case .failure:
                self.allFriends = []
                self.applyFilter(text: self.searchBar.text)
            }
        }
    }

    // MARK: - Builders
    private func makeFindFriendsFooter() -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 100))
        let button = UIButton(type: .system)
        button.setTitle("友だちを探す", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .bold)
        button.tintColor = .white
        button.backgroundColor = UIColor(displayP3Red: 0.00, green: 0.60, blue: 0.27, alpha: 1.0)
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

    @objc private func openQR() {
        guard ensureLoggedInOrRedirect() else { return }
        let nav = UINavigationController(rootViewController: QRScannerViewController())
        if let scanner = nav.viewControllers.first as? QRScannerViewController {
            scanner.onFoundID = { [weak self] _ in self?.startListenersIfNeeded() }
        }
        present(nav, animated: true)
    }

    @objc private func handleFriendsDidChange() { reload() }

    // MARK: - Search（ローカル）
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        applyFilter(text: searchText)
    }
    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchBar.text = nil
        view.endEditing(true)
        applyFilter(text: nil)
    }
    private func applyFilter(text: String?) {
        let q = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        friends = q.isEmpty
            ? allFriends
            : allFriends.filter { f in
                f.friendName.lowercased().contains(q) || f.friendId.lowercased().contains(q)
            }
        tableView.reloadData()
    }

    // MARK: - TableView
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { friends.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let f = friends[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: FriendListCell.reuseID, for: indexPath) as! FriendListCell

        // まずは friends コレクションの内容で描画
        cell.configure(name: f.friendName, id: f.friendId, photoURL: nil)

        // キャッシュがあれば即反映
        if let p = profileCache[f.friendUid] {
            cell.configure(name: p.name.isEmpty ? f.friendName : p.name,
                           id: p.id.isEmpty ? f.friendId : p.id,
                           photoURL: p.photoURL)
            return cell
        }

        // users/{uid} を単発取得して可視セルだけ更新
        db.collection("users").document(f.friendUid).getDocument { [weak self, weak tableView] snap, _ in
            guard let self = self, let tableView = tableView else { return }
            let data = snap?.data()
            let name = (data?["name"] as? String) ?? f.friendName
            let id   = (data?["id"] as? String) ?? f.friendId
            let url  = data?["photoURL"] as? String
            self.profileCache[f.friendUid] = (name, id, url)

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

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let friend = friends[indexPath.row]
        let vc = FriendTimetableViewController(friendUid: friend.friendUid,
                                               friendName: friend.friendName)
        navigationController?.pushViewController(vc, animated: true)
    }
}

