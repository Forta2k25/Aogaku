
import UIKit
import FirebaseAuth
import FirebaseFirestore
import GoogleMobileAds

@inline(__always)
private func makeAdaptiveAdSize(width: CGFloat) -> AdSize {
    return currentOrientationAnchoredAdaptiveBanner(width: width)
}

// 学科 → 略称（画像どおり）
private enum DepartmentAbbr {
    static let map: [String: String] = [
        // 文学部
        "日本文学科":"日文","英米文学科":"英米","比較芸術学科":"比芸","フランス文学科":"仏文","史学科":"文史",
        // 教育人間科学部
        "教育学科":"教育","心理学科":"心理",
        // 経済学部
        "経済学科":"経済","現代経済デザイン学科":"現デ",
        // 法学部
        "法学科":"法法","ヒューマンライツ学科":"法ヒュ",
        // 経営学部
        "経営学科":"経営","マーケティング学科":"経マ",
        // 総合文化政策学部
        "総合文化政策学科":"総文",
        // SIPEC（国際政治経済学部）
        "国際コミュニケーション学科":"コミュ","国際政治学科":"国政","国際経済学科":"国経",
        // 理工学部
        "物理科学科":"物理","数理サイエンス学科":"数理","化学・生命科学科":"生命",
        "電気電子工学科":"電工","機械創造工学科":"機械","経営システム工学科":"経シス","情報テクノロジー学科":"情テク",
        // 地球社会共生・コミュニティ・社情
        "地球社会共生学科":"地球","コミュニティ人間科学科":"コミュ","社会情報学科":"社情",
    ]
    static func abbr(for department: String?) -> String? {
        guard let d = department, !d.isEmpty else { return nil }
        return map[d] ?? d   // 見つからなければ原文表示（暫定）
    }
}

// 学部 → 学科（UserSettingsと同じ内容でOK）
private let FACULTY_DATA: [String:[String]] = [
    "国際政治経済学部": ["国際コミュニケーション学科","国際政治学科","国際経済学科"],
    "文学部": ["日本文学科","英米文学科","比較芸術学科","フランス文学科","史学科"],
    "教育人間科学部": ["教育学科","心理学科"],
    "法学部": ["法学科","ヒューマンライツ学科"],
    "社会情報学部": ["社会情報学科"],
    "経済学部": ["経済学科","現代経済デザイン学科"],
    "経営学部": ["経営学科","マーケティング学科"],
    "総合文化政策学部": ["総合文化政策学科"],
    "理工学部": ["物理科学科","数理サイエンス学科","化学・生命科学科","電気電子工学科","機械創造工学科","経営システム工学科","情報テクノロジー学科"],
    "地球社会共生学部": ["地球社会共生学科"],
    "コミュニティ人間科学部": ["コミュニティ人間科学科"],
]
private let FACULTY_NAMES = FACULTY_DATA.keys.sorted()

// 追加情報（セルのextra表示は deptAbbr/grade から組み立て）
private struct ProfileInfo {
    let faculty: String?
    let department: String?
    let grade: Int?
    var deptAbbr: String? { DepartmentAbbr.abbr(for: department) }
    var text: String? {
        var parts: [String] = []
        if let a = deptAbbr, !a.isEmpty { parts.append(a) }
        if let g = grade, g >= 1 { parts.append("\(g)年") }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }
}


final class FindFriendsViewController: UITableViewController, UISearchBarDelegate, BannerViewDelegate {

    private var outgoingListener: ListenerRegistration?
    private var allUsers: [UserPublic] = []
    private var results: [UserPublic] = []

    private var outgoing = Set<String>()
    private var friends  = Set<String>()

    // 追加：uid→学科略称・学年
    private var profileInfo = [String: ProfileInfo]()

    private let searchBar = UISearchBar()
    private let db = Firestore.firestore()

    // AdMob
    private let adContainer = UIView()
    private var bannerView: BannerView?
    private var adContainerHeight: NSLayoutConstraint?
    private var lastBannerWidth: CGFloat = 0
    private var didLoadBannerOnce = false
    
    // --- フィルタ状態
    private var rawResults: [UserPublic] = []     // 検索後の「素データ」
    private var filterGrade: Int? = nil           // 1..4 / nil=指定なし
    private var filterFaculty: String? = nil      // "" / nil=指定なし
    private var filterDepartment: String? = nil   // "" / nil=未指定

    private func appBackgroundColor(for traits: UITraitCollection) -> UIColor {
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.2, alpha: 1.0) : .systemBackground
    }
    private func applyBackgroundStyle() {
        let bg = appBackgroundColor(for: traitCollection)
        view.backgroundColor = bg
        tableView.backgroundColor = bg
        adContainer.backgroundColor = bg
        tableView.separatorColor = .separator
    }
    private func cellBackgroundColor(for traits: UITraitCollection) -> UIColor {
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.16, alpha: 1.0) : .secondarySystemBackground
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "友だちを探す"
        tableView.register(UserListCell.self, forCellReuseIdentifier: UserListCell.reuseID)
        tableView.rowHeight = 68

        searchBar.placeholder = "ユーザー名、IDから検索（@id 可）"
        searchBar.delegate = self
        navigationItem.titleView = searchBar

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease"),
            style: .plain,
            target: self,
            action: #selector(didTapFilter)
        )
        
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(reloadAll), for: .valueChanged)

        reloadAll()
        setupAdBanner()
        NotificationCenter.default.addObserver(self,
            selector: #selector(onAdMobReady),
            name: .adMobReady, object: nil)
        applyBackgroundStyle()
    }
    @objc private func onAdMobReady() {
        loadBannerIfNeeded()
    }


    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyBackgroundStyle()
            // 目に見える行だけ色を更新
            for cell in tableView.visibleCells {
                let bg = cellBackgroundColor(for: traitCollection)
                cell.backgroundColor = bg
                cell.contentView.backgroundColor = bg
            }
        }
    }


    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        loadBannerIfNeeded()
    }

    // 初期ロード
    @objc private func reloadAll() {
        guard let me = Auth.auth().currentUser?.uid else { return }
        let group = DispatchGroup()

        // users 取得（自分以外）
        group.enter()
        db.collection("users")
            .order(by: "createdAt", descending: true)
            .limit(to: 50)
            .getDocuments { [weak self] snap, _ in
                guard let self = self else { return }
                var newUsers: [UserPublic] = []
                var newInfo: [String: ProfileInfo] = [:]

                snap?.documents.forEach { doc in
                    if doc.documentID == me { return }
                    let d = doc.data()
                    let idStr = (d["id"] as? String) ?? ""
                    guard !idStr.isEmpty else { return }
                    let name = (d["name"] as? String) ?? ""
                    let display = name.isEmpty ? "@\(idStr)" : name

                    // 基本表示用
                    let u = UserPublic(uid: doc.documentID,
                                       idString: idStr,
                                       name: display,
                                       photoURL: d["photoURL"] as? String)
                    newUsers.append(u)

                    // 追加情報
                    let grade = d["grade"] as? Int
                    let faculty = d["faculty"] as? String
                    let dept    = d["department"] as? String
                    newInfo[u.uid] = ProfileInfo(faculty: faculty, department: dept, grade: grade)
                }

                self.allUsers = newUsers
                self.profileInfo.merge(newInfo, uniquingKeysWith: { _, new in new })
                group.leave()
            }

        // 自分の申請済み
        group.enter()
        db.collection("users").document(me).collection("requestsOutgoing").getDocuments { [weak self] snap, _ in
            self?.outgoing = Set(snap?.documents.map { $0.documentID } ?? [])
            group.leave()
        }

        // 自分の友だち
        group.enter()
        db.collection("users").document(me).collection("friends").getDocuments { [weak self] snap, _ in
            self?.friends = Set(snap?.documents.map { $0.documentID } ?? [])
            group.leave()
        }

        group.notify(queue: .main) {
            self.results = self.allUsers
            self.tableView.reloadData()
            self.refreshControl?.endRefreshing()
            self.rawResults = self.allUsers
            self.applyActiveFilter()
        }
    }

    // 検索
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        let keyword = searchBar.text ?? ""
        FriendService.shared.searchUsers(keyword: keyword) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let users):
                self.results = users
                self.tableView.reloadData()
                self.rawResults = users
                self.applyActiveFilter()
                self.enrichProfiles(for: users)
            case .failure:
                self.results = []
                self.tableView.reloadData()
            }
        }
        view.endEditing(true)
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results = allUsers
            rawResults = allUsers
            applyActiveFilter()
            tableView.reloadData()
        }
    }
    
    private func applyActiveFilter() {
        // フィルタに必要な追加情報が無い行を補完取得
        enrichProfiles(for: rawResults)

        results = rawResults.filter { u in
            guard let info = profileInfo[u.uid] else { return false } // 情報未取得は一旦除外
            if let g = filterGrade, (info.grade ?? -1) != g { return false }
            if let fac = filterFaculty {
                if info.faculty != fac { return false }
                if let dep = filterDepartment, !dep.isEmpty {
                    if info.department != dep { return false }
                }
            }
            return true
        }
        // フィルタが無ければ素データ
        if filterGrade == nil && filterFaculty == nil && (filterDepartment == nil || filterDepartment?.isEmpty == true) {
            results = rawResults
        }
        tableView.reloadData()
    }

    @objc private func didTapFilter() {
        let vc = FilterSheetController(
            grade: filterGrade,
            faculty: filterFaculty,
            department: filterDepartment
        )
        vc.onClear = { [weak self] in
            self?.filterGrade = nil
            self?.filterFaculty = nil
            self?.filterDepartment = nil
            self?.applyActiveFilter()
        }
        vc.onApply = { [weak self] grade, faculty, department in
            self?.filterGrade = grade
            self?.filterFaculty = faculty
            self?.filterDepartment = department
            self?.applyActiveFilter()
        }
        if let sheet = vc.sheetPresentationController {
            sheet.detents = [.medium()]      // iOS15+
            sheet.prefersGrabberVisible = true
        }
        present(vc, animated: true)
    }


    // 検索結果の追加情報を取得（10件ずつ）
    private func enrichProfiles(for users: [UserPublic]) {
        let missing = users.map { $0.uid }.filter { profileInfo[$0] == nil }
        guard !missing.isEmpty else { return }
        let chunks = stride(from: 0, to: missing.count, by: 10).map { Array(missing[$0 ..< min($0+10, missing.count)]) }
        for ids in chunks {
            db.collection("users").whereField(FieldPath.documentID(), in: ids).getDocuments { [weak self] snap, _ in
                guard let self = self else { return }
                var updatedUIDs: [String] = []
                snap?.documents.forEach { doc in
                    let d = doc.data()
                    let grade = d["grade"] as? Int
                    let faculty = d["faculty"] as? String
                    let dept    = d["department"] as? String
                    self.profileInfo[doc.documentID] = ProfileInfo(faculty: faculty, department: dept, grade: grade)

                    updatedUIDs.append(doc.documentID)
                }
                // 対象行だけ更新
                let rows = self.results.enumerated()
                    .filter { updatedUIDs.contains($0.element.uid) }
                    .map { IndexPath(row: $0.offset, section: 0) }
                if !rows.isEmpty {
                    self.tableView.reloadRows(at: rows, with: .none)
                }
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startOutgoingListener()
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        outgoingListener?.remove()
        outgoingListener = nil
    }

    private func startOutgoingListener() {
        guard let me = Auth.auth().currentUser?.uid else { return }
        outgoingListener?.remove()
        outgoingListener = db.collection("users").document(me)
            .collection("requestsOutgoing")
            .addSnapshotListener { [weak self] snap, _ in
                guard let self = self else { return }
                self.outgoing = Set(snap?.documents.map { $0.documentID } ?? [])
                self.tableView.reloadData()
            }
    }

    // TableView
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        results.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let u = results[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: UserListCell.reuseID, for: indexPath) as! UserListCell

        let placeholder = UIImage(systemName: "person.crop.circle.fill")
        let isFriend = friends.contains(u.uid)
        let isOutgoing = outgoing.contains(u.uid)

        let extra = profileInfo[u.uid]?.text
        cell.configure(user: u, isFriend: isFriend, isOutgoing: isOutgoing, placeholder: placeholder, extraText: extra)
        cell.actionButton.isEnabled = !isFriend
        cell.actionButton.isUserInteractionEnabled = !isFriend
        cell.actionButton.alpha = isFriend ? 0.5 : 1.0
        let bg = cellBackgroundColor(for: traitCollection)
        cell.backgroundColor = bg
        cell.contentView.backgroundColor = bg
        let selected = UIView()
        selected.backgroundColor = (traitCollection.userInterfaceStyle == .dark)
            ? UIColor(white: 0.22, alpha: 1.0)
            : UIColor.systemFill
        cell.selectedBackgroundView = selected
        
        // ボタン動作（未申請 & 未フレンドのときのみ）
        // --- ボタン動作を状態ごとに付け替え ---
        cell.actionButton.removeTarget(nil, action: nil, for: .allEvents)

        if isFriend {
            // 友だち：必要なら別動作を付ける。ここでは何もしない
        } else if isOutgoing {
            // 申請済 → 取り消し
            cell.actionButton.addAction(UIAction { [weak self] _ in
                guard let self = self else { return }
                let alert = UIAlertController(
                    title: "申請を取り消しますか？",
                    message: "\(u.name) への友だち申請をキャンセルします。",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "やめる", style: .cancel))
                alert.addAction(UIAlertAction(title: "取り消す", style: .destructive, handler: { _ in
                    self.cancelOutgoingRequest(to: u) { [weak self] err in
                        guard let self = self else { return }
                        if let err = err {
                            let a = UIAlertController(title: "エラー", message: err.localizedDescription, preferredStyle: .alert)
                            a.addAction(UIAlertAction(title: "OK", style: .default))
                            self.present(a, animated: true)
                            return
                        }
                        // 見た目を即時反映（listenerでも後追い同期）
                        self.outgoing.remove(u.uid)
                        if let r = self.results.firstIndex(where: { $0.uid == u.uid }) {
                            self.tableView.reloadRows(at: [IndexPath(row: r, section: 0)], with: .automatic)
                        }
                    }
                }))
                self.present(alert, animated: true)
            }, for: .touchUpInside)

        } else {
            // 未申請 → 送信
            cell.actionButton.addAction(UIAction { [weak self] _ in
                guard let self = self else { return }
                let alert = UIAlertController(
                    title: "友だち申請",
                    message: "\(u.name) に友だち申請を送りますか？",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
                alert.addAction(UIAlertAction(title: "送信する", style: .default, handler: { _ in
                    FriendService.shared.sendRequest(to: u) { [weak self] _ in
                        guard let self = self else { return }
                        self.outgoing.insert(u.uid)
                        if let r = self.results.firstIndex(where: { $0.uid == u.uid }) {
                            self.tableView.reloadRows(at: [IndexPath(row: r, section: 0)], with: .automatic)
                        }
                    }
                }))
                self.present(alert, animated: true)
            }, for: .touchUpInside)
        }

        return cell
    }

    // --- AdMob ---
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
        bannerView = bv
    }
    
    /// 「申請済」を取り消す：
    /// 自分: users/{me}/requestsOutgoing/{other}
    /// 相手: users/{other}/requestsIncoming/{me}
    private func cancelOutgoingRequest(to user: UserPublic, completion: @escaping (Error?) -> Void) {
        guard let me = Auth.auth().currentUser?.uid else {
            completion(NSError(domain: "auth", code: 401,
                               userInfo: [NSLocalizedDescriptionKey: "Not signed in"]))
            return
        }
        let batch = db.batch()
        let myOutRef   = db.collection("users").document(me)
            .collection("requestsOutgoing").document(user.uid)
        let theirInRef = db.collection("users").document(user.uid)
            .collection("requestsIncoming").document(me)
        batch.deleteDocument(myOutRef)
        batch.deleteDocument(theirInRef)
        batch.commit(completion: completion)
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
        if !didLoadBannerOnce {
            didLoadBannerOnce = true
            bv.load(Request())
        }
    }

    private func updateInsetsForBanner(height: CGFloat) {
        var inset = tableView.contentInset
        inset.bottom = height
        tableView.contentInset = inset
        tableView.verticalScrollIndicatorInsets.bottom = height
    }

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
}

final class FilterSheetController: UIViewController, UIPickerViewDataSource, UIPickerViewDelegate {
    var onApply: ((Int?, String?, String?) -> Void)?
    var onClear: (() -> Void)?

    //private let gradeOptions = ["1年","2年","3年","4年","指定なし"]
    private let gradeOptions = ["指定なし","1年","2年","3年","4年"]
    private let gradePicker = UIPickerView()
    private let facultyDeptPicker = UIPickerView()

    private var selectedGrade: Int?
    private var selectedFacultyIndex: Int? // nil=指定なし
    private var selectedDepartmentIndex: Int? // nil=未選択

    init(grade: Int?, faculty: String?, department: String?) {
        self.selectedGrade = grade
        super.init(nibName: nil, bundle: nil)
        if let fac = faculty, let idx = FACULTY_NAMES.firstIndex(of: fac) {
            selectedFacultyIndex = idx
            if let dep = department, let didx = FACULTY_DATA[fac]?.firstIndex(of: dep) {
                selectedDepartmentIndex = didx
            }
        }
        modalPresentationStyle = .pageSheet
    }
    required init?(coder: NSCoder) { fatalError() }
    
    // 学科リストを作るときに使う“有効な学部インデックス”
    private func currentFacultyIndex() -> Int? {
        if let i = selectedFacultyIndex { return i } // 保存済みがあれば優先
        let i = facultyDeptPicker.selectedRow(inComponent: 0)
        return (i < FACULTY_NAMES.count) ? i : nil   // “指定なし”はnil
    }


    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = (traitCollection.userInterfaceStyle == .dark)
            ? UIColor(white: 0.16, alpha: 1.0) : .systemBackground

        // ヘッダー（クリア / 適用）
        let h = UIStackView()
        h.axis = .horizontal
        h.distribution = .equalSpacing
        let clearBtn = UIButton(type: .system)
        clearBtn.setTitle("クリア", for: .normal)
        clearBtn.addAction(UIAction { [weak self] _ in self?.onClear?(); self?.dismiss(animated: true) }, for: .touchUpInside)
        let applyBtn = UIButton(type: .system)
        applyBtn.setTitle("適用", for: .normal)
        applyBtn.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            let grade = self.selectedGrade
            let faculty = (self.selectedFacultyIndex != nil) ? FACULTY_NAMES[self.selectedFacultyIndex!] : nil
            let department: String?
            if let fi = self.selectedFacultyIndex,
               let di = self.selectedDepartmentIndex,
               let list = FACULTY_DATA[FACULTY_NAMES[fi]], di < list.count {
                department = list[di]
            } else {
                department = nil
            }
            self.onApply?(grade, faculty, department)
            self.dismiss(animated: true)
        }, for: .touchUpInside)

        h.addArrangedSubview(clearBtn)
        let title = UILabel()
        title.text = "絞り込み"
        title.font = .boldSystemFont(ofSize: 17)
        h.addArrangedSubview(title)
        h.addArrangedSubview(applyBtn)

        // ピッカー
        gradePicker.dataSource = self; gradePicker.delegate = self
        facultyDeptPicker.dataSource = self; facultyDeptPicker.delegate = self

        let v = UIStackView(arrangedSubviews: [h, gradePicker, facultyDeptPicker])
        v.axis = .vertical
        v.spacing = 12
        v.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            v.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            v.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            v.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
        ])

        // 初期選択
        gradePicker.selectRow(selectedGrade ?? 0, inComponent: 0, animated: false)
        if let fi = selectedFacultyIndex {
            facultyDeptPicker.selectRow(fi, inComponent: 0, animated: false)
            facultyDeptPicker.reloadComponent(1)
        }
        if let di = selectedDepartmentIndex {
            facultyDeptPicker.selectRow(di + 1, inComponent: 1, animated: false) // ★ +1（0は指定なし）
        } else {
            facultyDeptPicker.selectRow(0, inComponent: 1, animated: false)      // ★ 指定なし
        }
        // （既存の初期選択コードの直後に追加）
        facultyDeptPicker.reloadComponent(1)


    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let fi = selectedFacultyIndex {
            facultyDeptPicker.selectRow(fi, inComponent: 0, animated: false)
        }
        facultyDeptPicker.reloadComponent(1)
        if let di = selectedDepartmentIndex {
            facultyDeptPicker.selectRow(di + 1, inComponent: 1, animated: false)
        } else {
            facultyDeptPicker.selectRow(0, inComponent: 1, animated: false) // 学科=指定なし
        }
    }


    // MARK: UIPicker
    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        pickerView === gradePicker ? 1 : 2
    }
    // 学部・学科ピッカーの行数
    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        if pickerView === gradePicker { return gradeOptions.count }
        if component == 0 { return FACULTY_NAMES.count + 1 } // 学部 + 指定なし
        guard let fi = currentFacultyIndex() else { return 1 } // 学科=「指定なし」1行だけ出す
        let fac = FACULTY_NAMES[fi]
        return (FACULTY_DATA[fac]?.count ?? 0) + 1            // 学科 + 指定なし
    }

    // 表示タイトル
    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        if pickerView === gradePicker { return gradeOptions[row] }
        if component == 0 { return row == FACULTY_NAMES.count ? "指定なし" : FACULTY_NAMES[row] }
        guard let fi = currentFacultyIndex() else { return row == 0 ? "指定なし" : nil }
        if row == 0 { return "指定なし" }
        let fac = FACULTY_NAMES[fi]
        return FACULTY_DATA[fac]?[row - 1]
    }

    // 選択時の状態更新
    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        if pickerView === gradePicker {
            selectedGrade = (row == 0) ? nil : row                   // 1..4 / nil
            return
        }
        if component == 0 {
            if row == FACULTY_NAMES.count {                          // 学部=指定なし
                selectedFacultyIndex = nil
                selectedDepartmentIndex = nil
                facultyDeptPicker.reloadComponent(1)
                return
            }
            selectedFacultyIndex = row
            selectedDepartmentIndex = nil                            // ★ 学科は未選択に戻す
            facultyDeptPicker.reloadComponent(1)
            facultyDeptPicker.selectRow(0, inComponent: 1, animated: true) // 学科=指定なしを指す
        } else {
            // ★ 学科の0行目=指定なし → nil、それ以外は配列index(row-1)
            selectedDepartmentIndex = (row == 0) ? nil : (row - 1)
        }
    }

}


