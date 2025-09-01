import UIKit
import FirebaseCore
import FirebaseFirestore

class syllabus: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating {

    @IBOutlet weak var categoryButton: UIButton!
    @IBOutlet weak var syllabus_table: UITableView!
    @IBOutlet weak var search_button: UIButton!

    struct SyllabusData {
        let class_name: String
        let teacher_name: String
        let time: String
        let campus: String
        let grade: String
        let category: String
        let credit: String
    }

    // Firestore
    private let db = Firestore.firestore()

    // ===== 上位→下位カテゴリ展開（必要に応じて調整） =====
    // 上位→下位カテゴリ展開（日本語だけで統一）
    private let categoryExpansion: [String: [String]] = [
        // 文学部系
        "文学部": [
            "文学部",
            "文学部共通",
            "文学部外国語科目",
            "英米文学科",
            "フランス文学科",
            "日本文学科",
            "史学科",
            "比較芸術学科"
        ],

        // 教育人間科学部系
        "教育人間科学部": [
            "教育人間科学部",
            "教育人間 外国語科目",
            "教育人間 教育学科",
            "教育人間 心理学科",
            "教育人間　外国語科目",
            "教育人間　教育学科",
            "教育人間　心理学科"
        ],

        // 経済・法・経営
        "経済学部": ["経済学部"],
        "法学部": ["法学部"],
        "経営学部": ["経営学部"],

        // 国政経
        "国際政治経済学部": [
            "国際政治経済学部",
            "国際政治学科",
            "国際経済学科",
            "国際コミュニケーション学科"
        ],

        // 総文政
        "総合文化政策学部": ["総合文化政策学部"],

        // 理工（スクショ準拠の日本語名で再構成）
        "理工学部": [
            "理工学部共通",
            "物理・数理",
            "化学・生命",
            "機械創造",
            "経営システム",
            "情報テクノロジ－",
            "物理科学",
            "数理サイエンス",
            ],

        // その他学部
        "コミュニティ人間科学部": ["ｺﾐｭﾆﾃｨ人間科学部"],
        "社会情報学部": ["社会情報学部"],
        "地球社会共生学部": ["地球社会共生学部"],

        // 横断科目
        "青山スタンダード科目": ["青山スタンダード科目"],
        "教職課程科目": ["教職課程科目"]
    ]


    // UIに出す候補
    private let categoryOptions = [
        "指定なし",
        "文学部",
        "教育人間科学部",
        "経済学部",
        "法学部",
        "経営学部",
        "国際政治経済学部",
        "総合文化政策学部",
        "理工学部",
        "コミュニティ人間科学部",
        "社会情報学部",
        "地球社会共生学部",
        "青山スタンダード科目",
        "教職課程科目",
    ]

    // 現在選択（nil = 指定なし）
    private var selectedCategory: String? = nil

    // データ
    var data: [SyllabusData] = []
    var filteredData: [SyllabusData] = []

    // 検索
    let searchController = UISearchController(searchResultsController: nil)
    private var searchDebounce: DispatchWorkItem?

    // ---- ページング状態 ----
    let pageSize = 10
    var lastDoc: DocumentSnapshot?
    var isLoading = false
    var reachedEnd = false
    var seenIds = Set<String>()

    override func viewDidLoad() {
        super.viewDidLoad()

        if FirebaseApp.app() == nil { FirebaseApp.configure() }

        syllabus_table.dataSource = self
        syllabus_table.delegate = self

        // 検索バー
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "授業名や教員名で検索"
        navigationItem.searchController = searchController
        definesPresentationContext = true

        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.title = "シラバス"

        loadNextPage()
    }
    

    // MARK: - 学部・分類ボタン
    @IBAction func categoryButtonTapped(_ sender: UIButton) {
        let ac = UIAlertController(title: "学部・分類を選択", message: nil, preferredStyle: .actionSheet)
        categoryOptions.forEach { name in
            ac.addAction(UIAlertAction(title: name, style: .default) { [weak self] _ in
                guard let self = self else { return }
                if name == "指定なし" {
                    self.selectedCategory = nil
                    self.categoryButton.setTitle("学部・分類（指定なし）", for: .normal)
                } else {
                    self.selectedCategory = name
                    self.categoryButton.setTitle(name, for: .normal)
                }
                self.reloadAfterFilterChange()
            })
        }
        ac.addAction(UIAlertAction(title: "閉じる", style: .cancel))
        ac.popoverPresentationController?.sourceView = sender
        ac.popoverPresentationController?.sourceRect = sender.bounds
        present(ac, animated: true)

    }

    // 選択カテゴリ→実データカテゴリ配列
    private func expandedCategories() -> [String]? {
        guard let c = selectedCategory, !c.isEmpty else { return nil }
        if let list = categoryExpansion[c], !list.isEmpty { return list }
        return [c]
    }

    // 分類フィルタを Query に適用（一覧）
    private func applyCategoryFilter(_ q: Query) -> Query {
        guard let list = expandedCategories() else { return q }
        if list.count == 1 { return q.whereField("category", isEqualTo: list[0]) }
        if list.count <= 10 { return q.whereField("category", in: list) } // Firestore制限
        // 10超える場合は適宜分割取得を入れる。とりあえず先頭で代表。
        return q.whereField("category", isEqualTo: list[0])
    }

    // フィルタ変更時共通
    private func reloadAfterFilterChange() {
        let text = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
            remoteSearch(prefix: text)
            return
        }
        data.removeAll()
        filteredData.removeAll()
        lastDoc = nil
        reachedEnd = false
        seenIds.removeAll()
        syllabus_table.reloadData()
        loadNextPage()
    }
    

    // MARK: - 一覧ページング
    func loadNextPage() {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true

        var q: Query = applyCategoryFilter(
            db.collection("classes").order(by: "class_name")
        ).limit(to: pageSize)

        if let last = lastDoc { q = q.start(afterDocument: last) }

        q.getDocuments { [weak self] snap, err in
            guard let self = self else { return }
            self.isLoading = false
            if let err = err { print("Firestore error:", err); return }
            guard let snap = snap else { return }

            if snap.documents.isEmpty { self.reachedEnd = true; return }

            var chunk: [SyllabusData] = []
            for doc in snap.documents {
                if self.seenIds.insert(doc.documentID).inserted {
                    chunk.append(self.toModel(doc.data()))
                }
            }

            self.lastDoc = snap.documents.last
            if snap.documents.count < self.pageSize { self.reachedEnd = true }

            self.data.append(contentsOf: chunk)
            self.filteredData = self.data
            DispatchQueue.main.async { self.syllabus_table.reloadData() }

            print("📦 got page:", snap.documents.count,
                  "total rows:", self.data.count,
                  "last:", self.lastDoc?.documentID ?? "nil")
        }
    }

    // MARK: - TableView
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { filteredData.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let subject = filteredData[indexPath.row]
        let cell = syllabus_table.dequeueReusableCell(withIdentifier: "class", for: indexPath) as! syllabusTableViewCell
        cell.class_name.text = subject.class_name
        cell.teacher_name.text = subject.teacher_name
        cell.time.text = subject.time
        cell.campus.text = subject.campus
        cell.grade.text = subject.grade
        cell.category.text = subject.category
        cell.credit.text = subject.credit
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 90 }

    // スクロール終端で追加読み込み（検索中はオフ）
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if searchController.isActive, let t = searchController.searchBar.text, !t.isEmpty { return }
        let offsetY = scrollView.contentOffset.y
        let contentH = scrollView.contentSize.height
        let frameH = scrollView.frame.size.height
        if offsetY > contentH - frameH - 400 { loadNextPage() }
    }

    // MARK: - Firestore -> Model
    private func toModel(_ x: [String: Any]) -> SyllabusData {
        var timeStr = ""
        if let t = x["time"] as? [String: Any] {
            let day = (t["day"] as? String) ?? ""
            let ps  = (t["periods"] as? [Int]) ?? []
            if ps.isEmpty { timeStr = day }
            else {
                let s = ps.sorted()
                timeStr = s.count == 1 ? "\(day)\(s[0])" : "\(day)\(s.first!)-\(s.last!)"
            }
        }
        let campusStr: String = {
            if let s = x["campus"] as? String { return s }
            if let arr = x["campus"] as? [String] { return arr.joined(separator: ",") }
            return ""
        }()
        return SyllabusData(
            class_name: x["class_name"] as? String ?? "",
            teacher_name: x["teacher_name"] as? String ?? "",
            time: timeStr,
            campus: campusStr,
            grade: x["grade"] as? String ?? "",
            category: x["category"] as? String ?? "",
            credit: String(x["credit"] as? Int ?? 0)
        )
    }

    // MARK: - テキスト検索
    func updateSearchResults(for searchController: UISearchController) {
        let raw = searchController.searchBar.text ?? ""
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        searchDebounce?.cancel()

        if text.isEmpty {
            filteredData = data
            syllabus_table.reloadData()
            return
        }

        let work = DispatchWorkItem { [weak self] in
            self?.remoteSearch(prefix: text)
        }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    // 正規化
    private func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        return lowered.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }

    // 2-gram
    private func ngrams2(_ s: String) -> [String] {
        let t = normalize(s)
        let chars = Array(t)
        guard !chars.isEmpty else { return [] }
        if chars.count == 1 { return [String(chars[0])] }
        var out: [String] = []
        for i in 0..<(chars.count - 1) {
            out.append(String(chars[i]) + String(chars[i + 1]))
        }
        return Array(Set(out))
    }

    // サーバー検索本体（カテゴリ展開も併用）
    private func remoteSearch(prefix rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            self.filteredData = self.data
            self.syllabus_table.reloadData()
            return
        }

        // --- 1文字は prefix（class_name / teacher_name） ---
        if text.count == 1 {
            let startKey = text
            let endKey   = text + "\u{f8ff}"

            let cats = expandedCategories()

            let buildQueries: () -> [Query] = { [weak self] in
                guard let self = self else { return [] }
                var arr: [Query] = []
                if let cs = cats {
                    // カテゴリごとに個別クエリ
                    for c in cs {
                        arr.append(
                            self.db.collection("classes")
                                .whereField("category", isEqualTo: c)
                                .order(by: "class_name")
                                .start(at: [startKey]).end(at: [endKey])
                                .limit(to: 50)
                        )
                        arr.append(
                            self.db.collection("classes")
                                .whereField("category", isEqualTo: c)
                                .order(by: "teacher_name")
                                .start(at: [startKey]).end(at: [endKey])
                                .limit(to: 50)
                        )
                    }
                } else {
                    arr.append(self.db.collection("classes").order(by: "class_name").start(at: [startKey]).end(at: [endKey]).limit(to: 50))
                    arr.append(self.db.collection("classes").order(by: "teacher_name").start(at: [startKey]).end(at: [endKey]).limit(to: 50))
                }
                return arr
            }

            let queries = buildQueries()
            let group = DispatchGroup()
            var docs: [QueryDocumentSnapshot] = []

            for q in queries {
                group.enter()
                q.getDocuments { snap, _ in
                    defer { group.leave() }
                    if let snap = snap { docs += snap.documents }
                }
            }

            group.notify(queue: .main) { [weak self] in
                guard let self = self else { return }
                var seen = Set<String>()
                let models = docs.compactMap { d -> SyllabusData? in
                    guard seen.insert(d.documentID).inserted else { return nil }
                    return self.toModel(d.data())
                }
                self.filteredData = models
                self.syllabus_table.reloadData()
                print("🔎 remote(1ch) results:", models.count)
            }
            return
        }

        // --- 2文字以上は n-gram(2) ---
        let grams = ngrams2(text)
        let tokens = Array(grams.prefix(10))
        guard !tokens.isEmpty else {
            self.filteredData = []
            self.syllabus_table.reloadData()
            return
        }

        // カテゴリ展開（nilなら全カテゴリ）
        let cats = expandedCategories()

        // arrayContainsAny と in の併用を避けるためカテゴリごとに並列取得
        let group = DispatchGroup()
        var docs: [QueryDocumentSnapshot] = []

        func runQuery(forCategory cat: String?) {
            var q: Query = self.db.collection("classes")
                .whereField("ngrams2", arrayContainsAny: tokens)
                .order(by: "class_name")
                .limit(to: 200)
            if let c = cat {
                q = q.whereField("category", isEqualTo: c)
            }
            group.enter()
            q.getDocuments { snap, _ in
                defer { group.leave() }
                if let snap = snap { docs += snap.documents }
            }
        }

        if let cs = cats, !cs.isEmpty {
            for c in cs { runQuery(forCategory: c) }
        } else {
            runQuery(forCategory: nil)
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            var seen = Set<String>()
            let models: [SyllabusData] = docs.compactMap { d in
                guard seen.insert(d.documentID).inserted else { return nil }
                let x = d.data()
                let docTokens = (x["ngrams2"] as? [String]) ?? []
                guard tokens.allSatisfy(docTokens.contains) else { return nil }
                return self.toModel(x)
            }
            self.filteredData = models
            self.syllabus_table.reloadData()
            print("🔍 remote(ngram) merged:", docs.count, "after AND:", models.count)
        }
    }
}
