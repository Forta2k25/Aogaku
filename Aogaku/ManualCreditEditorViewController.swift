//
//  ManualCreditEditorViewController.swift
//  Aogaku
//
//  Created by shu m on 2025/09/05.
//
import UIKit


/// 呼び出し側との型統一：外部からは `ManualCreditInput` として見えるが、
/// 実体はこの画面内の `Input` を使う
typealias ManualCreditInput = ManualCreditEditorViewController.Input


final class ManualCreditEditorViewController: UIViewController, UIPickerViewDataSource, UIPickerViewDelegate, UITextFieldDelegate {
    
    
    // ← これを追加（呼び出し側と同じプロパティ名）
    struct Input {
        var title: String
        var credits: Int
        var categoryIndex: Int   // 0:青山 1:外国語 2:学科 3:自由
        var isPlanned: Bool
        var termText: String     // 例: "23 前期" のような表示用文字列
    }

    // MARK: - Init

    private let onSave: (ManualCreditInput) -> Void
    private let termChoices: [String]
    private let initial: ManualCreditInput?

    /// - Parameters:
    ///   - termChoices: ピッカーに出す学期ラベル（表示文字列）
    ///   - initial: 編集時に流し込む値（新規なら nil）
    ///   - onSave: 保存時にコールバック
    init(termChoices: [String], initial: ManualCreditInput? = nil, onSave: @escaping (ManualCreditInput) -> Void) {
        self.termChoices = termChoices.isEmpty ? ["今学期"] : termChoices
        self.initial = initial
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - UI

    private let titleField = UITextField()
    private let creditsField = UITextField()
    private let seg = UISegmentedControl(items: ["青山", "外国語", "学科", "自由"])
    private let plannedSwitch = UISwitch()
    private let termPicker = UIPickerView()
    private let saveButton = UIButton(type: .system)

    private var selectedTermRow: Int = 0
    
    // キーボード上部の「完了」ボタン
    private lazy var kbToolbar: UIToolbar = {
        let bar = UIToolbar()
        bar.sizeToFit()
        let flex = UIBarButtonItem(systemItem: .flexibleSpace)
        let done = UIBarButtonItem(title: "閉じる", style: .done, target: self, action: #selector(dismissKeyboard))
        bar.items = [flex, done]
        return bar
    }()

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "単位を追加"
        view.backgroundColor = .systemBackground

        // ナビの閉じる/保存（右上保存はフォーム下ボタンと同じ動き）
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismissOrPop() })
        //navigationItem.rightBarButtonItem = UIBarButtonItem(title: "保存", style: .done, target: self, action: #selector(tapSave))

        // 各 UI を軽くセットアップ
        titleField.placeholder = "科目名（例：英語学概論）"
        titleField.borderStyle = .roundedRect
        titleField.delegate = self
        titleField.returnKeyType = .next

        creditsField.placeholder = "単位数（整数）"
        creditsField.borderStyle = .roundedRect
        creditsField.keyboardType = .numberPad
        
        // キーボードに「閉じる」ボタンを載せる
        titleField.inputAccessoryView = kbToolbar
        creditsField.inputAccessoryView = kbToolbar

        seg.selectedSegmentIndex = 0

        termPicker.dataSource = self
        termPicker.delegate = self

        saveButton.configuration = .filled()
        saveButton.configuration?.title = "保存"
        saveButton.configuration?.cornerStyle = .large
        saveButton.addAction(UIAction { [weak self] _ in self?.tapSave() }, for: .touchUpInside)

        // レイアウト
        let grid = UIStackView(); grid.axis = .vertical; grid.spacing = 14
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)

        func row(_ title: String, right: UIView) -> UIStackView {
            let l = UILabel(); l.text = title; l.font = .systemFont(ofSize: 15, weight: .semibold)
            let r = right; r.setContentHuggingPriority(.required, for: .horizontal)
            let s = UIStackView(arrangedSubviews: [l, UIView(), r])
            s.alignment = .center
            return s
        }
        

        grid.addArrangedSubview(titleField)
        grid.addArrangedSubview(creditsField)
        grid.addArrangedSubview(seg)

        let plannedRow = row("今学期の取得予定として登録", right: plannedSwitch)
        grid.addArrangedSubview(plannedRow)

        let termTitle = UILabel(); termTitle.text = "学期"; termTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        grid.addArrangedSubview(termTitle)
        grid.addArrangedSubview(termPicker)

        grid.addArrangedSubview(saveButton)

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            grid.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16)
        ])
        
        // 余白タップでキーボード閉じる
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        // 初期値（編集用 or 既定）
        if let initial {
            titleField.text = initial.title
            creditsField.text = String(initial.credits)
            seg.selectedSegmentIndex = initial.categoryIndex
            plannedSwitch.isOn = initial.isPlanned
            if let idx = termChoices.firstIndex(of: initial.termText) {
                selectedTermRow = idx
            }
        } else {
            selectedTermRow = 0
        }
        termPicker.selectRow(selectedTermRow, inComponent: 0, animated: false)
    }

    private func dismissOrPop() {
        if let nav = navigationController, nav.viewControllers.first != self {
            nav.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    // MARK: - Picker

    func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }
    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int { termChoices.count }
    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? { termChoices[row] }
    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) { selectedTermRow = row }

    // MARK: - Save

    @objc private func tapSave() {
        // 入力バリデーション（最低限）
        let name = titleField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            showTip("科目名を入力してください"); return
        }
        guard let num = Int(creditsField.text ?? ""), num > 0 else {
            showTip("単位数は 1 以上の整数で入力してください"); return
        }
        let idx = max(0, min(seg.selectedSegmentIndex, 3))
        let term = termChoices[selectedTermRow]

        onSave(ManualCreditInput(title: name, credits: num, categoryIndex: idx, isPlanned: plannedSwitch.isOn, termText: term))
        dismissOrPop()
    }

    private func showTip(_ msg: String) {
        let alert = UIAlertController(title: nil, message: msg, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // キーボード Next
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField == titleField {
            creditsField.becomeFirstResponder()
        }
        return true
    }
}
