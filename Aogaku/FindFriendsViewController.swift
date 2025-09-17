import UIKit
import FirebaseAuth
import FirebaseFirestore
import GoogleMobileAds

@inline(__always)
private func makeAdaptiveAdSize(width: CGFloat) -> AdSize {
    // プロジェクトにあるヘルパと同名ならそちらでもOK
    return currentOrientationAnchoredAdaptiveBanner(width: width)
}

final class FindFriendsViewController: UITableViewController, UISearchBarDelegate, BannerViewDelegate {

    private var outgoingListener: ListenerRegistration?
    
    // 一覧データ
    private var allUsers: [UserPublic] = []   // 初期表示用（自分以外）
    private var results: [UserPublic] = []    // 現在表示（検索結果 or allUsers）

    // ボタン状態用
    private var outgoing = Set<String>()      // 申請済みUID
    private var friends  = Set<String>()      // 既に友だちUID

    private let searchBar = UISearchBar()
    private let db = Firestore.firestore()
    
    // MARK: - AdMob (Banner) [ADDED]
    private let adContainer = UIView()
    private var bannerView: BannerView?
    private var adContainerHeight: NSLayoutConstraint?
    private var lastBannerWidth: CGFloat = 0
    private var didLoadBannerOnce = false

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
        setupAdBanner()        // [ADDED]
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        loadBannerIfNeeded()   // [ADDED]
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

    // [ADDED] 初回のみロード、回転時はサイズだけ更新
    private func loadBannerIfNeeded() {
        guard let bv = bannerView else { return }
        let safeWidth = view.safeAreaLayoutGuide.layoutFrame.width
        if safeWidth <= 0 { return }

        let useWidth = max(320, floor(safeWidth))
        if abs(useWidth - lastBannerWidth) < 0.5 { return } // 無駄な再ロード防止
        lastBannerWidth = useWidth

        let size = makeAdaptiveAdSize(width: useWidth)

        // 先に高さを確保
        adContainerHeight?.constant = size.size.height
        updateInsetsForBanner(height: size.size.height)
        view.layoutIfNeeded()

        guard size.size.height > 0 else { return }

        if !CGSizeEqualToSize(bv.adSize.size, size.size) {
            bv.adSize = size
        }

        if !didLoadBannerOnce {
            didLoadBannerOnce = true
            bv.load(Request())
        }
    }
    // [ADDED] UITableView の下余白を広告高に合わせる
    private func updateInsetsForBanner(height: CGFloat) {
        var inset = tableView.contentInset
        inset.bottom = height
        tableView.contentInset = inset
        tableView.verticalScrollIndicatorInsets.bottom = height
    }
    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
            let h = bannerView.adSize.size.height
            adContainerHeight?.constant = h
            updateInsetsForBanner(height: h)
            UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
        }

        func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
            adContainerHeight?.constant = 0
            updateInsetsForBanner(height: 0)
            UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
            print("Ad failed:", error.localizedDescription)
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
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startOutgoingListener()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        outgoingListener?.remove()
        outgoingListener = nil
    }

    private func startOutgoingListener() {
        guard let me = Auth.auth().currentUser?.uid else { return }
        outgoingListener?.remove()
        outgoingListener = db.collection("users").document(me)
            .collection("requestsOutgoing")
            .addSnapshotListener { [weak self] snap, _ in
                guard let self = self else { return }
                self.outgoing = Set(snap?.documents.map { $0.documentID } ?? [])
                self.tableView.reloadData() // ここで「申請済」⇄「追加」が即時反映
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
