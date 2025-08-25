//
//  AddCourseViewController.swift
//  Aogaku
//
//  Created by shu m on 2025/08/24.
//
import UIKit

protocol AddCourseViewControllerDelegate: AnyObject {
    func addCourseViewController(_ vc: AddCourseViewController, didCreate course: Course)
}

final class AddCourseViewController: UITableViewController {
    weak var delegate: AddCourseViewControllerDelegate?

    // 入力フィールド（テキスト）
    private let titleTF   = UITextField()
    private let teacherTF = UITextField()
    private let roomTF    = UITextField()
    private let idTF      = UITextField()      // 登録番号（空なら "" のまま）
    private let creditsTF = UITextField()      // 数字
    private let syllabusTF = UITextField()     // URL 文字列を入力

    // 追加：セグメント（キャンパス＝任意、科目分類＝必須）
    private let campusSeg   = UISegmentedControl(items: ["青山", "相模原"])
    private let categorySeg = UISegmentedControl(items: ["青スタ科目", "学科科目", "自由選択科目"])

    // 便利：ビュー埋め込みヘルパ
    private func embed(_ v: UIView, into cell: UITableViewCell) {
        v.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
            v.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
            v.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
            v.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
            v.heightAnchor.constraint(greaterThanOrEqualToConstant: 34)
        ])
    }

    init() {
        super.init(style: .insetGrouped)
        self.title = "新規作成"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.leftBarButtonItem  = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "保存", style: .done, target: self, action: #selector(save))

        // テキスト共通設定
        [titleTF, teacherTF, roomTF, idTF, creditsTF, syllabusTF].forEach {
            $0.clearButtonMode = .whileEditing
            $0.borderStyle = .roundedRect
        }
        titleTF.placeholder   = "科目名（必須）"
        teacherTF.placeholder = "教員名"
        roomTF.placeholder    = "教室"
        idTF.placeholder      = "登録番号"
        creditsTF.placeholder = "単位数（数字）"
        creditsTF.keyboardType = .numberPad
        syllabusTF.placeholder = "シラバスURL"

        // セグメント初期状態（キャンパス＝任意、分類＝必須）
        campusSeg.selectedSegmentIndex = UISegmentedControl.noSegment
        categorySeg.selectedSegmentIndex = UISegmentedControl.noSegment

        tableView.keyboardDismissMode = .onDrag
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func save() {
        // 必須：科目名
        let title = titleTF.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else {
            let a = UIAlertController(title: "科目名が未入力です。", message: "科目名は必須です。", preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            present(a, animated: true); return
        }
        let syllabusString: String? = {
                let s = syllabusTF.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return s.isEmpty ? nil : s
            }()
        
        // --- 単位数の検証 ---
        let creditsTextRaw = creditsTF.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 全角→半角変換してから判定
        let creditsText = creditsTextRaw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? creditsTextRaw

        var creditsValue: Int? = nil
        if !creditsText.isEmpty {
            if let v = Int(creditsText), (0...20).contains(v) {   // 範囲はお好みで
                creditsValue = v
            } else {
                let a = UIAlertController(
                    title: "単位数が不正です。",
                    message: "単位数は 0〜20 の数字で入力してください（例: 1, 2, 4）。",
                    preferredStyle: .alert
                )
                a.addAction(UIAlertAction(title: "OK", style: .default))
                present(a, animated: true)
                return
            }
        }
        // --------------------

        // 必須：科目分類（セグメント）
        guard categorySeg.selectedSegmentIndex != UISegmentedControl.noSegment else {
            let a = UIAlertController(title: "科目分類が未選択です。", message: "科目分類を選んでください。", preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            present(a, animated: true); return
        }

        // セグメント → 文字列
        let campusText: String? = {
            switch campusSeg.selectedSegmentIndex {
            case 0: return "青山"
            case 1: return "相模原"
            default: return nil            // 任意
            }
        }()
        let categoryText: String = {
            ["青山スタンダード科目", "学科科目", "自由選択科目"][categorySeg.selectedSegmentIndex]
        }()

        // URL 文字列 → URL?
        let url: URL? = {
            guard let s = syllabusTF.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty, let u = URL(string: s) else { return nil }
            return u
        }()

        // 登録番号：未入力なら "" のまま（リスト側で "-" 表示に変換）
        let course = Course(
            id: (idTF.text ?? ""),
            title: title,
            room: roomTF.text ?? "",
            teacher: teacherTF.text ?? "",
            credits: creditsValue,   // 未入力なら nil
            campus: campusText,                   // 任意
            category: categoryText,               // 必須
            syllabusURL: syllabusString                      // URL? 型
        )

        CourseStore.add(course)
        delegate?.addCourseViewController(self, didCreate: course)
        dismiss(animated: true)
    }

    // MARK: - table
    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 4   // 基本：科目名 / 教員名 / 教室 / 登録番号
        case 1: return 3   // オプション：キャンパス(セグ) / 単位数 / 科目分類(セグ)
        default: return 1  // リンク：シラバスURL
        }
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "基本情報"
        case 1: return "オプション"
        default: return "リンク"
        }
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none

        switch (indexPath.section, indexPath.row) {
        // 基本
        case (0,0): embed(titleTF,   into: cell)
        case (0,1): embed(teacherTF, into: cell)
        case (0,2): embed(roomTF,    into: cell)
        case (0,3): embed(idTF,      into: cell)

        // オプション（セグメント / 数字TF / セグメント）
        case (1,0): embed(campusSeg,   into: cell)
        case (1,1): embed(creditsTF,   into: cell)
        case (1,2): embed(categorySeg, into: cell)

        // リンク
        default:    embed(syllabusTF, into: cell)
        }
        return cell
    }
}
