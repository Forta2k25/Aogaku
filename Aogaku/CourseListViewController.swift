//  CourseListViewController.swift
//  Aogaku
//
//  Firebaseの授業一覧（曜日・時限で初回10件）
//  検索バー入力中は自動ロードを止め、フッターの「さらに読み込む」で
//  該当コースを追加10件ずつ取得（通信最小化）
//

import UIKit
import FirebaseFirestore

protocol CourseListViewControllerDelegate: AnyObject {
    func courseList(_ vc: CourseListViewController,
                    didSelect course: Course,
                    at location: SlotLocation)
}

final class CourseListViewController: UITableViewController, AddCourseViewControllerDelegate {

    // MARK: - Input
    weak var delegate: CourseListViewControllerDelegate?
    let location: SlotLocation

    // MARK: - Firestore state
    private let service = FirestoreService()
    private let termRaw: String?        // [ADDED] "（前期）" / "（後期）" などを保持
    private var remote: [Course] = []                 // サーバーから得た一覧を蓄積
    private var lastSnapshot: DocumentSnapshot?       // 次ページ用カーソル
    private var hasMore: Bool = true                  // まだ次があるか
    private var isLoading: Bool = false               // ロード中フラグ
    private var keyword: String?                      // 検索キーワード（空/ nil なら非検索）

    // MARK: - Currently displayed list (検索の有無で変わる)
    private var courses: [Course] = []
    
    

    // MARK: - UI (Search)
    private let searchField: UITextField = {
        let tf = UITextField()
        tf.placeholder = "科目名・教員・キャンパスで検索"
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

    // MARK: - Footer（検索中のみ表示）
    private let footerContainer = UIView(frame: .init(x: 0, y: 0, width: 0, height: 72))
    private let moreButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)

    // MARK: - Init
    init(location: SlotLocation, termRaw: String? = nil) {
        self.location = location
        self.termRaw  = termRaw
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - LifeCycle
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "\(location.dayName) \(location.period)限"
        navigationItem.largeTitleDisplayMode = .never

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
        if #available(iOS 15.0, *) { tableView.sectionHeaderTopPadding = 0 }
        tableView.keyboardDismissMode = .onDrag

        // 検索イベント
        searchField.addTarget(self, action: #selector(textChanged(_:)), for: .editingChanged)
        searchField.addTarget(self, action: #selector(endEditingNow), for: .editingDidEndOnExit)

        // セクションヘッダーに検索フィールド
        tableView.reloadData()

        // フッター（さらに読み込む）
        setupFooter()

        // 初回 10 件取得
        loadFirstPage()
    }
    
    // [ADDED] term のカッコだけを外して返す
    private func termDisplay(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        let t = s
            .replacingOccurrences(of: "（", with: "") // 全角
            .replacingOccurrences(of: "）", with: "")
            .replacingOccurrences(of: "(", with: "") // 半角
            .replacingOccurrences(of: ")", with: "")
        return t.isEmpty ? nil : t
    }


    // MARK: - Footer
    private func setupFooter() {
        moreButton.setTitle("さらに読み込む", for: .normal)
        moreButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        moreButton.addTarget(self, action: #selector(tapLoadMore), for: .touchUpInside)
        moreButton.layer.cornerRadius = 10
        moreButton.backgroundColor = .secondarySystemBackground

        spinner.hidesWhenStopped = true

        moreButton.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        footerContainer.addSubview(moreButton)
        footerContainer.addSubview(spinner)
        NSLayoutConstraint.activate([
            moreButton.centerXAnchor.constraint(equalTo: footerContainer.centerXAnchor),
            moreButton.centerYAnchor.constraint(equalTo: footerContainer.centerYAnchor),
            moreButton.heightAnchor.constraint(equalToConstant: 44),
            moreButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            spinner.centerXAnchor.constraint(equalTo: moreButton.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: moreButton.centerYAnchor),
        ])

        tableView.tableFooterView = UIView(frame: .zero) // 初期は非表示
    }

    private func showFooterIfNeeded() {
        // 検索語あり＋サーバの続きがある時だけ表示
        let q = (keyword ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty && hasMore {
            tableView.tableFooterView = footerContainer
        } else {
            tableView.tableFooterView = UIView(frame: .zero)
        }
    }

    // MARK: - 初回ロード
    private func loadFirstPage() {
        guard !isLoading else { return }
        isLoading = true
        setLoadingFooter(true)
        hasMore = true
        lastSnapshot = nil
        remote.removeAll()
        courses.removeAll()
        tableView.reloadData()

        service.fetchFirstPageForDay(
            day: location.dayName,
            period: location.period,
            term: expandedTerms(for: termRaw),
            limit: 10
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false
                self.setLoadingFooter(false)

                switch result {
                case .success(let page):
                    self.remote = page.courses
                    self.lastSnapshot = page.lastSnapshot
                    self.hasMore = (page.lastSnapshot != nil)

                    // 検索中かどうかで表示配列を決定
                    if let kw = self.keyword, !kw.isEmpty {
                        self.courses = self.filter(remote: self.remote, keyword: kw)
                    } else {
                        self.courses = self.remote
                    }
                    self.tableView.reloadData()
                    self.showFooterIfNeeded()

                case .failure(let err):
                    self.hasMore = false
                    self.showError(err)
                }
            }
        }
    }

    // MARK: - Paging: 自動追加（非検索時のみ）
    override func tableView(_ tableView: UITableView,
                            willDisplay cell: UITableViewCell,
                            forRowAt indexPath: IndexPath) {
        // 検索中はサーバーに取りに行かない（通信最小化）
        if let kw = keyword, !kw.isEmpty { return }
        guard hasMore, !isLoading else { return }

        // 末尾2行手前でプリフェッチ
        if indexPath.row >= courses.count - 2 {
            loadMore()
        }
    }

    private func setLoadingFooter(_ loading: Bool) {
        if loading {
            let sp = UIActivityIndicatorView(style: .medium)
            sp.startAnimating()
            sp.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 44)
            tableView.tableFooterView = sp
        } else {
            tableView.tableFooterView = UIView(frame: .zero)
        }
    }

    /// 非検索時の自動ページング
    private func loadMore() {
        guard let cursor = lastSnapshot, !isLoading, hasMore else { return }
        isLoading = true
        setLoadingFooter(true)

        service.fetchNextPageForDay(
            day: location.dayName,
            period: location.period,
            term: expandedTerms(for: termRaw),
            after: cursor,
            limit: 10
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false
                self.setLoadingFooter(false)

                switch result {
                case .success(let page):
                    if page.courses.isEmpty { self.hasMore = false }
                    self.lastSnapshot = page.lastSnapshot
                    self.hasMore = (page.lastSnapshot != nil)

                    // サーバー配列に追加
                    self.remote.append(contentsOf: page.courses)

                    // 非検索時はそのまま挿入
                    let start = self.courses.count
                    self.courses.append(contentsOf: page.courses)
                    let idxs = (start..<self.courses.count).map { IndexPath(row: $0, section: 0) }
                    self.tableView.insertRows(at: idxs, with: .fade)

                case .failure(let err):
                    self.hasMore = false
                    self.showError(err)
                }
            }
        }
    }
    
    // [ADDED] 前/後期を前半・後半まで含む配列に展開
    private func expandedTerms(for raw: String?) -> [String]? {
        guard let s = raw, !s.isEmpty else { return nil }
        if s.contains("前期") {
            return ["（前期）", "（前期前半）", "（前期後半）", "（前期隔1）", "（前期隔2）", "（通年）", "（通年隔1）", "（通年隔2）", "（前期集中）", "（集中）", //"（夏休集中）", "（春休集中）", "（通年集中）" 最大10個
            ]
        } else if s.contains("後期") {
            return ["（後期）", "（後期前半）", "（後期後半）", "（後期隔1）", "（後期隔2）", "（通年）", "（通年隔1）", "（通年隔2）", "（後期集中）", "（集中）", //"（夏休集中）", "（春休集中）", "（通年集中）" 最大10個
            ]
        }
        return [s] // それ以外（通年/集中など）はそのまま
    }


    // MARK: - 「さらに読み込む」（検索中のみ可）
    @objc private func tapLoadMore() {
        guard !(keyword ?? "").isEmpty, hasMore, !isLoading else { return }
        isLoading = true
        moreButton.isHidden = true
        spinner.startAnimating()

        // “該当コース”を10件ぶん増やすまで、サーバページを必要分だけ読む
        var need = 10

        func handle(_ result: Result<FirestorePage, Error>) {
            DispatchQueue.main.async {
                switch result {
                case .failure(let err):
                    self.isLoading = false
                    self.spinner.stopAnimating()
                    self.moreButton.isHidden = false
                    self.showError(err)

                case .success(let page):
                    self.remote.append(contentsOf: page.courses)
                    self.lastSnapshot = page.lastSnapshot
                    self.hasMore = (page.lastSnapshot != nil)

                    // 取得分から“該当”のみを抽出して courses に追加
                    let add = self.filter(remote: page.courses, keyword: self.keyword ?? "")
                    if !add.isEmpty {
                        let start = self.courses.count
                        let picked = Array(add.prefix(need))
                        self.courses.append(contentsOf: picked)
                        let idxs = (start..<self.courses.count).map { IndexPath(row: $0, section: 0) }
                        self.tableView.insertRows(at: idxs, with: .fade)
                        need -= picked.count
                    }

                    if need > 0, self.hasMore, let cursor = self.lastSnapshot {
                        // まだ不足 → 次のページを続けて取得（limit 少し大きめ）
                        self.service.fetchNextPageForDay(
                            day: self.location.dayName,
                            period: self.location.period,
                            term: self.expandedTerms(for: self.termRaw),
                            after: cursor,
                            limit: 25,
                            completion: handle
                        )
                    } else {
                        // 完了
                        self.isLoading = false
                        self.spinner.stopAnimating()
                        self.moreButton.isHidden = false
                        self.showFooterIfNeeded()
                    }
                }
            }
        }

        if let cursor = lastSnapshot {
            service.fetchNextPageForDay(
                day: location.dayName, period: location.period,
                term: expandedTerms(for: termRaw),
                after: cursor, limit: 25, completion: handle
            )
        } else {
            service.fetchFirstPageForDay(
                day: location.dayName, period: location.period,
                term: expandedTerms(for: termRaw),
                limit: 25, completion: handle
            )
        }
    }

    // MARK: - 検索（ローカルのみ）
    @objc private func textChanged(_ sender: UITextField) {
        let q = (sender.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        keyword = q.isEmpty ? nil : q

        if let kw = keyword {
            courses = filter(remote: remote, keyword: kw)
        } else {
            courses = remote
        }
        tableView.reloadData()
        showFooterIfNeeded()
    }

    /// 検索対象は「授業名・教師名・キャンパス・カテゴリー」のみ
    private func filter(remote: [Course], keyword: String) -> [Course] {
        let keys = keyword
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }

        return remote.filter { c in
            let hay = [
                c.title,
                c.teacher,
                c.campus ?? "",
                c.category ?? ""
            ].joined(separator: " ").lowercased()
            return keys.allSatisfy { hay.contains($0) }
        }
    }

    @objc private func endEditingNow() { view.endEditing(true) }

    // MARK: - Add custom course
    func addCourseViewController(_ vc: AddCourseViewController, didCreate course: Course) {
        // サーバー結果の手前にローカル追加して“見える化”
        remote.insert(course, at: 0)

        if let kw = keyword, !kw.isEmpty {
            // 検索中はフィルタを掛け直して全体を更新
            courses = filter(remote: remote, keyword: kw)
            tableView.reloadData()
            showFooterIfNeeded()
        } else {
            // 非検索中は先頭に1行だけ差し込む
            courses.insert(course, at: 0)
            tableView.insertRows(at: [IndexPath(row: 0, section: 0)], with: .automatic)
            tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: true)
        }
    }

    // MARK: - Navigation actions
    @objc private func backToTimetable() {
        if let nav = navigationController {
            if nav.viewControllers.first === self { dismiss(animated: true) }
            else { nav.popViewController(animated: true) }
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

    // MARK: - Table
    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
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
        52
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        courses.count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let c = courses[indexPath.row]
        var cfg = cell.defaultContentConfiguration()
        cfg.text = c.title
        cfg.textProperties.numberOfLines = 2
        cfg.secondaryText = metaTwoLines(for: c)
        cfg.secondaryTextProperties.numberOfLines = 0
        cfg.secondaryTextProperties.lineBreakMode = .byWordWrapping
        cfg.prefersSideBySideTextAndSecondaryText = false
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

    // MARK: - Helpers
    private func showError(_ err: Error) {
        let ac = UIAlertController(title: "読み込みエラー",
                                   message: err.localizedDescription,
                                   preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "OK", style: .default))
        present(ac, animated: true)
    }

    // リスト2行表示用
    private func metaTwoLines(for c: Course) -> String {
        let line1 = "\(c.teacher) ・ \(c.room.isEmpty ? "-" : c.room) ・ 登録番号 \(c.id)"
        var tail: [String] = []
        if let campus = c.campus, !campus.isEmpty { tail.append(campus) }
        if let credits = c.credits { tail.append("\(credits)単位") }
        if let category = c.category, !category.isEmpty { tail.append(category) }
        if let term = termDisplay(c.term) { tail.append(term) }   // ← [ADDED]
        return tail.isEmpty ? line1 : line1 + "\n" + tail.joined(separator: " ・ ")
    }
}
