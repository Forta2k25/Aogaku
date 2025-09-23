
import UIKit
import FirebaseAuth
import FirebaseFirestore
import GoogleMobileAds

@inline(__always)
private func makeAdaptiveAdSize(width: CGFloat) -> AdSize {
    return currentOrientationAnchoredAdaptiveBanner(width: width)
}

// 学科 → 略称（画像どおり）
private enum DepartmentAbbr {
    static let map: [String: String] = [
        // 文学部
        "日本文学科":"日文","英米文学科":"英米","比較芸術学科":"比芸","フランス文学科":"仏文","史学科":"文史",
        // 教育人間科学部
        "教育学科":"教育","心理学科":"心理",
        // 経済学部
        "経済学科":"経済","現代経済デザイン学科":"現デ",
        // 法学部
        "法学科":"法法","ヒューマンライツ学科":"法ヒュ",
        // 経営学部
        "経営学科":"経営","マーケティング学科":"経マ",
        // 総合文化政策学部
        "総合文化政策学科":"総文",
        // SIPEC（国際政治経済学部）
        "国際コミュニケーション学科":"コミュ","国際政治学科":"国政","国際経済学科":"国経",
        // 理工学部
        "物理科学科":"物理","数理サイエンス学科":"数理","化学・生命科学科":"生命",
        "電気電子工学科":"電工","機械創造工学科":"機械","経営システム工学科":"経シス","情報テクノロジー学科":"情テク",
        // 地球社会共生・コミュニティ・社情
        "地球社会共生学科":"地球","コミュニティ人間科学科":"コミュ","社会情報学科":"社情",
    ]
    static func abbr(for department: String?) -> String? {
        guard let d = department, !d.isEmpty else { return nil }
        return map[d] ?? d   // 見つからなければ原文表示（暫定）
    }
}

// セルで出す追加情報
private struct ProfileInfo {
    let deptAbbr: String?
    let grade: Int?
    var text: String? {
        var parts: [String] = []
        if let a = deptAbbr, !a.isEmpty { parts.append(a) }
        if let g = grade, g >= 1 { parts.append("\(g)年") }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }
}

final class FindFriendsViewController: UITableViewController, UISearchBarDelegate, BannerViewDelegate {

    private var outgoingListener: ListenerRegistration?
    private var allUsers: [UserPublic] = []
    private var results: [UserPublic] = []

    private var outgoing = Set<String>()
    private var friends  = Set<String>()

    // 追加：uid→学科略称・学年
    private var profileInfo = [String: ProfileInfo]()

    private let searchBar = UISearchBar()
    private let db = Firestore.firestore()

    // AdMob
    private let adContainer = UIView()
    private var bannerView: BannerView?
    private var adContainerHeight: NSLayoutConstraint?
    private var lastBannerWidth: CGFloat = 0
    private var didLoadBannerOnce = false

    private func appBackgroundColor(for traits: UITraitCollection) -> UIColor {
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.2, alpha: 1.0) : .systemBackground
    }
    private func applyBackgroundStyle() {
        let bg = appBackgroundColor(for: traitCollection)
        view.backgroundColor = bg
        tableView.backgroundColor = bg
        adContainer.backgroundColor = bg
        tableView.separatorColor = .separator
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "友だちを探す"
        tableView.register(UserListCell.self, forCellReuseIdentifier: UserListCell.reuseID)
        tableView.rowHeight = 68

        searchBar.placeholder = "ユーザー名、IDから検索（@id 可）"
        searchBar.delegate = self
        navigationItem.titleView = searchBar

        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(reloadAll), for: .valueChanged)

        reloadAll()
        setupAdBanner()
        applyBackgroundStyle()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyBackgroundStyle()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        loadBannerIfNeeded()
    }

    // 初期ロード
    @objc private func reloadAll() {
        guard let me = Auth.auth().currentUser?.uid else { return }
        let group = DispatchGroup()

        // users 取得（自分以外）
        group.enter()
        db.collection("users")
            .order(by: "createdAt", descending: true)
            .limit(to: 50)
            .getDocuments { [weak self] snap, _ in
                guard let self = self else { return }
                var newUsers: [UserPublic] = []
                var newInfo: [String: ProfileInfo] = [:]

                snap?.documents.forEach { doc in
                    if doc.documentID == me { return }
                    let d = doc.data()
                    let idStr = (d["id"] as? String) ?? ""
                    guard !idStr.isEmpty else { return }
                    let name = (d["name"] as? String) ?? ""
                    let display = name.isEmpty ? "@\(idStr)" : name

                    // 基本表示用
                    let u = UserPublic(uid: doc.documentID,
                                       idString: idStr,
                                       name: display,
                                       photoURL: d["photoURL"] as? String)
                    newUsers.append(u)

                    // 追加情報
                    let grade = d["grade"] as? Int
                    let dept  = d["department"] as? String
                    newInfo[u.uid] = ProfileInfo(deptAbbr: DepartmentAbbr.abbr(for: dept), grade: grade)
                }

                self.allUsers = newUsers
                self.profileInfo.merge(newInfo, uniquingKeysWith: { _, new in new })
                group.leave()
            }

        // 自分の申請済み
        group.enter()
        db.collection("users").document(me).collection("requestsOutgoing").getDocuments { [weak self] snap, _ in
            self?.outgoing = Set(snap?.documents.map { $0.documentID } ?? [])
            group.leave()
        }

        // 自分の友だち
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

    // 検索
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        let keyword = searchBar.text ?? ""
        FriendService.shared.searchUsers(keyword: keyword) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let users):
                self.results = users
                self.tableView.reloadData()
                self.enrichProfiles(for: users) // 追加情報を補完
            case .failure:
                self.results = []
                self.tableView.reloadData()
            }
        }
        view.endEditing(true)
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results = allUsers
            tableView.reloadData()
        }
    }

    // 検索結果の追加情報を取得（10件ずつ）
    private func enrichProfiles(for users: [UserPublic]) {
        let missing = users.map { $0.uid }.filter { profileInfo[$0] == nil }
        guard !missing.isEmpty else { return }
        let chunks = stride(from: 0, to: missing.count, by: 10).map { Array(missing[$0 ..< min($0+10, missing.count)]) }
        for ids in chunks {
            db.collection("users").whereField(FieldPath.documentID(), in: ids).getDocuments { [weak self] snap, _ in
                guard let self = self else { return }
                var updatedUIDs: [String] = []
                snap?.documents.forEach { doc in
                    let d = doc.data()
                    let grade = d["grade"] as? Int
                    let dept  = d["department"] as? String
                    self.profileInfo[doc.documentID] = ProfileInfo(deptAbbr: DepartmentAbbr.abbr(for: dept), grade: grade)
                    updatedUIDs.append(doc.documentID)
                }
                // 対象行だけ更新
                let rows = self.results.enumerated()
                    .filter { updatedUIDs.contains($0.element.uid) }
                    .map { IndexPath(row: $0.offset, section: 0) }
                if !rows.isEmpty {
                    self.tableView.reloadRows(at: rows, with: .none)
                }
            }
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
                self.tableView.reloadData()
            }
    }

    // TableView
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        results.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let u = results[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: UserListCell.reuseID, for: indexPath) as! UserListCell

        let placeholder = UIImage(systemName: "person.crop.circle.fill")
        let isFriend = friends.contains(u.uid)
        let isOutgoing = outgoing.contains(u.uid)

        let extra = profileInfo[u.uid]?.text
        cell.configure(user: u, isFriend: isFriend, isOutgoing: isOutgoing, placeholder: placeholder, extraText: extra)

        // ボタン動作（未申請 & 未フレンドのときのみ）
        if !isFriend && !isOutgoing {
            cell.actionButton.removeTarget(nil, action: nil, for: .allEvents)
            cell.actionButton.addAction(UIAction { [weak self] _ in
                guard let self = self else { return }
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

    // --- AdMob ---
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
        bv.adUnitID = "ca-app-pub-3940256099942544/2934735716"
        bv.rootViewController = self
        bv.adSize = AdSizeBanner
        bv.delegate = self
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
        if abs(useWidth - lastBannerWidth) < 0.5 { return }
        lastBannerWidth = useWidth
        let size = makeAdaptiveAdSize(width: useWidth)
        adContainerHeight?.constant = size.size.height
        updateInsetsForBanner(height: size.size.height)
        view.layoutIfNeeded()
        guard size.size.height > 0 else { return }
        if !CGSizeEqualToSize(bv.adSize.size, size.size) { bv.adSize = size }
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
}



/*
既存ファイル
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

    
    // ★ 追加
    private func appBackgroundColor(for traits: UITraitCollection) -> UIColor {
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.2, alpha: 1.0) : .systemBackground
    }
    private func applyBackgroundStyle() {
        let bg = appBackgroundColor(for: traitCollection)
        view.backgroundColor = bg
        tableView.backgroundColor = bg
        adContainer.backgroundColor = bg
        tableView.separatorColor = .separator
    }
    
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
        applyBackgroundStyle()
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyBackgroundStyle()
        }
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
*/
