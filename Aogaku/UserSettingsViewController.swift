import UIKit
import PhotosUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import GoogleMobileAds

// ===== AdMob helper =====
@inline(__always)
private func makeAdaptiveAdSize(width: CGFloat) -> AdSize {
    return currentOrientationAnchoredAdaptiveBanner(width: width)
}

// ===== 自分用アイコンキャッシュ（メモリ＋ディスク、バージョン管理） =====
private final class SelfAvatarCache {
    static let shared = SelfAvatarCache()
    private let mem = NSCache<NSString, UIImage>()
    private let fm = FileManager.default
    private let dir: URL

    private init() {
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        dir = base.appendingPathComponent("avatar-cache", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func fileURL(uid: String, version: Int) -> URL {
        dir.appendingPathComponent("\(uid)_v\(version).jpg")
    }

    func image(uid: String, version: Int) -> UIImage? {
        let key = "\(uid)#\(version)" as NSString
        if let img = mem.object(forKey: key) { return img }
        let url = fileURL(uid: uid, version: version)
        guard let data = try? Data(contentsOf: url),
              let img = UIImage(data: data) else { return nil }
        mem.setObject(img, forKey: key)
        return img
    }

    func latestVersion(for uid: String) -> Int? {
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        let prefix = "\(uid)_v"
        let versions = files.compactMap { url -> Int? in
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(".jpg") else { return nil }
            let vStr = name.dropFirst(prefix.count).dropLast(4) // remove ".jpg"
            return Int(vStr)
        }
        return versions.max()
    }

    func latestImage(uid: String) -> (image: UIImage, version: Int)? {
        guard let ver = latestVersion(for: uid),
              let img = image(uid: uid, version: ver) else { return nil }
        return (img, ver)
    }

    func store(_ image: UIImage, uid: String, version: Int) {
        let key = "\(uid)#\(version)" as NSString
        mem.setObject(image, forKey: key)
        let url = fileURL(uid: uid, version: version)
        if let data = image.jpegData(compressionQuality: 0.9) {
            let tmp = url.appendingPathExtension("tmp")
            try? data.write(to: tmp, options: .atomic)
            try? fm.removeItem(at: url)
            try? fm.moveItem(at: tmp, to: url)
        }
        purgeOldVersions(of: uid, keep: version)
    }

    private func purgeOldVersions(of uid: String, keep version: Int) {
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files {
            let name = f.lastPathComponent
            if name.hasPrefix("\(uid)_v"),
               name.hasSuffix(".jpg"),
               !name.contains("_v\(version).jpg") {
                try? fm.removeItem(at: f)
            }
        }
    }

    // photoURL から簡易バージョン推定（avatarVersion が無い場合のフォールバック）
    func versionFrom(urlString: String?) -> Int? {
        guard let s = urlString, let u = URL(string: s) else { return nil }
        if let q = u.query, !q.isEmpty { return abs(q.hashValue) }
        return abs(u.lastPathComponent.hashValue)
    }
}

// ===== 画像取得（URLSession） =====
private enum ImageFetcher {
    static func fetch(urlString: String, completion: @escaping (UIImage?) -> Void) {
        guard let url = URL(string: urlString) else { completion(nil); return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let d = data, let img = UIImage(data: d) else { completion(nil); return }
            completion(img)
        }.resume()
    }
}

// MARK: - Main VC
final class UserSettingsViewController: UIViewController, SideMenuDrawerDelegate, BannerViewDelegate {

    // MARK: UI（アイコンのみ・カメラボタン削除）
    private let avatarView = UIImageView()

    // Profile Fields
    private let gradeField = UITextField()
    private let facultyDeptField = UITextField()

    private let nameTitle = UILabel()
    private let nameField = UITextField()

    private let idTitle = UILabel()
    private let idField = UITextField()

    private let stack = UIStackView()

    // Pickers
    private let gradePicker = UIPickerView()
    private let facultyDeptPicker = UIPickerView()
    private let gradeOptions = ["1年","2年","3年","4年"]

    // AdMob (Banner)
    private let adContainer = UIView()
    private var bannerView: BannerView?
    private var lastBannerWidth: CGFloat = 0
    private var adContainerHeight: NSLayoutConstraint?
    private var didLoadBannerOnce = false
    private var stackBottomToSafeArea: NSLayoutConstraint?
    private var stackBottomToAdTop: NSLayoutConstraint?

    // Faculty data
    private let FACULTY_DATA: [String: [String]] = [
        "文学部": ["英米文学科","フランス文学科","日本文学科","史学科","比較芸術学科"],
        "教育人間科学部": ["教育学科","心理学科"],
        "経済学部": ["経済学科","現代経済デザイン学科"],
        "法学部": ["法学科","ヒューマンライツ学科"],
        "経営学部": ["経営学科","マーケティング学科"],
        "国際政治経済学部": ["国際政治学科","国際経済学科","国際コミュニケーション学科"],
        "総合文化政策学部": ["総合文化政策学科"],
        "理工学部": ["物理科学科","数理サイエンス学科","化学・生命科学科","電気電子工学科","機械創造工学科","経営システム工学科","情報テクノロジー学科"],
        "コミュニティ人間科学部": ["コミュニティ人間科学科"],
        "社会情報学部": ["社会情報学科"],
        "地球社会共生学部": ["地球社会共生学科"],
    ]
    private var facultyNames: [String] { FACULTY_DATA.keys.sorted() }
    private var selectedFacultyIndex = 0
    private var selectedDepartmentIndex = 0

    // Firebase
    private let db = Firestore.firestore()
    private var uid: String? { Auth.auth().currentUser?.uid }
    private var currentAvatarVersion: Int?

    // MARK: - Menu
    @objc @IBAction func didTapMenuButton(_ sender: Any) {
        let vc = SideMenuDrawerViewController()
        vc.modalPresentationStyle = .overFullScreen
        vc.modalTransitionStyle = .crossDissolve
        vc.delegate = self
        present(vc, animated: false)
    }

    // MARK: - LifeCycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        setupAvatarUI()
        setupProfileUI()
        setupNavMenuButtonIfNeeded()
        setupDismissKeyboardGesture()

        // まずはローカルキャッシュを即表示（通信なし）
        if let uid = uid, let cached = SelfAvatarCache.shared.latestImage(uid: uid) {
            avatarView.image = cached.image
            currentAvatarVersion = cached.version
        }

        // 次にプロフィールを読み込み（avatarVersion 確定→必要時のみDL）
        loadUserProfile()

        // 最後に広告（これ以降で stack の下端制約を adContainer に付け替える）
        setupAdBanner()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        loadBannerIfNeeded()
    }

    // MARK: - AdMob
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

        // ここで SafeArea → adContainer に付け替え
        stackBottomToSafeArea?.isActive = false
        stackBottomToAdTop = stack.bottomAnchor.constraint(lessThanOrEqualTo: adContainer.topAnchor, constant: -24)
        stackBottomToAdTop?.isActive = true

        let bv = BannerView()
        bv.translatesAutoresizingMaskIntoConstraints = false
        bv.adUnitID = "ca-app-pub-3940256099942544/2934735716"   // テストID
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
        self.bannerView = bv
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

    // BannerViewDelegate
    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        let h = bannerView.adSize.size.height
        adContainerHeight?.constant = h
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
    }
    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        adContainerHeight?.constant = 0
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
    }

    // MARK: - UI
    private func setupNavMenuButtonIfNeeded() {
        if navigationItem.rightBarButtonItem == nil {
            let img = UIImage(
                systemName: "line.3.horizontal",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            )
            let b = UIButton(type: .system)
            b.setImage(img, for: .normal)
            b.tintColor = .label
            b.addTarget(self, action: #selector(didTapMenuButton(_:)), for: .touchUpInside)
            b.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: 34),
                b.heightAnchor.constraint(equalToConstant: 34)
            ])
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: b)
        }
    }

    private func setupAvatarUI() {
        avatarView.image = UIImage(systemName: "person.circle.fill")
        avatarView.tintColor = .tertiaryLabel
        avatarView.contentMode = .scaleAspectFill
        avatarView.backgroundColor = .secondarySystemFill
        avatarView.clipsToBounds = true
        avatarView.isUserInteractionEnabled = true
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(avatarView)

        // アイコンは中央寄り（上の余白を少し広げる）
        NSLayoutConstraint.activate([
            avatarView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            avatarView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 140),
            avatarView.heightAnchor.constraint(equalTo: avatarView.widthAnchor)
        ])
        view.layoutIfNeeded()
        avatarView.layer.cornerRadius = 70

        // アイコンタップで変更（カメラボタンは廃止）
        let tap = UITapGestureRecognizer(target: self, action: #selector(selectAvatar))
        avatarView.addGestureRecognizer(tap)
    }

    private func setupProfileUI() {
        func doneToolbar(_ selector: Selector) -> UIToolbar {
            let tb = UIToolbar()
            tb.sizeToFit()
            tb.items = [
                UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                UIBarButtonItem(title: "完了", style: .done, target: self, action: selector)
            ]
            return tb
        }

        // 学年（短く）
        gradeField.attributedPlaceholder = NSAttributedString(
            string: "学年",
            attributes: [.foregroundColor: UIColor.placeholderText]
        )
        gradeField.borderStyle = .roundedRect
        gradeField.inputView = gradePicker
        gradeField.inputAccessoryView = doneToolbar(#selector(endEditingFields))
        gradePicker.dataSource = self
        gradePicker.delegate = self

        // 学部・学科（長く）
        facultyDeptField.attributedPlaceholder = NSAttributedString(
            string: "学部・学科",
            attributes: [.foregroundColor: UIColor.placeholderText]
        )
        facultyDeptField.borderStyle = .roundedRect
        facultyDeptField.inputView = facultyDeptPicker
        facultyDeptField.inputAccessoryView = doneToolbar(#selector(endEditingFields))
        facultyDeptPicker.dataSource = self
        facultyDeptPicker.delegate = self

        nameTitle.text = "名前"
        nameTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        nameField.placeholder = "未設定"
        nameField.borderStyle = .none
        nameField.clearButtonMode = .whileEditing
        nameField.inputAccessoryView = doneToolbar(#selector(commitName))
        nameField.addTarget(self, action: #selector(nameEditingChanged), for: .editingChanged)

        idTitle.text = "ID"
        idTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        idField.borderStyle = .none
        idField.isEnabled = false
        idField.textColor = .secondaryLabel

        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        // 1行目：学年（短）+ 学部学科（長）
        let row1 = UIStackView(arrangedSubviews: [gradeField, facultyDeptField])
        row1.axis = .horizontal
        row1.alignment = .fill
        row1.distribution = .fill
        row1.spacing = 12

        // 比率: grade : facultyDept ≈ 0.375 : 0.625
        let ratio = gradeField.widthAnchor.constraint(equalTo: facultyDeptField.widthAnchor, multiplier: 0.6)
        ratio.priority = .required
        ratio.isActive = true

        let nameStack = UIStackView()
        nameStack.axis = .vertical
        nameStack.spacing = 8
        nameStack.addArrangedSubview(nameTitle)
        nameStack.addArrangedSubview(underlineWrap(nameField))

        let idStack = UIStackView()
        idStack.axis = .vertical
        idStack.spacing = 8
        idStack.addArrangedSubview(idTitle)
        idStack.addArrangedSubview(underlineWrap(idField))

        [row1, nameStack, idStack].forEach { stack.addArrangedSubview($0) }

        // ★ 初期は SafeArea への下端制約のみ（adContainer 生成後に付け替える）
        stackBottomToSafeArea = stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
        stackBottomToSafeArea?.isActive = true

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            gradeField.heightAnchor.constraint(equalToConstant: 44),
            facultyDeptField.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    private func underlineWrap(_ field: UITextField) -> UIView {
        let container = UIView()
        field.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field)

        let line = UIView()
        line.backgroundColor = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)

        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: container.topAnchor),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            line.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            line.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    // MARK: - Load existing profile
    private func loadUserProfile() {
        guard let uid else { return }
        db.collection("users").document(uid).getDocument { [weak self] snap, _ in
            guard let self else { return }
            let data = snap?.data() ?? [:]

            DispatchQueue.main.async {
                // 学年
                if let grade = data["grade"] as? Int, (1...4).contains(grade) {
                    self.gradeField.text = "\(grade)年"
                    self.gradePicker.selectRow(grade - 1, inComponent: 0, animated: false)
                }

                // 学部・学科
                let faculty = data["faculty"] as? String ?? ""
                let dept = data["department"] as? String ?? ""
                if !faculty.isEmpty {
                    self.facultyDeptField.text = dept.isEmpty ? faculty : "\(faculty)・\(dept)"
                    if let idx = self.facultyNames.firstIndex(of: faculty) {
                        self.selectedFacultyIndex = idx
                        self.facultyDeptPicker.reloadAllComponents()
                        if let dlist = self.FACULTY_DATA[faculty],
                           let didx = dlist.firstIndex(of: dept) {
                            self.selectedDepartmentIndex = didx
                            self.facultyDeptPicker.selectRow(idx, inComponent: 0, animated: false)
                            self.facultyDeptPicker.selectRow(didx, inComponent: 1, animated: false)
                        }
                    }
                }

                // 名前
                if let name = data["name"] as? String, !name.isEmpty {
                    self.nameField.text = name
                } else {
                    self.nameField.text = nil
                }

                // ID
                if let id = data["id"] as? String {
                    self.idField.text = id
                } else if let disp = Auth.auth().currentUser?.displayName {
                    self.idField.text = disp
                }
            }

            // アイコン（avatarVersion を見て必要時のみDL）
            let url  = data["photoURL"] as? String
            let verRaw = (data["avatarVersion"] as? Int) ?? (data["photoVersion"] as? Int)
            let ver = verRaw ?? SelfAvatarCache.shared.versionFrom(urlString: url)
            self.currentAvatarVersion = ver

            if let uid = self.uid {
                if let ver = ver, let img = SelfAvatarCache.shared.image(uid: uid, version: ver) {
                    DispatchQueue.main.async { self.avatarView.image = img }
                } else if let url = url {
                    ImageFetcher.fetch(urlString: url) { img in
                        guard let img = img else { return }
                        let v = ver ?? 0
                        SelfAvatarCache.shared.store(img, uid: uid, version: v)
                        DispatchQueue.main.async { self.avatarView.image = img }
                    }
                }
            }
        }
    }

    // MARK: - Save handlers
    @objc private func endEditingFields() { view.endEditing(true) }
    @objc private func nameEditingChanged() { /* no-op */ }

    @objc private func commitName() {
        view.endEditing(true)
        guard let uid, let text = nameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        db.collection("users").document(uid).setData(["name": text], merge: true)
        if let user = Auth.auth().currentUser {
            let req = user.createProfileChangeRequest()
            req.displayName = text.isEmpty ? user.displayName : text
            req.commitChanges(completion: nil)
        }
    }

    private func updateGrade(_ grade: Int) {
        guard let uid else { return }
        db.collection("users").document(uid).setData(["grade": grade], merge: true)
    }

    private func updateFacultyDept(faculty: String, department: String) {
        guard let uid else { return }
        db.collection("users").document(uid).setData([
            "faculty": faculty,
            "department": department
        ], merge: true)
    }

    // MARK: - Avatar load/upload
    @objc private func selectAvatar() {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func uploadAvatar(_ image: UIImage) {
        guard let uid = self.uid else {
            showAlert(title: "ログインが必要です", message: "先にログインしてください。")
            return
        }

        // 即時UI反映（通信前）
        self.avatarView.image = image

        // Storage
        let ref = Storage.storage().reference(withPath: "avatars/\(uid).jpg")
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            showAlert(title: "エラー", message: "画像の変換に失敗しました。")
            return
        }

        let indicator = UIActivityIndicatorView(style: .large)
        indicator.startAnimating()
        indicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor)
        ])

        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        ref.putData(data, metadata: metadata) { [weak self] _, error in
            guard let self else { return }
            indicator.removeFromSuperview()
            if let error = error {
                self.showAlert(title: "アップロード失敗", message: error.localizedDescription)
                return
            }
            ref.downloadURL { url, error in
                if let error = error {
                    self.showAlert(title: "URL取得失敗", message: error.localizedDescription)
                    return
                }
                guard let url else { return }

                // Firestore を更新（avatarVersion インクリメント）
                self.db.collection("users").document(uid).setData([
                    "photoURL": url.absoluteString,
                    "photoUpdatedAt": FieldValue.serverTimestamp(),
                    "avatarVersion": FieldValue.increment(Int64(1))
                ], merge: true)

                // 予測版（現行 + 1）でキャッシュ保存して即時反映
                let newVersion = (self.currentAvatarVersion ?? (SelfAvatarCache.shared.latestVersion(for: uid) ?? 0)) + 1
                SelfAvatarCache.shared.store(image, uid: uid, version: newVersion)
                self.currentAvatarVersion = newVersion

                // Auth プロフィール（任意）
                if let user = Auth.auth().currentUser {
                    let change = user.createProfileChangeRequest()
                    change.photoURL = url
                    change.commitChanges(completion: nil)
                }
            }
        }
    }

    // MARK: - SideMenuDrawerDelegate
    func sideMenuDidSelectLogout() {
        let ac = UIAlertController(title: "ログアウトしますか？",
                                   message: "現在のアカウントからサインアウトします。",
                                   preferredStyle: .actionSheet)
        ac.addAction(UIAlertAction(title: "ログアウト", style: .destructive, handler: { _ in
            self.performSignOut()
        }))
        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        present(ac, animated: true)
    }

    func sideMenuDidSelectDeleteAccount() {
        let ac = UIAlertController(title: "アカウントを削除しますか？",
                                   message: "アカウントと関連データ（ユーザー情報・ID予約・アイコン画像）を削除します。この操作は取り消せません。",
                                   preferredStyle: .actionSheet)
        ac.addAction(UIAlertAction(title: "アカウント削除", style: .destructive, handler: { _ in
            self.performDeleteAccount()
        }))
        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        present(ac, animated: true)
    }

    func sideMenuDidSelectContact() { /* TODO */ }
    func sideMenuDidSelectTerms()   { /* TODO */ }
    func sideMenuDidSelectPrivacy() { /* TODO */ }
    func sideMenuDidSelectFAQ()     { /* TODO */ }

    // MARK: - Auth ops
    private func performSignOut() {
        do {
            try Auth.auth().signOut()
        } catch {
            showAlert(title: "ログアウトに失敗", message: error.localizedDescription)
            return
        }
        tabBarController?.selectedIndex = 2
    }

    private func performDeleteAccount() {
        guard let user = Auth.auth().currentUser else {
            tabBarController?.selectedIndex = 2
            return
        }
        let uid = user.uid
        let idLower = (user.displayName ?? "").lowercased()
        let storageRef = Storage.storage().reference(withPath: "avatars/\(uid).jpg")

        Task {
            // Firestore クリーンアップ
            do {
                let batch = db.batch()
                if !idLower.isEmpty {
                    batch.deleteDocument(db.collection("usernames").document(idLower))
                }
                batch.deleteDocument(db.collection("users").document(uid))
                try await batch.commit()
            } catch {
                print("⚠️ Firestore cleanup failed:", error.localizedDescription)
            }

            // 画像も削除
            storageRef.delete(completion: { _ in })

            // Auth 削除
            do {
                try await user.delete()
                await MainActor.run { self.tabBarController?.selectedIndex = 2 }
            } catch {
                let ns = error as NSError
                if ns.domain == AuthErrorDomain,
                   ns.code == AuthErrorCode.requiresRecentLogin.rawValue {
                    await MainActor.run {
                        self.showAlert(
                            title: "再ログインが必要です",
                            message: "安全のため、アカウント削除には再ログインが必要です。もう一度ログイン後に削除をお試しください。"
                        )
                        self.performSignOut()
                    }
                } else {
                    await MainActor.run {
                        self.showAlert(title: "アカウント削除に失敗", message: error.localizedDescription)
                    }
                }
            }
        }
    }

    // MARK: - Utils
    private func setupDismissKeyboardGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(endEditingFields))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    private func showAlert(title: String, message: String) {
        let ac = UIAlertController(title: title, message: message, preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "OK", style: .default))
        present(ac, animated: true)
    }
}

// MARK: - PHPicker Delegate
extension UserSettingsViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }
        if provider.canLoadObject(ofClass: UIImage.self) {
            provider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
                guard let self, let image = object as? UIImage, error == nil else { return }
                DispatchQueue.main.async { self.uploadAvatar(image) }
            }
        }
    }
}

// MARK: - UIPickerView DataSource/Delegate
extension UserSettingsViewController: UIPickerViewDataSource, UIPickerViewDelegate {
    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        if pickerView === gradePicker { return 1 }
        return 2 // faculty & department
    }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        if pickerView === gradePicker { return gradeOptions.count }
        if component == 0 { return facultyNames.count }
        let faculty = facultyNames[safe: selectedFacultyIndex] ?? facultyNames.first ?? ""
        return FACULTY_DATA[faculty]?.count ?? 0
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        if pickerView === gradePicker { return gradeOptions[row] }
        if component == 0 { return facultyNames[row] }
        let faculty = facultyNames[safe: selectedFacultyIndex] ?? facultyNames.first ?? ""
        return FACULTY_DATA[faculty]?[row] ?? ""
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        if pickerView === gradePicker {
            let text = gradeOptions[row]
            gradeField.text = text
            let grade = max(1, min(4, Int(text.replacingOccurrences(of: "年", with: "")) ?? 1))
            updateGrade(grade)
            return
        }
        if component == 0 {
            selectedFacultyIndex = row
            selectedDepartmentIndex = 0
            pickerView.reloadComponent(1)
            pickerView.selectRow(0, inComponent: 1, animated: false)
        } else {
            selectedDepartmentIndex = row
        }
        let faculty = facultyNames[safe: selectedFacultyIndex] ?? ""
        let department = FACULTY_DATA[faculty]?[safe: selectedDepartmentIndex] ?? ""
        facultyDeptField.text = department.isEmpty ? faculty : "\(faculty)・\(department)"
        updateFacultyDept(faculty: faculty, department: department)
    }
}

// 安全添字
private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
