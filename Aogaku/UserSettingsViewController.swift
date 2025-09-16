import UIKit
import PhotosUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

final class UserSettingsViewController: UIViewController, SideMenuDrawerDelegate {

    // MARK: - UI (アイコン + カメラ)
    private let avatarView = UIImageView()
    private let cameraButton = UIButton(type: .system)

    // MARK: - Profile Fields
    private let gradeField = UITextField()
    private let facultyDeptField = UITextField()

    private let nameTitle = UILabel()
    private let nameField = UITextField()

    private let idTitle = UILabel()
    private let idField = UITextField()

    private let stack = UIStackView()

    // MARK: - Pickers
    private let gradePicker = UIPickerView()
    private let facultyDeptPicker = UIPickerView()
    private let gradeOptions = ["1年","2年","3年","4年"]

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

    // MARK: - Firebase
    private let db = Firestore.firestore()
    private var uid: String? { Auth.auth().currentUser?.uid }

    // 右上メニュー（Storyboardでも/なくてもOK）
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
        loadCurrentAvatarIfExists()
        loadUserProfile()

        setupDismissKeyboardGesture()
    }

    // Storyboard上で右上ボタン未設置の保険
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

    // MARK: - Avatar UI
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
            avatarView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            avatarView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 140),
            avatarView.heightAnchor.constraint(equalTo: avatarView.widthAnchor)
        ])
        view.layoutIfNeeded()
        avatarView.layer.cornerRadius = 70

        // アイコンタップでも画像選択
        let tap = UITapGestureRecognizer(target: self, action: #selector(selectAvatar))
        avatarView.addGestureRecognizer(tap)

        // カメラボタン（右下）
        let camImg = UIImage(systemName: "camera.fill")
        cameraButton.setImage(camImg, for: .normal)
        cameraButton.tintColor = .white
        cameraButton.backgroundColor = .black.withAlphaComponent(0.7)
        cameraButton.layer.cornerRadius = 16
        cameraButton.layer.shadowOpacity = 0.15
        cameraButton.layer.shadowRadius = 4
        cameraButton.addTarget(self, action: #selector(selectAvatar), for: .touchUpInside)
        cameraButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cameraButton)

        NSLayoutConstraint.activate([
            cameraButton.widthAnchor.constraint(equalToConstant: 32),
            cameraButton.heightAnchor.constraint(equalToConstant: 32),
            cameraButton.trailingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 6),
            cameraButton.bottomAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 6)
        ])
    }

    // MARK: - Profile UI（学年/学部学科/名前/ID）
    private func setupProfileUI() {
        // 入力共通ツールバー（完了）
        func doneToolbar(_ selector: Selector) -> UIToolbar {
            let tb = UIToolbar()
            tb.sizeToFit()
            tb.items = [
                UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                UIBarButtonItem(title: "完了", style: .done, target: self, action: selector)
            ]
            return tb
        }

        // 学年
        gradeField.attributedPlaceholder = NSAttributedString(
            string: "学年",
            attributes: [.foregroundColor: UIColor.placeholderText]
        )
        gradeField.borderStyle = .roundedRect
        gradeField.inputView = gradePicker
        gradeField.inputAccessoryView = doneToolbar(#selector(endEditingFields))
        gradePicker.dataSource = self
        gradePicker.delegate = self

        // 学部・学科（2段ピッカー）
        facultyDeptField.attributedPlaceholder = NSAttributedString(
            string: "学部・学科",
            attributes: [.foregroundColor: UIColor.placeholderText]
        )
        facultyDeptField.borderStyle = .roundedRect
        facultyDeptField.inputView = facultyDeptPicker
        facultyDeptField.inputAccessoryView = doneToolbar(#selector(endEditingFields))
        facultyDeptPicker.dataSource = self
        facultyDeptPicker.delegate = self

        // 名前（表示名）
        nameTitle.text = "名前"
        nameTitle.font = .systemFont(ofSize: 16, weight: .semibold)

        nameField.placeholder = "未設定"
        nameField.borderStyle = .none
        nameField.clearButtonMode = .whileEditing
        nameField.inputAccessoryView = doneToolbar(#selector(commitName))
        nameField.addTarget(self, action: #selector(nameEditingChanged), for: .editingChanged)

        // ID（読み取り専用）
        idTitle.text = "ID"
        idTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        idField.borderStyle = .none
        idField.isEnabled = false
        idField.textColor = .secondaryLabel

        // レイアウト
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        // 1行目：学年・学部学科（横並び）
        let row1 = UIStackView(arrangedSubviews: [gradeField, facultyDeptField])
        row1.axis = .horizontal
        row1.spacing = 12
        row1.distribution = .fillEqually

        // 2行目：名前タイトル＋フィールド
        let nameStack = UIStackView()
        nameStack.axis = .vertical
        nameStack.spacing = 8
        nameStack.addArrangedSubview(nameTitle)
        nameStack.addArrangedSubview(underlineWrap(nameField))

        // 3行目：IDタイトル＋フィールド（非編集）
        let idStack = UIStackView()
        idStack.axis = .vertical
        idStack.spacing = 8
        idStack.addArrangedSubview(idTitle)
        idStack.addArrangedSubview(underlineWrap(idField))

        [row1, nameStack, idStack].forEach { stack.addArrangedSubview($0) }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),

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
            guard let self, let data = snap?.data() else { return }

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

            // 名前（表示名）
            if let name = data["name"] as? String, !name.isEmpty {
                self.nameField.text = name
            } else {
                self.nameField.text = nil
            }

            // ID（読み取り専用）
            if let id = data["id"] as? String {
                self.idField.text = id
            } else if let disp = Auth.auth().currentUser?.displayName {
                self.idField.text = disp
            }
        }
    }

    // MARK: - Save handlers
    @objc private func endEditingFields() { view.endEditing(true) }

    @objc private func nameEditingChanged() {
        // 入力中は何もしない（完了時に確定）
    }

    @objc private func commitName() {
        view.endEditing(true)
        guard let uid, let text = nameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

        // Firestore 保存
        db.collection("users").document(uid).setData(["name": text], merge: true)

        // Auth の displayName も更新（任意）
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
    private func loadCurrentAvatarIfExists() {
        if let url = Auth.auth().currentUser?.photoURL {
            loadImage(from: url) { [weak self] img in self?.avatarView.image = img ?? self?.avatarView.image }
            return
        }
        guard let uid = self.uid else { return }
        db.collection("users").document(uid).getDocument { [weak self] snap, _ in
            guard let self else { return }
            if let str = snap?.data()?["photoURL"] as? String, let url = URL(string: str) {
                self.loadImage(from: url) { img in self.avatarView.image = img ?? self.avatarView.image }
            }
        }
    }

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

        // 即時反映
        self.avatarView.image = image

        // Storage へアップロード
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

                // Firestore & Auth を更新
                self.db.collection("users").document(uid).setData([
                    "photoURL": url.absoluteString,
                    "photoUpdatedAt": FieldValue.serverTimestamp()
                ], merge: true)

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

    private func loadImage(from url: URL, completion: @escaping (UIImage?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let img = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async { completion(img) }
        }.resume()
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
            pickerView.selectRow(0, inComponent: 1, animated: true)
        } else {
            selectedDepartmentIndex = row
        }
        let faculty = facultyNames[safe: selectedFacultyIndex] ?? facultyNames.first ?? ""
        let department = FACULTY_DATA[faculty]?[safe: selectedDepartmentIndex] ?? ""
        facultyDeptField.text = department.isEmpty ? faculty : "\(faculty)・\(department)"
        updateFacultyDept(faculty: faculty, department: department)
    }
}

// 安全添字
private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
