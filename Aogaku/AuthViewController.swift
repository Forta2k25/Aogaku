import UIKit
import GoogleMobileAds
import SafariServices
import FirebaseAuth
import FirebaseFirestore

@inline(__always)
private func makeAdaptiveAdSize(width: CGFloat) -> AdSize {
    return currentOrientationAnchoredAdaptiveBanner(width: width)
}


final class AuthViewController: UIViewController, SideMenuDrawerDelegate, BannerViewDelegate {

    // MARK: - UI
    private let titleLabel = UILabel()
    private let googleButton = UIButton(type: .system)
    private let dividerView = UIView()   // "または" divider
    private let legacyToggle = UIButton(type: .system)
    private let legacyContainer = UIView()
    private let idField = UITextField()
    private let pwField = UITextField()
    private let loginButton = UIButton(type: .system)
    private let noteLabel = UILabel()
    private let stack = UIStackView()
    private var isLegacyExpanded = false

    private enum Keys {
        static let localProfileDraft = "LocalProfileDraftV1"
        static let shouldPromptInitialAvatar = "ShouldPromptInitialAvatarV1"
    }

    // ===== Header banner =====
    private let headerBanner = UIView()

    // ===== AdMob (Banner) =====
    private let adContainer = UIView()
    private var bannerView: BannerView?
    private var adContainerHeight: NSLayoutConstraint?
    private var lastBannerWidth: CGFloat = 0
    private var didLoadBannerOnce = false

    // stack の下端制約を付け替えるため保持
    private var stackBottomToSafeArea: NSLayoutConstraint?
    private var stackBottomToAdTop: NSLayoutConstraint?

    private func appBackgroundColor(for traits: UITraitCollection) -> UIColor {
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.20, alpha: 1.0) : .systemGroupedBackground
    }
    private func applyBackgroundStyle() {
        view.backgroundColor = appBackgroundColor(for: traitCollection)
        adContainer.backgroundColor = appBackgroundColor(for: traitCollection)
    }


    // MARK: - Helpers
    private func makeHamburgerButton(target: Any?, action: Selector) -> UIButton {
        let img = UIImage(
            systemName: "line.3.horizontal",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        )
        let b = UIButton(type: .system)
        b.setImage(img, for: .normal)
        b.tintColor = .label
        b.backgroundColor = .clear
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 44),
            b.heightAnchor.constraint(equalToConstant: 44),
        ])
        b.contentEdgeInsets = UIEdgeInsets(top: 11, left: 11, bottom: 11, right: 11)
        b.addTarget(target, action: action, for: .touchUpInside)
        return b
    }

    private func makeDoneToolbar(selector: Selector) -> UIToolbar {
        let tb = UIToolbar()
        tb.sizeToFit()
        tb.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(title: "完了", style: .done, target: self, action: selector)
        ]
        return tb
    }

    // MARK: - LifeCycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        setupUI()
        setupKeyboardToolbars()
        setupPasswordToggle()
        setupDismissKeyboardGesture()
        setupAdBanner()
        NotificationCenter.default.addObserver(self,
            selector: #selector(onAdMobReady),
            name: .adMobReady, object: nil)

        let menuButton = makeHamburgerButton(target: self, action: #selector(didTapSideMenuButton(_:)))
        view.addSubview(menuButton)
        NSLayoutConstraint.activate([
            menuButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            menuButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12)
        ])

        applyBackgroundStyle()
    }
    @objc private func onAdMobReady() {
        loadBannerIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // ▼ 追加：幅に合わせて一度だけロード
        loadBannerIfNeeded()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        AppGatekeeper.shared.checkAndPresentIfNeeded(on: self)
    }

    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyBackgroundStyle()
        }
    }

    // MARK: - UI
    private func setupUI() {
        setupHeaderBanner()

        // --- Google sign-in button ---
        googleButton.backgroundColor = .white
        googleButton.setTitleColor(UIColor(white: 0.2, alpha: 1), for: .normal)
        googleButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        googleButton.layer.cornerRadius = 12
        googleButton.layer.borderWidth = 1
        googleButton.layer.borderColor = UIColor.separator.cgColor
        googleButton.layer.shadowColor = UIColor.black.cgColor
        googleButton.layer.shadowOpacity = 0.06
        googleButton.layer.shadowOffset = CGSize(width: 0, height: 1)
        googleButton.layer.shadowRadius = 3
        googleButton.setTitle("  Googleでログイン / 新規登録", for: .normal)
        if let gIcon = UIImage(named: "google_logo") {
            googleButton.setImage(gIcon, for: .normal)
        }
        googleButton.imageView?.contentMode = .scaleAspectFit
        googleButton.addTarget(self, action: #selector(signInWithGoogle), for: .touchUpInside)

        // --- "または" divider ---
        let orLabel = UILabel()
        orLabel.text = "または"
        orLabel.font = .systemFont(ofSize: 13)
        orLabel.textColor = .secondaryLabel
        orLabel.textAlignment = .center
        dividerView.addSubview(orLabel)
        orLabel.translatesAutoresizingMaskIntoConstraints = false

        let leftLine = UIView()
        leftLine.backgroundColor = .separator
        let rightLine = UIView()
        rightLine.backgroundColor = .separator
        [leftLine, rightLine].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            dividerView.addSubview($0)
        }
        NSLayoutConstraint.activate([
            orLabel.centerXAnchor.constraint(equalTo: dividerView.centerXAnchor),
            orLabel.centerYAnchor.constraint(equalTo: dividerView.centerYAnchor),
            leftLine.leadingAnchor.constraint(equalTo: dividerView.leadingAnchor),
            leftLine.trailingAnchor.constraint(equalTo: orLabel.leadingAnchor, constant: -8),
            leftLine.centerYAnchor.constraint(equalTo: dividerView.centerYAnchor),
            leftLine.heightAnchor.constraint(equalToConstant: 0.5),
            rightLine.leadingAnchor.constraint(equalTo: orLabel.trailingAnchor, constant: 8),
            rightLine.trailingAnchor.constraint(equalTo: dividerView.trailingAnchor),
            rightLine.centerYAnchor.constraint(equalTo: dividerView.centerYAnchor),
            rightLine.heightAnchor.constraint(equalToConstant: 0.5),
        ])

        // --- Legacy toggle ---
        legacyToggle.setTitle("IDとパスワードでログイン（既存ユーザー）", for: .normal)
        legacyToggle.titleLabel?.font = .systemFont(ofSize: 14)
        legacyToggle.setTitleColor(.secondaryLabel, for: .normal)
        legacyToggle.addTarget(self, action: #selector(toggleLegacy), for: .touchUpInside)

        // --- Legacy container (hidden by default) ---
        legacyContainer.isHidden = true

        idField.placeholder = "ID（英数字・._）"
        idField.autocapitalizationType = .none
        idField.autocorrectionType = .no
        idField.borderStyle = .roundedRect
        idField.clearButtonMode = .whileEditing
        idField.returnKeyType = .next

        pwField.placeholder = "パスワード（6文字以上）"
        pwField.isSecureTextEntry = true
        pwField.borderStyle = .roundedRect
        pwField.returnKeyType = .done

        loginButton.setTitle("ログイン", for: .normal)
        loginButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        loginButton.addTarget(self, action: #selector(login), for: .touchUpInside)

        let legacyStack = UIStackView(arrangedSubviews: [idField, pwField, loginButton])
        legacyStack.axis = .vertical
        legacyStack.spacing = 12
        legacyStack.translatesAutoresizingMaskIntoConstraints = false
        legacyContainer.addSubview(legacyStack)
        NSLayoutConstraint.activate([
            legacyStack.topAnchor.constraint(equalTo: legacyContainer.topAnchor),
            legacyStack.leadingAnchor.constraint(equalTo: legacyContainer.leadingAnchor),
            legacyStack.trailingAnchor.constraint(equalTo: legacyContainer.trailingAnchor),
            legacyStack.bottomAnchor.constraint(equalTo: legacyContainer.bottomAnchor),
            idField.heightAnchor.constraint(equalToConstant: 44),
            pwField.heightAnchor.constraint(equalToConstant: 44),
            loginButton.heightAnchor.constraint(equalToConstant: 50),
        ])

        noteLabel.text = "※Googleアカウントは青学のメールアドレスでなくてもOKです。\n※登録する「ID」は、学内システムの学生番号とは異なります。"
        noteLabel.textColor = .secondaryLabel
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.numberOfLines = 0
        noteLabel.textAlignment = .center

        stack.axis = .vertical
        stack.spacing = 18
        [headerBanner, googleButton, dividerView, legacyToggle, legacyContainer, noteLabel]
            .forEach { stack.addArrangedSubview($0) }
        stack.setCustomSpacing(32, after: headerBanner)
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        stackBottomToSafeArea = stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 48),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stackBottomToSafeArea!,
            googleButton.heightAnchor.constraint(equalToConstant: 52),
            dividerView.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    private func setupHeaderBanner() {
        // アクセントカラーの小さい角丸アイコン枠
        let iconBg = UIView()
        iconBg.backgroundColor = HackColors.accent
        iconBg.layer.cornerRadius = 16
        iconBg.translatesAutoresizingMaskIntoConstraints = false

        let iconView = UIImageView(image: UIImage(
            systemName: "building.2.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        ))
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconBg.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: iconBg.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBg.centerYAnchor),
            iconBg.widthAnchor.constraint(equalToConstant: 56),
            iconBg.heightAnchor.constraint(equalToConstant: 56),
        ])

        let appNameLabel = UILabel()
        appNameLabel.text = "青山ハック"
        appNameLabel.font = .systemFont(ofSize: 28, weight: .bold)
        appNameLabel.textColor = .label
        appNameLabel.textAlignment = .center

        let subLabel = UILabel()
        subLabel.text = "ログイン / アカウント作成"
        subLabel.font = .systemFont(ofSize: 14)
        subLabel.textColor = .secondaryLabel
        subLabel.textAlignment = .center

        let vStack = UIStackView(arrangedSubviews: [iconBg, appNameLabel, subLabel])
        vStack.axis = .vertical
        vStack.alignment = .center
        vStack.spacing = 8
        vStack.setCustomSpacing(12, after: iconBg)

        headerBanner.addSubview(vStack)
        vStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            vStack.topAnchor.constraint(equalTo: headerBanner.topAnchor),
            vStack.bottomAnchor.constraint(equalTo: headerBanner.bottomAnchor),
            vStack.leadingAnchor.constraint(equalTo: headerBanner.leadingAnchor),
            vStack.trailingAnchor.constraint(equalTo: headerBanner.trailingAnchor),
        ])
    }
    private func setupAdBanner() {
        // 画面下に広告コンテナを固定
        adContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(adContainer)

        adContainerHeight = adContainer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            adContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            adContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            adContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            adContainerHeight!
        ])

        // stack の下端を広告コンテナの上端に付け替え（重なり防止）
        stackBottomToSafeArea?.isActive = false
        stackBottomToAdTop = stack.bottomAnchor.constraint(lessThanOrEqualTo: adContainer.topAnchor, constant: -24)
        stackBottomToAdTop?.isActive = true

        // RCで広告を止めているときはUIも消す
          guard AdsConfig.enabled else {
              adContainer.isHidden = true
              adContainerHeight?.constant = 0
              return
      }
        // GADBannerView（プロジェクトの typealias: BannerView / Request / AdSize）
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
        if abs(useWidth - lastBannerWidth) < 0.5 { return } // 連続ロード抑止
        lastBannerWidth = useWidth

        let size = makeAdaptiveAdSize(width: useWidth)

        // 先に高さを確保しておく
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

    // MARK: - BannerViewDelegate
    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        let h = bannerView.adSize.size.height
        adContainerHeight?.constant = h
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
    }

    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        adContainerHeight?.constant = 0
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
        print("Ad failed:", error.localizedDescription)
    }

    private func setupKeyboardToolbars() {
        idField.inputAccessoryView = makeDoneToolbar(selector: #selector(doneEditing))
        pwField.inputAccessoryView = makeDoneToolbar(selector: #selector(doneEditing))
        idField.addTarget(self, action: #selector(focusPassword), for: .editingDidEndOnExit)
        pwField.addTarget(self, action: #selector(submitOrDismiss), for: .editingDidEndOnExit)
    }

    private func setupPasswordToggle() {
        // 目アイコンで表示/非表示を切替
        let eye = UIButton(type: .system)
        eye.tintColor = .secondaryLabel
        eye.setImage(UIImage(systemName: "eye.slash"), for: .normal)
        eye.frame = CGRect(x: 0, y: 0, width: 30, height: 24)
        eye.addTarget(self, action: #selector(togglePasswordVisibility(_:)), for: .touchUpInside)

        pwField.rightView = eye
        pwField.rightViewMode = .always
        pwField.clearButtonMode = .never
    }

    private func setupDismissKeyboardGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(doneEditing))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    // MARK: - Actions (Keyboard / Toggle)
    @objc private func doneEditing() { view.endEditing(true) }
    @objc private func focusPassword() { pwField.becomeFirstResponder() }
    @objc private func submitOrDismiss() { view.endEditing(true) }

    @objc private func toggleLegacy() {
        isLegacyExpanded.toggle()
        UIView.animate(withDuration: 0.25) {
            self.legacyContainer.isHidden = !self.isLegacyExpanded
            self.stack.layoutIfNeeded()
        }
        let arrow = isLegacyExpanded ? "▲" : "▼"
        legacyToggle.setTitle("IDとパスワードでログイン（既存ユーザー）\(arrow)", for: .normal)
    }

    @objc private func togglePasswordVisibility(_ sender: UIButton) {
        pwField.isSecureTextEntry.toggle()
        let name = pwField.isSecureTextEntry ? "eye.slash" : "eye"
        sender.setImage(UIImage(systemName: name), for: .normal)

        if let existingText = pwField.text, pwField.isFirstResponder {
            pwField.deleteBackward()
            pwField.insertText(existingText + " ")
            pwField.deleteBackward()
        }
    }

    // MARK: - SideMenu（未ログインは「その他」だけ）
    @IBAction func didTapSideMenuButton(_ sender: Any) {
        let menu = SideMenuDrawerViewController()
        menu.modalPresentationStyle = .overFullScreen
        menu.modalTransitionStyle = .crossDissolve
        menu.delegate = self
        menu.showsAccountSection = false
        present(menu, animated: false) { [weak self, weak menu] in
          //  self?.attachInstagramButton(to: menu)   // ★ 追加
        }
    }
    
    // ===== Instagram: メニュー右下ボタンを後付け =====
   /* private func attachInstagramButton(to menuVC: UIViewController?) {
        guard let menuVC else { return }
        let tag = 9901
        if menuVC.view.viewWithTag(tag) != nil { return } // 二重追加ガード

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

        // タップでメニューを閉じて Instagram（アプリ優先→Web）へ
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
    } */


    // MARK: - Auth Flow

    @objc private func signInWithGoogle() {
        view.endEditing(true)
        let hud = makeHUD()
        Task { [weak self] in
            guard let self else { return }
            defer { hud.removeFromSuperview(); self.view.isUserInteractionEnabled = true }
            do {
                let needsSetup = try await AuthManager.shared.signInWithGoogle(presenting: self)
                // AuthStateListenerによるswapContentが終わった後に通知を投げる
                // （signInWithGoogle返却時点ではswapContent完了済み）
                if needsSetup {
                    NotificationCenter.default.post(name: .googleSignInNeedsIDSetup, object: nil)
                }
            } catch {
                await MainActor.run {
                    self.showAlert(title: "ログインエラー", message: error.localizedDescription)
                }
            }
        }
    }

    @objc private func login() {
        let id = idField.text ?? ""
        let pw = pwField.text ?? ""
        guard !id.isEmpty, !pw.isEmpty else {
            showAlert(title: "入力エラー", message: "IDとパスワードを入力してください。")
            return
        }
        view.endEditing(true)
        let hud = makeHUD()
        Task { [weak self] in
            guard let self else { return }
            defer { hud.removeFromSuperview(); self.view.isUserInteractionEnabled = true }
            do {
                try await AuthManager.shared.login(id: id, password: pw)
                // AuthStateListenerがSettingsHostVCを更新する
            } catch let e as AuthError {
                await MainActor.run { self.showAlert(title: "エラー", message: e.localizedDescription) }
            } catch {
                await MainActor.run { self.showAlert(title: "エラー", message: error.localizedDescription) }
            }
        }
    }

    private func makeHUD() -> UIActivityIndicatorView {
        let hud = UIActivityIndicatorView(style: .large)
        hud.startAnimating()
        view.isUserInteractionEnabled = false
        view.addSubview(hud)
        hud.center = view.center
        return hud
    }

    // MARK: - SideMenuDrawerDelegate（未ログイン時に使う項目）
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
    func sideMenuDidSelectTerms()    { presentTextPageFromFile(title: "利用規約",         fileName: "Terms",   fileExt: "rtf") }
    func sideMenuDidSelectPrivacy()  { presentTextPageFromFile(title: "プライバシーポリシー", fileName: "Privacy", fileExt: "rtf") }
    func sideMenuDidSelectFAQ()      { presentTextPageFromFile(title: "よくある質問",       fileName: "FAQ",     fileExt: "rtf") }



    func sideMenuDidSelectLogout() {}
    func sideMenuDidSelectDeleteAccount() {}

    // MARK: - Alert
    private func showAlert(title: String, message: String = "") {
        let ac = UIAlertController(title: title, message: message, preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "OK", style: .default))
        present(ac, animated: true)
    }
    
    
}
// MARK: - Textページ遷移（ファイル名指定）
private extension AuthViewController {
    func presentTextPageFromFile(title: String, fileName: String, fileExt: String = "txt") {
        let perform: () -> Void = { [weak self] in
            guard let self = self else { return }
            if let nav = self.navigationController {
                let vc = TextPageViewController(title: title, bundled: fileName, ext: fileExt)
                vc.overrideUserInterfaceStyle = .light
                vc.view.backgroundColor = .systemBackground
                nav.pushViewController(vc, animated: true)
            } else {
                let vc = TextPageViewController(title: title, bundled: fileName, ext: fileExt, showsCloseButton: true)
                vc.overrideUserInterfaceStyle = .light
                vc.view.backgroundColor = .systemBackground
                let nav = UINavigationController(rootViewController: vc)
                nav.overrideUserInterfaceStyle = .light
                nav.modalPresentationStyle = .fullScreen
                self.present(nav, animated: true)
            }
        }
        if let presented = self.presentedViewController {
            presented.dismiss(animated: false, completion: perform)
        } else {
            perform()
        }
    }
}




