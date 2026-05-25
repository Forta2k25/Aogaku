import UIKit
import FirebaseAuth
import FirebaseFirestore

final class IDSetupViewController: UIViewController {

    // MARK: - UI
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let nameField = UITextField()
    private let gradeField = UITextField()
    private let facultyDeptField = UITextField()
    private let idField = UITextField()
    private let doneButton = UIButton(type: .system)
    private let stack = UIStackView()

    // MARK: - Pickers
    private let gradePicker = UIPickerView()
    private let facultyDeptPicker = UIPickerView()
    private let gradeOptions = ["1年", "2年", "3年", "4年", "指定なし"]

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

    // MARK: - LifeCycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
        setupPickers()
        setupDismissKeyboardGesture()
    }

    // MARK: - UI Setup
    private func setupUI() {
        titleLabel.text = "アカウント設定"
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.textAlignment = .center

        subtitleLabel.text = "青山ハックで使うIDと学年・学部を設定してください。\nIDは後から変更できません。"
        subtitleLabel.font = .systemFont(ofSize: 14)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0
        subtitleLabel.textAlignment = .center

        nameField.placeholder = "表示名（あとから変更できます）"
        nameField.borderStyle = .roundedRect
        nameField.clearButtonMode = .whileEditing
        nameField.returnKeyType = .next

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

        idField.placeholder = "ID（英数字・._　3〜24文字）"
        idField.autocapitalizationType = .none
        idField.autocorrectionType = .no
        idField.borderStyle = .roundedRect
        idField.clearButtonMode = .whileEditing
        idField.returnKeyType = .done

        doneButton.setTitle("完了", for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        doneButton.backgroundColor = HackColors.accent
        doneButton.setTitleColor(.white, for: .normal)
        doneButton.layer.cornerRadius = 12
        doneButton.addTarget(self, action: #selector(done), for: .touchUpInside)

        let noteLabel = UILabel()
        noteLabel.text = "※登録する「ID」は学内システムの学生番号とは異なります。"
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.textColor = .secondaryLabel
        noteLabel.numberOfLines = 0
        noteLabel.textAlignment = .center

        stack.axis = .vertical
        stack.spacing = 16
        [titleLabel, subtitleLabel, nameField, gradeField, facultyDeptField, idField, doneButton, noteLabel]
            .forEach { stack.addArrangedSubview($0) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            nameField.heightAnchor.constraint(equalToConstant: 44),
            gradeField.heightAnchor.constraint(equalToConstant: 44),
            facultyDeptField.heightAnchor.constraint(equalToConstant: 44),
            idField.heightAnchor.constraint(equalToConstant: 44),
            doneButton.heightAnchor.constraint(equalToConstant: 52),
        ])

        let toolbar = makeToolbar()
        [nameField, gradeField, facultyDeptField, idField].forEach { $0.inputAccessoryView = toolbar }
        nameField.addTarget(self, action: #selector(endEditing), for: .editingDidEndOnExit)
        idField.addTarget(self, action: #selector(endEditing), for: .editingDidEndOnExit)
    }

    private func setupPickers() {
        gradePicker.dataSource = self
        gradePicker.delegate = self
        facultyDeptPicker.dataSource = self
        facultyDeptPicker.delegate = self
    }

    private func setupDismissKeyboardGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(endEditing))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    private func makeToolbar() -> UIToolbar {
        let tb = UIToolbar()
        tb.sizeToFit()
        tb.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(title: "完了", style: .done, target: self, action: #selector(endEditing))
        ]
        return tb
    }

    @objc private func endEditing() { view.endEditing(true) }

    // MARK: - Done Action
    @objc private func done() {
        let nameText = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let idText = (idField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let gradeText = gradeField.text ?? ""
        let facultyDeptText = facultyDeptField.text ?? ""

        guard !idText.isEmpty, !gradeText.isEmpty, !facultyDeptText.isEmpty else {
            showAlert(title: "入力エラー", message: "学年・学部学科・IDをすべて入力してください。")
            return
        }

        let grade: Int = (gradeText == "指定なし")
            ? 0 : max(1, min(4, Int(gradeText.replacingOccurrences(of: "年", with: "")) ?? 1))
        var comps = facultyDeptText.components(separatedBy: "・")
        var faculty = comps.first ?? ""
        var department = comps.count > 1 ? comps[1] : ""
        if facultyDeptText == "指定なし" || faculty.isEmpty { faculty = ""; department = "" }

        view.endEditing(true)
        let hud = UIActivityIndicatorView(style: .large)
        hud.startAnimating()
        view.isUserInteractionEnabled = false
        view.addSubview(hud)
        hud.center = view.center

        Task { [weak self] in
            guard let self else { return }
            defer {
                hud.removeFromSuperview()
                self.view.isUserInteractionEnabled = true
            }
            do {
                try await AuthManager.shared.setupIDForGoogleUser(
                    id: idText, name: nameText, grade: grade, faculty: faculty, department: department
                )
                await MainActor.run { self.dismiss(animated: true) }
            } catch let e as AuthError {
                await MainActor.run { self.showAlert(title: "エラー", message: e.localizedDescription) }
            } catch {
                await MainActor.run { self.showAlert(title: "エラー", message: error.localizedDescription) }
            }
        }
    }

    private func showAlert(title: String, message: String = "") {
        let ac = UIAlertController(title: title, message: message, preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "OK", style: .default))
        present(ac, animated: true)
    }
}

// MARK: - UIPickerView
extension IDSetupViewController: UIPickerViewDataSource, UIPickerViewDelegate {

    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        pickerView === gradePicker ? 1 : 2
    }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        if pickerView === gradePicker { return gradeOptions.count }
        if component == 0 { return facultyNames.count + 1 }
        let fIndex = facultyDeptPicker.selectedRow(inComponent: 0)
        if fIndex == facultyNames.count { return 0 }
        return FACULTY_DATA[facultyNames[fIndex]]?.count ?? 0
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        if pickerView === gradePicker { return gradeOptions[row] }
        if component == 0 { return row == facultyNames.count ? "指定なし" : facultyNames[row] }
        let fIndex = facultyDeptPicker.selectedRow(inComponent: 0)
        guard fIndex < facultyNames.count else { return nil }
        return FACULTY_DATA[facultyNames[fIndex]]?[row] ?? ""
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        if pickerView === gradePicker {
            gradeField.text = gradeOptions[row]
            return
        }
        if component == 0 {
            if row == facultyNames.count {
                facultyDeptField.text = "指定なし"
                facultyDeptPicker.reloadComponent(1)
                return
            }
            facultyDeptPicker.reloadComponent(1)
            if let first = FACULTY_DATA[facultyNames[row]]?.first {
                facultyDeptPicker.selectRow(0, inComponent: 1, animated: false)
                facultyDeptField.text = "\(facultyNames[row])・\(first)"
            } else {
                facultyDeptField.text = facultyNames[row]
            }
        } else {
            let fIndex = facultyDeptPicker.selectedRow(inComponent: 0)
            guard fIndex < facultyNames.count else { return }
            let dept = FACULTY_DATA[facultyNames[fIndex]]?[row] ?? ""
            facultyDeptField.text = dept.isEmpty ? facultyNames[fIndex] : "\(facultyNames[fIndex])・\(dept)"
        }
    }
}
