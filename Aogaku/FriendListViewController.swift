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
    private let bottomLine = UIView()
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
final class AvatarCache {
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

    /// バージョン指定なしで uid に紐づく画像を返す（メモリ → v0ファイル直接参照）
    /// ディレクトリスキャンは行わないので呼び出し側スレッドを問わず高速
    func anyImage(uid: String) -> UIImage? {
        return image(uid: uid, version: nil)  // {uid}_v0.jpg を直接確認
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
enum ImageFetcher {
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

    private let cardView = UIView()
    private let avatarView = UIImageView()
    private let nameLabel = UILabel()
    private let idLabel = UILabel()
    private let pinBadge = UIImageView(image: UIImage(systemName: "pin.fill"))
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setupUI() }

    private func setupUI() {
        selectionStyle = .default
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        // Card
        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = .secondarySystemBackground
        cardView.layer.cornerRadius = 16
//        cardView.layer.borderWidth = 1
//        cardView.layer.borderColor = UIColor.systemGray5.cgColor
        cardView.clipsToBounds = true

        // Avatar
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = 28
        avatarView.backgroundColor = .secondarySystemFill

        // Labels
        nameLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        idLabel.font = .systemFont(ofSize: 13)
        idLabel.textColor = .secondaryLabel

        let vStack = UIStackView(arrangedSubviews: [nameLabel, idLabel])
        vStack.axis = .vertical
        vStack.spacing = 2
        vStack.translatesAutoresizingMaskIntoConstraints = false

        // Pin
        pinBadge.translatesAutoresizingMaskIntoConstraints = false
        pinBadge.tintColor = .systemYellow
        pinBadge.isHidden = true

        // Chevron
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = .tertiaryLabel

        contentView.addSubview(cardView)
        cardView.addSubview(avatarView)
        cardView.addSubview(vStack)
        cardView.addSubview(pinBadge)
        cardView.addSubview(chevron)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),

            avatarView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            avatarView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 56),
            avatarView.heightAnchor.constraint(equalToConstant: 56),

            chevron.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),

            vStack.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
            vStack.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            vStack.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -10),

            pinBadge.widthAnchor.constraint(equalToConstant: 16),
            pinBadge.heightAnchor.constraint(equalToConstant: 16),
            pinBadge.trailingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 4),
            pinBadge.bottomAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 4)
        ])

        let sel = UIView()
        sel.backgroundColor = UIColor.secondarySystemFill
        sel.layer.cornerRadius = 16
        selectedBackgroundView = sel
    }

    func configure(name: String, id: String, image: UIImage?, pinned: Bool, extraText: String? = nil) {
        nameLabel.text = name
        var sub = "@\(id)"
        if let t = extraText, !t.isEmpty { sub += "    \(t)" }
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

    // MARK: - Grid vars
    private var occupiedSlots: [String: Set<Int>] = [:]
    private var loadedUids: Set<String> = []
    private var isGridExpanded: Bool = FreeGridState.load()

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
        tableView.register(FreeGridCell.self, forCellReuseIdentifier: FreeGridCell.reuseID)
        tableView.rowHeight = 80
        tableView.estimatedRowHeight = 0
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0

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
        NotificationCenter.default.addObserver(self,
            selector: #selector(onAdMobReady),
            name: .adMobReady, object: nil)
        NotificationCenter.default.addObserver(self,
            selector: #selector(saveGridState),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil)
        applyBackgroundStyle()
    }
    @objc private func onAdMobReady() {
        loadBannerIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        AppGatekeeper.shared.checkAndPresentIfNeeded(on: self)
        ScreenTracker.shared.appear("友だちリスト")
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
        ScreenTracker.shared.disappear("友だちリスト")
        FreeGridState.save(isGridExpanded)
        badgeListener?.remove()
        badgeListener = nil
        listenerIsActive = false
    }

    deinit {
        badgeListener?.remove()
        NotificationCenter.default.removeObserver(self)
    }

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

        // RCで広告を止めているときはUIも消す
        guard AdsConfig.enabled else {
            adContainer.isHidden = true
            adContainerHeight?.constant = 0
            return
        }
        
        let bv = BannerView()
        bv.translatesAutoresizingMaskIntoConstraints = false
        bv.adUnitID = AdsConfig.bannerUnitID     // ← RCの本番/テストIDを自動選択
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
        occupiedSlots.removeAll()
        loadedUids.removeAll()
        FriendService.shared.fetchFriends { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let list):
                self.allFriends = list
                self.applyFilter(text: self.searchBar.text)
                self.loadGridTimetables()
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
        UIView.performWithoutAnimation { tableView.reloadData() }
    }

    // ===== TableView =====

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // ── Section 0: グリッド ──
        if indexPath.section == 0 {
            let cell = tableView.dequeueReusableCell(withIdentifier: FreeGridCell.reuseID, for: indexPath) as! FreeGridCell
            cell.gridView.freeMap = buildFreeMap()
            cell.gridView.highlightDay = currentAcademicDay()
            cell.gridView.highlightPeriod = currentAcademicPeriod()
            cell.gridView.onTap = { [weak self] d, p, entries in
                self?.showFreeSheet(day: d, period: p, entries: entries)
            }
            return cell
        }

        // ── Section 1: 友だち一覧 ──
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
        guard indexPath.section == 1 else { return nil }
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
        guard indexPath.section == 1 else { return nil }
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
        guard indexPath.section == 1 else { return }
        let friend = friends[indexPath.row]

        // 開いた順更新
        FriendOpenOrderStore.shared.bump(uid: friend.friendUid)

        let vc = FriendTimetableViewController(friendUid: friend.friendUid,
                                               friendName: friend.friendName)
        navigationController?.pushViewController(vc, animated: true)
    }

    // MARK: - Grid section

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? (isGridExpanded ? 1 : 0) : friends.count
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        indexPath.section == 0 ? FreeGridView.preferredHeight : 80
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        section == 0 ? makeGridHeader() : nil
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        section == 0 ? 40 : 0
    }

    private func makeGridHeader() -> UIView {
        let v = UIView()
        v.backgroundColor = .clear

        let icon = UIImageView(image: UIImage(systemName: "person.2"))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false

        let lbl = UILabel()
        lbl.text = "空きコマで会える友だち"
        lbl.font = .systemFont(ofSize: 13, weight: .semibold)
        lbl.textColor = .secondaryLabel
        lbl.translatesAutoresizingMaskIntoConstraints = false

        let chevron = UIImageView()
        chevron.image = UIImage(systemName: isGridExpanded ? "chevron.up" : "chevron.down",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(icon)
        v.addSubview(lbl)
        v.addSubview(chevron)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 14),
            lbl.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            lbl.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -20),
            chevron.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
        ])
        v.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleGrid)))
        v.isUserInteractionEnabled = true
        return v
    }

    @objc private func toggleGrid() {
        isGridExpanded.toggle()
        FreeGridState.save(isGridExpanded)
        tableView.reloadSections(IndexSet(integer: 0), with: .automatic)
    }

    @objc private func saveGridState() {
        FreeGridState.save(isGridExpanded)
    }

    // MARK: - Grid data

    private func loadGridTimetables() {
        guard Auth.auth().currentUser != nil, !allFriends.isEmpty else { return }
        let cal = Calendar.current
        let now = Date()
        let month = cal.component(.month, from: now)
        let yr = cal.component(.year, from: now)
        let year = month >= 3 ? yr : yr - 1
        let sem = month >= 10 ? "後期" : "前期"
        let idA = "assignedCourses.\(year)_\(sem)"
        let idB = "assignedCourses.\(year).\(sem)"

        for friend in allFriends {
            let uid = friend.friendUid
            guard !loadedUids.contains(uid) else { continue }
            let ref = db.collection("users").document(uid).collection("timetable")
            ref.document(idA).getDocument { [weak self] snapA, errA in
                guard let self else { return }
                if errA == nil, let data = snapA?.data(), !data.isEmpty {
                    let slots = self.parseOccupiedSlots(from: data)
                    DispatchQueue.main.async {
                        self.occupiedSlots[uid] = slots
                        self.loadedUids.insert(uid)
                        self.reloadGridCellIfVisible()
                    }
                    return
                }
                ref.document(idB).getDocument { [weak self] snapB, _ in
                    guard let self else { return }
                    DispatchQueue.main.async {
                        if let data = snapB?.data(), !data.isEmpty {
                            self.occupiedSlots[uid] = self.parseOccupiedSlots(from: data)
                        }
                        self.loadedUids.insert(uid)
                        self.reloadGridCellIfVisible()
                    }
                }
            }
        }
    }

    private func reloadGridCellIfVisible() {
        guard isGridExpanded,
              tableView.numberOfSections > 0,
              tableView.numberOfRows(inSection: 0) > 0 else { return }
        tableView.reloadRows(at: [IndexPath(row: 0, section: 0)], with: .none)
    }

    private func parseOccupiedSlots(from data: [String: Any]) -> Set<Int> {
        var slots = Set<Int>()
        func tryAdd(key: String, value: Any) {
            guard let (d, p) = dayPeriodKey(key) else { return }
            let occupied: Bool
            if let dict = value as? [String: Any] {
                occupied = !(dict["title"] as? String ?? "").isEmpty || !dict.isEmpty
            } else if let b = value as? Bool { occupied = b
            } else { occupied = true }
            if occupied { slots.insert(d * 10 + p) }
        }
        if let cells = data["cells"] as? [String: Any] {
            for (k, v) in cells {
                if let nested = v as? [String: Any], dayPeriodKey(k) == nil {
                    for (pk, pv) in nested { tryAdd(key: "\(k)\(pk)", value: pv) }
                } else { tryAdd(key: k, value: v) }
            }
        } else {
            for (raw, val) in data {
                let k = raw.hasPrefix("cells.") ? String(raw.dropFirst("cells.".count)) : raw
                tryAdd(key: k, value: val)
            }
        }
        return slots
    }

    private func dayPeriodKey(_ key: String) -> (Int, Int)? {
        guard let rx = try? NSRegularExpression(pattern: #"^d(\d+)p(\d+)$"#),
              let m = rx.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)),
              let rD = Range(m.range(at: 1), in: key),
              let rP = Range(m.range(at: 2), in: key),
              let d = Int(key[rD]), let p = Int(key[rP]),
              (0...4).contains(d), (1...5).contains(p) else { return nil }
        return (d, p)
    }

    private func buildFreeMap() -> FreeGridView.FreeMap {
        var map: FreeGridView.FreeMap = [:]
        let loaded = allFriends.filter { loadedUids.contains($0.friendUid) }
        guard !loaded.isEmpty else { return map }
        for d in 0..<5 {
            for p in 1...5 {
                let slot = d * 10 + p
                let entries: [FreeSlotEntry] = loaded.compactMap { f in
                    guard !(occupiedSlots[f.friendUid]?.contains(slot) ?? false) else { return nil }
                    let prof = profileCache[f.friendUid]
                    let name = prof?.name.trimmingCharacters(in: .whitespaces) ?? ""
                    let avatar = AvatarCache.shared.image(uid: f.friendUid, version: prof?.avatarVersion)
                        ?? AvatarCache.shared.anyImage(uid: f.friendUid)
                    return FreeSlotEntry(uid: f.friendUid, name: name.isEmpty ? f.friendName : name, avatar: avatar)
                }
                if !entries.isEmpty {
                    if map[d] == nil { map[d] = [:] }
                    map[d]![p] = entries
                }
            }
        }
        return map
    }

    private func showFreeSheet(day: Int, period: Int, entries: [FreeSlotEntry]) {
        let days = ["月","火","水","木","金"]
        let title = "\(days[safe: day] ?? "?")曜 \(period)限が空いている友だち"
        let ac = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for e in entries.prefix(10) {
            ac.addAction(UIAlertAction(title: e.name, style: .default) { [weak self] _ in
                guard let self, let f = self.allFriends.first(where: { $0.friendUid == e.uid }) else { return }
                let vc = FriendTimetableViewController(friendUid: f.friendUid, friendName: f.friendName)
                self.navigationController?.pushViewController(vc, animated: true)
            })
        }
        if entries.count > 10 { ac.message = "他 \(entries.count - 10) 人" }
        ac.addAction(UIAlertAction(title: "閉じる", style: .cancel))
        if let pop = ac.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        present(ac, animated: true)
    }

    private func currentAcademicDay() -> Int? {
        let wd = Calendar.current.component(.weekday, from: Date())
        guard wd >= 2, wd <= 6 else { return nil }
        return wd - 2
    }

    private func currentAcademicPeriod() -> Int? {
        let cal = Calendar.current
        let now = Date()
        let wd = cal.component(.weekday, from: now)
        guard wd >= 2, wd <= 6 else { return nil }
        let h = cal.component(.hour, from: now)
        let m = cal.component(.minute, from: now)
        let t = h * 60 + m
        let schedule = [(9*60, 10*60+30, 1),(11*60, 12*60+30, 2),
                        (13*60+20, 14*60+50, 3),(15*60+5, 16*60+35, 4),(16*60+50, 18*60+20, 5)]
        return schedule.first { t >= $0.0 && t <= $0.1 }?.2
    }

}

// MARK: - Shared: 空きコマグリッド

// 開閉状態の永続化
enum FreeGridState {
    private static let key = "FreeGrid_expanded_v2"
    static func load() -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func save(_ v: Bool) { UserDefaults.standard.set(v, forKey: key) }
}

// グリッド1コマのエントリ
struct FreeSlotEntry {
    let uid: String
    let name: String
    let avatar: UIImage?

    init(uid: String, name: String, avatar: UIImage? = nil) {
        self.uid = uid
        self.name = name
        self.avatar = avatar
    }
}

// MARK: - FreeGridView

/// 月〜金 × 1〜5限のシンプルグリッド。
/// 各コマに空きの友だちを表示し、タップでシートを出す。
final class FreeGridView: UIView {

    typealias FreeMap = [Int: [Int: [FreeSlotEntry]]]   // day(0-4) → period(1-5) → entries

    var freeMap: FreeMap = [:] { didSet { refresh() } }
    var highlightDay: Int?    { didSet { refresh() } }
    var highlightPeriod: Int? { didSet { refresh() } }
    var onTap: ((Int, Int, [FreeSlotEntry]) -> Void)?

    // レイアウト定数
    private enum K {
        static let days = 5, periods = 5
        static let dayTitles    = ["月","火","水","木","金"]
        static let periodTitles = ["1","2","3","4","5"]
        static let hPad:   CGFloat = 8
        static let leftW:  CGFloat = 20   // 時限ラベル列幅
        static let colGap: CGFloat = 3    // 列間隔
        static let rowGap: CGFloat = 5    // 行間隔
        static let headerH: CGFloat = 20  // 曜日ラベル行高
        static let cellH:  CGFloat = 100  // コマ高さ
        static let topPad: CGFloat = 10
        static let botPad: CGFloat = 10
        static let visibleFriendsPerSlot = 5
    }

    static let preferredHeight: CGFloat = {
        K.topPad + K.headerH + K.rowGap
            + CGFloat(K.periods) * K.cellH + CGFloat(K.periods - 1) * K.rowGap
            + K.botPad
    }()

    // セルのビューと友だち表示スタックを保持 [period index][day index]
    private var slotCells: [[UIView]] = []
    private var slotStacks: [[UIStackView]] = []
    private var dayLabels: [UILabel] = []
    private var periodLabels: [UILabel] = []

    override init(frame: CGRect) { super.init(frame: frame); build() }
    required init?(coder: NSCoder) { super.init(coder: coder); build() }

    private func build() {
        backgroundColor = .clear
        isUserInteractionEnabled = true

        // 曜日ラベル
        for t in K.dayTitles {
            let l = label(t, size: 11, weight: .medium, color: .secondaryLabel)
            l.textAlignment = .center
            addSubview(l)
            dayLabels.append(l)
        }

        // 時限ラベル + コマ
        slotCells = Array(repeating: [], count: K.periods)
        slotStacks = Array(repeating: [], count: K.periods)
        for pi in 0..<K.periods {
            let pl = label(K.periodTitles[pi], size: 11, weight: .medium, color: .tertiaryLabel)
            pl.textAlignment = .center
            addSubview(pl)
            periodLabels.append(pl)

            for di in 0..<K.days {
                let cell = UIView()
                cell.layer.cornerRadius = 8
                cell.clipsToBounds = true
                cell.backgroundColor = UIColor.systemGray6
                cell.isUserInteractionEnabled = true
                cell.tag = di * 10 + (pi + 1)
                cell.translatesAutoresizingMaskIntoConstraints = false
                addSubview(cell)

                let stack = UIStackView()
                stack.axis = .vertical
                stack.alignment = .fill
                stack.distribution = .equalCentering
                stack.spacing = 3
                stack.isUserInteractionEnabled = false
                stack.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    stack.topAnchor.constraint(greaterThanOrEqualTo: cell.topAnchor, constant: 6),
                    stack.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -6),
                ])

                cell.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(slotTapped(_:))))

                slotCells[pi].append(cell)
                slotStacks[pi].append(stack)
            }
        }
    }

    // 手動レイアウト（AutoLayout より確実）
    override func layoutSubviews() {
        super.layoutSubviews()
        let availW = bounds.width - K.hPad * 2 - K.leftW - K.colGap
        let cellW  = (availW - CGFloat(K.days - 1) * K.colGap) / CGFloat(K.days)
        let originX = K.hPad + K.leftW + K.colGap

        // 曜日ラベル
        for di in 0..<K.days {
            let x = originX + CGFloat(di) * (cellW + K.colGap)
            dayLabels[di].frame = CGRect(x: x, y: K.topPad, width: cellW, height: K.headerH)
        }

        // 行（時限ラベル + コマ）
        for pi in 0..<K.periods {
            let y = K.topPad + K.headerH + K.rowGap + CGFloat(pi) * (K.cellH + K.rowGap)
            periodLabels[pi].frame = CGRect(x: K.hPad, y: y, width: K.leftW, height: K.cellH)
            for di in 0..<K.days {
                let x = originX + CGFloat(di) * (cellW + K.colGap)
                slotCells[pi][di].frame = CGRect(x: x, y: y, width: cellW, height: K.cellH)
            }
        }
    }

    // セルの見た目を更新
    private func refresh() {
        for pi in 0..<K.periods {
            let period = pi + 1
            let isCurPeriod = period == highlightPeriod
            periodLabels[pi].textColor = isCurPeriod ? .systemGreen : .tertiaryLabel
            periodLabels[pi].font = .systemFont(ofSize: 11, weight: isCurPeriod ? .bold : .medium)

            for di in 0..<K.days {
                let isCurDay = di == highlightDay
                dayLabels[di].textColor = isCurDay ? .systemGreen : .secondaryLabel
                dayLabels[di].font = .systemFont(ofSize: 11, weight: isCurDay ? .bold : .medium)

                let entries = freeMap[di]?[period] ?? []
                let cell    = slotCells[pi][di]
                let stack   = slotStacks[pi][di]
                let isCur   = isCurDay && isCurPeriod

                stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
                if entries.isEmpty {
                    cell.backgroundColor = UIColor.systemGray6
                    cell.layer.borderWidth = isCur ? 1.5 : 0
                    cell.layer.borderColor = UIColor.systemGreen.cgColor
                } else {
                    cell.backgroundColor = UIColor.systemGreen.withAlphaComponent(isCur ? 0.18 : 0.10)
                    cell.layer.borderWidth = isCur ? 1.5 : 0
                    cell.layer.borderColor = UIColor.systemGreen.cgColor
                    for entry in entries.prefix(K.visibleFriendsPerSlot) {
                        stack.addArrangedSubview(friendRow(for: entry))
                    }
                }
            }
        }
    }

    @objc private func slotTapped(_ gr: UITapGestureRecognizer) {
        guard let v = gr.view else { return }
        let d = v.tag / 10
        let p = v.tag % 10
        let entries = freeMap[d]?[p] ?? []
        guard !entries.isEmpty else { return }
        onTap?(d, p, entries)
    }

    // ヘルパー
    private func label(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func friendRow(for entry: FreeSlotEntry) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.distribution = .fill
        row.spacing = 3

        let avatar = UIImageView()
        avatar.contentMode = .scaleAspectFill
        avatar.clipsToBounds = true
        avatar.layer.cornerRadius = 9
        avatar.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.18)
        avatar.tintColor = .systemGreen
        avatar.image = entry.avatar ?? UIImage(systemName: "person.crop.circle.fill")
        avatar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 18),
            avatar.heightAnchor.constraint(equalToConstant: 18)
        ])

        let name = UILabel()
        name.text = entry.name
        name.font = .systemFont(ofSize: 10, weight: .semibold)
        name.textColor = .label
        name.numberOfLines = 1
        name.adjustsFontSizeToFitWidth = true
        name.minimumScaleFactor = 0.75
        name.lineBreakMode = .byTruncatingTail

        row.addArrangedSubview(avatar)
        row.addArrangedSubview(name)
        return row
    }
}

// MARK: - FreeGridCell（テーブルセルラッパー）

final class FreeGridCell: UITableViewCell {
    static let reuseID = "FreeGridCell"
    let gridView = FreeGridView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        gridView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(gridView)
        NSLayoutConstraint.activate([
            gridView.topAnchor.constraint(equalTo: contentView.topAnchor),
            gridView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            gridView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            gridView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            gridView.heightAnchor.constraint(equalToConstant: FreeGridView.preferredHeight),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Array safe subscript
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
