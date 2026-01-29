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
            // ✅ 少し詰める
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
        tableView.separatorStyle = .none
        tableView.register(SelfHeaderCell.self, forCellReuseIdentifier: SelfHeaderCell.reuseID)
        tableView.register(FriendListCell.self, forCellReuseIdentifier: FriendListCell.reuseID)

        if #available(iOS 15.0, *) {
            tableView.sectionHeaderTopPadding = 0
        }

        view.addSubview(tableView)

        // ✅ topBarの下から少しだけ上に寄せる（空白詰め）
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
        // iOSの自動余白が強い端末で少しだけ詰める
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

            // FirestoreにphotoURLが無ければ補完（次回から確実に反映）
            if (fsURL == nil || fsURL == ""), let authURL, !authURL.isEmpty {
                self.db.collection("users").document(uid).setData(["photoURL": authURL], merge: true)
            }
        }
    }

    // MARK: - Load friends
    private func reloadFriends() {
        FriendService.shared.fetchFriends { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let list): self.friends = list
            case .failure: self.friends = []
            }
            DispatchQueue.main.async { self.tableView.reloadData() }
        }
    }

    @objc private func handleFriendsDidChange() {
        guard ensureLoggedInOrRedirect() else { return }
        reloadFriends()
    }

    // MARK: - Table
    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : friends.count
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        // ✅ 自分セルを少し大きく
        indexPath.section == 0 ? 104 : 84
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? "友だち" : nil
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
            return cell
        }

        let f = friends[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: FriendListCell.reuseID, for: indexPath) as! FriendListCell
        let fallbackName = f.friendName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "@\(f.friendId)" : f.friendName

        cell.accessibilityIdentifier = f.friendUid

        let cachedImg = friendAvatarCache[f.friendUid]
        cell.configure(name: fallbackName, id: f.friendId, image: cachedImg, pinned: false, extraText: nil)

        if cachedImg == nil {
            loadFriendAvatarIfNeeded(friendUid: f.friendUid) { [weak self, weak cell] img in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard let cell else { return }
                    guard cell.accessibilityIdentifier == f.friendUid else { return }
                    if let img {
                        cell.configure(name: fallbackName, id: f.friendId, image: img, pinned: false, extraText: nil)
                    }
                }
            }
        }

        if #available(iOS 14.0, *) { cell.backgroundConfiguration = UIBackgroundConfiguration.clear() }
        cell.contentView.backgroundColor = .clear
        cell.backgroundColor = .clear

        return cell
    }

    // ✅ 横線：自分セル(section0)は出さない
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        let tag = 778899
        cell.contentView.viewWithTag(tag)?.removeFromSuperview()

        // ✅ 自分の下の線は消す
        guard indexPath.section == 1 else { return }

        let line = UIView()
        line.tag = tag
        line.translatesAutoresizingMaskIntoConstraints = false
        line.backgroundColor = UIColor.systemGray3.withAlphaComponent(0.85)

        cell.contentView.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 18),
            line.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -18),
            line.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 2.0)
        ])

        if indexPath.row == friends.count - 1 {
            line.isHidden = true
        }
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
        // ✅ 少し大きく
        avatarView.layer.cornerRadius = 36
        avatarView.backgroundColor = .secondarySystemFill
        avatarView.image = UIImage(systemName: "person.crop.circle.fill")

        // ✅ 少し大きく
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
            // ✅ 少し大きく
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
