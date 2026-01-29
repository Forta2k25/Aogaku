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
    private let gradeField = UITextField()         // 学年
    private let facultyDeptField = UITextField()   // 学部・学科（2コンポーネントピッカー）
    private let idField = UITextField()
    private let pwField = UITextField()
    private let signupButton = UIButton(type: .system)
    private let loginButton = UIButton(type: .system)
    private let noteLabel = UILabel()
    private let stack = UIStackView()
    private enum Keys {
        static let localProfileDraft = "LocalProfileDraftV1"
        static let shouldPromptInitialAvatar = "ShouldPromptInitialAvatarV1"
    }

    // MARK: - Pickers
    private let gradePicker = UIPickerView()
    private let facultyDeptPicker = UIPickerView()
    private let gradeOptions = ["1年","2年","3年","4年","指定なし"]
    private let noneLabel = "指定なし"

    
    // ===== AdMob (Banner) =====
    private let adContainer = UIView()
    private var bannerView: BannerView?
    private var adContainerHeight: NSLayoutConstraint?
    private var lastBannerWidth: CGFloat = 0
    private var didLoadBannerOnce = false

    // stack の下端制約を付け替えるため保持
    private var stackBottomToSafeArea: NSLayoutConstraint?
    private var stackBottomToAdTop: NSLayoutConstraint?

    // 学部→学科（必要に応じて編集）
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

        // ▼ ここを置換：ダーク時は黒、ライト時は白
        let inputBG: UIColor = (traitCollection.userInterfaceStyle == .dark) ? .black : .white
        [gradeField, facultyDeptField].forEach {
            $0.backgroundColor = inputBG
            $0.textColor = .label           // 文字はモードに追従
            // （placeholder は既に UIColor.placeholderText を使用しているのでOK）
        }
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
        setupPickers()
        setupKeyboardToolbars()
        setupPasswordToggle()
        setupDismissKeyboardGesture()
        setupAdBanner()
        NotificationCenter.default.addObserver(self,
            selector: #selector(onAdMobReady),
            name: .adMobReady, object: nil)

        // 右上のメニューボタン（未ログインは「その他」だけ）
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
        titleLabel.text = "青学ハック アカウント"
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.textAlignment = .center

        // Placeholder（薄いグレー）
        gradeField.attributedPlaceholder = NSAttributedString(
            string: "学年を選択",
            attributes: [.foregroundColor: UIColor.placeholderText]
        )
        gradeField.borderStyle = .roundedRect
        gradeField.inputView = gradePicker

        facultyDeptField.attributedPlaceholder = NSAttributedString(
            string: "学部・学科を選択",
            attributes: [.foregroundColor: UIColor.placeholderText]
        )
        facultyDeptField.borderStyle = .roundedRect
        facultyDeptField.inputView = facultyDeptPicker

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

        signupButton.setTitle("アカウント作成", for: .normal)
        signupButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        signupButton.addTarget(self, action: #selector(signUp), for: .touchUpInside)

        loginButton.setTitle("ログイン", for: .normal)
        loginButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        loginButton.addTarget(self, action: #selector(login), for: .touchUpInside)

        noteLabel.text = "※一度作成したアカウントのIDを変更することはできません。\n※登録する「ID」は、学内システムで使う学生番号とは異なります。"
        noteLabel.textColor = .secondaryLabel
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.numberOfLines = 0
        noteLabel.textAlignment = .center
        
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = 8
        ps.alignment = .center
        noteLabel.attributedText = NSAttributedString(
            string: noteLabel.text ?? "",
            attributes: [.paragraphStyle: ps,
                         .foregroundColor: UIColor.secondaryLabel,
                         .font: UIFont.systemFont(ofSize: 12)]
        )

        // スタック：上下に広げる（中央寄せをやめる）
        stack.axis = .vertical
        stack.spacing = 18
        [titleLabel,
         gradeField, facultyDeptField,
         idField, pwField,
         signupButton, loginButton,
         noteLabel].forEach { stack.addArrangedSubview($0) }
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        
        stackBottomToSafeArea = stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)

        let topInset: CGFloat = 120
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: topInset),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stackBottomToSafeArea!,

            gradeField.heightAnchor.constraint(equalToConstant: 44),
            facultyDeptField.heightAnchor.constraint(equalToConstant: 44),
            idField.heightAnchor.constraint(equalToConstant: 44),
            pwField.heightAnchor.constraint(equalToConstant: 44),
            signupButton.heightAnchor.constraint(equalToConstant: 50),
            loginButton.heightAnchor.constraint(equalToConstant: 50)
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

    private func setupPickers() {
        gradePicker.dataSource = self
        gradePicker.delegate = self

        facultyDeptPicker.dataSource = self
        facultyDeptPicker.delegate = self
    }

    private func setupKeyboardToolbars() {
        // すべての入力に「完了」ボタン
        gradeField.inputAccessoryView = makeDoneToolbar(selector: #selector(doneEditing))
        facultyDeptField.inputAccessoryView = makeDoneToolbar(selector: #selector(doneEditing))
        idField.inputAccessoryView = makeDoneToolbar(selector: #selector(doneEditing))
        pwField.inputAccessoryView = makeDoneToolbar(selector: #selector(doneEditing))

        // Return キーの動作
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

    // MARK: - Actions (Keyboard)
    @objc private func doneEditing() { view.endEditing(true) }
    @objc private func focusPassword() { pwField.becomeFirstResponder() }
    @objc private func submitOrDismiss() { view.endEditing(true) } // ここで login() にしてもOK

    @objc private func togglePasswordVisibility(_ sender: UIButton) {
        pwField.isSecureTextEntry.toggle()
        let name = pwField.isSecureTextEntry ? "eye.slash" : "eye"
        sender.setImage(UIImage(systemName: name), for: .normal)

        // isSecureTextEntry 切替時にカーソル位置が飛ぶのを防ぐ処理
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
    @objc private func signUp() { authFlow(isSignup: true) }
    @objc private func login()  { authFlow(isSignup: false) }

    private func authFlow(isSignup: Bool) {
        let id = idField.text ?? ""
        let pw = pwField.text ?? ""
        let gradeText = gradeField.text ?? ""
        let facultyDeptText = facultyDeptField.text ?? ""

        guard !id.isEmpty, !pw.isEmpty, !gradeText.isEmpty, !facultyDeptText.isEmpty else {
            showAlert(title: "入力エラー", message: "学年・学部学科・ID・パスワードを入力してください。")
            return
        }

        let grade: Int = (gradeText == "指定なし")
            ? 0
            : max(1, min(4, Int(gradeText.replacingOccurrences(of: "年", with: "")) ?? 1))
        var comps = facultyDeptText.components(separatedBy: "・")
        var faculty = comps.first ?? ""
        var department = comps.count > 1 ? comps[1] : ""
        if facultyDeptText == "指定なし" || faculty.isEmpty {
            faculty = ""
            department = ""
        }

        let hud = UIActivityIndicatorView(style: .large)
        hud.startAnimating()
        view.isUserInteractionEnabled = false
        view.addSubview(hud)
        hud.center = view.center

        Task { [weak self] in
            defer {
                DispatchQueue.main.async {
                    hud.removeFromSuperview()
                    self?.view.isUserInteractionEnabled = true
                }
            }
            do {
                
                if isSignup {
                    try await AuthManager.shared.signUp(
                        id: id, password: pw,
                        grade: grade, faculty: faculty, department: department
                    )

                    UserDefaults.standard.set(true, forKey: Keys.shouldPromptInitialAvatar)

                    // ローカル即時キャッシュ（プロフィール即反映用）
                    UserDefaults.standard.set([
                        "id": id,
                        "grade": grade,
                        "faculty": faculty,
                        "department": department
                    ], forKey: Keys.localProfileDraft)

                    // ✅ Firestore保存を「完了まで待つ」
                    if let user = Auth.auth().currentUser {
                        try await Firestore.firestore()
                            .collection("users")
                            .document(user.uid)
                            .setData([
                                "id": id,
                                "name": id,                 // ← 未入力ならIDを仮名にする（表示が空になりにくい）
                                "grade": grade,
                                "faculty": faculty,
                                "department": department
                            ], merge: true)
                    }

                    // AuthのdisplayNameにも反映（任意）
                    if let user = Auth.auth().currentUser {
                        let req = user.createProfileChangeRequest()
                        req.displayName = id
                        req.commitChanges(completion: nil)
                    }

                } else {
                    try await AuthManager.shared.login(id: id, password: pw)

                    // ✅ login後も profile を upsert（これで再ログイン後も確実に反映）
                    if let user = Auth.auth().currentUser {
                        try await Firestore.firestore()
                            .collection("users")
                            .document(user.uid)
                            .setData([
                                "id": id,
                                "grade": grade,
                                "faculty": faculty,
                                "department": department
                            ], merge: true)
                    }

                    // ローカルも更新（ProfileEditの即反映に効く）
                    UserDefaults.standard.set([
                        "id": id,
                        "grade": grade,
                        "faculty": faculty,
                        "department": department
                    ], forKey: Keys.localProfileDraft)
                }

                // 設定タブへ切り替え
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
                await MainActor.run {
                    self?.tabBarController?.selectedIndex = 4
                    // 0.8秒後に「初回アバター促し」通知を送る（設定VC側で1.2秒ディレイして提示）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        NotificationCenter.default.post(name: .shouldPromptInitialAvatar, object: nil)
                    }
                }
            } catch let e as AuthError {
                await MainActor.run { self?.showAlert(title: "エラー", message: e.localizedDescription) }
            } catch {
                await MainActor.run { self?.showAlert(title: "エラー", message: error.localizedDescription) }
            }
        }
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




// MARK: - UIPickerView DataSource/Delegate
extension AuthViewController: UIPickerViewDataSource, UIPickerViewDelegate {

    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        if pickerView === gradePicker { return 1 }
        return 2 // 学部・学科
    }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        if pickerView === gradePicker { return gradeOptions.count }          // 学年は「指定なし」あり
        if component == 0 { return facultyNames.count + 1 }                  // 学部末尾に「指定なし」
        let fIndex = facultyDeptPicker.selectedRow(inComponent: 0)
        if fIndex == facultyNames.count { return 0 }                         // 学部=指定なし → 学科行は無し
        let faculty = facultyNames[fIndex]
        return FACULTY_DATA[faculty]?.count ?? 0                             // 学科は通常のみ（指定なしナシ）
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
            gradeField.text = gradeOptions[row]                              // 保存は authFlow 内
            return
        }

        if component == 0 {
            // 学部
            if row == facultyNames.count {
                // 学部=指定なし → テキストを「指定なし」、学科は空
                facultyDeptField.text = "指定なし"
                selectedFacultyIndex = row
                selectedDepartmentIndex = 0
                facultyDeptPicker.reloadComponent(1)
                return
            }
            selectedFacultyIndex = row
            selectedDepartmentIndex = 0
            facultyDeptPicker.reloadComponent(1)

            // 先頭の学科があればプレビュー表示しておく
            if let first = FACULTY_DATA[facultyNames[row]]?.first {
                facultyDeptPicker.selectRow(0, inComponent: 1, animated: false)
                facultyDeptField.text = "\(facultyNames[row])・\(first)"
            } else {
                facultyDeptField.text = facultyNames[row]
            }
        } else {
            // 学科
            let fIndex = facultyDeptPicker.selectedRow(inComponent: 0)
            guard fIndex < facultyNames.count else { return }
            selectedDepartmentIndex = row
            let faculty = facultyNames[fIndex]
            let dept = FACULTY_DATA[faculty]?[row] ?? ""
            facultyDeptField.text = dept.isEmpty ? faculty : "\(faculty)・\(dept)"
        }
    }
}


// 安全添字ヘルパ
private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
