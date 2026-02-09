import UIKit
import FirebaseAuth
import FirebaseFirestore

final class UserSettingsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    // MARK: - UI
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    /// NavigationBar が無い場合でも QR/追加/通知 を表示するトップバー
    private let topBar = UIView()
    private let qrButton = UIButton(type: .system)
    private let addButton = UIButton(type: .system)
    private let bellButton = BadgeButton(type: .system)

    private var tableTopConstraint: NSLayoutConstraint?

    // MARK: - Models
    private struct SelfProfile {
        var name: String
        var id: String
        var photoURL: String?
        var grade: Int?
        var faculty: String?
        var department: String?

        var subtitle: String { id.isEmpty ? "" : "@\(id)" }
    }

    // 学科 → 略称（FindFriendsと同じ）
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
            return map[d] ?? d
        }
    }

    // 友だち表示用の追加情報（学科略称・学年）
    private struct ProfileInfo {
        let faculty: String?
        let department: String?
        let grade: Int?
        var deptAbbr: String? { DepartmentAbbr.abbr(for: department) }
        var text: String? {
            var parts: [String] = []
            if let a = deptAbbr, !a.isEmpty { parts.append(a) }
            if let g = grade, g >= 1 { parts.append("\(g)年") }
            return parts.isEmpty ? nil : parts.joined(separator: "・")
        }
    }

    private let db = Firestore.firestore()
    private var uid: String? { Auth.auth().currentUser?.uid }

    private var me: SelfProfile?
    private var friends: [Friend] = []

    // MARK: - Listeners
    private var badgeListener: ListenerRegistration?
    private var listenerIsActive = false
    private var loginAlertShown = false

    // MARK: - Friend avatar cache
    private var friendAvatarCache: [String: UIImage] = [:]     // friendUid -> image
    private var friendPhotoURLCache: [String: String] = [:]    // friendUid -> photoURL
    private var friendAvatarLoading: Set<String> = []          // friendUid in-flight

    // MARK: - Friend profile cache (dept/grade)
    private var friendProfileInfo: [String: ProfileInfo] = [:]
    private var friendProfileLoading: Set<String> = []

    // MARK: - Pin store (固定)
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

    // MARK: - LifeCycle
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "アカウント"
        view.backgroundColor = .systemGroupedBackground

        setupTopBar()
        setupTable()

        tableView.tableFooterView = makeFindFriendsFooter()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleFriendsDidChange),
                                               name: .friendsDidChange,
                                               object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        configureHeaderButtonsVisibility()
        adjustTopSpacing()

        guard ensureLoggedInOrRedirect() else { return }
        startListenersIfNeeded()
        loadSelfProfile()
        reloadFriends()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        badgeListener?.remove()
        badgeListener = nil
        listenerIsActive = false
    }

    deinit {
        badgeListener?.remove()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup
    private func setupTopBar() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.backgroundColor = .clear
        view.addSubview(topBar)

        // Buttons
        qrButton.setImage(UIImage(systemName: "qrcode.viewfinder"), for: .normal)
        qrButton.tintColor = .label
        qrButton.addTarget(self, action: #selector(openQR), for: .touchUpInside)
        qrButton.translatesAutoresizingMaskIntoConstraints = false

        addButton.setImage(UIImage(systemName: "person.badge.plus"), for: .normal)
        addButton.tintColor = .label
        addButton.addTarget(self, action: #selector(openFind), for: .touchUpInside)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        bellButton.addTarget(self, action: #selector(openRequests), for: .touchUpInside)
        bellButton.translatesAutoresizingMaskIntoConstraints = false
        bellButton.tintColor = .label

        topBar.addSubview(qrButton)
        topBar.addSubview(addButton)
        topBar.addSubview(bellButton)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 36),

            qrButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            qrButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            qrButton.widthAnchor.constraint(equalToConstant: 34),
            qrButton.heightAnchor.constraint(equalToConstant: 34),

            addButton.leadingAnchor.constraint(equalTo: qrButton.trailingAnchor, constant: 10),
            addButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 34),
            addButton.heightAnchor.constraint(equalToConstant: 34),

            bellButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
            bellButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            bellButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 34),
            bellButton.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    private func setupTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .systemGroupedBackground
        tableView.dataSource = self
        tableView.delegate = self

        // ✅ 友だちセルを端から端まで見せるため、セパレータは標準を使う
        tableView.separatorStyle = .singleLine
        tableView.separatorInset = .zero
        tableView.layoutMargins = .zero

        tableView.register(SelfHeaderCell.self, forCellReuseIdentifier: SelfHeaderCell.reuseID)
        tableView.register(FriendSettingsCell.self, forCellReuseIdentifier: FriendSettingsCell.reuseID)

        if #available(iOS 15.0, *) {
            tableView.sectionHeaderTopPadding = 0
        }

        view.addSubview(tableView)

        let top = tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -6)
        tableTopConstraint = top

        NSLayoutConstraint.activate([
            top,
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func adjustTopSpacing() {
        tableView.contentInset.top = -6
    }

    /// ナビがあるならnavigationItemに出す／無いならtopBarに出す
    private func configureHeaderButtonsVisibility() {
        if let nav = navigationController {
            topBar.isHidden = true

            let qrItem = UIBarButtonItem(image: UIImage(systemName: "qrcode.viewfinder"),
                                         style: .plain,
                                         target: self,
                                         action: #selector(openQR))
            let addItem = UIBarButtonItem(image: UIImage(systemName: "person.badge.plus"),
                                          style: .plain,
                                          target: self,
                                          action: #selector(openFind))

            nav.navigationBar.isHidden = false
            navigationItem.leftBarButtonItems = [qrItem, addItem]
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: bellButton)
        } else {
            topBar.isHidden = false
        }
    }

    // MARK: - Friend avatar loader
    private func loadFriendAvatarIfNeeded(friendUid: String, onImage: @escaping (UIImage?) -> Void) {
        if let img = friendAvatarCache[friendUid] { onImage(img); return }
        if friendAvatarLoading.contains(friendUid) { onImage(nil); return }
        friendAvatarLoading.insert(friendUid)

        let fetchURL: (@escaping (String?) -> Void) -> Void = { done in
            if let cached = self.friendPhotoURLCache[friendUid], !cached.isEmpty {
                done(cached); return
            }
            self.db.collection("users").document(friendUid).getDocument { snap, _ in
                let data = snap?.data() ?? [:]
                let url =
                    (data["photoURL"] as? String) ??
                    (data["avatarURL"] as? String) ??
                    (data["iconURL"] as? String) ??
                    ""
                if !url.isEmpty { self.friendPhotoURLCache[friendUid] = url }
                done(url.isEmpty ? nil : url)
            }
        }

        fetchURL { [weak self] urlString in
            guard let self else { return }
            guard let s = urlString, let url = SelfHeaderCell.safeURL(from: s) else {
                self.friendAvatarLoading.remove(friendUid)
                onImage(nil)
                return
            }

            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let self else { return }
                defer { self.friendAvatarLoading.remove(friendUid) }

                guard let data, let img = UIImage(data: data) else {
                    onImage(nil); return
                }
                self.friendAvatarCache[friendUid] = img
                onImage(img)
            }.resume()
        }
    }

    // MARK: - Friend profile (dept/grade) loader
    private func loadFriendProfileInfoIfNeeded(friendUid: String, completion: @escaping (ProfileInfo?) -> Void) {
        if let info = friendProfileInfo[friendUid] { completion(info); return }
        if friendProfileLoading.contains(friendUid) { completion(nil); return }
        friendProfileLoading.insert(friendUid)

        db.collection("users").document(friendUid).getDocument { [weak self] snap, _ in
            guard let self else { return }
            defer { self.friendProfileLoading.remove(friendUid) }

            let data = snap?.data() ?? [:]
            let faculty = data["faculty"] as? String
            let dept = data["department"] as? String
            let grade = data["grade"] as? Int
            let info = ProfileInfo(faculty: faculty, department: dept, grade: grade)
            self.friendProfileInfo[friendUid] = info
            completion(info)
        }
    }

    // MARK: - Navigation helper
    private func showOnNav(_ vc: UIViewController, title: String? = nil) {
        if let title { vc.title = title }
        if let nav = navigationController {
            nav.pushViewController(vc, animated: true)
        } else {
            let nav = UINavigationController(rootViewController: vc)
            nav.modalPresentationStyle = .fullScreen
            present(nav, animated: true)
        }
    }

    // MARK: - Login gate
    @discardableResult
    private func ensureLoggedInOrRedirect() -> Bool {
        guard Auth.auth().currentUser != nil else {
            if !loginAlertShown {
                loginAlertShown = true
                friends.removeAll()
                me = nil
                tableView.reloadData()
                bellButton.setBadgeVisible(false)

                let ac = UIAlertController(
                    title: "ログインが必要です",
                    message: "友だち機能はログイン状態でのみ使用可能です。",
                    preferredStyle: .alert
                )
                ac.addAction(UIAlertAction(title: "閉じる", style: .cancel, handler: { _ in
                    self.loginAlertShown = false
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

    // MARK: - Load self
    func loadSelfProfile() {
        guard let uid else { return }
        db.collection("users").document(uid).getDocument { [weak self] snap, _ in
            guard let self else { return }
            let data = snap?.data() ?? [:]

            let name = (data["name"] as? String) ?? ""
            let id = (data["id"] as? String) ?? ""

            let fsURL =
                (data["photoURL"] as? String) ??
                (data["avatarURL"] as? String) ??
                (data["iconURL"] as? String)

            let authURL = Auth.auth().currentUser?.photoURL?.absoluteString
            let url = ((fsURL?.isEmpty == false) ? fsURL : authURL)

            let grade = data["grade"] as? Int
            let faculty = data["faculty"] as? String
            let dept = data["department"] as? String

            self.me = SelfProfile(name: name, id: id, photoURL: url, grade: grade, faculty: faculty, department: dept)

            DispatchQueue.main.async { self.tableView.reloadData() }

            if (fsURL == nil || fsURL == ""), let authURL, !authURL.isEmpty {
                self.db.collection("users").document(uid).setData(["photoURL": authURL], merge: true)
            }
        }
    }

    // MARK: - Load friends
    private func sortFriendsPinnedFirst(_ list: [Friend]) -> [Friend] {
        list.sorted { a, b in
            let ap = FriendPinStore.shared.isPinned(a.friendUid)
            let bp = FriendPinStore.shared.isPinned(b.friendUid)
            if ap != bp { return ap && !bp }

            let an = a.friendName.trimmingCharacters(in: .whitespacesAndNewlines)
            let bn = b.friendName.trimmingCharacters(in: .whitespacesAndNewlines)
            let aa = an.isEmpty ? a.friendId : an
            let bb = bn.isEmpty ? b.friendId : bn
            return aa.localizedCaseInsensitiveCompare(bb) == .orderedAscending
        }
    }

    private func reloadFriends() {
        FriendService.shared.fetchFriends { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let list):
                self.friends = self.sortFriendsPinnedFirst(list)
            case .failure:
                self.friends = []
            }
            DispatchQueue.main.async { self.tableView.reloadData() }
        }
    }

    @objc private func handleFriendsDidChange() {
        guard ensureLoggedInOrRedirect() else { return }
        reloadFriends()
    }

    // MARK: - Friend delete (両者から削除)
    private func removeFriendFromBothSides(friendUid: String, completion: @escaping (Bool) -> Void) {
        guard let myUid = Auth.auth().currentUser?.uid else { completion(false); return }

        // friends がサブコレクション方式前提
        let myRef = db.collection("users").document(myUid).collection("friends").document(friendUid)
        let otherRef = db.collection("users").document(friendUid).collection("friends").document(myUid)

        let batch = db.batch()
        batch.deleteDocument(myRef)
        batch.deleteDocument(otherRef)

        batch.commit { err in
            completion(err == nil)
        }
    }

    // MARK: - Table
    func numberOfSections(in tableView: UITableView) -> Int { 2 }
    
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard section == 1 else { return nil }

        let container = UIView()
        container.backgroundColor = .clear

        let label = UILabel()
        label.text = "友だち"
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16), // ←ここで余白
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6)
        ])

        return container
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return section == 1 ? 32 : 0.01
    }


    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : friends.count
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        indexPath.section == 0 ? 104 : 86
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {

        if indexPath.section == 0 {
            let cell = tableView.dequeueReusableCell(withIdentifier: SelfHeaderCell.reuseID, for: indexPath) as! SelfHeaderCell
            cell.configure(name: me?.name ?? "プロフィール",
                           subtitle: me?.subtitle ?? "",
                           photoURL: me?.photoURL)

            if #available(iOS 14.0, *) { cell.backgroundConfiguration = UIBackgroundConfiguration.clear() }
            cell.contentView.backgroundColor = .clear
            cell.backgroundColor = .clear

            // 自分セルはセパレータ無し
            cell.separatorInset = UIEdgeInsets(top: 0, left: 10000, bottom: 0, right: 0)
            return cell
        }

        let f = friends[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: FriendSettingsCell.reuseID, for: indexPath) as! FriendSettingsCell

        let fallbackName = f.friendName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "@\(f.friendId)" : f.friendName
        cell.accessibilityIdentifier = f.friendUid

        let pinned = FriendPinStore.shared.isPinned(f.friendUid)
        let extra = friendProfileInfo[f.friendUid]?.text

        let cachedImg = friendAvatarCache[f.friendUid]
        cell.configure(name: fallbackName, id: f.friendId, image: cachedImg, pinned: pinned, extraText: extra)

        // アイコンロード
        if cachedImg == nil {
            loadFriendAvatarIfNeeded(friendUid: f.friendUid) { [weak self, weak cell] img in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard let cell else { return }
                    guard cell.accessibilityIdentifier == f.friendUid else { return }
                    if let img {
                        let pinnedNow = FriendPinStore.shared.isPinned(f.friendUid)
                        let extraNow = self.friendProfileInfo[f.friendUid]?.text
                        cell.configure(name: fallbackName, id: f.friendId, image: img, pinned: pinnedNow, extraText: extraNow)
                    }
                }
            }
        }

        // 学科・学年ロード
        if friendProfileInfo[f.friendUid] == nil {
            loadFriendProfileInfoIfNeeded(friendUid: f.friendUid) { [weak self, weak cell] info in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard let cell else { return }
                    guard cell.accessibilityIdentifier == f.friendUid else { return }
                    let pinnedNow = FriendPinStore.shared.isPinned(f.friendUid)
                    let extraNow = info?.text
                    cell.configure(name: fallbackName, id: f.friendId, image: self.friendAvatarCache[f.friendUid], pinned: pinnedNow, extraText: extraNow)
                }
            }
        }

        // フル幅セパレータ
        cell.preservesSuperviewLayoutMargins = false
        cell.separatorInset = .zero
        cell.layoutMargins = .zero

        if #available(iOS 14.0, *) { cell.backgroundConfiguration = UIBackgroundConfiguration.clear() }
        cell.contentView.backgroundColor = .clear
        cell.backgroundColor = .clear
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if indexPath.section == 0 {
            let vc = ProfileEditViewController(prefill: .init(
                name: me?.name,
                id: me?.id,
                grade: me?.grade,
                faculty: me?.faculty,
                department: me?.department,
                photoURL: me?.photoURL
            ))
            showOnNav(vc, title: "プロフィール編集")
            return
        }

        let friend = friends[indexPath.row]
        let vc = FriendTimetableViewController(friendUid: friend.friendUid, friendName: friend.friendName)
        showOnNav(vc, title: friend.friendName)
    }

    // MARK: - Swipe actions (固定 / 削除)
    func tableView(_ tableView: UITableView,
                   leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 1 else { return nil }
        let f = friends[indexPath.row]
        let pinned = FriendPinStore.shared.isPinned(f.friendUid)

        let title = pinned ? "固定解除" : "固定"
        let imageName = pinned ? "pin.slash" : "pin"

        let action = UIContextualAction(style: .normal, title: title) { [weak self] _,_,done in
            guard let self else { done(false); return }

            if pinned { FriendPinStore.shared.unpin(f.friendUid) }
            else { FriendPinStore.shared.pin(f.friendUid) }

            self.friends = self.sortFriendsPinnedFirst(self.friends)
            self.tableView.reloadSections(IndexSet(integer: 1), with: .automatic)
            done(true)
        }

        action.image = UIImage(systemName: imageName)
        action.backgroundColor = pinned ? .systemGray : .systemYellow

        let config = UISwipeActionsConfiguration(actions: [action])
        config.performsFirstActionWithFullSwipe = true
        return config
    }

    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 1 else { return nil }
        let f = friends[indexPath.row]

        let delete = UIContextualAction(style: .destructive, title: "削除") { [weak self] _,_,done in
            guard let self else { done(false); return }

            let alert = UIAlertController(
                title: "友だちを削除しますか？",
                message: "「はい」を押すと、お互いの友だち一覧から削除されます。",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "いいえ", style: .cancel, handler: { _ in
                done(false)
            }))
            alert.addAction(UIAlertAction(title: "はい", style: .destructive, handler: { _ in
                // ローカル保持を掃除
                FriendPinStore.shared.unpin(f.friendUid)
                self.friendAvatarCache.removeValue(forKey: f.friendUid)
                self.friendPhotoURLCache.removeValue(forKey: f.friendUid)
                self.friendProfileInfo.removeValue(forKey: f.friendUid)

                self.removeFriendFromBothSides(friendUid: f.friendUid) { success in
                    DispatchQueue.main.async {
                        if success {
                            self.reloadFriends()
                            done(true)
                        } else {
                            done(false)
                        }
                    }
                }
            }))
            self.present(alert, animated: true)
        }

        delete.image = UIImage(systemName: "trash")

        let config = UISwipeActionsConfiguration(actions: [delete])
        config.performsFirstActionWithFullSwipe = false
        return config
    }

    // MARK: - Footer
    private func makeFindFriendsFooter() -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 110))
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
            button.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            button.heightAnchor.constraint(equalToConstant: 56)
        ])
        return container
    }

    // MARK: - Actions
    @objc private func openFind() {
        guard ensureLoggedInOrRedirect() else { return }
        showOnNav(FindFriendsViewController(), title: "友だちを探す")
    }

    @objc private func openRequests() {
        guard ensureLoggedInOrRedirect() else { return }
        showOnNav(FriendRequestsViewController(), title: "申請")
    }

    @objc private func openQR() {
        guard ensureLoggedInOrRedirect() else { return }
        let nav = UINavigationController(rootViewController: QRScannerViewController())
        if let scanner = nav.viewControllers.first as? QRScannerViewController {
            scanner.onFoundID = { [weak self] _ in self?.startListenersIfNeeded() }
        }
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }
}

// MARK: - Friend cell (フル幅 / 左寄せ / 右 chevron / 学科・学年)
final class FriendSettingsCell: UITableViewCell {
    static let reuseID = "FriendSettingsCell"

    private let rowBG = UIView()
    private let avatarView = UIImageView()
    private let nameLabel = UILabel()
    private let idLabel = UILabel()
    private let extraLabel = UILabel()

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

        // フル幅背景
        rowBG.translatesAutoresizingMaskIntoConstraints = false
        rowBG.backgroundColor = .secondarySystemBackground
        rowBG.clipsToBounds = true
        contentView.addSubview(rowBG)

        // 端から端まで
        NSLayoutConstraint.activate([
            rowBG.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rowBG.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rowBG.topAnchor.constraint(equalTo: contentView.topAnchor),
            rowBG.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        // Avatar
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = 26
        avatarView.backgroundColor = .secondarySystemFill
        avatarView.image = UIImage(systemName: "person.crop.circle.fill")

        // Labels（左寄せ）
        nameLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        nameLabel.textColor = .label
        nameLabel.numberOfLines = 1

        idLabel.font = .systemFont(ofSize: 13, weight: .medium)
        idLabel.textColor = .secondaryLabel
        idLabel.numberOfLines = 1

        extraLabel.font = .systemFont(ofSize: 13, weight: .medium)
        extraLabel.textColor = .secondaryLabel
        extraLabel.numberOfLines = 1

        let vStack = UIStackView(arrangedSubviews: [nameLabel, idLabel, extraLabel])
        vStack.axis = .vertical
        vStack.spacing = 2
        vStack.alignment = .leading
        vStack.translatesAutoresizingMaskIntoConstraints = false

        // Pin
        pinBadge.translatesAutoresizingMaskIntoConstraints = false
        pinBadge.tintColor = .systemYellow
        pinBadge.isHidden = true

        // Chevron（右寄せ）
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = .tertiaryLabel

        rowBG.addSubview(avatarView)
        rowBG.addSubview(vStack)
        rowBG.addSubview(pinBadge)
        rowBG.addSubview(chevron)

        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: rowBG.leadingAnchor, constant: 16),
            avatarView.centerYAnchor.constraint(equalTo: rowBG.centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 52),
            avatarView.heightAnchor.constraint(equalToConstant: 52),

            chevron.trailingAnchor.constraint(equalTo: rowBG.trailingAnchor, constant: -16),
            chevron.centerYAnchor.constraint(equalTo: rowBG.centerYAnchor),

            vStack.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
            vStack.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -12),
            vStack.centerYAnchor.constraint(equalTo: rowBG.centerYAnchor),

            pinBadge.widthAnchor.constraint(equalToConstant: 16),
            pinBadge.heightAnchor.constraint(equalToConstant: 16),
            pinBadge.trailingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 4),
            pinBadge.bottomAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 4)
        ])

        // 選択背景
        let sel = UIView()
        sel.backgroundColor = UIColor.secondarySystemFill
        selectedBackgroundView = sel

        // フル幅セパレータ用
        preservesSuperviewLayoutMargins = false
        separatorInset = .zero
        layoutMargins = .zero
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarView.image = UIImage(systemName: "person.crop.circle.fill")
        nameLabel.text = nil
        idLabel.text = nil
        extraLabel.text = nil
        pinBadge.isHidden = true
    }

    func configure(name: String, id: String, image: UIImage?, pinned: Bool, extraText: String?) {
        nameLabel.text = name
        idLabel.text = "@\(id)"

        if let t = extraText, !t.isEmpty {
            extraLabel.text = t
            extraLabel.isHidden = false
        } else {
            extraLabel.text = nil
            extraLabel.isHidden = true
        }

        pinBadge.isHidden = !pinned
        avatarView.image = image ?? UIImage(systemName: "person.crop.circle.fill")
    }
}

// MARK: - Self Header Cell（ユーザー表示を少し大きく + URL頑健化）
final class SelfHeaderCell: UITableViewCell {
    static let reuseID = "SelfHeaderCell"

    private let avatarView = UIImageView()
    private let nameLabel = UILabel()
    private let subLabel = UILabel()
    private var currentURL: String?

    // 簡易キャッシュ
    private static var cache: [String: UIImage] = [:]

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        accessoryType = .disclosureIndicator
        selectionStyle = .default

        backgroundColor = .clear
        contentView.backgroundColor = .clear
        if #available(iOS 14.0, *) { backgroundConfiguration = UIBackgroundConfiguration.clear() }

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = 36
        avatarView.backgroundColor = .secondarySystemFill
        avatarView.image = UIImage(systemName: "person.crop.circle.fill")

        nameLabel.font = .systemFont(ofSize: 22, weight: .bold)
        subLabel.font = .systemFont(ofSize: 14, weight: .medium)
        subLabel.textColor = .secondaryLabel
        subLabel.numberOfLines = 1

        let vStack = UIStackView(arrangedSubviews: [nameLabel, subLabel])
        vStack.axis = .vertical
        vStack.spacing = 5
        vStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(avatarView)
        contentView.addSubview(vStack)

        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 72),
            avatarView.heightAnchor.constraint(equalToConstant: 72),

            vStack.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 14),
            vStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            vStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])

        let sel = UIView()
        sel.backgroundColor = UIColor.secondarySystemFill
        sel.layer.cornerRadius = 14
        selectedBackgroundView = sel
    }

    func configure(name: String, subtitle: String, photoURL: String?) {
        nameLabel.text = name.isEmpty ? "プロフィール" : name
        subLabel.text = subtitle
        loadImage(urlString: photoURL)
    }

    static func safeURL(from raw: String) -> URL? {
        if let u = URL(string: raw) { return u }
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
        if let encoded, let u = URL(string: encoded) { return u }
        return nil
    }

    private func loadImage(urlString: String?) {
        currentURL = urlString

        guard let s = urlString, let url = SelfHeaderCell.safeURL(from: s) else {
            avatarView.image = UIImage(systemName: "person.crop.circle.fill")
            return
        }

        if let cached = SelfHeaderCell.cache[s] {
            avatarView.image = cached
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self else { return }
            guard self.currentURL == urlString else { return }
            guard let data, let img = UIImage(data: data) else { return }
            SelfHeaderCell.cache[s] = img
            DispatchQueue.main.async { self.avatarView.image = img }
        }.resume()
    }
}
