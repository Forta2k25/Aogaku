import UIKit
import PhotosUI
import SafariServices
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

final class ProfileEditViewController: UIViewController {

    // MARK: - Prefill（統合画面から渡す）
    struct Prefill {
        var name: String?
        var id: String?
        var grade: Int?
        var faculty: String?
        var department: String?
        var photoURL: String?
    }

    private let prefill: Prefill?

    init(prefill: Prefill? = nil) {
        self.prefill = prefill
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.prefill = nil
        super.init(coder: coder)
    }

    // MARK: - Firebase
    private let db = Firestore.firestore()
    private var uid: String? { Auth.auth().currentUser?.uid }

    // MARK: - Local draft
    private enum Keys {
        static let localProfileDraft = "LocalProfileDraftV1"
    }

    // MARK: - UI
    private let scrollView = UIScrollView()
    private let contentView = UIView()

    private let avatarView = UIImageView()

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

    // MARK: - LifeCycle
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "プロフィール編集"
        view.backgroundColor = .systemGroupedBackground

        setupCloseButtonIfNeeded()
        setupHamburgerMenu()

        setupLayout()
        setupPickers()
        setupAvatarTap()
        setupDismissKeyboardGesture()

        // ✅ 開いた瞬間に反映（prefill / LocalDraft / auth）
        applyPrefillImmediately()

        // ✅ 裏でFirestore最新を取得して上書き（photoURLが無ければAuthから補完）
        loadUserProfile()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadUserProfile()
    }

    // MARK: - Close button (modal root の時だけ)
    private func setupCloseButtonIfNeeded() {
        let isModalRoot = (presentingViewController != nil) &&
                          (navigationController?.viewControllers.first === self)
        guard isModalRoot else { return }

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "戻る",
            style: .plain,
            target: self,
            action: #selector(closeSelf)
        )
    }
    
    private func presentCropper(with image: UIImage) {
        let cropVC = ImageCropViewController(image: image, titleText: "アイコンを切り抜き")

        cropVC.onCancel = { [weak cropVC] in
            cropVC?.dismiss(animated: true)
        }

        cropVC.onDone = { [weak self, weak cropVC] cropped in
            cropVC?.dismiss(animated: true) {
                self?.uploadAvatar(cropped)
            }
        }

        present(cropVC, animated: true)
    }

    @objc private func closeSelf() {
        dismiss(animated: true)
    }

    // MARK: - Right hamburger menu
    private func setupHamburgerMenu() {
        let img = UIImage(
            systemName: "line.3.horizontal",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: img,
                                                            style: .plain,
                                                            target: self,
                                                            action: #selector(didTapHamburger))
    }

    @objc private func didTapHamburger() {
        let ac = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

        ac.addAction(UIAlertAction(title: "利用規約", style: .default, handler: { [weak self] _ in
            self?.presentTextPageFromFile(title: "利用規約", fileName: "Terms", fileExt: "rtf")
        }))
        ac.addAction(UIAlertAction(title: "プライバシーポリシー", style: .default, handler: { [weak self] _ in
            self?.presentTextPageFromFile(title: "プライバシーポリシー", fileName: "Privacy", fileExt: "rtf")
        }))
        ac.addAction(UIAlertAction(title: "お問い合わせ", style: .default, handler: { [weak self] _ in
            self?.openContact()
        }))

        ac.addAction(UIAlertAction(title: "ログアウト", style: .destructive, handler: { [weak self] _ in
            self?.confirmLogout()
        }))

        ac.addAction(UIAlertAction(title: "アカウント削除", style: .destructive, handler: { [weak self] _ in
            self?.confirmDeleteAccount()
        }))

        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))

        if let pop = ac.popoverPresentationController {
            pop.barButtonItem = navigationItem.rightBarButtonItem
        }
        present(ac, animated: true)
    }

    private func openContact() {
        guard let url = URL(string: "https://lin.ee/6O9GBTz") else { return }
        let safari = SFSafariViewController(url: url)
        safari.preferredControlTintColor = .systemBlue
        present(safari, animated: true)
    }

    private func confirmLogout() {
        let ac = UIAlertController(title: "ログアウトしますか？",
                                   message: "現在のアカウントからサインアウトします。",
                                   preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        ac.addAction(UIAlertAction(title: "ログアウト", style: .destructive, handler: { [weak self] _ in
            self?.performSignOut()
        }))
        present(ac, animated: true)
    }

    private func performSignOut() {
        do { try Auth.auth().signOut() }
        catch {
            showAlert(title: "ログアウトに失敗", message: error.localizedDescription)
            return
        }

        if presentingViewController != nil {
            dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    private func confirmDeleteAccount() {
        let ac = UIAlertController(
            title: "アカウントを削除しますか？",
            message: "この操作は取り消せません。",
            preferredStyle: .alert
        )
        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        ac.addAction(UIAlertAction(title: "削除", style: .destructive, handler: { [weak self] _ in
            self?.performDeleteAccount()
        }))
        present(ac, animated: true)
    }

    private func performDeleteAccount() {
        guard let user = Auth.auth().currentUser, let uid = user.uid as String? else { return }

        Task { @MainActor in
            do { try await db.collection("users").document(uid).delete() } catch { }

            do {
                try await user.delete()
            } catch {
                showAlert(title: "削除に失敗",
                          message: "再ログイン直後に再度お試しください。\n(\(error.localizedDescription))")
                return
            }

            try? Auth.auth().signOut()

            if presentingViewController != nil {
                dismiss(animated: true)
            } else {
                navigationController?.popViewController(animated: true)
            }

            showAlert(title: "アカウント削除", message: "削除が完了しました。")
        }
    }

    // MARK: - UI
    private func setupLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = 70
        avatarView.backgroundColor = .secondarySystemFill
        avatarView.image = UIImage(systemName: "person.circle.fill")
        avatarView.tintColor = .tertiaryLabel
        avatarView.isUserInteractionEnabled = true

        contentView.addSubview(avatarView)
        NSLayoutConstraint.activate([
            avatarView.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor, constant: 24),
            avatarView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 140),
            avatarView.heightAnchor.constraint(equalTo: avatarView.widthAnchor)
        ])

        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -28)
        ])

        gradeField.placeholder = "学年"
        gradeField.borderStyle = .roundedRect
        gradeField.textAlignment = .center
        gradeField.textColor = .label

        facultyDeptField.placeholder = "学部・学科"
        facultyDeptField.borderStyle = .roundedRect
        facultyDeptField.textAlignment = .center
        facultyDeptField.textColor = .label

        let row1 = UIStackView(arrangedSubviews: [gradeField, facultyDeptField])
        row1.axis = .horizontal
        row1.spacing = 12
        row1.distribution = .fill
        stack.addArrangedSubview(row1)

        NSLayoutConstraint.activate([
            gradeField.heightAnchor.constraint(equalToConstant: 44),
            facultyDeptField.heightAnchor.constraint(equalToConstant: 44),
            gradeField.widthAnchor.constraint(equalTo: facultyDeptField.widthAnchor, multiplier: 0.45)
        ])

        nameTitle.text = "名前"
        nameTitle.font = .systemFont(ofSize: 16, weight: .semibold)

        nameField.placeholder = "未設定"
        nameField.borderStyle = .roundedRect
        nameField.returnKeyType = .done
        nameField.textColor = .label
        nameField.addTarget(self, action: #selector(commitName), for: .editingDidEndOnExit)
        nameField.addTarget(self, action: #selector(commitName), for: .editingDidEnd)

        let nameStack = UIStackView(arrangedSubviews: [nameTitle, nameField])
        nameStack.axis = .vertical
        nameStack.spacing = 8
        stack.addArrangedSubview(nameStack)

        idTitle.text = "ID"
        idTitle.font = .systemFont(ofSize: 16, weight: .semibold)

        idField.placeholder = "未設定"
        idField.borderStyle = .roundedRect
        idField.isEnabled = false
        idField.textColor = .secondaryLabel   // ✅ 薄グレーはIDだけ

        let idStack = UIStackView(arrangedSubviews: [idTitle, idField])
        idStack.axis = .vertical
        idStack.spacing = 8
        stack.addArrangedSubview(idStack)
    }

    private func setupPickers() {
        gradePicker.dataSource = self
        gradePicker.delegate = self
        facultyDeptPicker.dataSource = self
        facultyDeptPicker.delegate = self

        gradeField.inputView = gradePicker
        facultyDeptField.inputView = facultyDeptPicker

        let tb = UIToolbar()
        tb.sizeToFit()
        tb.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(title: "完了", style: .done, target: self, action: #selector(endEditingFields))
        ]
        gradeField.inputAccessoryView = tb
        facultyDeptField.inputAccessoryView = tb
        nameField.inputAccessoryView = tb
    }

    private func setupAvatarTap() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(selectAvatar))
        avatarView.addGestureRecognizer(tap)
    }

    private func setupDismissKeyboardGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(endEditingFields))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    @objc private func endEditingFields() {
        view.endEditing(true)
    }

    // MARK: - Local Draft
    private func loadLocalDraft() -> Prefill? {
        guard let dict = UserDefaults.standard.dictionary(forKey: Keys.localProfileDraft) else { return nil }
        let id = dict["id"] as? String
        let grade = dict["grade"] as? Int
        let faculty = dict["faculty"] as? String
        let department = dict["department"] as? String
        let photoURL = dict["photoURL"] as? String
        return Prefill(name: nil, id: id, grade: grade, faculty: faculty, department: department, photoURL: photoURL)
    }

    private func updateLocalDraft(photoURL: String?) {
        guard let photoURL, !photoURL.isEmpty else { return }
        var dict = UserDefaults.standard.dictionary(forKey: Keys.localProfileDraft) ?? [:]
        dict["photoURL"] = photoURL
        UserDefaults.standard.set(dict, forKey: Keys.localProfileDraft)
    }

    // MARK: - ✅ Prefill (prefill → localDraft → auth)
    private func applyPrefillImmediately() {
        let local = loadLocalDraft()
        let source = prefill ?? local

        // ✅ アイコン：prefill/localDraft → auth.photoURL
        let url = source?.photoURL ?? Auth.auth().currentUser?.photoURL?.absoluteString
        if let url, !url.isEmpty { loadImage(urlString: url) }

        // 名前
        if let n = source?.name, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nameField.text = n
        } else if let dn = Auth.auth().currentUser?.displayName, !dn.isEmpty {
            nameField.text = dn
        }

        // ID
        if let id = source?.id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            idField.text = id
        } else if let dn = Auth.auth().currentUser?.displayName, !dn.isEmpty {
            idField.text = dn
        }

        // 学年
        if let g = source?.grade { applyGradeToUI(g) }

        // 学部学科
        if let fac = source?.faculty, !fac.isEmpty {
            applyFacultyDeptToUI(faculty: fac, department: source?.department ?? "")
        }
    }

    // MARK: - Load from Firestore (latest)
    private func loadUserProfile() {
        guard let uid else { return }

        db.collection("users").document(uid).getDocument { [weak self] snap, _ in
            guard let self else { return }
            let data = snap?.data() ?? [:]

            let name = (data["name"] as? String) ?? ""
            let id = (data["id"] as? String) ?? ""
            let grade = data["grade"] as? Int
            let faculty = data["faculty"] as? String
            let dept = data["department"] as? String
            let photoURLFromFS = data["photoURL"] as? String

            // ✅ FirestoreにphotoURLが無ければ Auth.photoURL を使う（＆Firestoreへ補完）
            let authPhoto = Auth.auth().currentUser?.photoURL?.absoluteString
            let usedPhotoURL = (photoURLFromFS?.isEmpty == false) ? photoURLFromFS : authPhoto

            DispatchQueue.main.async {
                if !name.isEmpty { self.nameField.text = name }
                if !id.isEmpty { self.idField.text = id }
                if let grade { self.applyGradeToUI(grade) }
                if let faculty, !faculty.isEmpty {
                    self.applyFacultyDeptToUI(faculty: faculty, department: dept ?? "")
                }
                if let u = usedPhotoURL, !u.isEmpty {
                    self.loadImage(urlString: u)
                    self.updateLocalDraft(photoURL: u)
                }
            }

            // ✅ FirestoreにphotoURLが空だったら補完しておく（次回から確実に反映）
            if (photoURLFromFS == nil || photoURLFromFS == ""), let u = authPhoto, !u.isEmpty {
                self.db.collection("users").document(uid).setData(["photoURL": u], merge: true)
            }
        }
    }

    // MARK: - Save handlers
    @objc private func commitName() {
        guard let uid else { return }
        let text = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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

    // MARK: - Avatar picker & upload
    @objc private func selectAvatar() {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func uploadAvatar(_ image: UIImage) {
        guard let uid else { return }

        avatarView.image = image

        let resized = image.resized(maxEdge: 512)
        guard let data = resized.jpegData(compressionQuality: 0.75) else { return }

        let ref = Storage.storage().reference(withPath: "avatars/\(uid).jpg")
        let meta = StorageMetadata()
        meta.contentType = "image/jpeg"

        ref.putData(data, metadata: meta) { [weak self] _, error in
            guard let self else { return }
            if let error { print("upload error:", error); return }

            ref.downloadURL { url, error in
                if let error { print("url error:", error); return }
                guard let url else { return }

                // ✅ Firestoreに保存
                self.db.collection("users").document(uid).setData([
                    "photoURL": url.absoluteString,
                    "photoUpdatedAt": FieldValue.serverTimestamp()
                ], merge: true)

                // ✅ LocalDraftにも保存（次回起動/再ログインでも即反映）
                self.updateLocalDraft(photoURL: url.absoluteString)

                // ✅ Authにも保存
                if let user = Auth.auth().currentUser {
                    let req = user.createProfileChangeRequest()
                    req.photoURL = url
                    req.commitChanges(completion: nil)
                }
            }
        }
    }

    // MARK: - UI apply helpers
    private func applyGradeToUI(_ grade: Int) {
        if (1...4).contains(grade) {
            gradeField.text = "\(grade)年"
            gradePicker.selectRow(grade - 1, inComponent: 0, animated: false)
        } else {
            gradeField.text = "指定なし"
            gradePicker.selectRow(4, inComponent: 0, animated: false)
        }
    }

    private func applyFacultyDeptToUI(faculty: String, department: String) {
        facultyDeptField.text = department.isEmpty ? faculty : "\(faculty)・\(department)"

        if let fIdx = facultyNames.firstIndex(of: faculty) {
            selectedFacultyIndex = fIdx
            facultyDeptPicker.reloadAllComponents()
            facultyDeptPicker.selectRow(fIdx, inComponent: 0, animated: false)

            if let list = FACULTY_DATA[faculty], let dIdx = list.firstIndex(of: department) {
                selectedDepartmentIndex = dIdx
                facultyDeptPicker.selectRow(dIdx, inComponent: 1, animated: false)
            } else {
                selectedDepartmentIndex = 0
                if (FACULTY_DATA[faculty]?.count ?? 0) > 0 {
                    facultyDeptPicker.selectRow(0, inComponent: 1, animated: false)
                }
            }
        }
    }

    private func loadImage(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self else { return }
            guard let data, let img = UIImage(data: data) else { return }
            DispatchQueue.main.async { self.avatarView.image = img }
        }.resume()
    }

    private func showAlert(title: String, message: String = "") {
        let ac = UIAlertController(title: title, message: message, preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "OK", style: .default))
        present(ac, animated: true)
    }
}

// MARK: - PHPicker Delegate
extension ProfileEditViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }
        guard provider.canLoadObject(ofClass: UIImage.self) else { return }

        provider.loadObject(ofClass: UIImage.self) { [weak self] obj, _ in
            guard let self, let image = obj as? UIImage else { return }
            DispatchQueue.main.async {
                self.presentCropper(with: image)
            }
        }
    }
}

// MARK: - UIPickerView
extension ProfileEditViewController: UIPickerViewDataSource, UIPickerViewDelegate {

    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        if pickerView === gradePicker { return 1 }
        return 2
    }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        if pickerView === gradePicker { return gradeOptions.count }

        if component == 0 { return facultyNames.count + 1 }
        let fIndex = facultyDeptPicker.selectedRow(inComponent: 0)
        if fIndex == facultyNames.count { return 0 }
        let faculty = facultyNames[fIndex]
        return FACULTY_DATA[faculty]?.count ?? 0
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
            let grade = (text == "指定なし") ? 0 : (Int(text.replacingOccurrences(of: "年", with: "")) ?? 0)
            updateGrade(grade)
            return
        }

        if component == 0 {
            if row == facultyNames.count {
                facultyDeptField.text = "指定なし"
                updateFacultyDept(faculty: "", department: "")
                facultyDeptPicker.reloadComponent(1)
                return
            }

            selectedFacultyIndex = row
            selectedDepartmentIndex = 0
            facultyDeptPicker.reloadComponent(1)

            let faculty = facultyNames[row]
            if let first = FACULTY_DATA[faculty]?.first {
                facultyDeptPicker.selectRow(0, inComponent: 1, animated: false)
                facultyDeptField.text = "\(faculty)・\(first)"
                updateFacultyDept(faculty: faculty, department: first)
            } else {
                facultyDeptField.text = faculty
                updateFacultyDept(faculty: faculty, department: "")
            }
            return
        }

        let fIndex = facultyDeptPicker.selectedRow(inComponent: 0)
        guard fIndex < facultyNames.count else { return }
        let faculty = facultyNames[fIndex]
        let department = FACULTY_DATA[faculty]?[row] ?? ""
        facultyDeptField.text = department.isEmpty ? faculty : "\(faculty)・\(department)"
        updateFacultyDept(faculty: faculty, department: department)
    }
}

// MARK: - Textページ遷移
private extension ProfileEditViewController {
    func presentTextPageFromFile(title: String, fileName: String, fileExt: String = "rtf") {
        let perform: () -> Void = { [weak self] in
            guard let self else { return }
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
        if let presented = presentedViewController {
            presented.dismiss(animated: false, completion: perform)
        } else {
            perform()
        }
    }
}

// MARK: - Image util
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
