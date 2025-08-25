//
//  CourseListViewController.swift
//  Aogaku
//
//  Created by shu m on 2025/08/21.
//

import UIKit

struct Course: Codable, Equatable {
    let id: String
    let title: String
    let room: String          // 教室番号
    let teacher: String       // 教師名
    var credits: Int?          // 単位数
    var campus: String?        // 例: "青山", "相模原"
    var category: String?      // 例: "必修", "選択", "青山スタンダード科目"
    var syllabusURL: String?    // ← これを追加
}

protocol CourseListViewControllerDelegate: AnyObject {
    func courseList(_ vc: CourseListViewController,
                    didSelect course: Course,
                    at location: SlotLocation)
}

final class CourseListViewController: UITableViewController, AddCourseViewControllerDelegate {
    func addCourseViewController(_ vc: AddCourseViewController, didCreate course: Course) {
        reloadAllCourses()
        // 検索中ならフィルタを反映
        if let q = searchField.text, !q.trimmingCharacters(in: .whitespaces).isEmpty {
            textChanged(searchField)
        } else {
            courses = allCourses
            tableView.reloadData()
        }
    }
    
    
    weak var delegate: CourseListViewControllerDelegate?   // ← 追加
    // ...
    
    let location: SlotLocation
    private var courses: [Course] = []
    private var allCourses: [Course] = []
    
    // MARK: - UI (Search)
    private let searchField: UITextField = {
        let tf = UITextField()
        tf.placeholder = "科目名・教員・教室・科目番号で検索"
        tf.borderStyle = .roundedRect
        tf.clearButtonMode = .whileEditing
        tf.returnKeyType = .done
        tf.backgroundColor = .secondarySystemBackground
        tf.layer.cornerRadius = 10
        tf.layer.masksToBounds = true
        
        // 左に🔍アイコン
        let icon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        icon.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        
        let left = UIView(frame: CGRect(x: 0, y: 0, width: 28, height: 36))
        icon.center = CGPoint(x: 14, y: 18)
        left.addSubview(icon)
        
        tf.leftView = left
        tf.leftViewMode = .always
        return tf
    }()
    
    init(location: SlotLocation) {
        self.location = location
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "\(location.dayName) \(location.period)限"
        navigationItem.largeTitleDisplayMode = .never
        
        // 戻る／閉じるボタン（常に右上に出す）
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "戻る",
            style: .plain,
            target: self,
            action: #selector(backToTimetable)
        )
        
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "＋新規作成",
            style: .plain,
            target: self,
            action: #selector(tapAddCourse)
        )
        
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        
        // ★ 追加: iOS 15 のセクションヘッダー上余白をなくす
        if #available(iOS 15.0, *) {
            tableView.sectionHeaderTopPadding = 0
        }
        
        // ↓ ここはダミーデータ。実データがあれば置き換えてOK
        allCourses = [
            Course(id: "15408",
                   title: "Integrated English III",
                   room: "15306",
                   teacher: "Smith",
                   credits: 2,
                   campus: "青山",
                   category: "青山スタンダード科目",
                   syllabusURL:  "https://syllabus.aoyama.ac.jp/shousai.ashx?YR=2025&FN=1611020-0005&KW=&BQ=3f5e5d46524048535c48584c495933294f4e5745515b42564a5e4f5659534a22067e7d756d6071747c687e6e6b68606a6270667c6608050701780d087a0c1866127c7073767060051d74081e7d6b05186d77191e69731d1e657f190b6d60313146382052590a08412f2b5b29335d5349373a304e52313a4a12185c1808114e4fa5b3b6c0d4cdb7a2babde8ffe2c6ebe1e3f0f9e6a9b0d3a1bdd8aebea5debbda9784e09781e494829aeff9cecddfcdc796e2e68e92e5f18a9ee9f9869aedf782"// ←差し替え
                  ),

            Course(id: "17411",
                   title: "歴史と人間",
                   room: "N402",
                   teacher: "佐藤",
                   credits: 2,
                   campus: "青山",
                   category: "青山スタンダード科目",
                   syllabusURL:  "https://syllabus.aoyama.ac.jp/shousai.ashx?YR=2025&FN=1611020-0002&KW=&BQ=3f5e5d46524048535c48584c495933294f4e5745515b42564a5e4f5659534a22067e7d756d6071747c687e6e6b68606a6270667c6608050701780d087a0c1866127c7073767060051d74081e7d6b05186d77191e69731d1e657f190b6d60313146382052590a08412f2b5b29335d5349373a304e52313a4a12185c1808114e4fa5b3b6c0d4cdb7a2babde8ffe2c6ebe1e3f0f9e6a9b0d3a1bdd8aebea5debbda9784e09781e494829aeff9cecddfcdc796e2e68e92e5f18a9ee9f9869aedf782"
                  ),

            Course(id: "17710",
                   title: "グローバル文学理論",
                   room: "A305",
                   teacher: "Tanaka",
                   credits: 2,
                   campus: "青山",
                   category: "法学部",
                   syllabusURL:  "https://syllabus.aoyama.ac.jp/shousai.ashx?YR=2025&FN=1611020-0954&KW=&BQ=3f5e5d46524048535c48584c495933294f4e5745515b42564a5e4f5659534a22067e7d756d6071747c687e6e6b68606a6270667c6608050701780d087a0c1866127c7073767060051d74081e7d6b05186d77191e69731d1e657f190b6d60313146382052590a08412f2b5b29335d5349373a304e52313a4a12185c1808114e4fa5b3b6c0d4cdb7a2babde8ffe2c6ebe1e3f0f9e6a9b0d3a1bdd8aebea5debbda9784e09781e494829aeff9cecddfcdc796e2e68e92e5f18a9ee9f9869aedf782"
                  )
        ]
        reloadAllCourses()
        
        allCourses = builtinCourses() + CourseStore.load()
        courses = allCourses
        tableView.reloadData()

        
        // 検索フィールドのイベント & ヘッダー設置
        searchField.addTarget(self, action: #selector(textChanged(_:)), for: .editingChanged)
        searchField.addTarget(self, action: #selector(endEditingNow), for: .editingDidEndOnExit)
        buildSearchHeader() // ← メソッド名はそのまま使う
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        courses.count
    }
    
    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        let c = courses[indexPath.row]
        guard CourseStore.isCustom(c) else { return nil }

        let delete = UIContextualAction(style: .destructive, title: "削除") { _,_,done in
            CourseStore.remove(id: c.id)
            self.reloadAllCourses()
            // 今の並び（検索適用有無）を保ったまま再構築
            if let q = self.searchField.text, !q.trimmingCharacters(in: .whitespaces).isEmpty {
                self.textChanged(self.searchField)
            } else {
                self.courses = self.allCourses
                tableView.deleteRows(at: [indexPath], with: .automatic)
            }
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let c = courses[indexPath.row]
        var cfg = cell.defaultContentConfiguration()
        cfg.text = c.title
        cfg.textProperties.numberOfLines = 1

        // ← ここだけ差し替え（2行レイアウト用）
        cfg.secondaryText = metaTwoLines(for: c)
        cfg.secondaryTextProperties.numberOfLines = 0           // 必要分だけ折り返し
        cfg.secondaryTextProperties.lineBreakMode = .byWordWrapping
        cfg.prefersSideBySideTextAndSecondaryText = false       // タイトルの下に配置
        cfg.textToSecondaryTextVerticalPadding = 4
        cfg.secondaryTextProperties.color = .secondaryLabel
        
        
        cell.contentConfiguration = cfg
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        let course = courses[indexPath.row]
        let title = "登録しますか？"
        let message = "\(location.dayName) \(location.period)限に\n「\(course.title)」を登録します。"
        
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "登録", style: .default, handler: { [weak self] _ in
            guard let self = self else { return }
            self.delegate?.courseList(self, didSelect: course, at: self.location)
            self.backToTimetable()
        }))
        present(alert, animated: true)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadAllCourses()
        tableView.reloadData()
    }

    
    @objc private func backToTimetable() {
        if let nav = navigationController {
            if nav.viewControllers.first === self {
                dismiss(animated: true)
            } else {
                nav.popViewController(animated: true)
            }
        } else {
            dismiss(animated: true)
        }
    }
    
    @objc private func tapAddCourse() {
        let addVC = AddCourseViewController()
        addVC.delegate = self
        let nav = UINavigationController(rootViewController: addVC)
        present(nav, animated: true)
    }

    
    @objc private func textChanged(_ sender: UITextField) {
        let q = (sender.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            courses = allCourses
        } else {
            // 空白区切り AND 検索
            let keys = q.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            courses = allCourses.filter { c in
                let hay = [
                    c.title, c.teacher, c.room, c.id,
                    c.campus ?? "", c.category ?? ""
                ].joined(separator: " ").lowercased()

                return keys.allSatisfy { hay.contains($0.lowercased()) }
            }
        }
        tableView.reloadData()
    }
    
    @objc private func endEditingNow() {
        view.endEditing(true)
    }
    
    
    // もともと入れている内蔵データ（既存 allCourses 初期化部分を関数化）
    private func builtinCourses() -> [Course] {
        return [
            Course(id: "15408", title: "Integrated English III", room: "15306", teacher: "Smith",
                   credits: 2, campus: "青山", category: "青山スタンダード科目", syllabusURL: nil),
            Course(id: "17411", title: "歴史と人間", room: "N402", teacher: "佐藤",
                   credits: 2, campus: "青山", category: "青山スタンダード科目", syllabusURL: nil),
            Course(id: "17710", title: "グローバル文学理論", room: "A305", teacher: "Tanaka",
                   credits: 2, campus: "青山", category: "法学部", syllabusURL: nil),
        ]
    }

    private func reloadAllCourses() {
        let custom = CourseStore.load()
        allCourses = builtinCourses() + custom
    }

    
    // 2行表示（リスト用）—追加
    private func metaTwoLines(for c: Course) -> String {
        // 1行目：担当・教室・登録番号
        let line1 = "\(c.teacher) ・ \(c.room) ・ 登録番号 \(c.id)"

        // 2行目：キャンパス・単位数・区分（nil/空はスキップ）
        var tail: [String] = []
        if let campus = c.campus, !campus.isEmpty { tail.append(campus) }
        if let credits = c.credits { tail.append("\(credits)単位") }
        if let category = c.category, !category.isEmpty { tail.append(category) }

        return tail.isEmpty ? line1 : line1 + "\n" + tail.joined(separator: " ・ ")
    }

    // 1行表示（既存）—残しておく
    private func metaString(for c: Course) -> String {
        let idText = c.id.isEmpty ? "-" : c.id
        
        var line1: [String] = [
            c.teacher,         // 担当
            c.room,            // 教室
            "登録番号 \(idText)"
        ]
        let first = line1.joined(separator: " ・ ")

        var line2: [String] = []
        if let campus = c.campus, !campus.isEmpty { line2.append(campus) }
        if let credits = c.credits { line2.append("\(credits)単位") }
        if let category = c.category, !category.isEmpty { line2.append(category) }

        return [first, line2.joined(separator: " ・ ")].joined(separator: "\n")

    }

    
    // MARK: - Header (Search)
    // ★ 変更: tableHeaderView は使わず、セクションヘッダーで表示
    private func buildSearchHeader() {
        tableView.keyboardDismissMode = .onDrag
        tableView.reloadData() // ヘッダーを描画させる
    }
    
    // ★ 追加: セクションヘッダーに検索フィールドをレイアウト
    override func numberOfSections(in tableView: UITableView) -> Int { 1 }
    
    override func tableView(_ tableView: UITableView,
                            viewForHeaderInSection section: Int) -> UIView? {
        let header = UIView()
        header.backgroundColor = .clear
        
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            container.topAnchor.constraint(equalTo: header.topAnchor),
            container.bottomAnchor.constraint(equalTo: header.bottomAnchor)
        ])
        
        searchField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchField)
        container.directionalLayoutMargins = .init(top: 8, leading: 16, bottom: 8, trailing: 16)
        let g = container.layoutMarginsGuide
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            searchField.topAnchor.constraint(equalTo: g.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: g.bottomAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 36)
        ])
        return header
    }
    
    override func tableView(_ tableView: UITableView,
                            heightForHeaderInSection section: Int) -> CGFloat {
        return 52 // 36 + 上下8の余白
    }
    

}
