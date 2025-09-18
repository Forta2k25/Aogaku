// timetable.swift — friends view-ready / viewOnly対応版
import UIKit
import Foundation
import Photos
import GoogleMobileAds
import FirebaseAuth
import FirebaseFirestore
import WidgetKit   // ← 追加

@inline(__always) private func makeAdaptiveAdSize(width: CGFloat) -> AdSize {
    return currentOrientationAnchoredAdaptiveBanner(width: width)
}

// MARK: - Slot

struct SlotLocation: Codable, Hashable {
    let day: Int     // 0=月…5=土
    let period: Int  // 1..rows
    var dayName: String { ["月","火","水","木","金","土"][day] }
}

private func cellKey(day: Int, period: Int) -> String { "cells.d\(day)p\(period)" }
private func cellKey(_ loc: SlotLocation) -> String { cellKey(day: loc.day, period: loc.period) }

// Firestore 1コマのハッシュ
private func slotHash(_ c: Course, colorKey: String?) -> String {
    [
        c.id, c.title, c.room, c.teacher,
        c.credits.map(String.init) ?? "",
        c.campus ?? "", c.category ?? "", c.syllabusURL ?? "",
        colorKey ?? ""
    ].joined(separator: "|")
}
// Encode / Decode
private func encodeCourseMap(_ c: Course, colorKey: String?) -> [String: Any] {
    var m: [String: Any] = [
        "id": c.id, "title": c.title, "room": c.room, "teacher": c.teacher
    ]
    if let v = c.credits     { m["credits"] = v }
    if let v = c.campus      { m["campus"] = v }
    if let v = c.category    { m["category"] = v }
    if let v = c.syllabusURL { m["syllabusURL"] = v }
    if let v = colorKey      { m["colorKey"] = v }
    return m
}
private func decodeCourseMap(_ m: [String: Any]) -> Course {
    let id      = (m["id"] as? String) ?? ""
    let title   = (m["title"] as? String) ?? "（無題）"
    let room    = (m["room"] as? String) ?? ""
    let teacher = (m["teacher"] as? String) ?? ""
    let credits: Int? = {
        if let n = m["credits"] as? Int { return n }
        if let s = m["credits"] as? String, let n = Int(s) { return n }
        return nil
    }()
    let campus   = m["campus"] as? String
    let category = m["category"] as? String
    let url      = m["syllabusURL"] as? String
    return Course(id: id, title: title, room: room, teacher: teacher,
                  credits: credits, campus: campus, category: category, syllabusURL: url, term: nil)
}

// MARK: - Firestore Remote Store（users/{uid}/timetable/{term} に cells マップで保存）
private struct TimetableRemoteStore {
    let uid: String
    let termID: String
    private let db = Firestore.firestore()
    private var doc: DocumentReference {
        db.collection("users").document(uid).collection("timetable").document(termID)
    }
    private func fieldKey(day: Int, period: Int) -> String { "cells.d\(day)p\(period)" }
    func path() -> String { doc.path }

   
    func fetchHashes() async -> [String:String] {
        do {
            let snap = try await doc.getDocument()
            let data = snap.data() ?? [:]                 // [FIX] cells マップの存在を要求しない
            var out: [String:String] = [:]
            for (k, v) in data {                          // [FIX] "cells.dXpY" を総なめ
                guard k.hasPrefix("cells.d"),
                      let m = v as? [String: Any],
                      let h = m["h"] as? String else { continue }
                out[k] = h
            }
            return out
        } catch { return [:] }
    }


    func startListener(onChange: @escaping ([String: [String:Any]]) -> Void) -> ListenerRegistration {
        return doc.addSnapshotListener { snap, _ in
            //guard let data = snap?.data(), let cells = data["cells"] as? [String: Any] else { return }
            guard let data = snap?.data() else { return }
            var dict: [String:[String:Any]] = [:]
            for (k, v) in data {
                guard k.hasPrefix("cells.d"), let m = v as? [String: Any] else { continue }
                dict[k] = m
            }
            onChange(dict)
        }
    }

    func upsert(course: Course, colorKey: String?, day: Int, period: Int) async {
        let key = fieldKey(day: day, period: period)
        var base = encodeCourseMap(course, colorKey: colorKey)
        base["h"] = slotHash(course, colorKey: colorKey)
        var payload: [String: Any] = [
            key: base, "updatedAt": FieldValue.serverTimestamp()
        ]
        payload["\(key).u"] = FieldValue.serverTimestamp()
        try? await doc.setData(payload, merge: true)
    }

    func delete(day: Int, period: Int) async {
        let payload: [String: Any] = [
            fieldKey(day: day, period: period): FieldValue.delete(),
            "updatedAt": FieldValue.serverTimestamp()
        ]
        try? await doc.setData(payload, merge: true)
    }

    func backfillMissing(from localAssigned: [Course?], columns: Int) async {
        do {
            let snap = try await doc.getDocument()
            let data = snap.data() ?? [:]

            // [FIX] 既にあるキー集合をフラット名で把握
            let existingKeys: Set<String> = Set(data.keys.filter { $0.hasPrefix("cells.d") })

            var payload: [String: Any] = [:]
            let rows = (localAssigned.count + columns - 1) / columns

            for period in 1...rows {
                for day in 0..<columns {
                    let idx = (period - 1) * columns + day
                    guard idx < localAssigned.count, let course = localAssigned[idx] else { continue }
                    let key = fieldKey(day: day, period: period) // "cells.dXpY"
                    if !existingKeys.contains(key) {
                        let color = SlotColorStore.color(for: SlotLocation(day: day, period: period))?.rawValue
                        var map = encodeCourseMap(course, colorKey: color)
                        map["h"] = slotHash(course, colorKey: color)  // [FIX] ハッシュを保存
                        payload[key] = map
                        payload["\(key).u"] = FieldValue.serverTimestamp()
                    }
                }
            }

            if !payload.isEmpty {
                payload["updatedAt"] = FieldValue.serverTimestamp()
                try await doc.setData(payload, merge: true)
                print("[TTRemote] backfilled \(payload.filter{ $0.key.hasPrefix("cells.d") }.count) slots")
            } else {
                print("[TTRemote] backfill: nothing to add")
            }
        } catch {
            print("[TTRemote] backfill FAILED:", error.localizedDescription)
        }
    }


    func pullMerge(into assigned: inout [Course?], columns: Int) async {
        do {
            let snap = try await doc.getDocument()
            let data = snap.data() ?? [:]
            for (key, val) in data {
                // [FIX] "cells.dXpY" 形式のみ処理
                guard key.hasPrefix("cells.d"),
                      let m = val as? [String: Any],
                      let r = key.range(of: #"cells\.d(\d+)p(\d+)"#, options: .regularExpression) else { continue }

                let tag = String(key[r]).dropFirst(6) // "dXpY"
                let comps = tag.dropFirst().split(separator: "p")
                guard comps.count == 2,
                      let day = Int(comps[0]),
                      let period = Int(comps[1]) else { continue }

                let idx = (period - 1) * columns + day
                if assigned.indices.contains(idx) {
                    assigned[idx] = decodeCourseMap(m)
                }
                if let color = m["colorKey"] as? String {
                    let loc = SlotLocation(day: day, period: period)
                    if let key = SlotColorKey(rawValue: color) ?? SlotColorKey.allCases.first(where: { "\($0)" == color }) {
                        SlotColorStore.set(key, for: loc)
                    }
                }
            }
        } catch {
            print("pullMerge error:", error.localizedDescription)
        }
    }

}

// MARK: - timetable

final class timetable: UIViewController,
                       CourseListViewControllerDelegate,
                       CourseDetailViewControllerDelegate,
                       BannerViewDelegate {
    func courseDetail(_ vc: CourseDetailViewController,
                      didUpdate counts: AttendanceCounts,
                      for course: Course,
                      at location: SlotLocation) {
        // 出欠カウントはこの画面では未使用のため、特に処理なしでOK
    }

    

    // 表示専用フラグ & 閲覧対象UID
    private var overrideUID: String? = nil
    private var viewOnly: Bool = false
    public func setRemoteUID(_ uid: String?) { overrideUID = uid; startTermSync() }
    public func setViewOnly(_ flag: Bool) { viewOnly = flag; applyViewOnlyUI() }

    private var viewingUID: String {
        if let u = overrideUID, !u.isEmpty { return u }
        return AuthManager.shared.currentUID ?? UserDefaults.standard.string(forKey: "auth.uid") ?? ""
    }

    // ====== 行数の上限 ======
    private let titleMaxLines = 5
    private let subtitleMaxLines = 2
    private let periodRowMinHeight: CGFloat = 120

    // ===== Scroll root =====
    private let scrollView = UIScrollView()
    private let contentView = UIView()

    // ===== AdMob =====
    private let adContainer = UIView()
    private var bannerView: BannerView?
    private var lastBannerWidth: CGFloat = 0
    private var didLoadBannerOnce = false
    private var adContainerHeight: NSLayoutConstraint?
    private var scrollBottomConstraint: NSLayoutConstraint?

    // ===== Header =====
    private let headerBar = UIStackView()
    private let leftButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let rightStack = UIStackView()
    private let rightA = UIButton(type: .system)  // 単
    private let rightB = UIButton(type: .system)  // 共有/保存
    private let rightC = UIButton(type: .system)  // 設定
    private var headerTopConstraint: NSLayoutConstraint!

    // ===== Grid =====
    private let gridContainerView = UIView()
    private var colGuides: [UILayoutGuide] = []
    private var rowGuides: [UILayoutGuide] = []
    private(set) var slotButtons: [UIButton] = []

    // ===== Data / Settings =====
    private var registeredCourses: [Int: Course] = [:]
    private var bgObserver: NSObjectProtocol?

    // 同期
    private var remoteHashes: [String:String] = [:]
    private var termListener: ListenerRegistration?
    private var authHandle: AuthStateDidChangeListenerHandle?

    // 時限表示
    private let timePairs: [(start: String, end: String)] = [
        ("9:00","10:30"),("11:00","12:30"),("13:20","14:50"),
        ("15:05","16:35"),("16:50","18:20"),("18:30","20:00"),("20:10","21:40")
    ]

    private var settings = TimetableSettings.load()
    private var dayLabels: [String] { settings.includeSaturday ? ["月","火","水","木","金","土"] : ["月","火","水","木","金"] }
    private var periodLabels: [String] { (1...settings.periods).map { "\($0)" } }
    private var lastDaysCount = 5
    private var lastPeriodsCount = 5

    private var assigned: [Course?] = Array(repeating: nil, count: 25)

    // Layout constants
    private let spacing: CGFloat = 1
    private let cellPadding: CGFloat = 1
    private let headerRowHeight: CGFloat = 28
    private let timeColWidth: CGFloat = 40
    private let topRatio: CGFloat = 0.02

    // 現在学期
    private var currentTerm: TermKey = TermStore.loadSelected()

    // ===== リモートストア（自分 or 友だち） =====
    private var remoteStore: TimetableRemoteStore? {
        if let uid = overrideUID, !uid.isEmpty {
            return TimetableRemoteStore(uid: uid, termID: currentTerm.storageKey)
        }
        let uid = AuthManager.shared.currentUID ?? UserDefaults.standard.string(forKey: "auth.uid")
        guard let uid, !uid.isEmpty else { return nil }
        return TimetableRemoteStore(uid: uid, termID: currentTerm.storageKey)
    }

    // MARK: - Persistence
    private func saveAssigned() {
        do {
            let data = try JSONEncoder().encode(assigned)
            UserDefaults.standard.set(data, forKey: currentTerm.storageKey)
            TermStore.saveSelected(currentTerm)
        } catch { print("Save error:", error) }
        publishWidgetSnapshot()   // ← 追加（ここが肝）
    }
    private func loadAssigned(for term: TermKey) {
        let key = term.storageKey
        if let data = UserDefaults.standard.data(forKey: key),
           let loaded = try? JSONDecoder().decode([Course?].self, from: data) {
            assigned = loaded
        } else {
            assigned = Array(repeating: nil, count: dayLabels.count * periodLabels.count)
        }
        normalizeAssigned()
    }

    // MARK: - ViewOnly UI
    private func applyViewOnlyUI() {
        guard isViewLoaded else { return }
        if viewOnly {
            navigationItem.rightBarButtonItems = nil       // 右上ボタン群を非表示
            (view.viewWithTag(9001) as? UIView)?.isHidden = true // もしまとめビューがあれば隠す
        } else {
            // 通常表示（必要あれば右上ボタンを再構築）
        }
        reloadAllButtons()
    }
    
    // 今日のスナップショットを作って WidgetShared に保存
    private func publishWidgetSnapshot() {
        let cal = Calendar.current
        let now = Date()
        let wk = cal.component(.weekday, from: now)     // 1=Sun ... 7=Sat
        // あなたの配列は 0=月 なので変換（範囲外は最後の列に丸め）
        let dayIndex = max(0, min(dayLabels.count - 1, (wk + 5) % 7))

        // 「木曜日」などのラベル
        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.setLocalizedDateFormatFromTemplate("EEEE")
        let dayLabel = df.string(from: now)

        var ps: [WidgetPeriod] = []
        for period in 1...periodLabels.count {
            let idx = (period - 1) * dayLabels.count + dayIndex
            let tp = timePairs[period - 1]          // ("09:00","10:30") など
            let title = assigned.indices.contains(idx) ? (assigned[idx]?.title ?? "") : ""
            let room  = assigned.indices.contains(idx) ? (assigned[idx]?.room  ?? "") : ""
            let teacher = assigned.indices.contains(idx) ? (assigned[idx]?.teacher  ?? "") : ""
            ps.append(WidgetPeriod(index: period,
                                   title: title.isEmpty ? " " : title,
                                   room:  room,
                                   start: tp.start, end: tp.end, teacher: teacher))
        }

        let snap = WidgetSnapshot(date: now, weekday: wk, dayLabel: dayLabel, periods: ps)
        WidgetBridge.save(snap)                             // ← shared/WidgetShared.swift のやつ
        WidgetCenter.shared.reloadTimelines(ofKind: "AogakuWidgets")
    }

    // MARK: - Sync
    private func startTermSync() {
        termListener?.remove(); termListener = nil
        guard let store = remoteStore else { return }

        Task { [weak self] in
            guard let self else { return }
            let cols = self.dayLabels.count

            // ローカルコピー
            var localAssigned: [Course?] = await MainActor.run { self.assigned }
            // リモート→ローカル（勝ち）＋不足分の埋め
            await store.pullMerge(into: &localAssigned, columns: cols)
            await store.backfillMissing(from: localAssigned, columns: cols)

            // 差分監視
            self.remoteHashes = await store.fetchHashes()

            self.termListener = store.startListener { [weak self] cells in
                guard let self else { return }
                
                // --- ① まず削除検出（前回はあって今回は無いキー） ---      // [FIX] 追加
                let currentKeys = Set(cells.keys)
                let prevKeys    = Set(self.remoteHashes.keys)
                let deletedKeys = prevKeys.subtracting(currentKeys).filter { $0.hasPrefix("cells.d") }

                var didAnyChange = false

                for key in deletedKeys {
                    // "cells.dXpY" -> day, period を取り出す
                    guard let r = key.range(of: #"cells\.d(\d+)p(\d+)"#, options: .regularExpression) else { continue }
                    let tag = String(key[r]).dropFirst(6) // dXpY
                    let comps = tag.dropFirst().split(separator: "p")
                    guard comps.count == 2,
                          let day = Int(comps[0]),
                          let period = Int(comps[1]) else { continue }

                    let idx = (period - 1) * self.dayLabels.count + day
                    if self.assigned.indices.contains(idx) {
                        self.assigned[idx] = nil
                        if let btn = self.slotButtons.first(where: { $0.tag == idx }) {
                            self.configureButton(btn, at: idx)
                        }
                        didAnyChange = true
                    }
                    self.remoteHashes.removeValue(forKey: key)     // [FIX] ハッシュも消す
                }
                // --- ② 更新/追加（既存ロジック） ---
                var patches: [(Int, Int, Course, String?)] = []
                for (absKey, m) in cells {
                    guard let r = absKey.range(of: #"cells\.d(\d+)p(\d+)"#, options: .regularExpression) else { continue }
                    let tag = String(absKey[r]).dropFirst(6)
                    let comps = tag.dropFirst().split(separator: "p")
                    guard comps.count == 2, let day = Int(comps[0]), let period = Int(comps[1]) else { continue }

                    let remoteH = m["h"] as? String ?? ""
                    if self.remoteHashes[absKey] == remoteH { continue } // 変化なしはスキップ
                    self.remoteHashes[absKey] = remoteH
                    patches.append((day, period, decodeCourseMap(m), m["colorKey"] as? String))
                }
                
                // --- ③ UI反映 ---
                if !patches.isEmpty || didAnyChange {
                    Task { @MainActor in
                        let cols = self.dayLabels.count
                        for (day, period, course, color) in patches {
                            let idx = (period - 1) * cols + day
                            if self.assigned.indices.contains(idx) {
                                self.assigned[idx] = course
                                if let c = color, let key = SlotColorKey(rawValue: c) {
                                    SlotColorStore.set(key, for: SlotLocation(day: day, period: period))
                                }
                                if let btn = self.slotButtons.first(where: { $0.tag == idx }) {
                                    self.configureButton(btn, at: idx)
                                }
                            }
                        }
                        self.reloadAllButtons()
                        self.saveAssigned()
                    }
                }
            }
            await MainActor.run {
                self.assigned = localAssigned
                self.reloadAllButtons()
            }
        }
    }

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()

        normalizeAssigned()
        loadAssigned(for: currentTerm)

        startTermSync()
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, _ in
            self?.startTermSync()
        }

        view.backgroundColor = .systemBackground
        buildHeader()
        layoutGridContainer()
        buildGridGuides()
        placeHeaders()
        placePlusButtons()
        reloadAllButtons()

        NotificationCenter.default.addObserver(self, selector: #selector(onSettingsChanged),
                                               name: .timetableSettingsChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onRegisterFromDetail(_:)),
            name: .registerCourseToTimetable, object: nil
        )
        bgObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.saveAssigned() }

        setupAdBanner()
        applyViewOnlyUI() // ← 最後に反映
    }

    deinit {
        termListener?.remove(); termListener = nil
        if let h = authHandle { Auth.auth().removeStateDidChangeListener(h) }
        if let bgObserver {
            NotificationCenter.default.removeObserver(bgObserver)
        }
        NotificationCenter.default.removeObserver(self, name: .timetableSettingsChanged, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safeHeight = view.safeAreaLayoutGuide.layoutFrame.height
        headerTopConstraint.constant = safeHeight * 0.02
        loadBannerIfNeeded()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        publishWidgetSnapshot()   // フォアグラウンドに戻ったときも最新化
    }

    // MARK: - Register from detail (既存通知)
    @objc private func onRegisterFromDetail(_ note: Notification) {
        guard let info = note.userInfo,
              let dict = info["course"] as? [String: Any] else { return }
        let day    = (info["day"] as? Int) ?? 0
        let period = (info["period"] as? Int) ?? 1
        let cols   = dayLabels.count
        let idx    = (period - 1) * cols + day
        guard assigned.indices.contains(idx) else { return }

        let course = makeCourse(from: dict, docID: info["docID"] as? String)
        assigned[idx] = course
        if let btn = slotButtons.first(where: { $0.tag == idx }) { configureButton(btn, at: idx) }
        else { reloadAllButtons() }
        saveAssigned()

        let loc = SlotLocation(day: day, period: period)
        let colorName = SlotColorStore.color(for: loc)?.rawValue
        let key = cellKey(day: day, period: period)
        let localH = slotHash(course, colorKey: colorName)
        if remoteHashes[key] != localH {
            Task { await remoteStore?.upsert(course: course, colorKey: colorName, day: day, period: period) }
        }
    }

    private func makeCourse(from d: [String: Any], docID: String?) -> Course {
        let title   = (d["class_name"]   as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "（無題）"
        let room    = (d["room"]         as? String) ?? ""
        let teacher = (d["teacher_name"] as? String) ?? ""
        let code    = (d["code"]         as? String) ?? (docID ?? "")
        let credits: Int? = {
            if let n = d["credit"] as? Int { return n }
            if let s = d["credit"] as? String, let n = Int(s) { return n }
            return nil
        }()
        let campus   = d["campus"]   as? String
        let category = d["category"] as? String
        let url      = d["url"]      as? String
        return Course(id: code, title: title, room: room, teacher: teacher,
                      credits: credits, campus: campus, category: category, syllabusURL: url, term: nil)
    }

    // MARK: - Settings change
    @objc private func onSettingsChanged() {
        let oldDays = lastDaysCount, oldPeriods = lastPeriodsCount
        settings = TimetableSettings.load()
        assigned = remapAssigned(old: assigned, oldDays: oldDays, oldPeriods: oldPeriods,
                                 newDays: dayLabels.count, newPeriods: periodLabels.count)
        rebuildGrid()
        lastDaysCount = dayLabels.count
        lastPeriodsCount = periodLabels.count
    }
    private func remapAssigned(old: [Course?], oldDays: Int, oldPeriods: Int,
                               newDays: Int, newPeriods: Int) -> [Course?] {
        var dst = Array(repeating: nil as Course?, count: newDays * newPeriods)
        let copyDays = min(oldDays, newDays), copyPeriods = min(oldPeriods, newPeriods)
        for p in 0..<copyPeriods { for d in 0..<copyDays { dst[p * newDays + d] = old[p * oldDays + d] } }
        return dst
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
        if !didLoadBannerOnce { didLoadBannerOnce = true; bv.load(Request()) }
    }

    private func normalizeAssigned() {
        let need = periodLabels.count * dayLabels.count
        if assigned.count < need {
            assigned.append(contentsOf: Array(repeating: nil, count: need - assigned.count))
        } else if assigned.count > need {
            assigned = Array(assigned.prefix(need))
        }
    }

    private func rebuildGrid() {
        gridContainerView.subviews.forEach { $0.removeFromSuperview() }
        normalizeAssigned()
        slotButtons.forEach { $0.removeFromSuperview() }
        slotButtons.removeAll()
        colGuides.forEach { gridContainerView.removeLayoutGuide($0) }
        rowGuides.forEach { gridContainerView.removeLayoutGuide($0) }
        colGuides.removeAll(); rowGuides.removeAll()
        buildGridGuides(); placeHeaders(); placePlusButtons(); reloadAllButtons()
    }

    // MARK: - Header
    private func buildHeader() {
        headerBar.axis = .horizontal
        headerBar.alignment = .center
        headerBar.distribution = .fill
        headerBar.spacing = 8
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerBar)

        leftButton.setTitle(currentTerm.displayTitle, for: .normal)
        leftButton.addTarget(self, action: #selector(tapLeft), for: .touchUpInside)

        titleLabel.text = "時間割"
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        rightStack.axis = .horizontal
        rightStack.alignment = .center
        rightStack.spacing = 8
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.setContentHuggingPriority(.required, for: .horizontal)

        func styleIcon(_ b: UIButton, _ systemName: String? = nil, title: String? = nil) {
            if let systemName {
                var cfg = UIButton.Configuration.plain()
                cfg.image = UIImage(systemName: systemName)
                cfg.preferredSymbolConfigurationForImage =
                    UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
                cfg.baseForegroundColor = .label
                cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
                b.configuration = cfg
            } else if let title {
                b.setTitle(title, for: .normal)
                b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
                b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
            }
            b.backgroundColor = .secondarySystemBackground
            b.layer.cornerRadius = 8
            b.layer.borderWidth = 1
            b.layer.borderColor = UIColor.separator.cgColor
        }

        styleIcon(rightA, title: "単")
        let multiIcon = (UIDevice.current.systemVersion as NSString).floatValue >= 16.0
            ? "point.3.connected.trianglepath.dotted" : "ellipsis.circle"
        styleIcon(rightB, multiIcon)
        styleIcon(rightC, "gearshape.fill")

        rightA.addTarget(self, action: #selector(tapRightA), for: .touchUpInside)
        rightB.addTarget(self, action: #selector(tapRightB), for: .touchUpInside)
        rightC.addTarget(self, action: #selector(tapRightC), for: .touchUpInside)

        rightStack.addArrangedSubview(rightA)
        rightStack.addArrangedSubview(rightB)
        rightStack.addArrangedSubview(rightC)

        let spacerL = UIView(); spacerL.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let spacerR = UIView(); spacerR.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerBar.addArrangedSubview(leftButton)
        headerBar.addArrangedSubview(spacerL)
        headerBar.addArrangedSubview(titleLabel)
        headerBar.addArrangedSubview(spacerR)
        headerBar.addArrangedSubview(rightStack)

        [leftButton, titleLabel, rightStack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        headerBar.isLayoutMarginsRelativeArrangement = true
        headerBar.layoutMargins = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        headerBar.setContentHuggingPriority(.required, for: .vertical)
        headerBar.setContentCompressionResistancePriority(.required, for: .vertical)
        let clamp = headerBar.heightAnchor.constraint(equalTo: titleLabel.heightAnchor, constant: 16)
        clamp.priority = .required; clamp.isActive = true

        NSLayoutConstraint.activate([
            leftButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            rightStack.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor)
        ])
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.centerXAnchor.constraint(equalTo: headerBar.centerXAnchor).isActive = true

        let g = view.safeAreaLayoutGuide
        headerTopConstraint = headerBar.topAnchor.constraint(equalTo: g.topAnchor, constant: 0)
        NSLayoutConstraint.activate([
            headerTopConstraint,
            headerBar.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            headerBar.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            headerBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    // MARK: - Grid container（縦スクロール）
    private func layoutGridContainer() {
        let g = view.safeAreaLayoutGuide
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        scrollBottomConstraint?.isActive = false
        scrollBottomConstraint = scrollView.bottomAnchor.constraint(equalTo: g.bottomAnchor)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            scrollBottomConstraint!
        ])

        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])

        gridContainerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(gridContainerView)
        NSLayoutConstraint.activate([
            gridContainerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            gridContainerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 0),
            gridContainerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            gridContainerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        ])
    }

    // MARK: - Guides
    private func buildGridGuides() {
        let colCount = 1 + dayLabels.count
        colGuides.removeAll()
        for _ in 0..<colCount {
            let g = UILayoutGuide()
            gridContainerView.addLayoutGuide(g)
            colGuides.append(g)
            g.topAnchor.constraint(equalTo: gridContainerView.topAnchor).isActive = true
            g.bottomAnchor.constraint(equalTo: gridContainerView.bottomAnchor).isActive = true
        }
        colGuides[0].leadingAnchor.constraint(equalTo: gridContainerView.leadingAnchor).isActive = true
        colGuides[colCount-1].trailingAnchor.constraint(equalTo: gridContainerView.trailingAnchor).isActive = true
        colGuides[0].widthAnchor.constraint(equalToConstant: timeColWidth).isActive = true
        for i in 1..<colCount {
            colGuides[i].leadingAnchor.constraint(equalTo: colGuides[i-1].trailingAnchor, constant: spacing).isActive = true
            if i >= 2 { colGuides[i].widthAnchor.constraint(equalTo: colGuides[1].widthAnchor).isActive = true }
        }

        let rowCount = 1 + periodLabels.count
        rowGuides.removeAll()
        for _ in 0..<rowCount {
            let g = UILayoutGuide()
            gridContainerView.addLayoutGuide(g)
            rowGuides.append(g)
            g.leadingAnchor.constraint(equalTo: gridContainerView.leadingAnchor).isActive = true
            g.trailingAnchor.constraint(equalTo: gridContainerView.trailingAnchor).isActive = true
        }
        rowGuides[0].topAnchor.constraint(equalTo: gridContainerView.topAnchor).isActive = true
        rowGuides[rowCount-1].bottomAnchor.constraint(equalTo: gridContainerView.bottomAnchor).isActive = true
        rowGuides[0].heightAnchor.constraint(equalToConstant: headerRowHeight).isActive = true

        for i in 1..<rowCount {
            rowGuides[i].topAnchor.constraint(equalTo: rowGuides[i-1].bottomAnchor, constant: spacing).isActive = true
            if i >= 2 { rowGuides[i].heightAnchor.constraint(equalTo: rowGuides[1].heightAnchor).isActive = true }
        }
        rowGuides[1].heightAnchor.constraint(greaterThanOrEqualToConstant: periodRowMinHeight).isActive = true
    }

    // MARK: - Headers / Time markers
    private func placeHeaders() {
        for i in 0..<dayLabels.count {
            let l = headerLabel(dayLabels[i])
            gridContainerView.addSubview(l)
            NSLayoutConstraint.activate([
                l.centerXAnchor.constraint(equalTo: colGuides[i+1].centerXAnchor),
                l.centerYAnchor.constraint(equalTo: rowGuides[0].centerYAnchor)
            ])
        }
        for r in 0..<periodLabels.count {
            let marker = makeTimeMarker(for: r + 1)
            gridContainerView.addSubview(marker)
            NSLayoutConstraint.activate([
                marker.centerXAnchor.constraint(equalTo: colGuides[0].centerXAnchor),
                marker.widthAnchor.constraint(equalToConstant: timeColWidth),
                marker.centerYAnchor.constraint(equalTo: rowGuides[r+1].centerYAnchor)
            ])
        }
    }
    private func headerLabel(_ text: String) -> UILabel {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.text = text
        l.font = .systemFont(ofSize: 16, weight: .regular)
        l.textAlignment = .center
        return l
    }
    private func makeTimeMarker(for period: Int) -> UIView {
        let v = UIStackView()
        v.axis = .vertical; v.alignment = .center; v.spacing = 2
        v.translatesAutoresizingMaskIntoConstraints = false
        let top = UILabel(); top.font = .systemFont(ofSize: 11); top.textColor = .secondaryLabel; top.textAlignment = .center
        let mid = UILabel(); mid.font = .systemFont(ofSize: 16, weight: .semibold); mid.textAlignment = .center; mid.text = "\(period)"
        let bottom = UILabel(); bottom.font = .systemFont(ofSize: 11); bottom.textColor = .secondaryLabel; bottom.textAlignment = .center
        if period-1 < timePairs.count {
            top.text    = timePairs[period-1].start
            bottom.text = timePairs[period-1].end
        }
        [top, mid, bottom].forEach { v.addArrangedSubview($0) }
        return v
    }

    // MARK: - Buttons
    private func baseCellConfig(bg: UIColor, fg: UIColor,
                                stroke: UIColor? = nil, strokeWidth: CGFloat = 0) -> UIButton.Configuration {
        var cfg = UIButton.Configuration.filled()
        cfg.baseBackgroundColor = bg
        cfg.baseForegroundColor = fg
        cfg.contentInsets = .init(top: 8, leading: 10, bottom: 8, trailing: 10)
        cfg.background.cornerRadius = 5
        cfg.background.backgroundInsets = .zero
        cfg.background.strokeColor = stroke
        cfg.background.strokeWidth = strokeWidth
        return cfg
    }

    private func configureButton(_ b: UIButton, at idx: Int) {
        b.backgroundColor = .clear; b.layer.borderWidth = 0; b.layer.cornerRadius = 0
        if !(assigned.indices.contains(idx) && assigned[idx] != nil) {
            b.removeTimetableContentView()
            var cfg = baseCellConfig(bg: .secondarySystemBackground, fg: .tertiaryLabel,
                                     stroke: UIColor.separator, strokeWidth: 1)
            cfg.title = viewOnly ? " " : "＋"
            cfg.titleAlignment = .center
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { inAttr in
                var out = inAttr; out.font = .systemFont(ofSize: 22, weight: .semibold)
                let p = NSMutableParagraphStyle(); p.alignment = .center; out.paragraphStyle = p; return out
            }
            b.configuration = cfg
            return
        }
        let cols = dayLabels.count
        let row  = idx / cols
        let col  = idx % cols
        let loc  = SlotLocation(day: col, period: row + 1)
        let colorKey = SlotColorStore.color(for: loc) ?? .teal

        var cfg = baseCellConfig(bg: colorKey.uiColor, fg: .white)
        cfg.title = nil; cfg.subtitle = nil
        b.configuration = cfg

        let content = b.ensureTimetableContentView()
        let course = assigned[idx]!
        content.titleLabel.text = course.title
        content.roomLabel.text  = course.room
        content.titleLabel.textColor = .white
        content.roomLabel.textColor  = .white
    }
    private func reloadAllButtons() { for b in slotButtons { configureButton(b, at: b.tag) } }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if termListener == nil, remoteStore != nil { startTermSync() }
        reloadAllButtons()
    }

    private func placePlusButtons() {
        let rows = periodLabels.count, cols = dayLabels.count
        for r in 0..<rows {
            for c in 0..<cols {
                let b = UIButton(type: .system)
                b.translatesAutoresizingMaskIntoConstraints = false
                gridContainerView.addSubview(b)
                let rowG = rowGuides[r+1], colG = colGuides[c+1]
                NSLayoutConstraint.activate([
                    b.topAnchor.constraint(equalTo: rowG.topAnchor, constant: cellPadding),
                    b.bottomAnchor.constraint(equalTo: rowG.bottomAnchor, constant: -cellPadding),
                    b.leadingAnchor.constraint(equalTo: colG.leadingAnchor, constant: cellPadding),
                    b.trailingAnchor.constraint(equalTo: colG.trailingAnchor, constant: -cellPadding)
                ])
                let idx = r * cols + c
                b.tag = idx
                b.addTarget(self, action: #selector(slotTapped(_:)), for: .touchUpInside)
                slotButtons.append(b)
                configureButton(b, at: idx)
            }
        }
    }

    private func gridIndex(for loc: SlotLocation) -> Int {
        let cols = dayLabels.count
        return loc.day + (loc.period - 1) * cols
    }

    // MARK: - Detail / List
    private func presentCourseDetail(_ course: Course, at loc: SlotLocation) {
        let vc = CourseDetailViewController(course: course, location: loc)
        vc.delegate = self
        vc.modalPresentationStyle = .pageSheet
        if let sheet = vc.sheetPresentationController {
            if #available(iOS 16.0, *) {
                let id = UISheetPresentationController.Detent.Identifier("ninetyTwo")
                sheet.detents = [.custom(identifier: id){ $0.maximumDetentValue * 0.92 }, .large()]
                sheet.selectedDetentIdentifier = id
            } else {
                sheet.detents = [.large()]; sheet.selectedDetentIdentifier = .large
            }
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 16
        }
        present(vc, animated: true)
    }

    @objc private func slotTapped(_ sender: UIButton) {
        let cols = dayLabels.count
        let idx  = sender.tag
        let row  = sender.tag / cols
        let col  = sender.tag % cols
        let loc = SlotLocation(day: col, period: row + 1)

        if viewOnly { return } // 読み取り専用時は編集不可
        if let course = assigned[idx] { presentCourseDetail(course, at: loc); return }
        
        // ▼▼▼ ここから変更 ▼▼▼
        let termRaw = firestoreTermRaw(for: currentTerm)      // [CHANGED] 画面上の学期→Firestoreの生文字列（"（前期）" 等）に変換して取得
        let listVC = CourseListViewController(location: loc,  // [CHANGED] termRaw を渡す
                                              termRaw: termRaw)

        listVC.delegate = self
        if let nav = navigationController { nav.pushViewController(listVC, animated: true) }
        else {
            let nav = UINavigationController(rootViewController: listVC)
            nav.modalPresentationStyle = .fullScreen
            present(nav, animated: true)
        }
    }

    // MARK: - CourseList delegate
    func courseList(_ vc: CourseListViewController, didSelect course: Course, at location: SlotLocation) {
        normalizeAssigned()
        let idx = (location.period - 1) * dayLabels.count + location.day
        assigned[idx] = course
        if let btn = slotButtons.first(where: { $0.tag == idx }) { configureButton(btn, at: idx) }
        else { reloadAllButtons() }
        saveAssigned()

        let day = location.day, period = location.period
        let loc = SlotLocation(day: day, period: period)
        let colorName = SlotColorStore.color(for: loc)?.rawValue
        let key = cellKey(day: day, period: period)
        let localH = slotHash(course, colorKey: colorName)
        if remoteHashes[key] != localH {
            Task { await remoteStore?.upsert(course: course, colorKey: colorName, day: day, period: period) }
        }

        if let nav = vc.navigationController {
            if nav.viewControllers.first === vc { vc.dismiss(animated: true) } else { nav.popViewController(animated: true) }
        } else { vc.dismiss(animated: true) }
    }

    // MARK: - CourseDetail delegate
    // 置き換え：courseDetail(_:didChangeColor:at:)
    func courseDetail(_ vc: CourseDetailViewController, didChangeColor key: SlotColorKey, at location: SlotLocation) {
        // 1) ローカルの色とUI
        SlotColorStore.set(key, for: location)
        let idx = gridIndex(for: location)
        if (0..<slotButtons.count).contains(idx) { configureButton(slotButtons[idx], at: idx) }
        else { rebuildGrid() }

        // 2) そのコマに科目が入っているなら、色変更としてリモートへ反映
        if assigned.indices.contains(idx), let course = assigned[idx] {
            let k = cellKey(day: location.day, period: location.period)   // [ADD]
            let localH = slotHash(course, colorKey: key.rawValue)         // [ADD]
            if remoteHashes[k] != localH {                                // [ADD] 変化がある時だけ送信
                Task {
                    await remoteStore?.upsert(
                        course: course,
                        colorKey: key.rawValue,
                        day: location.day,
                        period: location.period
                    )
                }
            }
        }
    }
    // [ADDED] 表示中の TermKey → Firestore の term 生文字列に変換
    private func firestoreTermRaw(for term: TermKey) -> String? {
        // TermKey の表示題目に含まれる語で判定（例: "2025年前期" など）
        let t = term.displayTitle
        if t.contains("前期") { return "（前期）" }
        if t.contains("後期") { return "（後期）" }
        /*
        if t.contains("前期前半") { return "（前期）" }
        if t.contains("前期後半") { return "（前期）" }
        if t.contains("後期前半") { return "（後期）" }
        if t.contains("後期後半") { return "（後期）" }*/
        // 年間や集中など他の種別も使うならここでマップを追加
        return nil // 不明ならフィルタなし
    }


    func courseDetail(_ vc: CourseDetailViewController, requestEditFor course: Course, at location: SlotLocation) {
        vc.dismiss(animated: true) {
            let termRaw = self.firestoreTermRaw(for: self.currentTerm)   // [ADDED]
            let listVC = CourseListViewController(location: location, termRaw: termRaw) // [CHANGED]
            listVC.delegate = self
            if let nav = self.navigationController { nav.pushViewController(listVC, animated: true) }
            else {
                let nav = UINavigationController(rootViewController: listVC)
                nav.modalPresentationStyle = .fullScreen
                self.present(nav, animated: true)
            }
        }
    }
    func courseDetail(_ vc: CourseDetailViewController, requestDelete course: Course, at location: SlotLocation) {
        let idx = (location.period - 1) * self.dayLabels.count + location.day
        self.assigned[idx] = nil
        if let btn = self.slotButtons.first(where: { $0.tag == idx }) { self.configureButton(btn, at: idx) }
        else { self.reloadAllButtons() }
        vc.dismiss(animated: true)
        saveAssigned()
        let key = cellKey(day: location.day, period: location.period)   // [FIX] 追加
        remoteHashes.removeValue(forKey: key)                            // [FIX] 追加
        Task { await remoteStore?.delete(day: location.day, period: location.period) }
    }
    func courseDetail(_ vc: CourseDetailViewController, didDeleteAt location: SlotLocation) {
        assigned[index(for: location)] = nil
        reloadAllButtons()
        saveAssigned()
        let key = cellKey(day: location.day, period: location.period)   // [FIX] 追加
        remoteHashes.removeValue(forKey: key)                            // [FIX] 追加
        Task { await remoteStore?.delete(day: location.day, period: location.period) }
    }
    func courseDetail(_ vc: CourseDetailViewController, didEdit course: Course, at location: SlotLocation) {
        assigned[index(for: location)] = course
        reloadAllButtons()
        saveAssigned()
        let day = location.day, period = location.period
        let colorName = SlotColorStore.color(for: location)?.rawValue
        let key = cellKey(day: day, period: period)
        let localH = slotHash(course, colorKey: colorName)
        if remoteHashes[key] != localH {
            Task { await remoteStore?.upsert(course: course, colorKey: colorName, day: day, period: period) }
        }
    }

    // MARK: - Helpers
    private func index(for loc: SlotLocation) -> Int { (loc.period - 1) * dayLabels.count + loc.day }
    private func uniqueCoursesInAssigned() -> [Course] {
        var seen = Set<String>(), out: [Course] = []
        for c in assigned.compactMap({ $0 }) {
            let key = (c.id.isEmpty ? "" : c.id) + "#" + c.title
            if seen.insert(key).inserted { out.append(c) }
        }
        return out
    }
    
    
    
    

    // MARK: - AdMob
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

        scrollBottomConstraint?.isActive = false
        scrollBottomConstraint = scrollView.bottomAnchor.constraint(equalTo: adContainer.topAnchor)
        scrollBottomConstraint?.isActive = true

        let bv = BannerView()
        bv.translatesAutoresizingMaskIntoConstraints = false
        bv.adUnitID = "ca-app-pub-3940256099942544/2934735716" // Test
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
        var inset = scrollView.contentInset
        inset.bottom = height
        scrollView.contentInset = inset
        scrollView.verticalScrollIndicatorInsets.bottom = height
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

    // MARK: - Header actions
    @objc private func tapLeft() {
        let thisYear = Calendar.current.component(.year, from: Date())
        let years = Array((thisYear - 4)...(thisYear + 1))
        let vc = TermPickerViewController(years: years, selected: currentTerm) { [weak self] picked in
            guard let self = self, let picked = picked else { return }
            self.changeTerm(to: picked)
        }
        if let sheet = vc.sheetPresentationController {
            if #available(iOS 16.0, *) { sheet.detents = [.medium(), .large()] }
            else { sheet.detents = [.medium()] }
            sheet.prefersGrabberVisible = true
        }
        present(vc, animated: true)
    }
    private func changeTerm(to newTerm: TermKey) {
        guard newTerm != currentTerm else { return }
        currentTerm = newTerm
        leftButton.setTitle(newTerm.displayTitle, for: .normal)
        loadAssigned(for: newTerm)
        startTermSync()
        saveAssigned()
    }
    @objc private func tapRightA() {
        let term = TermStore.loadSelected()
        let vc = CreditsFullViewController(currentTerm: term)
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }
    @objc private func tapRightB() {
        let action = UIAlertController(title: "時間割を保存 / 共有", message: nil, preferredStyle: .actionSheet)
        action.addAction(UIAlertAction(title: "写真に保存", style: .default) { [weak self] _ in
            self?.saveCurrentTimetableToPhotos()
        })
        action.addAction(UIAlertAction(title: "共有…", style: .default) { [weak self] _ in
            self?.shareCurrentTimetable()
        })
        action.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        if let pop = action.popoverPresentationController { pop.sourceView = rightB; pop.sourceRect = rightB.bounds }
        present(action, animated: true)
    }
    @objc private func tapRightC() {
        let vc = TimetableSettingsViewController()
        if let nav = navigationController { nav.pushViewController(vc, animated: true) }
        else { let nav = UINavigationController(rootViewController: vc); present(nav, animated: true) }
    }

    // MARK: - Share / Save
    private func makeTimetableImage() -> UIImage {
        gridContainerView.layoutIfNeeded()
        let targetView = gridContainerView
        let size = targetView.bounds.size
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in targetView.layer.render(in: ctx.cgContext) }
    }
    private func shareCurrentTimetable() {
        let image = makeTimetableImage()
        let activityVC = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        if let sheet = activityVC.sheetPresentationController {
            if #available(iOS 16.0, *) { sheet.detents = [.medium(), .large()]; sheet.selectedDetentIdentifier = .medium }
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 16
        }
        if let pop = activityVC.popoverPresentationController { pop.sourceView = rightB; pop.sourceRect = rightB.bounds }
        present(activityVC, animated: true)
    }
    private func saveCurrentTimetableToPhotos() {
        let image = makeTimetableImage()
        func finish(_ ok: Bool, _ error: Error?) {
            let title = ok ? "保存しました" : "保存に失敗しました"
            let msg   = ok ? "写真アプリに保存されました" : (error?.localizedDescription ?? "写真への保存権限をご確認ください")
            let ac = UIAlertController(title: title, message: msg, preferredStyle: .alert)
            ac.addAction(UIAlertAction(title: "OK", style: .default))
            present(ac, animated: true)
        }
        if #available(iOS 14, *) {
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            switch status {
            case .notDetermined:
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { s in
                    DispatchQueue.main.async {
                        if s == .authorized || s == .limited { self.performSaveToPhotos(image, completion: finish) }
                        else { finish(false, nil) }
                    }
                }
            case .authorized, .limited: performSaveToPhotos(image, completion: finish)
            default: finish(false, nil)
            }
        } else {
            let status = PHPhotoLibrary.authorizationStatus()
            if status == .notDetermined {
                PHPhotoLibrary.requestAuthorization { s in
                    DispatchQueue.main.async { (s == .authorized) ? self.performSaveToPhotos(image, completion: finish) : finish(false, nil) }
                }
            } else if status == .authorized { performSaveToPhotos(image, completion: finish) }
            else { finish(false, nil) }
        }
    }
    private func performSaveToPhotos(_ image: UIImage, completion: @escaping (Bool, Error?) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }) { ok, err in DispatchQueue.main.async { completion(ok, err) } }
    }
}

// MARK: - コマ内容ビュー（タッチ無効）
final class TimetableCellContentView: UIView {
    let titleLabel = UILabel()
    let roomLabel  = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let v = UIStackView(arrangedSubviews: [titleLabel, roomLabel])
        v.axis = .vertical; v.alignment = .center; v.spacing = 4
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            v.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            v.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            v.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 3
        titleLabel.lineBreakMode = .byTruncatingTail
        roomLabel.font = .systemFont(ofSize: 11, weight: .medium)
        roomLabel.textAlignment = .center
        roomLabel.numberOfLines = 1
        roomLabel.lineBreakMode = .byTruncatingTail
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private extension UIButton {
    func ensureTimetableContentView() -> TimetableCellContentView {
        let tag = 987654
        if let v = viewWithTag(tag) as? TimetableCellContentView { return v }
        let v = TimetableCellContentView()
        v.tag = tag; v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor),
            v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.topAnchor.constraint(equalTo: topAnchor),
            v.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        return v
    }
    func removeTimetableContentView() { viewWithTag(987654)?.removeFromSuperview() }
}

// MARK: - 学期ピッカー
final class TermPickerViewController: UIViewController, UIPickerViewDataSource, UIPickerViewDelegate {
    private let years: [Int]
    private var selectedYear: Int
    private var selectedSemester: Semester
    private let onDone: (TermKey?) -> Void
    private let picker = UIPickerView()
    private let toolbar = UIToolbar()
    init(years: [Int], selected: TermKey, onDone: @escaping (TermKey?) -> Void) {
        self.years = years; self.selectedYear = selected.year; self.selectedSemester = selected.semester; self.onDone = onDone
        super.init(nibName: nil, bundle: nil); modalPresentationStyle = .pageSheet
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        let cancel = UIBarButtonItem(title: "キャンセル", style: .plain, target: self, action: #selector(cancelTap))
        let flex = UIBarButtonItem(systemItem: .flexibleSpace)
        let done = UIBarButtonItem(title: "完了", style: .done, target: self, action: #selector(doneTap))
        toolbar.items = [cancel, flex, done]; view.addSubview(toolbar)
        picker.translatesAutoresizingMaskIntoConstraints = false; picker.dataSource = self; picker.delegate = self; view.addSubview(picker)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            picker.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            picker.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            picker.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        if let yi = years.firstIndex(of: selectedYear) { picker.selectRow(yi, inComponent: 0, animated: false) }
        if let si = Semester.allCases.firstIndex(of: selectedSemester) { picker.selectRow(si, inComponent: 1, animated: false) }
    }
    @objc private func cancelTap() { onDone(nil); dismiss(animated: true) }
    @objc private func doneTap() { onDone(TermKey(year: selectedYear, semester: selectedSemester)); dismiss(animated: true) }
    func numberOfComponents(in pickerView: UIPickerView) -> Int { 2 }
    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        component == 0 ? years.count : Semester.allCases.count
    }
    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        component == 0 ? "\(years[row])年" : Semester.allCases[row].display
    }
    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        if component == 0 { selectedYear = years[row] } else { selectedSemester = Semester.allCases[row] }
    }

}

// MARK: - Adapter to your project's delegate signatures
extension timetable {
    
    // 例：色変更
    func courseDetailViewController(_ vc: CourseDetailViewController,
                                    didChangeColor key: SlotColorKey,
                                    at location: SlotLocation) {
        // 私の実装へ橋渡し
        courseDetail(vc, didChangeColor: key, at: location)
    }
    
    // 例：編集完了（コマ内容更新）
    func courseDetailViewController(_ vc: CourseDetailViewController,
                                    didEdit course: Course,
                                    at location: SlotLocation) {
        courseDetail(vc, didEdit: course, at: location)
    }
    
    // 例：このコマの削除
    func courseDetailViewController(_ vc: CourseDetailViewController,
                                    didDeleteAt location: SlotLocation) {
        courseDetail(vc, didDeleteAt: location)
    }
    
    // 例：編集画面に遷移したい（コース選択し直し）
    func courseDetailViewController(_ vc: CourseDetailViewController,
                                    requestEditFor course: Course,
                                    at location: SlotLocation) {
        courseDetail(vc, requestEditFor: course, at: location)
    }
    
    // 例：削除のリクエスト（確認からの削除）
    func courseDetailViewController(_ vc: CourseDetailViewController,
                                    requestDelete course: Course,
                                    at location: SlotLocation) {
        courseDetail(vc, requestDelete: course, at: location)
    }
    
    /// あなたの内部構造に合わせて coursesByDay を用意できるなら、それを使ってスナップショットを生成
    func exportTodayToWidget(coursesByDay: [[Course]]) {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: Date()) // 1=Sun ... 7=Sat
        // 0=Mon.. なら変換（Mon=2→0, Tue=3→1, ...）
        let dayIndex = (weekday + 5) % 7
        guard (0..<coursesByDay.count).contains(dayIndex) else { return }

        let today = coursesByDay[dayIndex]
        var periods: [WidgetPeriod] = []

        for i in 0..<min(5, today.count) {
            let c = today[i]
            let slot = PeriodTime.slots[i]
            periods.append(.init(index: i+1, title: c.title, room: c.room,
                                 start: slot.start, end: slot.end, teacher: c.teacher))
        }

        let labels = ["日曜日","月曜日","火曜日","水曜日","木曜日","金曜日","土曜日"]
        let snap = WidgetSnapshot(date: Date(), weekday: weekday,
                                  dayLabel: labels[(weekday-1+7)%7],
                                  periods: periods)
        WidgetBridge.save(snap)
    }
    
    
    
}

