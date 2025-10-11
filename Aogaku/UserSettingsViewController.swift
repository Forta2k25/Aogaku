import UIKit
import PhotosUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import GoogleMobileAds
import FirebaseFunctions
import SafariServices
import FirebaseRemoteConfig


// ===== AdMob helper =====
@inline(__always)
private func makeAdaptiveAdSize(width: CGFloat) -> AdSize {
    return currentOrientationAnchoredAdaptiveBanner(width: width)
}

// ===== Ad configuration (Remote Config + test devices) =====
enum AdsConfig {
    private static let rc = RemoteConfig.remoteConfig()

    static func bootstrap() {
        // AdMobのstart/testDeviceはAppDelegateで実行する想定
        rc.setDefaults([
            "ads_enabled": true as NSObject,
            "ads_live": false as NSObject,
            "ads_banner_id_test": "ca-app-pub-3940256099942544/2934735716" as NSObject,
            "ads_banner_id_prod": "" as NSObject
        ])
        rc.fetchAndActivate { _, _ in
            NotificationCenter.default.post(name: .adMobReady, object: nil)
        }
    }




    static var enabled: Bool { rc["ads_enabled"].boolValue }

    static var bannerUnitID: String {
        let isLive = rc["ads_live"].boolValue
        if isLive {
            let s = rc["ads_banner_id_prod"].stringValue ?? ""
            return s.isEmpty ? (rc["ads_banner_id_test"].stringValue ?? "ca-app-pub-3940256099942544/2934735716") : s
        } else {
            return rc["ads_banner_id_test"].stringValue ?? "ca-app-pub-3940256099942544/2934735716"
        }
    }
}

extension Notification.Name {
    static let shouldPromptInitialAvatar = Notification.Name("ShouldPromptInitialAvatar")
}

// ===== 自分用アイコンキャッシュ（メモリ＋ディスク、バージョン管理） =====
private final class SelfAvatarCache {

    static let shared = SelfAvatarCache()
    private let mem = NSCache<NSString, UIImage>()
    private let fm = FileManager.default
    private let dir: URL
    private let kLocalProfileDraft = "LocalProfileDraftV1"

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
            let vStr = name.dropFirst(prefix.count).dropLast(4)
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

    // 設定タブのインデックス（必要なら調整）
    private let settingsTabIndex = 4
    
    // 初回アバタープロンプト用キー
    private let kShouldPromptInitialAvatar = "ShouldPromptInitialAvatarV1"

    // この画面での一時フラグ
    private var pendingShowPostUploadTip = false       // 「はい」→設定完了後に案内を出すか
    private var didCheckInitialAvatarPrompt = false    // viewDidAppearでの多重表示ガード

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
    private let gradeOptions = ["1年","2年","3年","4年","指定なし"]
    private let noneLabel = "指定なし"

    // AdMob (Banner)
    private let adContainer = UIView()
    private var bannerView: BannerView?
    private var lastBannerWidth: CGFloat = 0
    private var adContainerHeight: NSLayoutConstraint?
    private var didLoadBannerOnce = false
    private var stackBottomToSafeArea: NSLayoutConstraint?
    private var stackBottomToAdTop: NSLayoutConstraint?
    private var initialPromptQueued = false
    private var authListenerHandle: AuthStateDidChangeListenerHandle?
    private var initialPromptNotBefore = Date.distantPast

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
    private lazy var functions = Functions.functions(region: "asia-northeast1")
    
    // 画面の一番下あたりに追加（クラス内のどこでもOK）
    private func appBackgroundColor(for traits: UITraitCollection) -> UIColor {
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.20, alpha: 1.0) : .systemGroupedBackground
    }
    private func cardBackgroundColor(for traits: UITraitCollection) -> UIColor {
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.16, alpha: 1.0) : .secondarySystemBackground
    }
    private func applyBackgroundStyle() {
        let bg = appBackgroundColor(for: traitCollection)
        view.backgroundColor = bg
        adContainer.backgroundColor = bg

        let fieldBG = cardBackgroundColor(for: traitCollection)
        [gradeField, facultyDeptField].forEach {
            $0.backgroundColor = fieldBG      // ピッカー用の2つのテキスト欄を少し明るいグレーに
        }
    }


 
    // MARK: - Menu
    @objc @IBAction func didTapMenuButton(_ sender: Any) {
        let vc = SideMenuDrawerViewController()
        vc.modalPresentationStyle = .overFullScreen
        // vc.modalTransitionStyle = .crossDissolve // ← 削ってOK
        vc.delegate = self
        present(vc, animated: false)
    }
/*
    // ===== Instagram: メニュー右下ボタンを後付け =====
    private func attachInstagramButton(to menuVC: UIViewController?) {
        guard let menuVC else { return }
        let tag = 9901
        if menuVC.view.viewWithTag(tag) != nil { return }

        let b = UIButton(type: .system)
        b.tag = tag
        b.translatesAutoresizingMaskIntoConstraints = false
        if let img = UIImage(named: "instagram") {
            b.setImage(img.withRenderingMode(.alwaysOriginal), for: .normal)
            b.tintColor = nil
        } else {
            b.setImage(UIImage(systemName: "camera.viewfinder"), for: .normal)
            b.tintColor = .label
        }
        b.contentEdgeInsets = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        b.accessibilityLabel = "Instagram を開く"

        b.addAction(UIAction { [weak self, weak menuVC] _ in
            menuVC?.dismiss(animated: true) { [weak self] in
                self?.openInstagramProfile()
            }
        }, for: .touchUpInside)

        menuVC.view.addSubview(b)
        NSLayoutConstraint.activate([
            b.trailingAnchor.constraint(equalTo: menuVC.view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            b.bottomAnchor.constraint(equalTo: menuVC.view.safeAreaLayoutGuide.bottomAnchor, constant: -32), // 12→32（+20）
            b.widthAnchor.constraint(equalToConstant: 48), // 36→48
            b.heightAnchor.constraint(equalTo: b.widthAnchor)
        ])
    }

    private func openInstagramProfile() {
        let appURL = URL(string: "instagram://user?username=aogaku.hack")!
        if UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL)
            return
        }
        let webURL = URL(string: "https://www.instagram.com/aogaku.hack/")!
        let safari = SFSafariViewController(url: webURL)
        safari.preferredControlTintColor = .systemBlue
        if let presented = self.presentedViewController {
            presented.dismiss(animated: false) { [weak self] in self?.present(safari, animated: true) }
        } else {
            present(safari, animated: true)
        }
    }

*/

    // MARK: - LifeCycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        
#if DEBUG
let tripleTap = UITapGestureRecognizer(target: self, action: #selector(openAdInspector))
tripleTap.numberOfTapsRequired = 3
view.addGestureRecognizer(tripleTap)
#endif

        setupAvatarUI()
        setupProfileUI()
        setupNavMenuButtonIfNeeded()
        setupDismissKeyboardGesture()

        if let uid = uid, let cached = SelfAvatarCache.shared.latestImage(uid: uid) {
            avatarView.image = cached.image
            currentAvatarVersion = cached.version
        }

        // ★ 追加：ローカル下書きを即時表示
        applyLocalProfileDraftIfAny()

        // 既存:
        loadUserProfile()
        setupAdBanner()
        // Remote Config 反映完了を待ってから読み込む
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onAdsConfigReady),
            name: .adMobReady,
            object: nil
        )
        applyBackgroundStyle()
        
        NotificationCenter.default.addObserver(self,
            selector: #selector(onShouldPromptInitialAvatar),
            name: .shouldPromptInitialAvatar,
            object: nil)

    }
    
    @objc private func onShouldPromptInitialAvatar() {
        // 遷移直後はUIや認証がまだ動いているので、0.0秒後に再評価して出す
        initialPromptNotBefore = Date().addingTimeInterval(0.0)
        presentInitialAvatarPromptIfNeeded()
    }
    
#if DEBUG
@objc private func openAdInspector() {
    MobileAds.shared.presentAdInspector(from: self) { error in
        print("AdInspector:", error?.localizedDescription ?? "opened")
    }
}
#endif

    @objc private func onAdsConfigReady() {
        guard let bv = bannerView else { return }
        bv.adUnitID = AdsConfig.bannerUnitID   // RCのads_live/ads_banner_id_*で自動切替
        didLoadBannerOnce = false
        loadBannerIfNeeded()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 初回だけ他タブに飛ばされるのを防ぐ：常に設定タブ(index=4)へ
        if let tbc = tabBarController, tbc.selectedIndex != settingsTabIndex {
            tbc.selectedIndex = settingsTabIndex
        }
        // ★ 追加：未表示の項目があればローカル下書きを即適用し、0.35秒だけカバーを出す
        if (idField.text?.isEmpty ?? true) ||
           (gradeField.text?.isEmpty ?? true) ||
           (facultyDeptField.text?.isEmpty ?? true) {
            setLoading(true)                // 既存のローディングカバー
            applyLocalProfileDraftIfAny()   // ★ ローカル → 即表示
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.setLoading(false)     // Firestoreが遅れても一旦閉じる（その後はloadUserProfileで上書き）
            }
        }

    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        loadBannerIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        AppGatekeeper.shared.checkAndPresentIfNeeded(on: self)
        reloadAllProfileFieldsIfIDMissing()

        // 画面安定まで待つ（例：0.0秒）
        initialPromptNotBefore = Date().addingTimeInterval(0.0)

        // 次のランループでキック（以降の判定はメソッド内）
        DispatchQueue.main.async { [weak self] in
            self?.presentInitialAvatarPromptIfNeeded()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyBackgroundStyle()
        }
    }
    // ▼ 追加：UID別に「初回アラートは既に表示済みか？」を保持
    private func hasShownInitialAvatarPrompt(uid: String) -> Bool {
        UserDefaults.standard.bool(forKey: "InitialAvatarPromptShown.\(uid)")
    }

    private func markShownInitialAvatarPrompt(uid: String) {
        UserDefaults.standard.set(true, forKey: "InitialAvatarPromptShown.\(uid)")
        // 任意：サーバー側にも刻んでおくと端末を跨いでも二重表示しない
        if !uid.isEmpty {
            db.collection("users").document(uid)
                .setData(["initialAvatarPromptShown": true], merge: true)
        }
    }

    private func presentInitialAvatarPromptIfNeeded() {
        // 二重起動ガード
        guard !initialPromptQueued else { return }

        // サインアップ直後に立てたグローバルフラグが OFF なら出さない
        let shouldGlobal = UserDefaults.standard.bool(forKey: kShouldPromptInitialAvatar)
        guard shouldGlobal else { return }

        // 画面安定まで待つ（viewDidAppear で設定した時刻を尊重）
        let now = Date()
        if now < initialPromptNotBefore {
            let delay = initialPromptNotBefore.timeIntervalSince(now) + 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.presentInitialAvatarPromptIfNeeded()
            }
            return
        }

        // uid がまだ取得できていない場合は、認証状態変化を待って再試行
        guard let uid = self.uid, !uid.isEmpty else {
            if authListenerHandle == nil {
                authListenerHandle = Auth.auth().addStateDidChangeListener { [weak self] _, _ in
                    self?.presentInitialAvatarPromptIfNeeded()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.presentInitialAvatarPromptIfNeeded()
            }
            return
        }

        // 既にこの uid で提示済みなら出さない
        guard !hasShownInitialAvatarPrompt(uid: uid) else { return }

        // UIAlertController を組み立て
        let ac = UIAlertController(
            title: "アイコンを設定しますか？",
            message: "設定された画像は他の人にも表示されます。",
            preferredStyle: .alert
        )
        ac.addAction(UIAlertAction(title: "いいえ", style: .cancel, handler: { [weak self] _ in
            self?.showLaterTipSafely()
        }))
        ac.addAction(UIAlertAction(title: "はい", style: .default, handler: { [weak self] _ in
            self?.pendingShowPostUploadTip = true
            self?.selectAvatar()
        }))

        // 提示を試行
        initialPromptQueued = true
        presentSafely(ac,
            onPresented: { [weak self] in
                guard let self = self else { return }
                // 一度提示できたらフラグを倒す（今後は出さない）
                UserDefaults.standard.set(false, forKey: self.kShouldPromptInitialAvatar)
                self.markShownInitialAvatarPrompt(uid: uid)
                self.initialPromptQueued = false
                // 認証リスナーを解除
                if let h = self.authListenerHandle {
                    Auth.auth().removeStateDidChangeListener(h)
                    self.authListenerHandle = nil
                }
            },
            onFailed: { [weak self] in
                // まだ他のモーダル等で塞がっている → 少し遅らせて再挑戦
                guard let self = self else { return }
                self.initialPromptQueued = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.presentInitialAvatarPromptIfNeeded()
                }
            }
        )
    }


    // 置換：既存の presentSafely を以下で差し替え
    private func presentSafely(
        _ alert: UIAlertController,
        attempts: Int = 80,                      // ← 約16秒（80回×0.2秒）
        interval: TimeInterval = 0.2,
        onPresented: (() -> Void)? = nil,
        onFailed: (() -> Void)? = nil
    ) {
        var tries = 0
        func canPresent() -> Bool {
            return self.isViewLoaded && self.view.window != nil && self.presentedViewController == nil
        }
        func tick() {
            if canPresent() {
                self.present(alert, animated: true, completion: onPresented)
            } else if tries < attempts {
                tries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: tick)
            } else {
                onFailed?()   // ← 規定回数超えでもう一度チャンスを作る
            }
        }
        tick()
    }


    private func showLaterTipSafely() {
        let tip = UIAlertController(title: nil,
                                    message: "アイコンをタッチするといつでも設定することができます。",
                                    preferredStyle: .alert)
        tip.addAction(UIAlertAction(title: "OK", style: .default))
        presentSafely(tip)
    }

    
    private func applyLocalProfileDraftIfAny() {
        guard let raw = UserDefaults.standard.dictionary(forKey: kLocalProfileDraft) else { return }

        let id  = (raw["id"] as? String) ?? ""
        let g   = (raw["grade"] as? Int) ?? 0
        let fac = (raw["faculty"] as? String) ?? ""
        let dep = (raw["department"] as? String) ?? ""

        // ID（無効フィールドだが表示はできる）
        if !id.isEmpty { idField.text = id }

        // 学年
        if (1...4).contains(g) {
            gradeField.text = "\(g)年"
            gradePicker.selectRow(g - 1, inComponent: 0, animated: false)
        } else if g == 0 {
            gradeField.text = "指定なし"
            gradePicker.selectRow(4, inComponent: 0, animated: false) // optionsの最後が「指定なし」
        }

        // 学部・学科（ピッカー位置も同期）
        if !fac.isEmpty {
            facultyDeptField.text = dep.isEmpty ? fac : "\(fac)・\(dep)"
            if let fIdx = facultyNames.firstIndex(of: fac) {
                selectedFacultyIndex = fIdx
                facultyDeptPicker.reloadAllComponents()
                facultyDeptPicker.selectRow(fIdx, inComponent: 0, animated: false)
                if let list = FACULTY_DATA[fac], let dIdx = list.firstIndex(of: dep) {
                    selectedDepartmentIndex = dIdx
                    facultyDeptPicker.selectRow(dIdx, inComponent: 1, animated: false)
                }
            }
        } else if dep.isEmpty {
            facultyDeptField.text = "指定なし"
        }
    }
    
    
    // IDが空ならローカル即時反映→Authを軽くリロード→Firestore再取得
    private func reloadAllProfileFieldsIfIDMissing() {
        // すでに何か入っていれば何もしない
        if let t = idField.text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }

        // 1) ローカル下書きを即時適用（ID/学年/学科を瞬時に見せる）
        applyLocalProfileDraftIfAny()

        // 2) ローディングを短時間だけ出す（体感改善）
        setLoading(true)

        // 3) Authの表示名などを最新化（完了を待つ必要は薄いが念のため）
        Auth.auth().currentUser?.reload { [weak self] _ in
            guard let self = self else { return }
            // 4) Firestoreを再取得（loadUserProfileは既存）
            self.loadUserProfile()
            // 5) カバーは少し遅らせて外す（画面チラつき防止）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.setLoading(false)
            }
        }
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

        stackBottomToSafeArea?.isActive = false
        stackBottomToAdTop = stack.bottomAnchor.constraint(lessThanOrEqualTo: adContainer.topAnchor, constant: -24)
        stackBottomToAdTop?.isActive = true
        
        // ★ RCで広告を無効化しているならUIも非表示に
        guard AdsConfig.enabled else {
            adContainer.isHidden = true
            adContainerHeight?.constant = 0
            return
        }

        let bv = BannerView()
        bv.translatesAutoresizingMaskIntoConstraints = false
        
        
        // ★ 本番/テストを Remote Config で切替
        bv.adUnitID = AdsConfig.bannerUnitID

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
        guard AdsConfig.enabled, let bv = bannerView else { return }
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
                b.widthAnchor.constraint(equalToConstant: 44),
                b.heightAnchor.constraint(equalToConstant: 44)
            ])
            b.contentEdgeInsets = UIEdgeInsets(top: 11, left: 11, bottom: 11, right: 11)
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

        NSLayoutConstraint.activate([
            avatarView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            avatarView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 140),
            avatarView.heightAnchor.constraint(equalTo: avatarView.widthAnchor)
        ])
        view.layoutIfNeeded()
        avatarView.layer.cornerRadius = 70

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

        // 学年（さらに短く & 中央寄せ）
        gradeField.attributedPlaceholder = NSAttributedString(
            string: "学年",
            attributes: [.foregroundColor: UIColor.placeholderText]
        )
        gradeField.borderStyle = .roundedRect
        gradeField.textAlignment = .center
        gradeField.inputView = gradePicker
        gradeField.inputAccessoryView = doneToolbar(#selector(endEditingFields))
        gradePicker.dataSource = self
        gradePicker.delegate = self

        // 学部・学科（さらに長く）
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
        nameField.textColor = .label       // 入力文字が見えるように固定
        nameField.tintColor = .label       // キャレット（縦棒）の色。好みで .systemBlue でもOK
        nameField.textAlignment = .left
        nameField.clearButtonMode = .whileEditing
        nameField.rightView = nil
        nameField.rightViewMode = .never
        // 入力中文字の属性を明示（文字が透明になる事故を防止）
        nameField.textColor = .label
        nameField.backgroundColor = .clear
        nameField.defaultTextAttributes = [
            .foregroundColor: UIColor.label,
            .font: UIFont.systemFont(ofSize: 17)
        ]
        nameField.typingAttributes = [
            .foregroundColor: UIColor.label,
            .font: UIFont.systemFont(ofSize: 17)
        ]

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

        // 新比率: grade : facultyDept ≈ 0.31 : 0.69（grade = 0.45 * faculty）
        let ratio = gradeField.widthAnchor.constraint(equalTo: facultyDeptField.widthAnchor, multiplier: 0.45)
        ratio.priority = .required
        ratio.isActive = true

        let nameStack = UIStackView()
        nameStack.axis = .vertical
        nameStack.spacing = 8
        nameStack.addArrangedSubview(nameTitle)
        let nameRow = underlineWrap(nameField)
        nameStack.addArrangedSubview(nameRow)
        let focusTap = UITapGestureRecognizer(target: self, action: #selector(focusNameField))
        focusTap.cancelsTouchesInView = false
        nameRow.addGestureRecognizer(focusTap)


        let idStack = UIStackView()
        idStack.axis = .vertical
        idStack.spacing = 8
        idStack.addArrangedSubview(idTitle)
        idStack.addArrangedSubview(underlineWrap(idField))

        [row1, nameStack, idStack].forEach { stack.addArrangedSubview($0) }

        // 初期は SafeArea への下端制約（adContainer 生成後に付け替え）
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
                if let grade = data["grade"] as? Int, (1...4).contains(grade) {
                    self.gradeField.text = "\(grade)年"
                    self.gradePicker.selectRow(grade - 1, inComponent: 0, animated: false)
                }

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

                if !self.nameField.isFirstResponder {
                    if let name = data["name"] as? String, !name.isEmpty {
                        self.nameField.text = name
                    } else {
                        self.nameField.text = nil
                    }
                }

                if let id = data["id"] as? String {
                    self.idField.text = id
                } else if let disp = Auth.auth().currentUser?.displayName {
                    self.idField.text = disp
                }
                // 既存の UI 反映（grade / faculty&dept / name / id）を書き終えた末尾に追加
                UserDefaults.standard.removeObject(forKey: self.kLocalProfileDraft)
            }

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

    @objc private func focusNameField() {
        nameField.becomeFirstResponder()
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

    // MARK: - Avatar flow
    @objc private func selectAvatar() {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentCropper(with image: UIImage) {
        let cropVC = ImageCropViewController(image: image, titleText: "アイコンを切り取る")
        cropVC.modalPresentationStyle = .fullScreen
        cropVC.onCancel = { [weak self] in self?.dismiss(animated: true) }
        cropVC.onDone = { [weak self] cropped in
            guard let self else { return }
            self.dismiss(animated: true) {
                self.uploadAvatar(cropped)
            }
        }
        present(cropVC, animated: true)
    }

    private func uploadAvatar(_ image: UIImage) {
        guard let uid = self.uid else {
            showAlert(title: "ログインが必要です", message: "先にログインしてください。")
            return
        }

        // 即時UI反映
        self.avatarView.image = image

        // 転送量削減（最大辺512px）
        let resized = image.resized(maxEdge: 512)

        // Storage
        let ref = Storage.storage().reference(withPath: "avatars/\(uid).jpg")
        guard let data = resized.jpegData(compressionQuality: 0.75) else {
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
                let newVersion = (self.currentAvatarVersion
                                  ?? (SelfAvatarCache.shared.latestVersion(for: uid) ?? 0)) + 1
                SelfAvatarCache.shared.store(resized, uid: uid, version: newVersion)
                self.currentAvatarVersion = newVersion

                // Auth プロフィール（任意）
                if let user = Auth.auth().currentUser {
                    let change = user.createProfileChangeRequest()
                    change.photoURL = url
                    change.commitChanges(completion: nil)
                }

                // ★「はい」経由のときだけ、完了後に案内を出す（安全present）
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.pendingShowPostUploadTip {
                        self.pendingShowPostUploadTip = false
                        self.showLaterTipSafely()
                    }
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

    func sideMenuDidSelectContact() {
        guard let url = URL(string: "https://lin.ee/6O9GBTz") else { return }
        let safari = SFSafariViewController(url: url)
        safari.preferredControlTintColor = .systemBlue
        // サイドメニューが出ている場合の二重提示ガード
        if let presented = self.presentedViewController {
            presented.dismiss(animated: false) { [weak self] in
                self?.present(safari, animated: true)
            }
        } else {
            present(safari, animated: true)
        }
    }
    func sideMenuDidSelectTerms() {
        presentTextPageFromFile(title: "利用規約", fileName: "Terms", fileExt: "rtf")
    }

    func sideMenuDidSelectPrivacy() {
        presentTextPageFromFile(title: "プライバシーポリシー", fileName: "Privacy", fileExt: "rtf")
    }
/*
    func sideMenuDidSelectFAQ() {
        presentTextPageFromFile(title: "よくある質問", fileName: "FAQ", fileExt: "rtf")
    }
*/

    // MARK: - Auth ops
    private func performSignOut() {
        do {
            try Auth.auth().signOut()
        } catch {
            showAlert(title: "ログアウトに失敗", message: error.localizedDescription)
            return
        }
        tabBarController?.selectedIndex = settingsTabIndex
    }
    
    private let kLocalProfileDraft = "LocalProfileDraftV1"


    private func performDeleteAccount() {
        guard Auth.auth().currentUser != nil else { return }
        setLoading(true)

        Task { @MainActor in
            do {
                guard let uid = Auth.auth().currentUser?.uid else { throw NSError(domain: "Auth", code: -1) }

                // 1) 先にクライアント側で Firestore/Storage を確実に削除
                //    - サブコレクション（timetable など）→ users/{uid} 本体
                //    - usernames インデックス、アイコン画像 も併せて削除
                try? await deleteUsernameMapping(uid: uid)
                await deleteAvatarFiles(uid: uid)
                try? await deleteSelfUserTree(uid: uid)   // ← users/{uid} ドキュメントまで消す

                // 2) サーバ側の最終掃除（Authユーザー削除や片付けの保険）
                _ = try await functions.httpsCallable("deleteAccountServerSide").call([:])

                // 3) ログアウト & UI
                try? Auth.auth().signOut()
                self.switchToTab(index: self.settingsTabIndex)
                self.showAlert(title: "アカウント削除", message: "削除が完了しました。")

            } catch {
                let ns = error as NSError
                let detailsAny = ns.userInfo[FunctionsErrorDetailsKey]
                let details: String
                if let d = detailsAny as? [String: Any] {
                    details = d.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                } else {
                    details = String(describing: detailsAny ?? "")
                }
                let msg = "domain=\(ns.domain), code=\(ns.code), \(details)"
                print("CALLABLE ERROR:", msg)
                self.showAlert(title: "アカウント削除に失敗", message: msg)
            }


            self.setLoading(false)
        }
    }


    
    private func deleteSelfUserTree(uid: String) async throws {
        let db = Firestore.firestore()
        let mySubs = ["timetable","Friends","friends",
                      "requestsIncoming","requestIncoming","incomingRequests",
                      "requestsOutgoing","requestOutgoing","outgoingRequests"]
        for s in mySubs {
            let snap = try await db.collection("users").document(uid).collection(s).getDocuments()
            for d in snap.documents {
                try await awaitDelete(d.reference)
            }
        }
        try await awaitDelete(db.collection("users").document(uid))
    }

    private func deleteUsernameMapping(uid: String) async throws {
        let db = Firestore.firestore()
        let snap = try await db.collection("users").document(uid).getDocument()
        if let key = (snap.get("idLower") as? String)
            ?? (snap.get("usernameLower") as? String)
            ?? ((snap.get("id") as? String)?.lowercased()) {
            try? await awaitDelete(db.collection("usernames").document(key))
        }
    }

    private func deleteAvatarFiles(uid: String) async {
        let storage = Storage.storage()
        await awaitDelete(storage.reference(withPath: "avatars/\(uid).jpg"))
        let folder = storage.reference(withPath: "avatars/\(uid)")
        if let list = try? await folder.listAll() {
            for item in list.items { await awaitDelete(item) }
            for prefix in list.prefixes {
                if let list2 = try? await prefix.listAll() {
                    for item in list2.items { await awaitDelete(item) }
                }
            }
        }
    }


    // MARK: - Loading HUD（クラス内）
    private var loadingCover: UIView?

    private func setLoading(_ loading: Bool) {
        if loading {
            guard loadingCover == nil else { return }
            let cover = UIView()
            cover.backgroundColor = UIColor.black.withAlphaComponent(0.2)
            cover.translatesAutoresizingMaskIntoConstraints = false

            let spinner = UIActivityIndicatorView(style: .large)
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimating()
            cover.addSubview(spinner)

            view.addSubview(cover)
            NSLayoutConstraint.activate([
                cover.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                cover.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                cover.topAnchor.constraint(equalTo: view.topAnchor),
                cover.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                spinner.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: cover.centerYAnchor)
            ])

            view.isUserInteractionEnabled = false
            loadingCover = cover
        } else {
            view.isUserInteractionEnabled = true
            loadingCover?.removeFromSuperview()
            loadingCover = nil
        }
    }

    // タブ切替（クラス内）
    private func switchToTab(index: Int) {
        navigationController?.popToRootViewController(animated: true)
        tabBarController?.selectedIndex = index
    }

    // 相手側 Friends / requests* の「自分に関する行」を削除（クラス内）
    private func clientSideCrossCleanup(uid: String) async throws {
        let db = Firestore.firestore()
        let groups = [
            "Friends","friends",
            "requestsIncoming","requestIncoming","incomingRequests",
            "requestsOutgoing","requestOutgoing","outgoingRequests"
        ]
        // 1) ドキュメントID = uid 型
        for g in groups {
            let q = db.collectionGroup(g).whereField(FieldPath.documentID(), isEqualTo: uid)
            let snap = try await q.getDocuments()
            for d in snap.documents {
                try await awaitDelete(d.reference)
            }
        }
        // 2) フィールド参照型
        let fields = ["uid","friendUid","fromUid","toUid","ownerUid","targetUid"]
        for g in groups {
            for f in fields {
                let q = db.collectionGroup(g).whereField(f, isEqualTo: uid)
                let snap = try await q.getDocuments()
                for d in snap.documents {
                    try await awaitDelete(d.reference)
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
    
    // Firestore: delete を await でラップ（Void を明示して返す）
    private func awaitDelete(_ ref: DocumentReference) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ref.delete { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: ())   // ← Void を返す
                }
            }
        }
    }

    // Storage: delete を await でラップ（非throwing、Void を返す）
    private func awaitDelete(_ ref: StorageReference) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            ref.delete { _ in
                cont.resume(returning: ())      // ← Void を返す
            }
        }
    }

    deinit {
        if let h = authListenerHandle {
            Auth.auth().removeStateDidChangeListener(h)
        }
        NotificationCenter.default.removeObserver(self, name: .shouldPromptInitialAvatar, object: nil)
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
                DispatchQueue.main.async { self.presentCropper(with: image) }
            }
        }
    }
}

// MARK: - UIPickerView DataSource/Delegate
extension UserSettingsViewController: UIPickerViewDataSource, UIPickerViewDelegate {

    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        if pickerView === gradePicker { return 1 }
        return 2 // 学部・学科
    }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        if pickerView === gradePicker { return gradeOptions.count }          // 学年は「指定なし」あり
        if component == 0 { return facultyNames.count + 1 }                  // 学部末尾に「指定なし」
        let fIndex = facultyDeptPicker.selectedRow(inComponent: 0)
        if fIndex == facultyNames.count { return 0 }                         // 学部=指定なし → 学科は表示しない
        let faculty = facultyNames[fIndex]
        return FACULTY_DATA[faculty]?.count ?? 0                             // 学科は通常のみ
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        if pickerView === gradePicker { return gradeOptions[row] }
        if component == 0 { return row == facultyNames.count ? "指定なし" : facultyNames[row] }
        let fIndex = facultyDeptPicker.selectedRow(inComponent: 0)
        guard fIndex < facultyNames.count else { return nil }
        let faculty = facultyNames[fIndex]
        return FACULTY_DATA[faculty]?[row] ?? ""
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        if pickerView === gradePicker {
            let text = gradeOptions[row]
            gradeField.text = text
            let grade = (text == "指定なし") ? 0
                      : max(1, min(4, Int(text.replacingOccurrences(of: "年", with: "")) ?? 1))
            updateGrade(grade)                                               // 0 ならフレンド表示なし
            return
        }

        if component == 0 {
            // 学部
            if row == facultyNames.count {
                facultyDeptField.text = "指定なし"
                updateFacultyDept(faculty: "", department: "")               // 空文字で保存
                facultyDeptPicker.reloadComponent(1)
                return
            }
            selectedFacultyIndex = row
            selectedDepartmentIndex = 0
            facultyDeptPicker.reloadComponent(1)

            // 先頭学科があれば表示＆保存
            let faculty = facultyNames[row]
            if let first = FACULTY_DATA[faculty]?.first, !first.isEmpty {
                facultyDeptPicker.selectRow(0, inComponent: 1, animated: false)
                facultyDeptField.text = "\(faculty)・\(first)"
                updateFacultyDept(faculty: faculty, department: first)
            } else {
                facultyDeptField.text = faculty
                updateFacultyDept(faculty: faculty, department: "")
            }
            return
        }

        // 学科
        let fIndex = facultyDeptPicker.selectedRow(inComponent: 0)
        guard fIndex < facultyNames.count else { return }
        selectedDepartmentIndex = row
        let faculty = facultyNames[fIndex]
        let department = FACULTY_DATA[faculty]?[row] ?? ""
        facultyDeptField.text = department.isEmpty ? faculty : "\(faculty)・\(department)"
        updateFacultyDept(faculty: faculty, department: department)
    }
    
}
// MARK: - Textページ遷移（RTFファイルを読み込む）
private extension UserSettingsViewController {
    func presentTextPageFromFile(title: String, fileName: String, fileExt: String = "rtf") {
        let show: () -> Void = { [weak self] in
            guard let self = self else { return }
            if let nav = self.navigationController {
                // UINavigationController 配下 → push
                let vc = TextPageViewController(title: title, bundled: fileName, ext: fileExt)
                vc.overrideUserInterfaceStyle = .light
                vc.view.backgroundColor = .systemBackground
                nav.pushViewController(vc, animated: true)
            } else {
                // それ以外 → 全画面モーダル（閉じるボタン付き）
                let vc = TextPageViewController(title: title, bundled: fileName, ext: fileExt, showsCloseButton: true)
                vc.overrideUserInterfaceStyle = .light
                vc.view.backgroundColor = .systemBackground
                let nav = UINavigationController(rootViewController: vc)
                nav.overrideUserInterfaceStyle = .light            // ← ナビもライト固定
                nav.modalPresentationStyle = .fullScreen
                self.present(nav, animated: true)
            }
        }
        if let presented = self.presentedViewController {
            // サイドメニューなどが出ていたら先に閉じる
            presented.dismiss(animated: false, completion: show)
        } else {
            show()
        }
    }
}


// 安全添字
private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// 画像ユーティリティ
private extension UIImage {
    func resized(maxEdge: CGFloat) -> UIImage {
        let w = size.width, h = size.height
        let scale = min(1.0, maxEdge / max(w, h))
        if scale >= 0.999 { return self }
        let newSize = CGSize(width: w * scale, height: h * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
        draw(in: CGRect(origin: .zero, size: newSize))
        let img = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return img ?? self
    }
}
