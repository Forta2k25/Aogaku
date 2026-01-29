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
    
    private var isOnlineList: Bool { location.period == 0 }

    // MARK: - Selection state (オンラインは連続追加)
    // オンライン（period==0）のときは、同じ授業名を二重登録しないためのキーセット
    private var addedCourseKeys: Set<String> = []

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
        
        /*
        title = "\(location.dayName) \(location.period)限"
        navigationItem.largeTitleDisplayMode = .never */
        
 /*       let isOnlineMode = (location.period == 0) // period=0 を OD 行の合図に
        if isOnlineMode {
            title = "\(location.dayName) オンライン"
            navigationItem.largeTitleDisplayMode = .never
        } else {
            title = "\(location.dayName) \(location.period)限"
            navigationItem.largeTitleDisplayMode = .never
        }
*/
        title = isOnlineList ? "\(location.dayName) オンライン"   // 例: 金 オンライン
                             : "\(location.dayName) \(location.period)限"
        
        
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

        // ▼ 初回ロード
        if isOnlineList {
            loadFirstPageOnline()
        } else {
            loadFirstPage()
        }
        // 初回 10 件取得
        /*loadFirstPage()*/
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


    // 最大 n 個ずつに分割
    private func chunk<T>(_ xs: [T], by n: Int) -> [[T]] {
        guard n > 0 else { return [xs] }
        var out: [[T]] = []
        var i = 0
        while i < xs.count { out.append(Array(xs[i..<min(i+n, xs.count)])); i += n }
        return out.isEmpty ? [[]] : out
    }

    // 検索ボックスを分かち
    private func splitQuery(_ q: String?) -> [String] {
        let s = (q ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return [] }
        return s.components(separatedBy: .whitespaces).filter{ !$0.isEmpty }
    }

    // 「オンライン」を拾う n-gram（Firestore の ngrams2 に入れてある想定）
    private let onlineNGrams = ["オン","ンラ","ライ","イン"]
    // オンライン一覧（曜日タブの最下段）初回ロード
    // 取得条件：room/campus が “ONLINE授業” 系の候補をサーバで緩く取得
    // ローカルで (1) 曜日一致（time.day / day / weekday の順）
    //           (2) 学期一致（後期→後期系＋通年系 / 前期→前期系＋通年系）
    //           (3) 可能なら period=0 を含む（無ければ通す）
    // を満たすものだけに絞る
    // オンライン一覧（曜日タブの最下段）初回ロード
    // ─────────────────────────────────────────────────────────────
    // オンライン一覧（曜日タブの最下段）初回ロード（全件取得版）
    // 条件：room/campus が ONLINE 系 → ローカルで 学期＋曜日 を厳密絞り込み
    // ─────────────────────────────────────────────────────────────
    private func loadFirstPageOnline() {
        guard !isLoading else { return }
        isLoading = true
        setLoadingFooter(false)
        courses.removeAll()
        tableView.reloadData()

        let db  = Firestore.firestore()
        let col = db.collection("classes")

        // 1) サーバ側：ONLINE 系候補を2系統で全件取得（ページング）
        let roomCandidates   = ["ONLINE授業", "オンライン授業", "Online", "online"]
        let campusCandidates = ["ONLINE授業", "オンライン授業", "ONLINE", "オンライン"]
        let pageSize = 500   // 1ページあたり。必要に応じて増減可

        func fetchAll(_ base: Query, label: String, completion: @escaping ([QueryDocumentSnapshot]) -> Void) {
            var out: [QueryDocumentSnapshot] = []
            func step(_ cursor: DocumentSnapshot?) {
                var q = base.limit(to: pageSize)
                if let c = cursor { q = q.start(afterDocument: c) }
                q.getDocuments { snap, err in
                    if let err = err {
                        self.dlog("query(\(label)) error: \(err.localizedDescription)")
                        completion(out)
                        return
                    }
                    let docs = snap?.documents ?? []
                    out.append(contentsOf: docs)
                    self.dlog("query(\(label)) fetched so far: \(out.count)")
                    if docs.count < pageSize { completion(out) }
                    else { step(docs.last) }
                }
            }
            step(nil)
        }

        let g = DispatchGroup()
        var byRoom:   [QueryDocumentSnapshot] = []
        var byCampus: [QueryDocumentSnapshot] = []

        g.enter()
        fetchAll(col.whereField("room",   in: roomCandidates),   label: "room in")   { byRoom   = $0; g.leave() }
        g.enter()
        fetchAll(col.whereField("campus", in: campusCandidates), label: "campus in") { byCampus = $0; g.leave() }

        // 2) ユーティリティ（曜日・学期の正規化）
        let targetDay = location.dayName                          // "月" など
        let expanded = expandedTerms(for: termRaw) ?? []          // ["（後期）","（通年）",…] / 無指定なら []

        func normDay(_ raw: String?) -> String? {
            guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            if let r = s.range(of: "曜") { return String(s[..<r.lowerBound]) } // "火曜日" → "火"
            return String(s.prefix(1))                                        // "火" / "水" など
        }
        func dayFromMap(_ m: [String: Any]) -> String? {
            if let t = m["time"] as? [String: Any], let d = t["day"] as? String { return normDay(d) }
            if let d = m["day"]     as? String { return normDay(d) }
            if let d = m["weekday"] as? String { return normDay(d) }
            return nil
        }
        func termAllow(_ s: String?) -> Bool {
            guard !expanded.isEmpty else { return true } // 学期未指定時は通す
            let t = (s ?? "")
            return expanded.contains { t.contains($0) }
        }
        let isOnlineDoc: ([String: Any]) -> Bool = { m in
            let room   = (m["room"] as? String) ?? ""
            let campus = (m["campus"] as? String) ?? ""
            let byR = roomCandidates.contains { room.localizedCaseInsensitiveContains($0) }
            let byC = campusCandidates.contains { campus.localizedCaseInsensitiveContains($0) }
            return byR || byC
        }

        // 3) 取得完了後にローカル絞り込み → Course 化 → 表示
        g.notify(queue: .main) {
            self.isLoading = false

            // 重複排除（documentID 基準）
            var uniq: [String: QueryDocumentSnapshot] = [:]
            for d in byRoom   { uniq[d.documentID] = d }
            for d in byCampus { uniq[d.documentID] = d }

            self.dlog("online fetched raw: room=\(byRoom.count), campus=\(byCampus.count), unique=\(uniq.count)")

            var picked: [Course] = []
            picked.reserveCapacity(uniq.count)

            for d in uniq.values {
                let m = d.data()
                guard isOnlineDoc(m) else { continue }                   // 念のため最終確認
                guard let day = dayFromMap(m), day == targetDay else { continue } // 曜日一致
                guard termAllow(m["term"] as? String) else { continue }  // 学期一致（前期⇄通年 / 後期⇄通年）

                if let c = Course(doc: d) {
                    picked.append(c)
                }
            }

            picked.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

            self.remote  = picked
            self.courses = picked
            self.tableView.reloadData()
            self.tableView.tableFooterView = UIView(frame: .zero)

            self.dlog("displayed rows: \(picked.count), day=\(targetDay), term=\(self.termRaw ?? "nil")")
            if picked.isEmpty {
                self.dlog("empty. check fields: time.day/day/weekday, term 文字列, room/campus 値")
            }
        }
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

        // オンライン一覧は複数追加を想定：追加済みはチェックマーク
        if isOnlineList {
            cell.accessoryType = addedCourseKeys.contains(courseKey(c)) ? .checkmark : .none
        } else {
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }


    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let course = courses[indexPath.row]

        // オンライン（period==0）は「複数追加」が目的。
        // すでに追加済みなら、確認ダイアログは出さず軽く知らせるだけにする。
        if isOnlineList, addedCourseKeys.contains(courseKey(course)) {
            let ac = UIAlertController(title: nil, message: "すでに追加済みです", preferredStyle: .alert)
            present(ac, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak ac] in
                ac?.dismiss(animated: true)
            }
            return
        }

        let title = "登録しますか？"
        // period==0（OD 行）は「オンライン授業」、それ以外は「n限」
        let slotCaption = (location.period == 0) ? "オンライン授業" : "\(location.period)限"
        let message = "\(location.dayName) \(slotCaption)に「\(course.title)」を登録します。"

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))

        alert.addAction(UIAlertAction(title: "登録", style: .default, handler: { [weak self] _ in
            guard let self = self else { return }

            // 既存の経路：時間割へ反映（オンライン/通常どちらも delegate 経由）
            self.delegate?.courseList(self, didSelect: course, at: self.location)

            // オンライン行（period==0）は「複数追加」を許可：画面を閉じない
            if self.isOnlineList {
                self.addedCourseKeys.insert(self.courseKey(course))
                self.tableView.reloadRows(at: [indexPath], with: .none)

                let done = UIAlertController(title: nil, message: "追加しました", preferredStyle: .alert)
                self.present(done, animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak done] in
                    done?.dismiss(animated: true)
                }
                return
            }

            // 通常コマは 1件登録したら戻る
            self.backToTimetable()
        }))

        present(alert, animated: true)
    }


    // MARK: - Debug log (DEBUGビルドのみ)
    #if DEBUG
    private func dlog(_ msg: String) { print("[OnlineList] \(msg)") }
    #else
    private func dlog(_ msg: String) { /* no-op on Release */ }
    #endif


    // MARK: - Helpers
    /// オンライン授業は「登録番号（course.id）」が空/重複（例: ++++++）しうるため、
    /// **同じ授業名（title）だけを重複判定キー**として扱う。
    /// - 要件: 「同じ授業名じゃなければ追加できるように」
    private func courseKey(_ c: Course) -> String {
        if isOnlineList {
            return normalizeTitleKey(c.title)
        }

        let raw = c.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { return raw }

        // 通常コマで登録番号が空のケースのフォールバック
        return normalizeTitleKey(c.title) + "|" + c.teacher.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 表記ゆれ（全角スペース/連続スペース/改行）を吸収して「授業名キー」を作る
    private func normalizeTitleKey(_ s: String) -> String {
        let replaced = s.replacingOccurrences(of: "\u{3000}", with: " ") // 全角→半角
        let parts = replaced
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        return parts.joined(separator: " ").lowercased()
    }

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




/*
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
    
    private var isOnlineList: Bool { location.period == 0 }

    // MARK: - Selection state
    // オンライン（period==0）のときは「登録」後に画面を閉じず、複数授業を連続追加できるようにする。
    // 追加済みの行はチェックマーク表示にする。
    private var addedCourseIDs: Set<String> = []

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
        
        /*
        title = "\(location.dayName) \(location.period)限"
        navigationItem.largeTitleDisplayMode = .never */
        
 /*       let isOnlineMode = (location.period == 0) // period=0 を OD 行の合図に
        if isOnlineMode {
            title = "\(location.dayName) オンライン"
            navigationItem.largeTitleDisplayMode = .never
        } else {
            title = "\(location.dayName) \(location.period)限"
            navigationItem.largeTitleDisplayMode = .never
        }
*/
        title = isOnlineList ? "\(location.dayName) オンライン"   // 例: 金 オンライン
                             : "\(location.dayName) \(location.period)限"
        
        
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

        // ▼ 初回ロード
        if isOnlineList {
            loadFirstPageOnline()
        } else {
            loadFirstPage()
        }
        // 初回 10 件取得
        /*loadFirstPage()*/
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


    // 最大 n 個ずつに分割
    private func chunk<T>(_ xs: [T], by n: Int) -> [[T]] {
        guard n > 0 else { return [xs] }
        var out: [[T]] = []
        var i = 0
        while i < xs.count { out.append(Array(xs[i..<min(i+n, xs.count)])); i += n }
        return out.isEmpty ? [[]] : out
    }

    // 検索ボックスを分かち
    private func splitQuery(_ q: String?) -> [String] {
        let s = (q ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return [] }
        return s.components(separatedBy: .whitespaces).filter{ !$0.isEmpty }
    }

    // 「オンライン」を拾う n-gram（Firestore の ngrams2 に入れてある想定）
    private let onlineNGrams = ["オン","ンラ","ライ","イン"]
    // オンライン一覧（曜日タブの最下段）初回ロード
    // 取得条件：room/campus が “ONLINE授業” 系の候補をサーバで緩く取得
    // ローカルで (1) 曜日一致（time.day / day / weekday の順）
    //           (2) 学期一致（後期→後期系＋通年系 / 前期→前期系＋通年系）
    //           (3) 可能なら period=0 を含む（無ければ通す）
    // を満たすものだけに絞る
    // オンライン一覧（曜日タブの最下段）初回ロード
    // ─────────────────────────────────────────────────────────────
    // オンライン一覧（曜日タブの最下段）初回ロード（全件取得版）
    // 条件：room/campus が ONLINE 系 → ローカルで 学期＋曜日 を厳密絞り込み
    // ─────────────────────────────────────────────────────────────
    private func loadFirstPageOnline() {
        guard !isLoading else { return }
        isLoading = true
        setLoadingFooter(false)
        courses.removeAll()
        tableView.reloadData()

        let db  = Firestore.firestore()
        let col = db.collection("classes")

        // 1) サーバ側：ONLINE 系候補を2系統で全件取得（ページング）
        let roomCandidates   = ["ONLINE授業", "オンライン授業", "Online", "online"]
        let campusCandidates = ["ONLINE授業", "オンライン授業", "ONLINE", "オンライン"]
        let pageSize = 500   // 1ページあたり。必要に応じて増減可

        func fetchAll(_ base: Query, label: String, completion: @escaping ([QueryDocumentSnapshot]) -> Void) {
            var out: [QueryDocumentSnapshot] = []
            func step(_ cursor: DocumentSnapshot?) {
                var q = base.limit(to: pageSize)
                if let c = cursor { q = q.start(afterDocument: c) }
                q.getDocuments { snap, err in
                    if let err = err {
                        self.dlog("query(\(label)) error: \(err.localizedDescription)")
                        completion(out)
                        return
                    }
                    let docs = snap?.documents ?? []
                    out.append(contentsOf: docs)
                    self.dlog("query(\(label)) fetched so far: \(out.count)")
                    if docs.count < pageSize { completion(out) }
                    else { step(docs.last) }
                }
            }
            step(nil)
        }

        let g = DispatchGroup()
        var byRoom:   [QueryDocumentSnapshot] = []
        var byCampus: [QueryDocumentSnapshot] = []

        g.enter()
        fetchAll(col.whereField("room",   in: roomCandidates),   label: "room in")   { byRoom   = $0; g.leave() }
        g.enter()
        fetchAll(col.whereField("campus", in: campusCandidates), label: "campus in") { byCampus = $0; g.leave() }

        // 2) ユーティリティ（曜日・学期の正規化）
        let targetDay = location.dayName                          // "月" など
        let expanded = expandedTerms(for: termRaw) ?? []          // ["（後期）","（通年）",…] / 無指定なら []

        func normDay(_ raw: String?) -> String? {
            guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            if let r = s.range(of: "曜") { return String(s[..<r.lowerBound]) } // "火曜日" → "火"
            return String(s.prefix(1))                                        // "火" / "水" など
        }
        func dayFromMap(_ m: [String: Any]) -> String? {
            if let t = m["time"] as? [String: Any], let d = t["day"] as? String { return normDay(d) }
            if let d = m["day"]     as? String { return normDay(d) }
            if let d = m["weekday"] as? String { return normDay(d) }
            return nil
        }
        func termAllow(_ s: String?) -> Bool {
            guard !expanded.isEmpty else { return true } // 学期未指定時は通す
            let t = (s ?? "")
            return expanded.contains { t.contains($0) }
        }
        let isOnlineDoc: ([String: Any]) -> Bool = { m in
            let room   = (m["room"] as? String) ?? ""
            let campus = (m["campus"] as? String) ?? ""
            let byR = roomCandidates.contains { room.localizedCaseInsensitiveContains($0) }
            let byC = campusCandidates.contains { campus.localizedCaseInsensitiveContains($0) }
            return byR || byC
        }

        // 3) 取得完了後にローカル絞り込み → Course 化 → 表示
        g.notify(queue: .main) {
            self.isLoading = false

            // 重複排除（documentID 基準）
            var uniq: [String: QueryDocumentSnapshot] = [:]
            for d in byRoom   { uniq[d.documentID] = d }
            for d in byCampus { uniq[d.documentID] = d }

            self.dlog("online fetched raw: room=\(byRoom.count), campus=\(byCampus.count), unique=\(uniq.count)")

            var picked: [Course] = []
            picked.reserveCapacity(uniq.count)

            for d in uniq.values {
                let m = d.data()
                guard isOnlineDoc(m) else { continue }                   // 念のため最終確認
                guard let day = dayFromMap(m), day == targetDay else { continue } // 曜日一致
                guard termAllow(m["term"] as? String) else { continue }  // 学期一致（前期⇄通年 / 後期⇄通年）

                if let c = Course(doc: d) {
                    picked.append(c)
                }
            }

            picked.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

            self.remote  = picked
            self.courses = picked
            self.tableView.reloadData()
            self.tableView.tableFooterView = UIView(frame: .zero)

            self.dlog("displayed rows: \(picked.count), day=\(targetDay), term=\(self.termRaw ?? "nil")")
            if picked.isEmpty {
                self.dlog("empty. check fields: time.day/day/weekday, term 文字列, room/campus 値")
            }
        }
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

        // オンライン一覧は複数追加を想定：追加済みはチェックマーク
        if isOnlineList {
            cell.accessoryType = addedCourseIDs.contains(courseKey(c)) ? .checkmark : .none
        } else {
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }


    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let course = courses[indexPath.row]

        // オンライン（period==0）は「複数追加」が目的。
        // すでに追加済みなら、確認ダイアログは出さず軽く知らせるだけにする。
        if isOnlineList, addedCourseIDs.contains(course.id) {
            let ac = UIAlertController(title: nil, message: "すでに追加済みです", preferredStyle: .alert)
            present(ac, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak ac] in
                ac?.dismiss(animated: true)
            }
            return
        }

        let title = "登録しますか？"
        // period==0（OD 行）は「オンライン授業」、それ以外は「n限」
        let slotCaption = (location.period == 0) ? "オンライン授業" : "\(location.period)限"
        let message = "\(location.dayName) \(slotCaption)に\n「\(course.title)」を登録します。"

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))

        alert.addAction(UIAlertAction(title: "登録", style: .default, handler: { [weak self] _ in
            guard let self = self else { return }

            // 既存の経路（通常コマはこれで反映される）
            self.delegate?.courseList(self, didSelect: course, at: self.location)

            // ===== オンライン行（period==0）のときだけ、時間割へ通知を飛ばす =====
            if self.location.period == 0 {
                let key = courseKey(course)
                var dict: [String: Any] = [
                    "id":           key,
                    "code":         course.id,
                    "class_name":   course.title,
                    "teacher_name": course.teacher,
                    "room":         course.room
                ]
                if let v = course.credits     { dict["credit"]   = v }
                if let v = course.campus      { dict["campus"]   = v }
                if let v = course.category    { dict["category"] = v }
                if let v = course.syllabusURL { dict["url"]      = v }
                if let v = course.term        { dict["term"]     = v }  // Firestoreの term 生文字列

                let payload: [String: Any] = [
                    "course": dict,               // ← 時間割側が期待する辞書
                    "docID":  key,
                    "day":    self.location.day,  // 0 始まり
                    "period": self.location.period
                ]

                NotificationCenter.default.post(
                    name: .registerCourseToTimetable,
                    object: self,
                    userInfo: payload
                )
                self.dlog("post register: day=\(self.location.day), period=\(self.location.period), id=\(course.id)")

                // ===== 複数追加対応：オンラインは画面を閉じない =====
                self.addedCourseIDs.insert(courseKey(course))
                self.tableView.reloadRows(at: [indexPath], with: .none)

                // 軽いフィードバック
                let done = UIAlertController(title: nil, message: "追加しました", preferredStyle: .alert)
                self.present(done, animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak done] in
                    done?.dismiss(animated: true)
                }
                return
            }

            // 画面を戻す
            self.backToTimetable()
        }))

        present(alert, animated: true)
    }


    // MARK: - Debug log (DEBUGビルドのみ)
    #if DEBUG
    private func dlog(_ msg: String) { print("[OnlineList] \(msg)") }
    #else
    private func dlog(_ msg: String) { /* no-op on Release */ }
    #endif


    // MARK: - Helpers
    /// オンライン授業は登録番号（course.id）が空/重複するケースがあるため、
    /// タイトル等から安定したキーを作って重複追加・チェック表示に利用する。
    private func courseKey(_ c: Course) -> String {
        let raw = c.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { return raw }
        // できるだけ衝突しにくい組み合わせ（必要なら要素を追加）
        return [
            c.title.trimmingCharacters(in: .whitespacesAndNewlines),
            c.teacher.trimmingCharacters(in: .whitespacesAndNewlines),
            c.room.trimmingCharacters(in: .whitespacesAndNewlines),
            (c.campus ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            (c.term ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "|")
    }

    private func showError(_ err: Error) {
        let ac = UIAlertController(title: "読み込みエラー",
                                   message: err.localizedDescription,
                                   preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "OK", style: .default))
        present(ac, animated: true)
    }

    // リスト2行表示用
    private func metaTwoLines(for c: Course) -> String {
        // オンライン一覧では登録番号は不要
        let roomText = c.room.isEmpty ? "-" : c.room
        let line1: String
        if isOnlineList {
            line1 = "\(c.teacher) ・ \(roomText)"
        } else {
            line1 = "\(c.teacher) ・ \(roomText) ・ 登録番号 \(c.id)"
        }
        var tail: [String] = []
        if let campus = c.campus, !campus.isEmpty { tail.append(campus) }
        if let credits = c.credits { tail.append("\(credits)単位") }
        if let category = c.category, !category.isEmpty { tail.append(category) }
        if let term = termDisplay(c.term) { tail.append(term) }   // ← [ADDED]
        return tail.isEmpty ? line1 : line1 + "\n" + tail.joined(separator: " ・ ")
    }
}


*/
