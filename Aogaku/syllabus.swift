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
    var category: String? = nil
    var department: String? = nil
    var campus: String? = nil
    var place: String? = nil
    var grade: String? = nil
    var day: String? = nil
    var periods: [Int]? = nil
    var timeSlots: [(String, Int)]? = nil
    var term: String? = nil
    var undecided: Bool? = nil      // ★ 追加：授業名に「不定」を含む
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
    private var filterUndecided: Bool = false
    private var activeKeyword: String? = nil
    private var localOffset = 0
    private let localPageSize = 20
    private var usingLocalList = false
    private var localIsLoading = false
    private var isBackgroundFilling = false
    private let localPrefetchBatch = 120
    private var loadingOverlay: SyllabusLoadingOverlay?
    private var listSessionId = UUID()
    private var evalMethodCacheByStableKey: [String: String] = [:]
    private var evalMethodCacheByEvalKey: [String: String] = [:]

    
    // ===== データ =====
    struct SyllabusData {
        let docID: String                // ソース依存（自動ID / 行番号ID）
        let stableKey: String            // ソースをまたいで同一授業を識別するキー
        let class_name: String
        let teacher_name: String
        let time: String
        let campus: String
        let grade: String
        let category: String
        let credit: String
        let term: String
        let eval_method: String
    }

    private var data: [SyllabusData] = []
    private var filteredData: [SyllabusData] = []
    private var evalMethodCache: [String: String] = [:]

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
    
    // MARK: - Dark Gray theming
    private func appBackgroundColor(for traits: UITraitCollection) -> UIColor {
        // 画面のベース色
        return traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.20, alpha: 1.0)   // #333 くらい
            : .systemBackground
    }
    private func cellBackgroundColor(for traits: UITraitCollection) -> UIColor {
        // セルのカード色（ベースより少し濃い/明るい）
        return traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.16, alpha: 1.0)   // #292929 くらい
            : .secondarySystemBackground
    }
    private func separatorColor(for traits: UITraitCollection) -> UIColor {
        return traits.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.12)
            : .separator
    }
    private func searchFieldBackground(for traits: UITraitCollection) -> UIColor {
        return traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.18, alpha: 1.0)
            : .systemGray6
    }
    private func applyBackgroundStyle() {
        let bg = appBackgroundColor(for: traitCollection)
        view.backgroundColor = bg
        syllabus_table.backgroundColor = bg
        adContainer.backgroundColor = bg  // バナーの土台も揃える

        syllabus_table.separatorColor = separatorColor(for: traitCollection)

        // 検索バーのテキストフィールド背景
        if let tf = searchController.searchBar.value(forKey: "searchField") as? UITextField {
            tf.backgroundColor = searchFieldBackground(for: traitCollection)
        }

        // 目に見えているセルの再着色
        for cell in syllabus_table.visibleCells {
            let cbg = cellBackgroundColor(for: traitCollection)
            cell.backgroundColor = cbg
            cell.contentView.backgroundColor = cbg
            // 選択時
            let selected = UIView()
            selected.backgroundColor = (traitCollection.userInterfaceStyle == .dark)
                ? UIColor(white: 0.22, alpha: 1.0)
                : UIColor.systemFill
            (cell as? UITableViewCell)?.selectedBackgroundView = selected
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

        showLoadingOverlay()

        // ★ いったんメインループに返してUI(ロード画面)を描画 → その後BGで初期化
        DispatchQueue.main.async { [weak self] in
            self?.startInitialLoad()
        }

        setupAdBanner()
        NotificationCenter.default.addObserver(self,
            selector: #selector(onAdMobReady),
            name: .adMobReady, object: nil)
        applyBackgroundStyle()

        }
    
    @objc private func onAdMobReady() {
        loadBannerIfNeeded()
    }


    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        AppGatekeeper.shared.checkAndPresentIfNeeded(on: self)
    }


    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        loadBannerIfNeeded()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyBackgroundStyle()
        }
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

    private func startInitialLoad() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // ★ prepare はBGで（UIを止めない）
            LocalSyllabusIndex.shared.prepare()
            let ready = LocalSyllabusIndex.shared.isReady

            let criteria = SyllabusSearchCriteria(
                category: self.selectedCategory,
                department: self.filterDepartment,
                campus: self.filterCampus,
                place: self.filterPlace,
                grade: self.filterGrade,
                day: self.filterDay,
                periods: self.filterPeriods,
                timeSlots: self.filterTimeSlots,
                term: self.filterTerm,
                undecided: self.filterUndecided
            )

            DispatchQueue.main.async {
                self.usingLocalList = false
                self.loadNextPage()          // Firestoreで一覧
                // hideLoadingOverlay は loadNextPage 内で呼ばれてるのでそのままでOK
            }
            // LocalSyllabusIndex.prepare() はこのまま残してOK（検索用）

        }
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
        // RCで広告を止めているときはUIも消す
        guard AdsConfig.enabled else {
            adContainer.isHidden = true
            adContainerHeight?.constant = 0
            return
        }
        let bv = BannerView()
        bv.translatesAutoresizingMaskIntoConstraints = false
        bv.adUnitID = AdsConfig.bannerUnitID     // ← RCの本番/テストIDを自動選択
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

    private func normalizeTerm(_ raw: String) -> String {
        // 括弧・空白の除去
        var s = raw.replacingOccurrences(of: "[()（）\\s]", with: "", options: .regularExpression)

        // 全角→半角数字
        if let x = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) { s = x }

        // 「隔週第1週/第2週」を短縮
        s = s.replacingOccurrences(of: "隔週第1週", with: "隔1")
             .replacingOccurrences(of: "隔週第2週", with: "隔2")

        // 代表表記
        switch s.lowercased() {
        case "前期","春学期","spring":                 return "前期"
        case "後期","秋学期","autumn","fall":           return "後期"
        case "通年","年間","fullyear","yearlong":       return "通年"
        default:
            // 具体表記の短縮（通年隔1/前期隔1/後期隔1 など）
            s = s.replacingOccurrences(of: "通年隔週第1週", with: "通年隔1")
                 .replacingOccurrences(of: "通年隔週第2週", with: "通年隔2")
                 .replacingOccurrences(of: "前期隔週第1週", with: "前期隔1")
                 .replacingOccurrences(of: "前期隔週第2週", with: "前期隔2")
                 .replacingOccurrences(of: "後期隔週第1週", with: "後期隔1")
                 .replacingOccurrences(of: "後期隔週第2週", with: "後期隔2")
            return s
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
    
    private func makeEvalKey(className: String, teacher: String) -> String {
        let cn = normalizeForSearch(className)
        let tn = normalizeForSearch(teacher)
        return cn + "|" + tn
    }

    // 異なるソース（Firestore自動ID / ローカル行番号ID）でも一致する安定キー
    private func makeStableKey(className: String,
                               teacher: String,
                               time: String,
                               campus: String,
                               grade: String,
                               category: String,
                               term: String) -> String {
        let cn = normalizeForSearch(className)
        let tn = normalizeForSearch(teacher)
        let cat = normalizeForSearch(category)
        let tm = time.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        let cp = campus.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression).lowercased()
        let gr = grade.lowercased()
        let tr = normalizeTerm(term)
        return [cn, tn, tm, cp, gr, cat, tr].joined(separator: "|")
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
        filterUndecided = criteria.undecided ?? false

        DispatchQueue.main.async { [weak self] in
            self?.resetAndReload(keyword: criteria.keyword)
        }
    }

    // ===== リロード共通 =====
    private func resetAndReload(keyword: String?) {
        let kw = (keyword ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        activeKeyword = kw.isEmpty ? nil : kw
        searchDebounce?.cancel()
        isLoading = false
        reachedEnd = false
        lastDoc = nil
        seenIds.removeAll()
        listSessionId = UUID()          // ★ 新しいセッションを開始
        isBackgroundFilling = false      // 旧BGループの続行を避ける（念のため）
        usingLocalList = false           // 一旦無効化（BG追記のガード用）

        if kw.isEmpty {
            usingLocalList = false

            // ✅ 条件が変わったら「今までロードした授業」を残さない
            data.removeAll()
            filteredData.removeAll()
            localOffset = 0
            syllabus_table.setContentOffset(.zero, animated: false)
            syllabus_table.reloadData()

            scrollToTop()
            loadNextPage()   // ✅ 1ページ目から取り直す（条件の授業だけになる）
            return
        }

        data.removeAll()
        filteredData.removeAll()
        searchController.isActive = false
        syllabus_table.setContentOffset(.zero, animated: false)
        syllabus_table.reloadData()

       // let kw = (keyword ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
        // 形態（オンライン/対面）
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

        // === 不定（授業名に「不定」を含む）===
        if filterUndecided {
            let name = (x["class_name"] as? String) ?? ""
            if name.contains("不定") == false { return false }
            // 不定のときは曜日・時限チェックはスキップ（時間が空欄な科目に対応）
        } else {
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
        }

        // ★ 学期（括弧付きや表記ゆれを吸収して判定）
        if let want = filterTerm, !want.isEmpty {
            let termRaw = (x["term"] as? String) ?? ""
            let normalized = normalizeTerm(termRaw)  // ← ()/（）/空白を除去＆代表表記へ

            if want == "集中" {
                // 「不定集中」など、"～集中" なら OK（後段の「不定」判定と組み合わせ）
                if !normalized.contains("集中") { return false }
            } else {
                // それ以外は完全一致
                if normalized != want { return false }
            }
        }

        // 学期（括弧や表記ゆれを吸収して判定）
        if let wantTerm = filterTerm, !wantTerm.isEmpty {
            let doc  = normalizeTerm((x["term"] as? String) ?? "")
            let want = normalizeTerm(wantTerm)

            switch want {
            case "集中":
                // 例: 前期集中 / 後期集中 / 夏休集中 など
                if doc.contains("集中") == false { return false }
            case "通年":
                // 例: 通年 / 通年隔1 / 通年隔2 / 通年集中 など
                if doc.hasPrefix("通年") == false { return false }
            case "前期":
                // 例: 前期 / 前期隔1 / 前期隔2 / 前期集中 などもマッチさせたいなら hasPrefix に
                if doc.hasPrefix("前期") == false { return false }
            case "後期":
                if doc.hasPrefix("後期") == false { return false }
            default:
                // 具体名（通年隔1 など）を選んだときは完全一致
                if doc != want { return false }
            }
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
        if !filterUndecided && (filterTimeSlots == nil || filterTimeSlots?.isEmpty == true) {
            if let d = filterDay,    !d.isEmpty { q = q.whereField("time.day", isEqualTo: d) }
            if let ps = filterPeriods, ps.count == 1 {
                q = q.whereField("time.periods", arrayContains: ps[0])
            }
        }

        return q
    }

    func loadNextPage() {
        if let kw = activeKeyword, !kw.isEmpty { return }

            // ✅ ローカル一覧を使っているときだけ、Firestoreページングを止める
        if usingLocalList && LocalSyllabusIndex.shared.isReady { return }

        guard !isLoading, !reachedEnd else { return }
        isLoading = true

        let session = listSessionId   // ★ 追加：この呼び出しのセッションを固定

        let qBase = baseQuery()
        let hasTimeFilter = (filterDay?.isEmpty == false) || ((filterPeriods?.count ?? 0) == 1)

        var q: Query = hasTimeFilter
            ? qBase.limit(to: pageSizeBase)
            : qBase.order(by: "class_name").limit(to: pageSizeBase)

        if let last = lastDoc { q = q.start(afterDocument: last) }

        q.getDocuments { [weak self] snap, err in
            guard let self = self else { return }

            // ★ 追加：条件が変わった（別リロード/別検索に移った）結果は捨てる
            guard self.listSessionId == session else { return }

            self.isLoading = false
            if let err = err { print("Firestore error:", err); return }
            guard let snap = snap else { return }

            if snap.documents.isEmpty {
                self.reachedEnd = true
                return
            }

            var chunk: [SyllabusData] = []
            for d in snap.documents {
                guard self.seenIds.insert(d.documentID).inserted else { continue }
                let raw = d.data()
                if !self.docMatchesFilters(raw) { continue }
                chunk.append(self.toModel(docID: d.documentID, raw))
            }

            self.lastDoc = snap.documents.last
            if snap.documents.count < self.pageSizeBase { self.reachedEnd = true }

            let safeChunk = self.preserveEvalMethod(from: self.data, into: chunk)
            self.data.append(contentsOf: safeChunk)

            if hasTimeFilter {
                self.data.sort { $0.class_name.localizedStandardCompare($1.class_name) == .orderedAscending }
            }

            self.filteredData = self.data

            DispatchQueue.main.async {
                // ★ 念のためUI反映直前もセッション確認
                guard self.listSessionId == session else { return }
                self.syllabus_table.reloadData()
                self.hideLoadingOverlay()
            }
        }
    }


    // ===== TableView =====
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { filteredData.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let subject = filteredData[indexPath.row]
        let cell = syllabus_table.dequeueReusableCell(withIdentifier: "class", for: indexPath) as! syllabusTableViewCell

        // 左側
        cell.class_name.text   = subject.class_name
        cell.teacher_name.text = subject.teacher_name
        cell.time.text         = subject.time
        cell.campus.text       = subject.campus
        cell.grade.text        = subject.grade
        cell.category.text     = subject.category

        // 右上：単位/学期（従来どおり）
        cell.credit.text    = subject.credit.isEmpty ? "-" : "\(subject.credit)単位"
        cell.termLabel.text = subject.term.isEmpty   ? "-" : subject.term

        let ekey = makeEvalKey(className: subject.class_name, teacher: subject.teacher_name)

        let evalText = subject.eval_method.isEmpty
            ? (evalMethodCacheByEvalKey[ekey]
                ?? evalMethodCacheByStableKey[subject.stableKey]
                ?? evalMethodCache[subject.docID]
                ?? "-")
            : subject.eval_method

        cell.eval_method.text = evalText
        
        // === 追加：表示できた評価方法をキャッシュ＆モデルへ書き戻す ===
        if evalText != "-" {
            // 安定キー/DocID 両方でキャッシュ
            evalMethodCacheByEvalKey[ekey] = evalText
            evalMethodCacheByStableKey[subject.stableKey] = evalText
            evalMethodCache[subject.docID] = evalText

            // もしモデル側が空なら、その場で書き戻して今後のリロードでも消えないようにする
            if subject.eval_method.isEmpty {
                let updated = SyllabusData(
                    docID: subject.docID,
                    stableKey: subject.stableKey,
                    class_name: subject.class_name,
                    teacher_name: subject.teacher_name,
                    time: subject.time,
                    campus: subject.campus,
                    grade: subject.grade,
                    category: subject.category,
                    credit: subject.credit,
                    term: subject.term,
                    eval_method: evalText
                )
                // filteredData を更新
                filteredData[indexPath.row] = updated
                // data も該当行を更新（stableKey優先で一致）
                if let i = data.firstIndex(where: { $0.stableKey == subject.stableKey || $0.docID == subject.docID }) {
                    data[i] = updated
                }
            }
        }

        // 見た目
        let cbg = cellBackgroundColor(for: traitCollection)
        cell.backgroundColor = cbg
        cell.contentView.backgroundColor = cbg
        let selected = UIView()
        selected.backgroundColor = (traitCollection.userInterfaceStyle == .dark)
            ? UIColor(white: 0.22, alpha: 1.0)
            : UIColor.systemFill
        cell.selectedBackgroundView = selected

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

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if let kw = activeKeyword, !kw.isEmpty { return }

        if usingLocalList {
            if isBackgroundFilling { return }
            let session = listSessionId 
            let y = scrollView.contentOffset.y
            let needMore = y > scrollView.contentSize.height - scrollView.frame.size.height - 400
            if needMore {
                let criteria = SyllabusSearchCriteria(
                    category: selectedCategory,
                    department: filterDepartment,
                    campus: filterCampus,
                    place: filterPlace,
                    grade: filterGrade,
                    day: filterDay,
                    periods: filterPeriods,
                    timeSlots: filterTimeSlots,
                    term: filterTerm,
                    undecided: filterUndecided
                )
                let chunk = LocalSyllabusIndex.shared.page(criteria: criteria, offset: localOffset, limit: localPageSize)
                if !chunk.isEmpty {
                    let safeChunk = self.preserveEvalMethod(from: self.data, into: chunk)  // ← 温存
                    let start = data.count
                    data.append(contentsOf: safeChunk)
                    filteredData = data

                    let newIndexPaths = (start..<data.count).map { IndexPath(row: $0, section: 0) }

                    self.syllabus_table.performBatchUpdates {
                        self.syllabus_table.insertRows(at: newIndexPaths, with: .none)
                    }
                    self.localOffset += safeChunk.count
                }
            }
            return
        }

        // （従来のリモート無限スクロール）
        if usingLocalList && LocalSyllabusIndex.shared.isReady { return }  // ✅ ローカル一覧の時だけ止める
        if searchController.isActive, let t = searchController.searchBar.text, !t.isEmpty { return }
        let offsetY = scrollView.contentOffset.y
        let contentH = scrollView.contentSize.height
        let frameH = scrollView.frame.size.height
        if offsetY > contentH - frameH - 400 { loadNextPage() }
    }
    
    private func showLoadingOverlay(title: String = "シラバスを読み込み中…", subtitle: String = "初回のみ数秒かかることがあります") {
        guard loadingOverlay == nil else { return }
        let ov = SyllabusLoadingOverlay()
        ov.update(title: title, subtitle: subtitle)
        ov.present(on: self.view)
        loadingOverlay = ov
    }

    private func hideLoadingOverlay() {
        loadingOverlay?.dismiss()
        loadingOverlay = nil
    }

    private func kickoffBackgroundLocalFill(criteria: SyllabusSearchCriteria) {
        let session = listSessionId                      // ★ 開始時のセッションを捕まえる
        guard usingLocalList, !isBackgroundFilling, (activeKeyword?.isEmpty ?? true) else { return }
        isBackgroundFilling = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            while self.usingLocalList,
                  (self.activeKeyword?.isEmpty ?? true),
                  self.listSessionId == session {        // ★ 途中で条件が変わったら即中断
                let chunk = LocalSyllabusIndex.shared.page(
                    criteria: criteria,
                    offset: self.localOffset,
                    limit: self.localPrefetchBatch
                )
                if chunk.isEmpty { break }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self,
                          self.usingLocalList,
                          (self.activeKeyword?.isEmpty ?? true),
                          self.listSessionId == session
                    else { return }

                    // ★ ここで既存の eval_method を温存
                    let safeChunk = self.preserveEvalMethod(from: self.data, into: chunk)
                    let start = data.count
                    data.append(contentsOf: safeChunk)
                    filteredData = data

                    let newIndexPaths = (start..<data.count).map { IndexPath(row: $0, section: 0) }

                    self.syllabus_table.performBatchUpdates {
                        self.syllabus_table.insertRows(at: newIndexPaths, with: .none)
                    }
                    self.localOffset += safeChunk.count
                }
                usleep(80_000)
            }
            DispatchQueue.main.async { [weak self] in
                // ★ 新セッションに切り替わっていたら触らない
                if self?.listSessionId == session { self?.isBackgroundFilling = false }
            }
        }
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
            // String/配列どっちでも「キャンパス名を正規化 → 重複除去 → ソート → join」
            var parts: [String] = []
            if let s = x["campus"] as? String {
                parts = s.split(separator: ",").map { String($0) }
            } else if let arr = x["campus"] as? [String] {
                parts = arr
            }
            let normalized = parts
                .map { canonicalizeCampusString($0) ?? $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let uniqSorted = Array(Set(normalized)).sorted()
            return uniqSorted.joined(separator: ",")
        }()

        let termRaw = (x["term"] as? String) ?? ""
        let term = normalizeTerm(termRaw)
        let eval = (x["eval_method"] as? String) ?? ""

        // ★ 安定キー
        let key = makeStableKey(className: x["class_name"] as? String ?? "",
                                teacher: x["teacher_name"] as? String ?? "",
                                time: timeStr,
                                campus: campusStr,
                                grade: x["grade"] as? String ?? "",
                                category: x["category"] as? String ?? "",
                                term: term)

        let model = SyllabusData(
            docID: docID,
            stableKey: key,
            class_name: x["class_name"] as? String ?? "",
            teacher_name: x["teacher_name"] as? String ?? "",
            time: timeStr,
            campus: campusStr,
            grade: x["grade"] as? String ?? "",
            category: x["category"] as? String ?? "",
            credit: String(x["credit"] as? Int ?? 0),
            term: term,
            eval_method: eval
        )

        if !eval.isEmpty {
            self.evalMethodCache[docID] = eval
            self.evalMethodCacheByStableKey[key] = eval

            let ekey = makeEvalKey(className: model.class_name, teacher: model.teacher_name)
            self.evalMethodCacheByEvalKey[ekey] = eval
        }

        return model
    }

    // ===== 検索バーの更新 =====
    func updateSearchResults(for searchController: UISearchController) {
        let text = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        activeKeyword = text.isEmpty ? nil : text
        searchDebounce?.cancel()

        if text.isEmpty {
            setSearching(false)
            resetAndReload(keyword: nil)   // ✅ 1から作り直す
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
        let session = listSessionId
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            self.filteredData = self.data
            self.syllabus_table.reloadData()
            scrollToTop()
            setSearching(false)
            return
        }

        if LocalSyllabusIndex.shared.isReady {
            let criteria = SyllabusSearchCriteria(
                keyword: text,              // ★ キーワードも入れる
                category: selectedCategory,
                department: filterDepartment,
                campus: filterCampus,
                place: filterPlace,
                grade: filterGrade,
                day: filterDay,
                periods: filterPeriods,
                timeSlots: filterTimeSlots,
                term: filterTerm,
                undecided: filterUndecided
            )
            let models = LocalSyllabusIndex.shared.search(text: text, criteria: criteria)
            let merged = self.preserveEvalMethod(from: self.data, into: models)
            self.filteredData = merged
            self.syllabus_table.reloadData()
            self.scrollToTop()
            self.setSearching(false)
            return
        } else {
            loadNextPage()
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
    private func mergeEvalMethodFromOld(_ old: [SyllabusData], into new: [SyllabusData]) -> [SyllabusData] {
        // 旧一覧から一発で引ける辞書を作る（O(n)）
        var byId: [String: String] = [:]
        var byStable: [String: String] = [:]
        var byEvalKey: [String: String] = [:]

        for o in old where !o.eval_method.isEmpty {
            byId[o.docID] = o.eval_method
            byStable[o.stableKey] = o.eval_method
            let ekey = makeEvalKey(className: o.class_name, teacher: o.teacher_name)
            byEvalKey[ekey] = o.eval_method
        }

        return new.map { n in
            if !n.eval_method.isEmpty { return n }

            let ekey = makeEvalKey(className: n.class_name, teacher: n.teacher_name)

            // キャッシュ → old辞書 の順に探す（どっちが生きてても拾える）
            let val =
                evalMethodCacheByEvalKey[ekey] ?? byEvalKey[ekey] ??
                evalMethodCacheByStableKey[n.stableKey] ?? byStable[n.stableKey] ??
                evalMethodCache[n.docID] ?? byId[n.docID] ??
                ""

            guard !val.isEmpty else { return n }

            return SyllabusData(
                docID: n.docID,
                stableKey: n.stableKey,
                class_name: n.class_name,
                teacher_name: n.teacher_name,
                time: n.time,
                campus: n.campus,
                grade: n.grade,
                category: n.category,
                credit: n.credit,
                term: n.term,
                eval_method: val
            )
        }
    }

    private func preserveEvalMethod(from old: [SyllabusData], into new: [SyllabusData]) -> [SyllabusData] {
        // old は使わない（作り直しコストが重すぎる）
        return new.map { n in
            if !n.eval_method.isEmpty { return n }

            let ekey = makeEvalKey(className: n.class_name, teacher: n.teacher_name)
            let val = evalMethodCacheByEvalKey[ekey]
                ?? evalMethodCacheByStableKey[n.stableKey]
                ?? evalMethodCache[n.docID]
                ?? ""

            guard !val.isEmpty else { return n }

            return SyllabusData(
                docID: n.docID,
                stableKey: n.stableKey,
                class_name: n.class_name,
                teacher_name: n.teacher_name,
                time: n.time,
                campus: n.campus,
                grade: n.grade,
                category: n.category,
                credit: n.credit,
                term: n.term,
                eval_method: val
            )
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
