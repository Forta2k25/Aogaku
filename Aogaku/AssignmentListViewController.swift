
import UIKit
import UserNotifications
import EventKit
import GoogleMobileAds   // ← 追加

// TimetableSettingsViewController と同じヘルパー（Adaptive Banner）
@inline(__always)
private func makeAdaptiveAdSize(width: CGFloat) -> AdSize {
    return currentOrientationAnchoredAdaptiveBanner(width: width)
}

/// MemoTaskViewController 側の保存形式に合わせた最小モデル
private struct SavedTask: Codable {
    var title: String
    var due: Date?
    var done: Bool
    var notificationIds: [String]?
    var calendarEventId: String?
}

/// 1行分に表示するための整形済みデータ（元の保存場所も保持）
private struct TaskRow {
    var title: String
    var due: Date?
    var courseId: String
    var courseTitle: String
    var done: Bool

    // 保存元の情報（トグル・削除用）
    var udKey: String
    var udIndex: Int
    var notificationIds: [String]?
    var calendarEventId: String?
}

final class AssignmentListViewController: UITableViewController, BannerViewDelegate {

    private let courseTitleById: [String: String]
    private var rows: [TaskRow] = []

    // ===== AdMob Banner ===== (他画面と同じ構成)
    private let adContainer = UIView()
    private var bannerView: BannerView?
    private var adContainerHeight: NSLayoutConstraint?
    private var lastBannerWidth: CGFloat = 0
    private var didLoadBannerOnce = false
    private let bannerTopPadding: CGFloat = 60  // 他画面に合わせて余白を確保

    init(courseTitleById: [String:String]) {
        self.courseTitleById = courseTitleById
        super.init(style: .insetGrouped)
        self.title = "課題一覧"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .adMobReady, object: nil)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")

        // 戻る（モーダルで開かれた場合のために Close を明示）
        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .close, target: self, action: #selector(closeTapped)
            )
        }

        loadAllTasks()
        applyEmptyStateIfNeeded()

        // --- AdMob 設置（TimetableSettings と同じ流儀） ---
        setupAdBanner()
        NotificationCenter.default.addObserver(self,
            selector: #selector(onAdMobReady),
            name: .adMobReady, object: nil)
    }

    @objc private func onAdMobReady() {
        loadBannerIfNeeded()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 万一ナビゲーションバーが隠れている構成でも表示されるように
        navigationController?.setNavigationBarHidden(false, animated: false)
    }

    // 画面サイズ確定後に Adaptive サイズでロード
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        loadBannerIfNeeded()
    }

    @objc private func closeTapped() {
        if let nav = navigationController, nav.viewControllers.first !== self {
            nav.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    // MARK: - Load / Save
    private func loadArray(forKey key: String) -> [SavedTask] {
        if let data = UserDefaults.standard.data(forKey: key),
           let arr = try? JSONDecoder().decode([SavedTask].self, from: data) { return arr }
        return []
    }
    private func saveArray(_ arr: [SavedTask], forKey key: String) {
        if let data = try? JSONEncoder().encode(arr) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func loadAllTasks() {
        rows.removeAll()

        let ud = UserDefaults.standard
        // すべてのキーから "tasks." で始まるものを抽出
        for (key, value) in ud.dictionaryRepresentation() {
            guard key.hasPrefix("tasks.") else { continue }
            guard let data = value as? Data,
                  let items = try? JSONDecoder().decode([SavedTask].self, from: data) else { continue }

            // courseId をキー名から推定
            // - 新: "tasks.<courseId>_yYYYY_tCODE_wX pY"
            // - 旧: "tasks.<courseId>"
            let raw = String(key.dropFirst("tasks.".count))
            let courseId: String = raw.split(separator: "_").first.map(String.init) ?? raw
            let courseTitle = courseTitleById[courseId] ?? courseId

            for (idx, t) in items.enumerated() {
                rows.append(TaskRow(title: t.title,
                                    due: t.due,
                                    courseId: courseId,
                                    courseTitle: courseTitle,
                                    done: t.done,
                                    udKey: key,
                                    udIndex: idx,
                                    notificationIds: t.notificationIds,
                                    calendarEventId: t.calendarEventId))
            }
        }

        // 期限の早い順（nil は最後）
        rows.sort { a, b in
            switch (a.due, b.due) {
            case let (x?, y?): return x < y
            case (_?, nil):     return true
            case (nil, _?):     return false
            case (nil, nil):    return a.title < b.title
            }
        }
        tableView.reloadData()
    }

    private func applyEmptyStateIfNeeded() {
        if rows.isEmpty {
            let label = UILabel()
            label.text = "課題は設定されていません"
            label.textColor = .secondaryLabel
            label.textAlignment = .center
            label.numberOfLines = 0
            label.font = .systemFont(ofSize: 15)
            tableView.backgroundView = label
        } else {
            tableView.backgroundView = nil
        }
    }

    // MARK: - Table
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let r = rows[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)

        var cfg = UIListContentConfiguration.subtitleCell()
        cfg.text = r.title
        if let d = r.due {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ja_JP")
            f.dateFormat = "M/d(E) HH:mm"
            cfg.secondaryText = "期限: \(f.string(from: d)) ・ \(r.courseTitle)"
        } else {
            cfg.secondaryText = r.courseTitle
        }
        cell.contentConfiguration = cfg
        cell.accessoryType = r.done ? .checkmark : .none
        return cell
    }

    // タップで完了トグル
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        var r = rows[indexPath.row]
        var arr = loadArray(forKey: r.udKey)
        guard r.udIndex < arr.count else { return }
        arr[r.udIndex].done.toggle()
        saveArray(arr, forKey: r.udKey)

        r.done = arr[r.udIndex].done
        rows[indexPath.row] = r
        tableView.reloadRows(at: [indexPath], with: .automatic)
    }

    // 右スワイプで削除（通知・カレンダーも掃除）
    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
                            -> UISwipeActionsConfiguration? {
        let action = UIContextualAction(style: .destructive, title: "削除") { [weak self] _,_,done in
            guard let self = self else { return }
            let r = self.rows[indexPath.row]
            var arr = self.loadArray(forKey: r.udKey)
            guard r.udIndex < arr.count else { done(false); return }

            let t = arr[r.udIndex]
            if let ids = t.notificationIds, !ids.isEmpty {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
            }
            if let eid = t.calendarEventId {
                let store = EKEventStore()
                if let ev = store.event(withIdentifier: eid) {
                    try? store.remove(ev, span: .thisEvent, commit: true)
                }
            }
            arr.remove(at: r.udIndex)
            self.saveArray(arr, forKey: r.udKey)

            // インデックスが変わるので再ロード
            self.loadAllTasks()
            self.applyEmptyStateIfNeeded()
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [action])
    }

    // MARK: - AdMob Banner (TimetableSettings と同等の実装)
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

        // Remote Config で広告停止中なら UI も畳む
        guard AdsConfig.enabled else {
            adContainer.isHidden = true
            adContainerHeight?.constant = 0
            updateBottomInset(0)
            return
        }

        let bv = BannerView()
        bv.translatesAutoresizingMaskIntoConstraints = false
        bv.adUnitID = AdsConfig.bannerUnitID
        bv.rootViewController = self
        bv.adSize = AdSizeBanner
        bv.delegate = self

        adContainer.addSubview(bv)
        NSLayoutConstraint.activate([
            bv.leadingAnchor.constraint(equalTo: adContainer.leadingAnchor),
            bv.trailingAnchor.constraint(equalTo: adContainer.trailingAnchor),
            bv.bottomAnchor.constraint(equalTo: adContainer.bottomAnchor),
            bv.topAnchor.constraint(equalTo: adContainer.topAnchor, constant: bannerTopPadding) // 少し下げる
        ])

        // 初期高さ（余白分も確保）
        let safeWidth = view.safeAreaLayoutGuide.layoutFrame.width
        let useWidth = max(320, floor(safeWidth))
        let size = makeAdaptiveAdSize(width: useWidth)
        adContainerHeight?.constant = size.size.height + bannerTopPadding

        bannerView = bv
    }

    private func loadBannerIfNeeded() {
        guard let bv = bannerView else { return }
        let safeWidth = view.safeAreaLayoutGuide.layoutFrame.width
        guard safeWidth > 0 else { return }

        let useWidth = max(320, floor(safeWidth))
        if abs(useWidth - lastBannerWidth) < 0.5 { return }  // 同幅の連続ロードを抑止
        lastBannerWidth = useWidth

        let size = makeAdaptiveAdSize(width: useWidth)
        adContainerHeight?.constant = size.size.height + bannerTopPadding
        view.layoutIfNeeded()

        guard size.size.height > 0 else { return }
        if !CGSizeEqualToSize(bv.adSize.size, size.size) {
            bv.adSize = size
        }
        if !didLoadBannerOnce {
            didLoadBannerOnce = true
            bv.load(Request())
        }
    }

    // Table の下インセットを調整してバナーと被らないようにする
    private func updateBottomInset(_ h: CGFloat) {
        tableView.contentInset.bottom = h
        tableView.scrollIndicatorInsets.bottom = h
    }

    // MARK: - BannerViewDelegate
    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        let h = bannerView.adSize.size.height
        adContainerHeight?.constant = h + bannerTopPadding
        updateBottomInset(h + bannerTopPadding)
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
    }

    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        adContainerHeight?.constant = 0
        updateBottomInset(0)
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
        print("Ad failed:", error.localizedDescription)
    }
}
