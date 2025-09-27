import UIKit
import FirebaseAuth
import FirebaseFirestore
import GoogleMobileAds

// ===== AdMob helper =====
@inline(__always)
private func makeAdaptiveAdSize(width: CGFloat) -> AdSize {
    return currentOrientationAnchoredAdaptiveBanner(width: width)
}

// 学科 → 略称
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
        // SIPEC
        "国際コミュニケーション学科":"コミュ","国際政治学科":"国政","国際経済学科":"国経",
        // 理工学部
        "物理科学科":"物理","数理サイエンス学科":"数理","化学・生命科学科":"生命",
        "電気電子工学科":"電工","機械創造工学科":"機械","経営システム工学科":"経シス","情報テクノロジー学科":"情テク",
        // 地球社会共生 / 社情 / コミュニティ
        "地球社会共生学科":"地球","社会情報学科":"社情","コミュニティ人間科学科":"コミュ",
    ]
    static func abbr(_ department: String?) -> String? {
        guard let d = department, !d.isEmpty else { return nil }
        return map[d] ?? d // 無ければ原文
    }
}


// ===== 「開いた順」ローカル保存 =====
private final class FriendOpenOrderStore {
    static let shared = FriendOpenOrderStore()
    private let mapKey = "friend_open_order_map"          // [uid: seq]
    private let counterKey = "friend_open_order_counter"  // Int
    private let ud = UserDefaults.standard
    private var map: [String: Int]
    private var counter: Int
    private init() {
        map = ud.dictionary(forKey: mapKey) as? [String: Int] ?? [:]
        counter = ud.integer(forKey: counterKey)
    }
    func seq(for uid: String) -> Int? { map[uid] }
    func bump(uid: String) {
        counter &+= 1
        map[uid] = counter
        ud.set(map, forKey: mapKey)
        ud.set(counter, forKey: counterKey)
    }
}

// ===== ピン留めローカル保存 =====
private final class FriendPinStore {
    static let shared = FriendPinStore()
    private let key = "friend_pinned_set"
    private let ud = UserDefaults.standard
    private var set: Set<String>
    private init() {
        let arr = ud.array(forKey: key) as? [String] ?? []
        set = Set(arr)
    }
    func isPinned(_ uid: String) -> Bool { set.contains(uid) }
    func pin(_ uid: String) { set.insert(uid); save() }
    func unpin(_ uid: String) { set.remove(uid); save() }
    private func save() { ud.set(Array(set), forKey: key) }
}

// ===== アイコンキャッシュ（メモリ＋ディスク、バージョン差し替え） =====
private final class AvatarCache {
    static let shared = AvatarCache()
    private let mem = NSCache<NSString, UIImage>()
    private let fm = FileManager.default
    private let dir: URL
    private init() {
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        dir = base.appendingPathComponent("avatar-cache", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // ファイル名: uid_v{version}.jpg （version が nil の場合は 0）
    private func fileURL(uid: String, version: Int?) -> URL {
        let v = version ?? 0
        return dir.appendingPathComponent("\(uid)_v\(v).jpg")
    }

    func image(uid: String, version: Int?) -> UIImage? {
        let key = "\(uid)#\(version ?? 0)" as NSString
        if let img = mem.object(forKey: key) { return img }
        let url = fileURL(uid: uid, version: version)
        guard let data = try? Data(contentsOf: url),
              let img = UIImage(data: data) else { return nil }
        mem.setObject(img, forKey: key)
        return img
    }

    func store(_ image: UIImage, uid: String, version: Int?) {
        let key = "\(uid)#\(version ?? 0)" as NSString
        mem.setObject(image, forKey: key)
        let url = fileURL(uid: uid, version: version)
        if let data = image.jpegData(compressionQuality: 0.9) {
            // 原子的に書き込み
            let tmp = url.appendingPathExtension("tmp")
            try? data.write(to: tmp, options: .atomic)
            try? fm.removeItem(at: url)
            try? fm.moveItem(at: tmp, to: url)
        }
        purgeOldVersions(of: uid, keep: version ?? 0)
    }

    // その uid の古い版を削除
    private func purgeOldVersions(of uid: String, keep version: Int) {
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files {
            let name = f.lastPathComponent
            guard name.hasPrefix("\(uid)_v"),
                  name.hasSuffix(".jpg") else { continue }
            if !name.contains("_v\(version).jpg") {
                try? fm.removeItem(at: f)
            }
        }
    }

    // photoURL のクエリ（例: token=xxxx）から簡易バージョンを推定（なければ nil）
    func versionFrom(urlString: String?) -> Int? {
        guard let s = urlString,
              let u = URL(string: s) else { return nil }
        // クエリの token/alt/generation などからハッシュっぽい整数を作る
        if let q = u.query, !q.isEmpty {
            return abs(q.hashValue)
        }
        // 最終パス要素に見えるハッシュがあれば
        return abs(u.lastPathComponent.hashValue)
    }
}

// ===== ネットワーク画像取得（URLSession） =====
private enum ImageFetcher {
    static func fetch(urlString: String, completion: @escaping (UIImage?) -> Void) {
        guard let url = URL(string: urlString) else { completion(nil); return }
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let d = data, let img = UIImage(data: d) else { completion(nil); return }
            completion(img)
        }
        task.resume()
    }
}

// ===== Avatar付きセル（右下にピンバッジ） =====
final class FriendListCell: UITableViewCell {
    static let reuseID = "FriendListCell"

    private let avatarView = UIImageView()
    private let nameLabel = UILabel()
    private let idLabel = UILabel()
    private let pinBadge = UIImageView(image: UIImage(systemName: "pin.fill"))

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setupUI() }

    private func setupUI() {
        selectionStyle = .none
        accessoryType = .disclosureIndicator
        backgroundColor = .clear

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

        pinBadge.translatesAutoresizingMaskIntoConstraints = false
        pinBadge.tintColor = .systemYellow
        pinBadge.isHidden = true

        contentView.addSubview(avatarView)
        contentView.addSubview(vStack)
        contentView.addSubview(pinBadge)

        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 56),
            avatarView.heightAnchor.constraint(equalToConstant: 56),

            vStack.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
            vStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            vStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),

            // ピンはアバター右下
            pinBadge.widthAnchor.constraint(equalToConstant: 16),
            pinBadge.heightAnchor.constraint(equalToConstant: 16),
            pinBadge.trailingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 4),
            pinBadge.bottomAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 4)
        ])
    }

    func configure(name: String, id: String, image: UIImage?, pinned: Bool, extraText: String? = nil) {
        nameLabel.text = name
        var sub = "@\(id)"
        if let t = extraText, !t.isEmpty { sub += "    \(t)" } // ← @id の右に表示
        idLabel.text = sub

        pinBadge.isHidden = !pinned
        avatarView.image = image ?? UIImage(systemName: "person.crop.circle.fill")
    }

}

// ===== FriendList VC =====
final class FriendListViewController: UITableViewController, UISearchBarDelegate, BannerViewDelegate {

    private let db = Firestore.firestore()
    
    // 名前のフォールバック: name → friendName → @id
    private func displayName(name: String?, friendName: String, id: String, friendId: String) -> String {
        let n1 = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !n1.isEmpty { return n1 }
        let n2 = friendName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n2.isEmpty { return n2 }
        return "@\(id.isEmpty ? friendId : id)"
    }


    private struct Profile {
        var name: String
        var id: String
        var photoURL: String?
        var avatarVersion: Int?
        var grade: Int?          // 追加
        var deptAbbr: String?    // 追加

        var extra: String? {
            var parts: [String] = []
            if let d = deptAbbr, !d.isEmpty { parts.append(d) }  // 学科があれば入れる
            if let g = grade, g >= 1 { parts.append("\(g)年") }  // 学年があれば入れる
            return parts.isEmpty ? nil : parts.joined(separator: "・")
        }
    }


    private var allFriends: [Friend] = []
    private var friends: [Friend] = []
    private var profileCache: [String: Profile] = [:] // key: friendUid

    private var badgeListener: ListenerRegistration?
    private var listenerIsActive = false

    private let bellButton = BadgeButton(type: .system)

    // AdMob
    private let adContainer = UIView()
    private var bannerView: BannerView?
    private var adContainerHeight: NSLayoutConstraint?
    private var lastBannerWidth: CGFloat = 0
    private var didLoadBannerOnce = false

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

    // 検索バー
    private let searchBar = UISearchBar(frame: .zero)

    // 未ログインガード
    private var loginAlertShown = false
    
    // ★ 追加: ダーク時だけグレー、ライト時は従来通り
    private func appBackgroundColor(for traits: UITraitCollection) -> UIColor {
        if traits.userInterfaceStyle == .dark {
            return UIColor(white: 0.2, alpha: 1.0)   // 好みで 0.10〜0.16 で微調整可
        } else {
            return .systemBackground
        }
    }

    private func applyBackgroundStyle() {
        let bg = appBackgroundColor(for: traitCollection)
        view.backgroundColor = bg
        tableView.backgroundColor = bg
        adContainer.backgroundColor = bg        // 広告コンテナも合わせる
        // 仕切線を少し薄めに（任意）
        tableView.separatorColor = .separator
    }

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

        // 下部「友だちを探す」
        tableView.tableFooterView = makeFindFriendsFooter()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleFriendsDidChange),
                                               name: .friendsDidChange,
                                               object: nil)

        setupAdBanner()
        applyBackgroundStyle()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        AppGatekeeper.shared.checkAndPresentIfNeeded(on: self)
    }

    
    // ダーク／ライト切替に追随
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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard ensureLoggedInOrRedirect() else { return }
        startListenersIfNeeded()

        if allFriends.isEmpty {
            reload()
        } else {
            applyFilter(text: searchBar.text) // 並び替え更新
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        badgeListener?.remove()
        badgeListener = nil
        listenerIsActive = false
    }

    deinit { badgeListener?.remove() }

    // ===== Login Gate =====
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
                ac.addAction(UIAlertAction(title: "設定へ", style: .default, handler: { [weak self] _ in
                    guard let self = self else { return }
                    self.loginAlertShown = false

                    // 左から4番目（index 3）のタブ＝設定へ遷移
                    if let tab = self.tabBarController ?? (self.view.window?.rootViewController as? UITabBarController) {
                        let idx = 4 // 0-based
                        if let vcs = tab.viewControllers, vcs.indices.contains(idx) {
                            tab.selectedIndex = idx
                            // そのタブが UINavigationController ならルートまで戻しておく
                            if let nav = vcs[idx] as? UINavigationController {
                                nav.popToRootViewController(animated: false)
                            }
                        } else {
                            tab.selectedIndex = idx
                        }
                    }
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

    // ===== Admob =====
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
        bv.adUnitID = "ca-app-pub-3940256099942544/2934735716" // テストID
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

        if !CGSizeEqualToSize(bv.adSize.size, size.size) {
            bv.adSize = size
        }
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
    // BannerViewDelegate
    func bannerViewDidReceiveAd(_ banner: BannerView) { /* no-op */ }
    func bannerView(_ banner: BannerView, didFailToReceiveAdWithError error: Error) {
        adContainerHeight?.constant = 0
    }

    // ===== Data =====
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

    // ===== Builders =====
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

    // ===== Navigation =====
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

    // ===== Search（ローカル） =====
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        applyFilter(text: searchText)
    }
    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchBar.text = nil
        view.endEditing(true)
        applyFilter(text: nil)
    }

    /// テキストでフィルタ → ピン優先 → それぞれを「開いた順（seq降順）」で安定ソート
    private func applyFilter(text: String?) {
        let q = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var filtered = q.isEmpty
            ? allFriends
            : allFriends.filter { f in
                f.friendName.lowercased().contains(q) || f.friendId.lowercased().contains(q)
            }

        let baseIndex: [String: Int] = Dictionary(uniqueKeysWithValues:
            allFriends.enumerated().map { ($0.element.friendUid, $0.offset) }
        )

        filtered.sort { a, b in
            let aPinned = FriendPinStore.shared.isPinned(a.friendUid)
            let bPinned = FriendPinStore.shared.isPinned(b.friendUid)
            if aPinned != bPinned { return aPinned && !bPinned } // ピンは先頭
            let sa = FriendOpenOrderStore.shared.seq(for: a.friendUid) ?? Int.min
            let sb = FriendOpenOrderStore.shared.seq(for: b.friendUid) ?? Int.min
            if sa != sb { return sa > sb } // 開いた順（新しいほど上）
            // 最後に元の順序で安定化
            let ia = baseIndex[a.friendUid] ?? .max
            let ib = baseIndex[b.friendUid] ?? .max
            return ia < ib
        }

        friends = filtered
        tableView.reloadData()
    }

    // ===== TableView =====
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { friends.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let f = friends[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: FriendListCell.reuseID, for: indexPath) as! FriendListCell

        // 1) ローカルキャッシュがあればそれを表示
        if let p = profileCache[f.friendUid] {
            let idForShow = p.id.isEmpty ? f.friendId : p.id
            let nameForShow = displayName(name: p.name, friendName: f.friendName, id: idForShow, friendId: f.friendId)

            let cachedImage = AvatarCache.shared.image(uid: f.friendUid, version: p.avatarVersion)
            cell.configure(name: nameForShow,
                           id: idForShow,
                           image: cachedImage,
                           pinned: FriendPinStore.shared.isPinned(f.friendUid),
                           extraText: p.extra)

            // 画像が未取得ならDL → 反映
            if cachedImage == nil, let url = p.photoURL {
                ImageFetcher.fetch(urlString: url) { img in
                    guard let img = img else { return }
                    AvatarCache.shared.store(img, uid: f.friendUid, version: p.avatarVersion)
                    DispatchQueue.main.async {
                        if let visible = tableView.cellForRow(at: indexPath) as? FriendListCell {
                            visible.configure(name: nameForShow,
                                              id: idForShow,
                                              image: img,
                                              pinned: FriendPinStore.shared.isPinned(f.friendUid),
                                              extraText: p.extra)
                        }
                    }
                }
            }
            return cell
        }

        // 2) まだキャッシュがなければ仮描画 → Firestore 取得
        let fallbackName = f.friendName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "@\(f.friendId)" : f.friendName
        let cachedImage = AvatarCache.shared.image(uid: f.friendUid, version: nil)
        cell.configure(name: fallbackName,
                       id: f.friendId,
                       image: cachedImage,
                       pinned: FriendPinStore.shared.isPinned(f.friendUid),
                       extraText: nil)

        db.collection("users").document(f.friendUid).getDocument { [weak self, weak tableView] snap, _ in
            guard let self = self, let tableView = tableView else { return }
            let data = snap?.data() ?? [:]

            let rawName = data["name"] as? String
            let id = (data["id"] as? String) ?? f.friendId
            let url = data["photoURL"] as? String
            let verRaw = (data["avatarVersion"] as? Int) ?? (data["photoVersion"] as? Int)
            let ver = verRaw ?? AvatarCache.shared.versionFrom(urlString: url)
            let grade = data["grade"] as? Int
            let dept  = data["department"] as? String

            let profile = Profile(name: rawName ?? f.friendName,
                                  id: id,
                                  photoURL: url,
                                  avatarVersion: ver,
                                  grade: grade,
                                  deptAbbr: DepartmentAbbr.abbr(dept))
            self.profileCache[f.friendUid] = profile

            let idForShow = id
            let nameForShow = displayName(name: rawName, friendName: f.friendName, id: idForShow, friendId: f.friendId)

            let cached = AvatarCache.shared.image(uid: f.friendUid, version: ver)
            DispatchQueue.main.async {
                if let visible = tableView.cellForRow(at: indexPath) as? FriendListCell {
                    visible.configure(name: nameForShow,
                                      id: idForShow,
                                      image: cached,
                                      pinned: FriendPinStore.shared.isPinned(f.friendUid),
                                      extraText: profile.extra)
                }
            }

            if cached == nil, let url = url {
                ImageFetcher.fetch(urlString: url) { img in
                    guard let img = img else { return }
                    AvatarCache.shared.store(img, uid: f.friendUid, version: ver)
                    DispatchQueue.main.async {
                        if let visible = tableView.cellForRow(at: indexPath) as? FriendListCell {
                            visible.configure(name: nameForShow,
                                              id: idForShow,
                                              image: img,
                                              pinned: FriendPinStore.shared.isPinned(f.friendUid),
                                              extraText: profile.extra)
                        }
                    }
                }
            }
        }

        return cell
    }


    // ===== 右スワイプ：ピン留め / 解除 =====
    override func tableView(_ tableView: UITableView,
                            leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        let f = friends[indexPath.row]
        let pinned = FriendPinStore.shared.isPinned(f.friendUid)

        let title = pinned ? "ピン解除" : "ピン留め"
        let imageName = pinned ? "pin.slash" : "pin"
        let action = UIContextualAction(style: .normal, title: title) { [weak self] _,_,done in
            guard let self = self else { done(false); return }
            if pinned {
                FriendPinStore.shared.unpin(f.friendUid)
            } else {
                FriendPinStore.shared.pin(f.friendUid)
            }
            self.applyFilter(text: self.searchBar.text)
            done(true)
        }
        action.image = UIImage(systemName: imageName)
        action.backgroundColor = pinned ? .systemGray : .systemYellow

        return UISwipeActionsConfiguration(actions: [action]) // フルスワイプ挙動はデフォルトのまま
    }

    // ===== 左スワイプ：削除（フルスワイプ可、確認アラート付き） =====
    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        let f = friends[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "削除") { [weak self] _,_,done in
            guard let self = self else { done(false); return }
            let alert = UIAlertController(title: "削除しますか？",
                                          message: "この友だちをリストから削除します。",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel, handler: { _ in
                done(false)
            }))
            alert.addAction(UIAlertAction(title: "削除", style: .destructive, handler: { _ in
                // ピンも開いた順も一応クリーンアップ
                FriendPinStore.shared.unpin(f.friendUid)
                FriendService.shared.removeFriend(f.friendUid) { _ in
                    self.reload()
                    done(true)
                }
            }))
            self.present(alert, animated: true)
        }
        delete.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [delete])
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let friend = friends[indexPath.row]

        // 開いた順更新
        FriendOpenOrderStore.shared.bump(uid: friend.friendUid)

        let vc = FriendTimetableViewController(friendUid: friend.friendUid,
                                               friendName: friend.friendName)
        navigationController?.pushViewController(vc, animated: true)
    }
}
