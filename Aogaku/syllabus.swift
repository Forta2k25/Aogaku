import UIKit
import FirebaseCore
import FirebaseFirestore

// 右画面から渡す検索条件
struct SyllabusSearchCriteria {
    var keyword: String? = nil
    var category: String? = nil      // 学部（上位）
    var department: String? = nil    // 学科（完全一致）
    var campus: String? = nil        // "青山" / "相模原"
    var place: String? = nil         // "対面" / "オンライン" / nil
    var grade: String? = nil
    var day: String? = nil           // 単一曜日のみの最適化用
    var periods: [Int]? = nil
    var timeSlots: [(String, Int)]? = nil // 複数セル: (day, period)
}

final class syllabus: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating {

    @IBOutlet weak var syllabus_table: UITableView!
    @IBOutlet weak var search_button: UIButton!

    private let db = Firestore.firestore()

    // 学部→下位カテゴリ
    private let categoryExpansion: [String: [String]] = [
        "文学部": ["文学部","文学部共通","文学部外国語科目","英米文学科","フランス文学科","日本文学科","史学科","比較芸術学科"],
        "教育人間科学部": ["教育人間科学部","教育人間 外国語科目","教育人間 教育学科","教育人間 心理学科","教育人間　外国語科目","教育人間　教育学科","教育人間　心理学科"],
        "経済学部": ["経済学部"],
        "法学部": ["法学部"],
        "経営学部": ["経営学部"],
        "国際政治経済学部": ["国際政治経済学部","国際政治学科","国際経済学科","国際コミュニケーション学科"],
        "総合文化政策学部": ["総合文化政策学部"],
        "理工学部": ["理工学部共通","物理・数理","化学・生命","機械創造","経営システム","情報テクノロジ－","物理科学","数理サイエンス"],
        "コミュニティ人間科学部": ["ｺﾐｭﾆﾃｨ人間科学部"],
        "社会情報学部": ["社会情報学部"],
        "地球社会共生学部": ["地球社会共生学部"],
        "青山スタンダード科目": ["青山スタンダード科目"],
        "教職課程科目": ["教職課程科目"]
    ]

    // 現在の条件
    private var selectedCategory: String? = nil
    private var filterDepartment: String? = nil
    private var filterCampus: String? = nil
    private var filterPlace: String? = nil
    private var filterGrade: String? = nil
    private var filterDay: String? = nil
    private var filterPeriods: [Int]? = nil
    private var filterTimeSlots: [(day: String, period: Int)]? = nil

    // データ
    struct SyllabusData {
        let class_name: String
        let teacher_name: String
        let time: String
        let campus: String
        let grade: String
        let category: String
        let credit: String
    }
    private var data: [SyllabusData] = []
    private var filteredData: [SyllabusData] = []

    // 検索バー
    private let searchController = UISearchController(searchResultsController: nil)
    private var searchDebounce: DispatchWorkItem?

    // ページング
    private var pageSize = 24
    private var lastDoc: DocumentSnapshot?
    private var isLoading = false
    private var reachedEnd = false
    private var seenIds = Set<String>()

    override func viewDidLoad() {
        super.viewDidLoad()
        if FirebaseApp.app() == nil { FirebaseApp.configure() }

        syllabus_table.dataSource = self
        syllabus_table.delegate = self

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

    // 検索画面へ
    @IBAction func didTapSearchButton(_ sender: Any) {
        let sb = UIStoryboard(name: "Main", bundle: nil)
        guard let vc = sb.instantiateViewController(withIdentifier: "syllabus_search") as? syllabus_search else { return }

        // 初期値
        vc.initialCategory   = selectedCategory
        vc.initialDepartment = filterDepartment
        vc.initialCampus     = filterCampus
        vc.initialPlace      = filterPlace
        vc.initialGrade      = filterGrade
        vc.initialDay        = filterDay
        vc.initialPeriods    = filterPeriods

        vc.onApply = { [weak self] c in self?.apply(criteria: c) }

        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 16
        }
        present(nav, animated: true)
    }

    // ===== 文字列ユーティリティ =====
    private func canonicalizeCampusString(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.contains("相模") || t.contains("sagamihara") || t == "s" { return "相模原" }
        if t.contains("青山") || t.contains("aoyama")     || t == "a" { return "青山" }
        return nil
    }
    private func docCampusSet(_ x: [String: Any]) -> Set<String> {
        var out: Set<String> = []
        if let s = x["campus"] as? String, let c = canonicalizeCampusString(s) { out.insert(c) }
        else if let arr = x["campus"] as? [String] {
            for v in arr { if let c = canonicalizeCampusString(v) { out.insert(c) } }
        }
        return out
    }
    // 授業名の末尾が「オンライン」注記か（［］/【】/（）/[]/() を許容）
    private func isOnlineClassName(_ name: String) -> Bool {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "[\\[［\\(（【]\\s*オンライン\\s*[\\]］\\)）】]\\s*$"
        return t.range(of: pattern, options: .regularExpression) != nil
    }
    // 2gram
    private func ngrams2(_ s: String) -> [String] {
        let cs = Array(s)
        guard !cs.isEmpty else { return [] }
        if cs.count == 1 { return [String(cs[0])] }
        var out: Set<String> = []
        for i in 0..<(cs.count-1) { out.insert(String(cs[i]) + String(cs[i+1])) }
        return Array(out)
    }

    private func apply(criteria: SyllabusSearchCriteria) {
        selectedCategory = criteria.category
        filterDepartment = criteria.department
        filterCampus     = criteria.campus
        filterPlace      = criteria.place
        filterGrade      = criteria.grade
        filterDay        = criteria.day
        filterPeriods    = criteria.periods
        filterTimeSlots  = criteria.timeSlots

        resetAndReload(keyword: criteria.keyword)
    }

    private func resetAndReload(keyword: String?) {
        searchDebounce?.cancel()
        isLoading = false
        reachedEnd = false
        lastDoc = nil
        seenIds.removeAll()

        // ページサイズは控えめ（厳しめクエリでページ数を減らす）
        pageSize = 24

        data.removeAll()
        filteredData.removeAll()
        searchController.isActive = false
        syllabus_table.setContentOffset(.zero, animated: false)
        syllabus_table.reloadData()

        let kw = (keyword ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if kw.isEmpty {
            searchController.searchBar.text = nil
            loadNextPage()
        } else {
            searchController.searchBar.text = kw
            remoteSearch(prefix: kw)
        }
    }

    // クライアント側の最終フィルタ（最小限）
    private func docMatchesFilters(_ x: [String: Any]) -> Bool {
        // campus
        if let c = filterCampus, !c.isEmpty {
            let want = canonicalizeCampusString(c) ?? c
            if !docCampusSet(x).contains(want) { return false }
        }
        // place
        if let p = filterPlace, !p.isEmpty {
            let name = (x["class_name"] as? String) ?? ""
            if p == "オンライン", !isOnlineClassName(name) { return false }
            if p == "対面",       isOnlineClassName(name)  { return false }
        }
        // grade
        if let g = filterGrade, !g.isEmpty {
            let s = (x["grade"] as? String) ?? ""
            if !(s == g || s.contains(g)) { return false }
        }
        // time：複数セル優先で厳密に
        let t = x["time"] as? [String: Any]
        let d = (t?["day"] as? String) ?? ""
        let ps = (t?["periods"] as? [Int]) ?? []
        if let slots = filterTimeSlots, !slots.isEmpty {
            if !slots.contains(where: { $0.0 == d && ps.contains($0.1) }) { return false }
        } else {
            if let day = filterDay, !day.isEmpty, day != d { return false }
            if let fp = filterPeriods {
                if fp.count == 1  { if !ps.contains(fp[0]) { return false } }
                else if fp.count > 1 { if !Set(fp).isSubset(of: Set(ps)) { return false } }
            }
        }
        return true
    }

    // 学部展開
    private func expandedCategories() -> [String]? {
        guard let c = selectedCategory, !c.isEmpty else { return nil }
        if let list = categoryExpansion[c], !list.isEmpty { return list }
        return [c]
    }

    // ===== クエリを最大限絞る =====
    private func baseQuery() -> Query {
        var q: Query = db.collection("classes")

        // 学科 > 学部の順で反映
        if let dept = filterDepartment, !dept.isEmpty {
            q = q.whereField("category", isEqualTo: dept)
        } else if let list = expandedCategories() {
            if list.count == 1 { q = q.whereField("category", isEqualTo: list[0]) }
            else if list.count <= 10 { q = q.whereField("category", in: list) }
            else { q = q.whereField("category", isEqualTo: list[0]) }
        }

        if let g = filterGrade, !g.isEmpty {
            q = q.whereField("grade", isEqualTo: g)
        }

        // ■ 複数セル：day IN (...) と periods arrayContainsAny (...)
        var usedArrayContains = false
        if let slots = filterTimeSlots, !slots.isEmpty {
            let days = Array(Set(slots.map { $0.0 })).sorted()
            let periods = Array(Set(slots.map { $0.1 })).sorted()
            if !days.isEmpty { q = q.whereField("time.day", in: Array(days.prefix(10))) }   // Firestore の in は最大10
            if !periods.isEmpty {
                q = q.whereField("time.periods", arrayContainsAny: Array(periods.prefix(10)))
                usedArrayContains = true
            }
        } else {
            // 単一最適化
            if let d = filterDay, !d.isEmpty { q = q.whereField("time.day", isEqualTo: d) }
            if let ps = filterPeriods, ps.count == 1 {
                q = q.whereField("time.periods", arrayContains: ps[0])
                usedArrayContains = true
            }
        }

        // ■ オンライン：可能なら ngrams2 で母集団を縮める（arrayContains 系の重複は避ける）
        if let p = filterPlace, p == "オンライン", !usedArrayContains {
            let grams = ngrams2("オンライン")
            if !grams.isEmpty {
                q = q.whereField("ngrams2", arrayContainsAny: Array(grams.prefix(10)))
                // usedArrayContains = true  // 明示不要だが記載しておくならここ
            }
        }

        return q
    }

    // ===== ページング一覧 =====
    func loadNextPage() {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true

        var q: Query = baseQuery().order(by: "class_name").limit(to: pageSize)
        if let last = lastDoc { q = q.start(afterDocument: last) }

        q.getDocuments { [weak self] snap, err in
            guard let self = self else { return }
            self.isLoading = false
            if let err = err { print("Firestore error:", err); return }
            guard let snap = snap else { return }
            if snap.documents.isEmpty { self.reachedEnd = true; return }

            var chunk: [SyllabusData] = []
            for d in snap.documents {
                guard self.seenIds.insert(d.documentID).inserted else { continue }
                let raw = d.data()
                if !self.docMatchesFilters(raw) { continue }
                chunk.append(self.toModel(raw))
            }

            self.lastDoc = snap.documents.last
            if snap.documents.count < self.pageSize { self.reachedEnd = true }

            self.data.append(contentsOf: chunk)
            self.filteredData = self.data
            DispatchQueue.main.async { self.syllabus_table.reloadData() }

            print("📦 page:", snap.documents.count, "added:", chunk.count, "total:", self.data.count,
                  "last:", self.lastDoc?.documentID ?? "nil")
        }
    }

    // ===== TableView =====
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

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if searchController.isActive, let t = searchController.searchBar.text, !t.isEmpty { return }
        let offsetY = scrollView.contentOffset.y
        let contentH = scrollView.contentSize.height
        let frameH = scrollView.frame.size.height
        if offsetY > contentH - frameH - 400 { loadNextPage() }
    }

    // Firestore -> Model
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

    // ===== 検索バー（テキスト検索は従来通りだが place=オンラインならトークンを合流） =====
    func updateSearchResults(for searchController: UISearchController) {
        let text = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        searchDebounce?.cancel()
        if text.isEmpty {
            filteredData = data
            syllabus_table.reloadData()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.remoteSearch(prefix: text) }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        return lowered.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }
    private func tokensForSearch(_ s: String) -> [String] {
        ngrams2(normalize(s))
    }

    private func remoteSearch(prefix rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            self.filteredData = self.data
            self.syllabus_table.reloadData()
            return
        }

        if text.count == 1 {
            let startKey = text, endKey = text + "\u{f8ff}"
            let queries: [Query] = [
                baseQuery().order(by: "class_name").start(at: [startKey]).end(at: [endKey]).limit(to: 50),
                baseQuery().order(by: "teacher_name").start(at: [startKey]).end(at: [endKey]).limit(to: 50)
            ]
            let group = DispatchGroup()
            var docs: [QueryDocumentSnapshot] = []
            for q in queries {
                group.enter()
                q.getDocuments { snap, _ in defer { group.leave() }
                    if let snap = snap { docs += snap.documents }
                }
            }
            group.notify(queue: .main) { [weak self] in
                guard let self = self else { return }
                var seen = Set<String>()
                let models = docs.compactMap { d -> SyllabusData? in
                    let raw = d.data()
                    if !self.docMatchesFilters(raw) { return nil }
                    guard seen.insert(d.documentID).inserted else { return nil }
                    return self.toModel(raw)
                }
                self.filteredData = models
                self.syllabus_table.reloadData()
            }
            return
        }

        // 2文字以上：検索トークン + （オンラインなら）オンラインのトークンも合流
        var tokens = Array(tokensForSearch(text).prefix(10))
        if filterPlace == "オンライン" {
            tokens = Array(Set(tokens + ngrams2("オンライン"))).prefix(10).map { $0 }
        }

        var q: Query = baseQuery()
            .whereField("ngrams2", arrayContainsAny: tokens)
            .order(by: "class_name")
            .limit(to: 200)

        q.getDocuments { [weak self] snap, _ in
            guard let self = self else { return }
            let docs = snap?.documents ?? []
            var seen = Set<String>()
            let models: [SyllabusData] = docs.compactMap { d in
                let x = d.data()
                if !self.docMatchesFilters(x) { return nil }
                let docTokens = (x["ngrams2"] as? [String]) ?? []
                guard tokens.allSatisfy(docTokens.contains) else { return nil }
                guard seen.insert(d.documentID).inserted else { return nil }
                return self.toModel(x)
            }
            self.filteredData = models
            self.syllabus_table.reloadData()
            print("🔍 remote(ngram) merged:", docs.count, "after AND:", models.count)
        }
    }
}
