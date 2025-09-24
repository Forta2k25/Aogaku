import UIKit
import FirebaseCore
import FirebaseFirestore
import GoogleMobileAds

@inline(__always)
private func makeAdaptiveAdSize(width: CGFloat) -> AdSize {
    return currentOrientationAnchoredAdaptiveBanner(width: width)
}

// ===== 検索条件 =====
struct SyllabusSearchCriteria {
    var keyword: String? = nil
    var category: String? = nil      // 学部（上位）
    var department: String? = nil    // 学科（完全一致）
    var campus: String? = nil        // "青山" / "相模原"
    var place: String? = nil         // "対面" / "オンライン" / nil
    var grade: String? = nil
    var day: String? = nil           // 単一曜日のときだけ入る最適化用
    var periods: [Int]? = nil
    var timeSlots: [(String, Int)]? = nil // 複数セル選択: (day, period)
    var term: String? = nil          // "前期" / "後期" / nil
}

final class syllabus: UIViewController,
                      UITableViewDataSource, UITableViewDelegate,
                      BannerViewDelegate, UISearchResultsUpdating {

    @IBOutlet weak var syllabus_table: UITableView!
    @IBOutlet weak var search_button: UIButton!

    // Firestore
    private let db = Firestore.firestore()

    // ===== 上位→下位カテゴリ展開 =====
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
    private func expandedCategories() -> [String]? {
        guard let cat = selectedCategory, !cat.isEmpty else { return nil }
        if let list = categoryExpansion[cat] { return list }
        return [cat]
    }

    // ===== AdMob (Banner) =====
    private let adContainer = UIView()
    private var bannerView: BannerView?
    private var lastBannerWidth: CGFloat = 0
    private var adContainerHeight: NSLayoutConstraint?

    // ===== 現在の条件（保持用） =====
    private var selectedCategory: String? = nil
    private var filterDepartment: String? = nil
    private var filterCampus: String? = nil
    private var filterPlace: String? = nil      // 対面/オンライン
    private var filterGrade: String? = nil
    private var filterDay: String? = nil
    private var filterPeriods: [Int]? = nil
    private var filterTimeSlots: [(day: String, period: Int)]? = nil
    private var filterTerm: String? = nil       // ★ 学期

    // ===== データ =====
    struct SyllabusData {
        let docID: String
        let class_name: String
        let teacher_name: String
        let time: String
        let campus: String
        let grade: String
        let category: String
        let credit: String
        let term: String
    }
    private var data: [SyllabusData] = []
    private var filteredData: [SyllabusData] = []

    // ===== 検索バー =====
    private let searchController = UISearchController(searchResultsController: nil)
    private var searchDebounce: DispatchWorkItem?

    // ===== ページング =====
    private var pageSizeBase = 10
    private var lastDoc: DocumentSnapshot?
    private var isLoading = false
    private var reachedEnd = false
    private var seenIds = Set<String>()

    // ===== Loading indicator =====
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private func setSearching(_ searching: Bool) {
        if searching {
            if syllabus_table.backgroundView !== loadingIndicator {
                syllabus_table.backgroundView = loadingIndicator
            }
            loadingIndicator.startAnimating()
        } else {
            loadingIndicator.stopAnimating()
            if syllabus_table.backgroundView === loadingIndicator {
                syllabus_table.backgroundView = nil
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        syllabus_table.rowHeight = UITableView.automaticDimension
        syllabus_table.estimatedRowHeight = 110

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

        // Loading indicator
        loadingIndicator.hidesWhenStopped = true

        loadNextPage()
        setupAdBanner()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        loadBannerIfNeeded()
    }

    // ===== 検索画面へ =====
    @IBAction func didTapSearchButton(_ sender: Any) {
        let sb = UIStoryboard(name: "Main", bundle: nil)
        guard let searchVC = sb.instantiateViewController(withIdentifier: "syllabus_search") as? syllabus_search else {
            print("❌ failed to instantiate syllabus_search"); return
        }
        // 初期値（前回の選択を保持）
        searchVC.initialCategory   = selectedCategory
        searchVC.initialDepartment = filterDepartment
        searchVC.initialCampus     = filterCampus
        searchVC.initialPlace      = filterPlace
        searchVC.initialGrade      = filterGrade
        searchVC.initialDay        = filterDay
        searchVC.initialPeriods    = filterPeriods
        searchVC.initialTimeSlots  = filterTimeSlots
        searchVC.initialTerm       = filterTerm   // ★ 追加

        searchVC.onApply = { [weak self] criteria in
            self?.apply(criteria: criteria)
        }

        let nav = UINavigationController(rootViewController: searchVC)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 16
        }
        present(nav, animated: true)
    }

    // ===== Ad: 下部固定 =====
    private func setupAdBanner() {
        adContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(adContainer)

        adContainerHeight = adContainer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            adContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            adContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            adContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            adContainerHeight!
        ])

        let bv = BannerView()
        bv.translatesAutoresizingMaskIntoConstraints = false
        bv.adUnitID = "ca-app-pub-3940256099942544/2934735716" // テストID
        bv.rootViewController = self
        bv.adSize = AdSizeBanner
        bv.delegate = self

        adContainer.addSubview(bv)
        NSLayoutConstraint.activate([
            bv.leadingAnchor.constraint(equalTo: adContainer.leadingAnchor),
            bv.trailingAnchor.constraint(equalTo: adContainer.trailingAnchor),
            bv.topAnchor.constraint(equalTo: adContainer.topAnchor),
            bv.bottomAnchor.constraint(equalTo: adContainer.bottomAnchor)
        ])
        self.bannerView = bv
    }

    private func updateInsetsForBanner(height: CGFloat) {
        var inset = syllabus_table.contentInset
        inset.bottom = height
        syllabus_table.contentInset = inset
        syllabus_table.scrollIndicatorInsets.bottom = height
    }

    private func loadBannerIfNeeded() {
        guard let bv = bannerView else { return }
        let safeWidth = view.safeAreaLayoutGuide.layoutFrame.width
        if safeWidth <= 0 { return }

        let useWidth = max(320, floor(safeWidth))
        if abs(useWidth - lastBannerWidth) < 0.5 { return }
        lastBannerWidth = useWidth

        let size = makeAdaptiveAdSize(width: useWidth)

        adContainerHeight?.constant = size.size.height
        updateInsetsForBanner(height: size.size.height)
        view.layoutIfNeeded()

        guard size.size.height > 0 else { return }
        if !CGSizeEqualToSize(bv.adSize.size, size.size) { bv.adSize = size }
        bv.load(Request())
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { UITableView.automaticDimension }

    // MARK: - BannerViewDelegate
    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        let h = bannerView.adSize.size.height
        adContainerHeight?.constant = h
        updateInsetsForBanner(height: h)
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
    }
    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        adContainerHeight?.constant = 0
        updateInsetsForBanner(height: 0)
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
        print("Ad failed:", error.localizedDescription)
    }

    // ===== 共通ヘルパ =====
    private func scrollToTop(_ animated: Bool = false) {
        let y = -syllabus_table.adjustedContentInset.top
        syllabus_table.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
    }

    // ===== 正規化ユーティリティ =====

    // 学期表記の正規化
    private func normalizeTerm(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "[()（）\\s]", with: "", options: .regularExpression).lowercased()
        switch t {
        case "前期","春学期","spring": return "前期"
        case "後期","秋学期","autumn","fall": return "後期"
        case "通年","年間","fullyear","yearlong": return "通年"
        default:
            return s.replacingOccurrences(of: "[()（）]", with: "", options: .regularExpression)
        }
    }

    // カタカナ⇄ひらがな変換（SDK差異に依存しない）
    private func toKatakana(_ s: String) -> String {
        let ms = NSMutableString(string: s) as CFMutableString
        CFStringTransform(ms, nil, kCFStringTransformHiraganaKatakana, false) // → カタカナ
        return ms as String
    }
    private func toHiragana(_ s: String) -> String {
        let ms = NSMutableString(string: s) as CFMutableString
        CFStringTransform(ms, nil, kCFStringTransformHiraganaKatakana, true)  // → ひらがな
        return ms as String
    }

    // 文字検索の正規化（ひらがな統一・長音削除・記号除去）
    private func normalizeForSearch(_ raw: String) -> String {
        var s = raw
        if let x = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) { s = x }
        s = toHiragana(s)                   // ひらがな統一
        s = s.lowercased()
        s = s.replacingOccurrences(of: "[\\s\\p{Punct}ー‐-–—・／/,.、．\\[\\]［］()（）{}【】]+",
                                   with: "",
                                   options: .regularExpression) // 長音も除去
        return s
    }
    
    // 授業名＋教員名を検索用に正規化して結合
    private func aggregateDocText(_ x: [String: Any]) -> String {
        let name = (x["class_name"] as? String) ?? ""
        let teacher = (x["teacher_name"] as? String) ?? ""
        return normalizeForSearch(name + teacher)
    }

    // arrayContainsAny 用：カタカナ＋長音保持 版（空白・記号のみ除去）
    private func squashForTokensKeepingLong(_ raw: String) -> String {
        var s = raw
        if let x = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) { s = x }
        s = toKatakana(s)                   // カタカナ側に寄せる
        s = s.lowercased()
        // ※ 長音「ー」「ｰ」は残す。その他の空白/記号を除去
        s = s.replacingOccurrences(of: "[\\s‐-–—・／/,.、．\\[\\]［］()（）{}【】]+",
                                   with: "",
                                   options: .regularExpression)
        return s
    }

    // n-gram（事前整形済み文字列から生成／順序保持）
    private func ngrams2Raw(_ prepared: String) -> [String] {
        let cs = Array(prepared)
        guard !cs.isEmpty else { return [] }
        if cs.count == 1 { return [String(cs[0])] }
        var out: [String] = []
        out.reserveCapacity(cs.count - 1)
        for i in 0..<(cs.count - 1) {
            out.append(String(cs[i]) + String(cs[i+1]))
        }
        return out
    }

    // arrayContainsAny に投げるトークン（最大10）：ひらがな版＋カタカナ長音版をインターリーブ
    private func tokensForArrayContainsAny(_ text: String) -> [String] {
        let hira = ngrams2Raw(normalizeForSearch(text))          // ひらがな・長音除去
        let kata = ngrams2Raw(squashForTokensKeepingLong(text))  // カタカナ・長音保持
        var seen = Set<String>()
        var res: [String] = []
        var i = 0
        let n = max(hira.count, kata.count)
        while res.count < 10 && i < n {
            if i < hira.count {
                let t = hira[i]
                if seen.insert(t).inserted { res.append(t) }
            }
            if res.count >= 10 { break }
            if i < kata.count {
                let t = kata[i]
                if seen.insert(t).inserted { res.append(t) }
            }
            i += 1
        }
        return res
    }

    // ===== 条件適用 =====
    private func apply(criteria: SyllabusSearchCriteria) {
        selectedCategory = criteria.category
        filterDepartment = criteria.department
        filterCampus     = criteria.campus
        filterPlace      = criteria.place
        filterGrade      = criteria.grade
        filterDay        = criteria.day
        filterPeriods    = criteria.periods
        filterTimeSlots  = criteria.timeSlots
        filterTerm       = criteria.term

        DispatchQueue.main.async { [weak self] in
            self?.resetAndReload(keyword: criteria.keyword)
        }
    }

    // ===== リロード共通 =====
    private func resetAndReload(keyword: String?) {
        searchDebounce?.cancel()
        isLoading = false
        reachedEnd = false
        lastDoc = nil
        seenIds.removeAll()

        // 通信量節約：重い条件のときだけページ大きめ
        if (filterPlace?.isEmpty == false) || (filterTimeSlots?.isEmpty == false) {
            pageSizeBase = 50
        } else {
            pageSizeBase = 10
        }

        data.removeAll()
        filteredData.removeAll()
        searchController.isActive = false
        syllabus_table.setContentOffset(.zero, animated: false)
        syllabus_table.reloadData()

        let kw = (keyword ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if kw.isEmpty {
            searchController.searchBar.text = nil
            setSearching(false)          // 検索していないので非表示
            loadNextPage()
        } else {
            searchController.searchBar.text = kw
            // ★ 検索開始時はいったん空表示＋くるくる
            filteredData.removeAll()
            syllabus_table.reloadData()
            scrollToTop()
            setSearching(true)
            remoteSearch(text: kw)
        }
    }

    // ===== クライアント側の最終フィルタ =====
    private func docMatchesFilters(_ x: [String: Any]) -> Bool {
        // キャンパス
        if let c = filterCampus, !c.isEmpty {
            let want = canonicalizeCampusString(c) ?? c
            if !docCampusSet(x).contains(want) { return false }
        }
        // 形態（授業名末尾の [オンライン] などで判定）
        if let p = filterPlace, !p.isEmpty {
            let name = (x["class_name"] as? String) ?? ""
            if p == "オンライン" {
                if !isOnlineClassName(name) { return false }
            } else if p == "対面" {
                if isOnlineClassName(name) { return false }
            }
        }
        // 学年
        if let g = filterGrade, !g.isEmpty {
            let s = (x["grade"] as? String) ?? ""
            if !(s == g || s.contains(g)) { return false }
        }
        // 曜日・時限
        let time = x["time"] as? [String: Any]
        let docDay = (time?["day"] as? String) ?? ""
        let docPeriods = (time?["periods"] as? [Int]) ?? []

        if let slots = filterTimeSlots, !slots.isEmpty {
            let ok = slots.contains { $0.0 == docDay && docPeriods.contains($0.1) }
            if !ok { return false }
        } else {
            if let d = filterDay, !d.isEmpty, docDay != d { return false }
            if let ps = filterPeriods {
                if ps.count == 1 {
                    if !docPeriods.contains(ps[0]) { return false }
                } else if ps.count > 1 {
                    if !Set(ps).isSubset(of: Set(docPeriods)) { return false }
                }
            }
        }
        // ★ 学期（前期/後期）
        if let wantTerm = filterTerm, !wantTerm.isEmpty {
            let termRaw = (x["term"] as? String) ?? ""
            let normalized = normalizeTerm(termRaw)
            if normalized != wantTerm { return false }
        }
        return true
    }

    // ===== クエリのベース（通信費削減：できるだけサーバで絞る） =====
    private func baseQuery() -> Query {
        var q: Query = db.collection("classes")

        // 学科 or 学部ツリー
        if let dept = filterDepartment, !dept.isEmpty {
            q = q.whereField("category", isEqualTo: dept)
        } else if let list = expandedCategories() {
            if list.count == 1 { q = q.whereField("category", isEqualTo: list[0]) }
            else if list.count <= 10 { q = q.whereField("category", in: list) }
            else { q = q.whereField("category", isEqualTo: list[0]) } // インデックス対策
        }

        if let g = filterGrade,  !g.isEmpty { q = q.whereField("grade",  isEqualTo: g) }

        // 曜日/時限（単一のみはサーバで）
        if (filterTimeSlots == nil || filterTimeSlots?.isEmpty == true) {
            if let d = filterDay,    !d.isEmpty { q = q.whereField("time.day", isEqualTo: d) }
            if let ps = filterPeriods, ps.count == 1 {
                q = q.whereField("time.periods", arrayContains: ps[0])
            }
        }

        // ★ 学期（可能ならサーバで）
        if let t = filterTerm, !t.isEmpty {
            q = q.whereField("term", isEqualTo: t) // データが前期/後期で入っている前提
        }

        return q
    }

    // ===== ページング一覧 =====
    func loadNextPage() {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true

        let qBase = baseQuery().order(by: "class_name")
        var q: Query = qBase.limit(to: pageSizeBase)
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
                chunk.append(self.toModel(docID: d.documentID, raw))
            }

            self.lastDoc = snap.documents.last
            if snap.documents.count < self.pageSizeBase { self.reachedEnd = true }

            self.data.append(contentsOf: chunk)
            self.filteredData = self.data
            DispatchQueue.main.async { self.syllabus_table.reloadData() }

            // 必要なときだけ次ページ先読み（通信量を抑える）
            if self.filteredData.isEmpty,
               !self.reachedEnd,
               (self.filterPlace?.isEmpty == false || self.filterTimeSlots?.isEmpty == false) {
                self.loadNextPage()
            }

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
        cell.credit.text = subject.credit.isEmpty ? "-" : "\(subject.credit)単位"
        cell.termLabel.text = subject.term.isEmpty ? "-" : subject.term
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = filteredData[indexPath.row]

        let sb = UIStoryboard(name: "Main", bundle: nil)
        guard let detail = sb.instantiateViewController(withIdentifier: "SyllabusDetailViewController") as? SyllabusDetailViewController else {
            print("❌ failed to instantiate SyllabusDetailViewController"); return
        }

        // 渡す最小情報
        detail.docID = item.docID
        detail.initialTitle = item.class_name
        detail.initialTeacher = item.teacher_name
        detail.initialCredit = item.credit

        detail.modalPresentationStyle = .pageSheet
        if let sheet = detail.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 16
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }

        present(detail, animated: true)
    }

    @IBAction func didTapFavorites(_ sender: Any) {
        let vc = FavoritesListViewController()
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
    }

    // ===== 無限スクロール（検索中は停止） =====
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if searchController.isActive, let t = searchController.searchBar.text, !t.isEmpty { return }
        let offsetY = scrollView.contentOffset.y
        let contentH = scrollView.contentSize.height
        let frameH = scrollView.frame.size.height
        if offsetY > contentH - frameH - 400 { loadNextPage() }
    }

    // ===== Firestore → Model 変換 =====
    private func toModel(docID: String, _ x: [String: Any]) -> SyllabusData {
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

        let termRaw = (x["term"] as? String) ?? ""
        let term = normalizeTerm(termRaw)

        return SyllabusData(
            docID: docID,
            class_name: x["class_name"] as? String ?? "",
            teacher_name: x["teacher_name"] as? String ?? "",
            time: timeStr,
            campus: campusStr,
            grade: x["grade"] as? String ?? "",
            category: x["category"] as? String ?? "",
            credit: String(x["credit"] as? Int ?? 0),
            term: term
        )
    }

    // ===== 検索バーの更新 =====
    func updateSearchResults(for searchController: UISearchController) {
        let text = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        searchDebounce?.cancel()

        if text.isEmpty {
            filteredData = data
            syllabus_table.reloadData()
            scrollToTop()
            setSearching(false)      // 入力クリア時は消灯
            return
        }

        // ★ 新しい検索を始める時はいったん空表示にして上の古いセルを消す＋くるくる
        if !filteredData.isEmpty {
            filteredData.removeAll()
            syllabus_table.reloadData()
            scrollToTop()
        }
        setSearching(true)

        let work = DispatchWorkItem { [weak self] in self?.remoteSearch(text: text) }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    // ===== リモート検索（通信量を抑えつつ、長い語でもヒットが減らないように） =====
    private func remoteSearch(text rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            self.filteredData = self.data
            self.syllabus_table.reloadData()
            scrollToTop()
            setSearching(false)
            return
        }

        // 1文字は prefix 検索（2クエリ）…軽量で十分
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
                let models = docs.compactMap { (d) -> SyllabusData? in
                    let raw = d.data()
                    guard self.docMatchesFilters(raw) else { return nil }
                    guard seen.insert(d.documentID).inserted else { return nil }
                    return self.toModel(docID: d.documentID, raw)
                }
                self.filteredData = models
                self.syllabus_table.reloadData()
                self.scrollToTop()
                self.setSearching(false)   // 結果確定（0件でも消灯）
            }
            return
        }

        // 2文字以上：n-gram で粗く拾い、ローカル contains で最終判定
        let normalizedQuery = normalizeForSearch(text)
        let tokens  = tokensForArrayContainsAny(text)      // ← ここが改良点
        guard !tokens.isEmpty else {
            // トークン化できない場合は軽量 prefix へ
            filteredData.removeAll()
            syllabus_table.reloadData()
            scrollToTop()
            fallbackPrefixSearch(text: text, base: [])
            return
        }

        var q: Query = baseQuery()
            .whereField("ngrams2", arrayContainsAny: tokens)  // サーバ側：ORで粗く
            .order(by: "class_name")
            .limit(to: 120)                                   // 上限で通信を制御

        q.getDocuments { [weak self] snap, _ in
            guard let self = self else { return }
            let docs = snap?.documents ?? []

            // ローカル最終判定：正規化した「授業名+教員名」に正規化クエリが含まれるか（substring）
            var seen = Set<String>()
            let models = docs.compactMap { (d) -> SyllabusData? in
                let x = d.data()
                guard self.docMatchesFilters(x) else { return nil }
                let haystack = self.aggregateDocText(x)
                guard haystack.contains(normalizedQuery) else { return nil }
                guard seen.insert(d.documentID).inserted else { return nil }
                return self.toModel(docID: d.documentID, x)
            }

            if !models.isEmpty {
                self.filteredData = models
                self.syllabus_table.reloadData()
                self.scrollToTop()
                self.setSearching(false)   // 結果確定
            } else {
                // 0件なら最小限のフォールバック（ここでは継続表示、確定はフォールバック側で消灯）
                self.filteredData.removeAll()
                self.syllabus_table.reloadData()
                self.scrollToTop()
                self.fallbackPrefixSearch(text: text, existingIDs: seen, base: [])
            }
            print("🔍 ngram fetched:", docs.count, "final:", models.count)
        }
    }

    // 足りない時だけのフォールバック（prefix）…“追記”ではなく“置換”
    private func fallbackPrefixSearch(text: String,
                                     existingIDs: Set<String> = [],
                                     base: [SyllabusData] = []) {
        let startKey = text, endKey = text + "\u{f8ff}"
        let queries: [Query] = [
            baseQuery().order(by: "class_name").start(at: [startKey]).end(at: [endKey]).limit(to: 40),
            baseQuery().order(by: "teacher_name").start(at: [startKey]).end(at: [endKey]).limit(to: 40)
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
            var seen = existingIDs
            var models: [SyllabusData] = base   // ★ 既存filteredDataは使わない（追記しない）
            for d in docs {
                if !seen.insert(d.documentID).inserted { continue }
                let raw = d.data()
                if !self.docMatchesFilters(raw) { continue }
                models.append(self.toModel(docID: d.documentID, raw))
            }
            self.filteredData = models
            self.syllabus_table.reloadData()
            self.scrollToTop()
            self.setSearching(false)       // フォールバック結果確定（0件でも消灯）
            print("🔁 fallback(prefix) replaced, total:", models.count)
        }
    }

    // === キャンパス・オンライン注記（重複定義なし） ===
    private func canonicalizeCampusString(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.contains("相模") || t.contains("sagamihara") || t == "s" { return "相模原" }
        if t.contains("青山") || t.contains("aoyama")     || t == "a" { return "青山" }
        return nil
    }
    private func docCampusSet(_ x: [String: Any]) -> Set<String> {
        var out: Set<String> = []
        if let s = x["campus"] as? String {
            if let c = canonicalizeCampusString(s) { out.insert(c) }
        } else if let arr = x["campus"] as? [String] {
            for v in arr { if let c = canonicalizeCampusString(v) { out.insert(c) } }
        }
        return out
    }
    private func isOnlineClassName(_ name: String) -> Bool {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "[\\[［\\(（【]\\s*オンライン\\s*[\\]］\\)）】]\\s*$"
        return t.range(of: pattern, options: .regularExpression) != nil
    }
}
