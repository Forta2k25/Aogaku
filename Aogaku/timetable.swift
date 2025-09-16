
import UIKit
import Foundation
import Photos
import GoogleMobileAds


@inline(__always)
private func makeAdaptiveAdSize(width: CGFloat) -> AdSize {
    return currentOrientationAnchoredAdaptiveBanner(width: width)
}
// MARK: - Slot

struct SlotLocation : Codable, Hashable {
    let day: Int   // 0=月…5=土
    let period: Int   // 1..rows
    var dayName: String { ["月","火","水","木","金","土"][day] }
}

// MARK: - timetable

final class timetable: UIViewController,
                       CourseListViewControllerDelegate,
                       CourseDetailViewControllerDelegate,
                       BannerViewDelegate {

    // ====== 行数の上限（必要ならここだけ変えればOK） ======
    private let titleMaxLines = 5
    private let subtitleMaxLines = 2

    private let periodRowMinHeight: CGFloat = 120   // 時限行の最小高さ

    // ===== Scroll root =====
    private let scrollView = UIScrollView()
    private let contentView = UIView()   // スクロールの中身
    
    // ===== AdMob (Banner) =====
    private let adContainer = UIView()           // 画面下に固定するコンテナ
    // ← 既存のプロパティを置換
    private var bannerView: BannerView?
    private var lastBannerWidth: CGFloat = 0
    private var didLoadBannerOnce = false
    private var adContainerHeight: NSLayoutConstraint?

    // ===== Header =====
    private let headerBar = UIStackView()
    private let leftButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let rightStack = UIStackView()
    private let rightA = UIButton(type: .system)  // 単
    private let rightB = UIButton(type: .system)
    private let rightC = UIButton(type: .system)
    private var headerTopConstraint: NSLayoutConstraint!

    // ===== Grid =====
    private let gridContainerView = UIView()
    private var colGuides: [UILayoutGuide] = []  // 0列目=時限列, 1..=曜日列
    private var rowGuides: [UILayoutGuide] = []  // 0行目=ヘッダ行, 1..=各時限
    private(set) var slotButtons: [UIButton] = []

    // ===== Data / Settings =====
    private var registeredCourses: [Int: Course] = [:]
    private var bgObserver: NSObjectProtocol?
    
    private var scrollBottomConstraint: NSLayoutConstraint?

    // 1限〜7限までの開始・終了
    private let timePairs: [(start: String, end: String)] = [
        ("9:00",  "10:30"),
        ("11:00", "12:30"),
        ("13:20", "14:50"),
        ("15:05", "16:35"),
        ("16:50", "18:20"),
        ("18:30", "20:00"),
        ("20:10", "21:40")
    ]

    private var settings = TimetableSettings.load()
    private var dayLabels: [String] {
        settings.includeSaturday ? ["月","火","水","木","金","土"] : ["月","火","水","木","金"]
    }
    private var periodLabels: [String] { (1...settings.periods).map { "\($0)" } }

    // 直近の列数・行数（再構築時に使う）
    private var lastDaysCount = 5
    private var lastPeriodsCount = 5

    // “登録科目”（未登録は nil）
    private var assigned: [Course?] = Array(repeating: nil, count: 25)

    // MARK: Layout constants
    private let spacing: CGFloat = 1
    private let cellPadding: CGFloat = 1 // コマの大きさ調整
    private let headerRowHeight: CGFloat = 28
    private let timeColWidth: CGFloat = 40
    private let topRatio: CGFloat = 0.02
    
    // 追加: 現在の学期
    private var currentTerm: TermKey = TermStore.loadSelected()

    // MARK: - Persistence (UserDefaults)
    //private let saveKey = "assignedCourses.v1"

    private func saveAssigned() {
        do {
            let data = try JSONEncoder().encode(assigned)
            UserDefaults.standard.set(data, forKey: currentTerm.storageKey)
            TermStore.saveSelected(currentTerm) // 現在選択の学期も保持
        } catch {
            print("Save error:", error)
        }
    }

    private func loadAssigned(for term: TermKey) {
        let key = term.storageKey
        if let data = UserDefaults.standard.data(forKey: key),
           let loaded = try? JSONDecoder().decode([Course?].self, from: data) {
            assigned = loaded
        } else {
            // データがまだない学期 → 空配列（現在の行列サイズに合わせて初期化）
            assigned = Array(repeating: nil, count: dayLabels.count * periodLabels.count)
        }
        normalizeAssigned()
    }
    
    // MARK: - AdMob banner
    private func setupAdBanner() {
        // 1) adContainer を下部に固定（あなたの既存コードをそのまま）
        adContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(adContainer)

        adContainerHeight = adContainer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            adContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            adContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            adContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            adContainerHeight!
        ])

        // 2) ✅ scrollView の下端を safeArea から adContainer.top に付け替える
        scrollBottomConstraint?.isActive = false
        scrollBottomConstraint = scrollView.bottomAnchor.constraint(equalTo: adContainer.topAnchor)
        scrollBottomConstraint?.isActive = true

        // 3) GADBannerView の生成・貼り付け（あなたの実装でOK）
        let bv = BannerView()
        bv.translatesAutoresizingMaskIntoConstraints = false
        bv.adUnitID = "ca-app-pub-3940256099942544/2934735716"   // テストID
        bv.rootViewController = self
        
        // ★ 事前に「仮サイズ」を入れておく（320x50）
        bv.adSize = AdSizeBanner
        bv.delegate = self
        
        adContainer.addSubview(bv)
        NSLayoutConstraint.activate([
            // ★ 変更：leading/trailing で横幅を adContainer と同じに固定
            bv.leadingAnchor.constraint(equalTo: adContainer.leadingAnchor),
            bv.trailingAnchor.constraint(equalTo: adContainer.trailingAnchor),
            bv.topAnchor.constraint(equalTo: adContainer.topAnchor),
            bv.bottomAnchor.constraint(equalTo: adContainer.bottomAnchor)
        ])
        self.bannerView = bv
    }


    private func updateInsetsForBanner(height: CGFloat) {
        // バナー高さぶん下マージンを足して、内容が隠れないようにする
        var inset = scrollView.contentInset
        inset.bottom = height
        scrollView.contentInset = inset
        scrollView.verticalScrollIndicatorInsets.bottom = height
    }
    // MARK: - GADBannerViewDelegate
    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        let h = bannerView.adSize.size.height
        adContainerHeight?.constant = h
        updateInsetsForBanner(height: h)   // ← これを追加
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
        print("Ad loaded. size=", bannerView.adSize.size)
       }

    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        adContainerHeight?.constant = 0
        updateInsetsForBanner(height: 0)   // ← これも
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
        print("Ad failed:", error.localizedDescription)
       }




    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        normalizeAssigned()
        loadAssigned(for: currentTerm)    // ← ここだけ置換
        
        view.backgroundColor = .systemBackground
        buildHeader()
        layoutGridContainer()
        buildGridGuides()
        placeHeaders()
        placePlusButtons()
        reloadAllButtons()//追加

        NotificationCenter.default.addObserver(
            self, selector: #selector(onSettingsChanged),
            name: .timetableSettingsChanged, object: nil
        )
        
        // ▼▼ ここが今回の肝：通知を監視 ▼▼
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onRegisterFromDetail(_:)),
            name: .registerCourseToTimetable,
            object: nil
        )
        
        bgObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.saveAssigned() }
        
        
        setupAdBanner()
    }

    deinit {
        if let bgObserver { NotificationCenter.default.removeObserver(bgObserver) }
        NotificationCenter.default.removeObserver(self, name: .timetableSettingsChanged, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        
        let safeHeight = view.safeAreaLayoutGuide.layoutFrame.height
        headerTopConstraint.constant = safeHeight * topRatio
        loadBannerIfNeeded()   // ← ここでだけ呼ぶ

    }
    // MARK: - Notification handler（登録）
    @objc private func onRegisterFromDetail(_ note: Notification) {
        guard let info = note.userInfo,
              let dict = info["course"] as? [String: Any] else { return }

        // どのコマか（未指定時はとりあえず月1）
        let day    = (info["day"] as? Int) ?? 0
        let period = (info["period"] as? Int) ?? 1
        let idx    = (period - 1) * dayLabels.count + day
        guard assigned.indices.contains(idx) else { return }

        // Course を生成
        let course = makeCourse(from: dict, docID: info["docID"] as? String)

        // 書き込み & 反映
        assigned[idx] = course
        if let btn = slotButtons.first(where: { $0.tag == idx }) {
            configureButton(btn, at: idx)
        } else {
            reloadAllButtons()
        }
        saveAssigned()

        // 軽いフィードバック
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let ac = UIAlertController(title: "登録しました", message: "\(["月","火","水","木","金","土"][day]) \(period)限に「\(course.title)」を登録しました。", preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "OK", style: .default))
        present(ac, animated: true)
    }
    
    // timetable.swift

    private func makeCourse(from d: [String: Any], docID: String?) -> Course {
        // Firestore → Swift への安全な取り出し
        let title   = (d["class_name"]   as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "（無題）"
        let room    = (d["room"]         as? String) ?? ""
        let teacher = (d["teacher_name"] as? String) ?? ""
        let code    = (d["code"]         as? String) ?? (docID ?? "")

        // credit は Int または String の可能性があるので Int? に正規化
        let credits: Int? = {
            if let n = d["credit"] as? Int { return n }
            if let s = d["credit"] as? String, let n = Int(s) { return n }
            return nil
        }()

        let campus   = d["campus"]   as? String
        let category = d["category"] as? String
        let url      = d["url"]      as? String

        // ★ あなたの Course(init:) に完全一致
        return Course(
            id: code,
            title: title,
            room: room,
            teacher: teacher,
            credits: credits,
            campus: campus,
            category: category,
            syllabusURL: url
        )
    }

   /*
    let id: String            // Firestore: code
    let title: String         // Firestore: class_name
    let room: String          // Firestore: room
    let teacher: String       // Firestore: teacher_name
    var credits: Int?         // Firestore: credit
    var campus: String?       // Firestore: campus
    var category: String?     // Firestore: category
    var syllabusURL: String?  // Firestore: url*/

    // MARK: - Settings change

    @objc private func onSettingsChanged() {
        let oldDays = lastDaysCount
        let oldPeriods = lastPeriodsCount

        settings = TimetableSettings.load()
        assigned = remapAssigned(old: assigned,
                                 oldDays: oldDays, oldPeriods: oldPeriods,
                                 newDays: dayLabels.count, newPeriods: periodLabels.count)

        rebuildGrid()
        lastDaysCount = dayLabels.count
        lastPeriodsCount = periodLabels.count
    }

    private func remapAssigned(old: [Course?],
                               oldDays: Int, oldPeriods: Int,
                               newDays: Int, newPeriods: Int) -> [Course?] {
        var dst = Array(repeating: nil as Course?, count: newDays * newPeriods)
        let copyDays = min(oldDays, newDays)
        let copyPeriods = min(oldPeriods, newPeriods)
        for p in 0..<copyPeriods {
            for d in 0..<copyDays {
                dst[p * newDays + d] = old[p * oldDays + d]
            }
        }
        return dst
    }
    
    private func loadBannerIfNeeded() {
        //print("safeWidth=", view.safeAreaLayoutGuide.layoutFrame.width,
            //  "insets=", view.safeAreaInsets)

        guard let bv = bannerView else { return }

        // SafeArea を引いた現在の実幅
        let safeWidth = view.safeAreaLayoutGuide.layoutFrame.width
        if safeWidth <= 0 { return }

        // 広告の最小幅を担保して丸める
        let useWidth = max(320, floor(safeWidth))
        // ✅ 幅が前回と同じなら何もしない（ループ防止）
        if abs(useWidth - lastBannerWidth) < 0.5 { return }
        lastBannerWidth = useWidth

        // サイズ更新 → 初回だけロード
        let size = makeAdaptiveAdSize(width: useWidth)
                
        // 2) ★ 先にコンテナの高さを確保して 0 を回避
        adContainerHeight?.constant = size.size.height
        updateInsetsForBanner(height: size.size.height)   // ← 重なり防止（任意）
        view.layoutIfNeeded()                             // ← ここ重要
        
        // ★ 高さ0は不正 → ロードしない
        guard size.size.height > 0 else {
            print("Skip load: invalid AdSize ->", size.size)
            return
        }
        // サイズを反映（同じサイズなら何もしない）
        if !CGSizeEqualToSize(bv.adSize.size, size.size) {
            bv.adSize = size
        }

        if !didLoadBannerOnce {
            didLoadBannerOnce = true
            bv.load(Request())
        }
        
        print("→ adSize set:", size.size)   // ← 高さが 50/90/250 などになるはず
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
        colGuides.removeAll()
        rowGuides.removeAll()

        buildGridGuides()
        placeHeaders()
        placePlusButtons()
        reloadAllButtons()
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
        let multiIcon: String
        if #available(iOS 16.0, *) {
            multiIcon = "point.3.connected.trianglepath.dotted"
        } else {
            multiIcon = "ellipsis.circle"
        }
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

        // Layout
        [leftButton, titleLabel, rightStack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        headerBar.isLayoutMarginsRelativeArrangement = true
        headerBar.layoutMargins = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        headerBar.setContentHuggingPriority(.required, for: .vertical)
        headerBar.setContentCompressionResistancePriority(.required, for: .vertical)

        let clamp = headerBar.heightAnchor.constraint(equalTo: titleLabel.heightAnchor, constant: 16)
        clamp.priority = .required
        clamp.isActive = true

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

        // --- ScrollView ----------------------------------------------------
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        // まずは safeArea.bottom へ。← この制約をプロパティに保持しておく
        scrollBottomConstraint?.isActive = false
        scrollBottomConstraint = scrollView.bottomAnchor.constraint(equalTo: g.bottomAnchor)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            scrollBottomConstraint!                               // ← ここだけ可変
        ])

        // --- contentView（スクロールの中身） -------------------------------
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])

        // --- gridContainer（実際のグリッド） -------------------------------
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
        // 列（時限 + 曜日）
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

        // 行（ヘッダ1 + 時限n）
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
        // 基準行に最小高さを与える（セルが伸びないための土台）
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
        v.axis = .vertical
        v.alignment = .center
        v.spacing = 2
        v.translatesAutoresizingMaskIntoConstraints = false

        let top = UILabel()
        top.font = .systemFont(ofSize: 11, weight: .regular)
        top.textColor = .secondaryLabel
        top.textAlignment = .center

        let mid = UILabel()
        mid.font = .systemFont(ofSize: 16, weight: .semibold)
        mid.textAlignment = .center
        mid.text = "\(period)"

        let bottom = UILabel()
        bottom.font = .systemFont(ofSize: 11, weight: .regular)
        bottom.textColor = .secondaryLabel
        bottom.textAlignment = .center

        if period-1 < timePairs.count {
            top.text    = timePairs[period-1].start
            bottom.text = timePairs[period-1].end
        } else {
            top.text = nil; bottom.text = nil
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
        cfg.background.cornerRadius = 5 //コマの丸さ調整
        cfg.background.backgroundInsets = .zero
        cfg.background.strokeColor = stroke
        cfg.background.strokeWidth = strokeWidth
        return cfg
    }

    private func configureButton(_ b: UIButton, at idx: Int) {
        // layer / background は使わない（Configuration に集約）
        b.backgroundColor = .clear
        b.layer.borderWidth = 0
        b.layer.cornerRadius = 0

        guard assigned.indices.contains(idx), let course = assigned[idx] else {
            // ＋セル：自前ビューは外す
            b.removeTimetableContentView()

            var cfg = baseCellConfig(bg: .secondarySystemBackground,
                                     fg: .tertiaryLabel,
                                     stroke: UIColor.separator, strokeWidth: 1)
            cfg.title = "＋"
            cfg.titleAlignment = .center
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { inAttr in
                var out = inAttr
                out.font = .systemFont(ofSize: 22, weight: .semibold)
                let p = NSMutableParagraphStyle(); p.alignment = .center
                out.paragraphStyle = p
                return out
            }
            b.configuration = cfg
            return
        }

        // 登録済みセル（背景は Configuration、文字は自前ビューで制御）
        let cols = dayLabels.count
        let row  = idx / cols
        let col  = idx % cols
        let loc  = SlotLocation(day: col, period: row + 1)
        let colorKey = SlotColorStore.color(for: loc) ?? .teal

        var cfg = baseCellConfig(bg: colorKey.uiColor, fg: .white)
        cfg.title = nil           // ←内部ラベルは使わない
        cfg.subtitle = nil
        b.configuration = cfg

        // 自前ビューに文字を設定（ここで折り返し・省略を完全管理）
        let content = b.ensureTimetableContentView()
        content.titleLabel.text = course.title
        content.roomLabel.text  = course.room
        content.titleLabel.textColor = .white
        content.roomLabel.textColor  = .white
    }


    private func reloadAllButtons() {
        for b in slotButtons { configureButton(b, at: b.tag) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadAllButtons()
    }

    private func placePlusButtons() {
        let rows = periodLabels.count
        let cols = dayLabels.count
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

    // MARK: - Course detail / select

    private func presentCourseDetail(_ course: Course, at loc: SlotLocation) {
        let vc = CourseDetailViewController(course: course, location: loc)
        vc.delegate = self
        vc.modalPresentationStyle = .pageSheet

        if let sheet = vc.sheetPresentationController {
            if #available(iOS 16.0, *) {
                let id = UISheetPresentationController.Detent.Identifier("ninetyTwo")
                sheet.detents = [
                    .custom(identifier: id) { ctx in ctx.maximumDetentValue * 0.92 },
                    .large()
                ]
                sheet.selectedDetentIdentifier = id
            } else {
                sheet.detents = [.large()]
                sheet.selectedDetentIdentifier = .large
            }
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 16
        }
        present(vc, animated: true)
    }

    // MARK: - Actions
    
    // MARK: - Share (screenshot + half sheet)

    /// 時間割（グリッド全体）を画像にする
    private func makeTimetableImage() -> UIImage {
        // レイアウトを最新化
        gridContainerView.layoutIfNeeded()

        // 画像化する対象はグリッド全体（曜日ヘッダ・時限マーカー含む）
        let targetView = gridContainerView
        let size = targetView.bounds.size

        // Retina解像度でレンダリング
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let image = renderer.image { ctx in
            // offscreenでも確実に描ける layer.render(in:) を使用
            targetView.layer.render(in: ctx.cgContext)
        }
        return image
    }

    /// 共有シートをハーフシートで出す
    private func shareCurrentTimetable() {
        let image = makeTimetableImage()

        let activityVC = UIActivityViewController(
            activityItems: [image],
            applicationActivities: nil
        )
        // ハーフシート（画面下から）の見た目にする
        if let sheet = activityVC.sheetPresentationController {
            if #available(iOS 16.0, *) {
                sheet.detents = [.medium(), .large()]
                sheet.selectedDetentIdentifier = .medium
            } else {
                // iOS15 は pageSheet相当の挙動。必要なら modalPresentationStyle を変えてもOK
            }
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 16
        }

        // iPad対策（ポップオーバー起点）
        if let pop = activityVC.popoverPresentationController {
            pop.sourceView = rightB
            pop.sourceRect = rightB.bounds
        }

        present(activityVC, animated: true)
    }
    // MARK: - Save to Photos

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
                        if s == .authorized || s == .limited {
                            self.performSaveToPhotos(image, completion: finish)
                        } else {
                            finish(false, nil)
                        }
                    }
                }
            case .authorized, .limited:
                performSaveToPhotos(image, completion: finish)
            default:
                finish(false, nil)
            }
        } else {
            let status = PHPhotoLibrary.authorizationStatus()
            if status == .notDetermined {
                PHPhotoLibrary.requestAuthorization { s in
                    DispatchQueue.main.async {
                        if s == .authorized {
                            self.performSaveToPhotos(image, completion: finish)
                        } else {
                            finish(false, nil)
                        }
                    }
                }
            } else if status == .authorized {
                performSaveToPhotos(image, completion: finish)
            } else {
                finish(false, nil)
            }
        }
    }

    private func performSaveToPhotos(_ image: UIImage, completion: @escaping (Bool, Error?) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }) { ok, err in
            DispatchQueue.main.async { completion(ok, err) }
        }
    }



    @objc private func tapLeft() {
        // 年度候補（必要に応じて増やしてください）
        let thisYear = Calendar.current.component(.year, from: Date())
        let years = Array(((thisYear - 4)...(thisYear + 1)).reversed())  // ← [Int]　// 直近5年＋来年

        // ピッカーの入った下からのシート
        let vc = TermPickerViewController(years: years,
                                          selected: currentTerm) { [weak self] picked in
            guard let self = self, let picked = picked else { return }
            self.changeTerm(to: picked)
        }
        if let sheet = vc.sheetPresentationController {
            if #available(iOS 16.0, *) {
                let ds: [UISheetPresentationController.Detent] = [.medium(), .large()]
                sheet.detents = ds
            } else {
                sheet.detents = [UISheetPresentationController.Detent.medium()]
            }
            sheet.prefersGrabberVisible = true
        }

        present(vc, animated: true)
    }
    
    
    
    private func changeTerm(to newTerm: TermKey) {
        guard newTerm != currentTerm else { return }
        currentTerm = newTerm
        leftButton.setTitle(newTerm.displayTitle, for: .normal)
        loadAssigned(for: newTerm)
        reloadAllButtons()
        saveAssigned() // 選択学期記憶
    }

    @objc private func tapRightA() {
        let term = TermStore.loadSelected()                  // いま表示中の学期

        // ✅ 余計な引数は渡さない
        let vc = CreditsFullViewController(currentTerm: term)

        let nav = UINavigationController(rootViewController: vc)
        // ✅ 明示的に書くと安全（.fullScreen でもOK）
        nav.modalPresentationStyle = UIModalPresentationStyle.fullScreen

        present(nav, animated: true)
    }


    @objc private func tapRightB() {
        let action = UIAlertController(title: "時間割を保存 / 共有", message: nil, preferredStyle: .actionSheet)
        action.addAction(UIAlertAction(title: "写真に保存", style: .default) { [weak self] _ in
            self?.saveCurrentTimetableToPhotos()
        })
        action.addAction(UIAlertAction(title: "共有…", style: .default) { [weak self] _ in
            self?.shareCurrentTimetable()   // ← 既に実装済みの共有へ
        })
        action.addAction(UIAlertAction(title: "キャンセル", style: .cancel))

        // iPad対策（ポップオーバーの起点）
        if let pop = action.popoverPresentationController {
            pop.sourceView = rightB
            pop.sourceRect = rightB.bounds
        }
        present(action, animated: true)
    }


    @objc private func tapRightC() {
        let vc = TimetableSettingsViewController()
        if let nav = navigationController {
            nav.pushViewController(vc, animated: true)
        } else {
            let nav = UINavigationController(rootViewController: vc)
            present(nav, animated: true)
        }
    }

    @objc private func slotTapped(_ sender: UIButton) {
        let cols = dayLabels.count
        let idx  = sender.tag
        let row  = sender.tag / cols
        let col  = sender.tag % cols

        let loc = SlotLocation(day: col, period: row + 1)

        if let course = assigned[idx] {
            presentCourseDetail(course, at: loc)
            return
        }

        let listVC = CourseListViewController(location: loc)
        listVC.delegate = self

        if let nav = navigationController {
            nav.pushViewController(listVC, animated: true)
        } else {
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

        if let btn = slotButtons.first(where: { $0.tag == idx }) {
            configureButton(btn, at: idx)
        } else {
            reloadAllButtons()
        }
        saveAssigned()

        if let nav = vc.navigationController {
            if nav.viewControllers.first === vc { vc.dismiss(animated: true) }
            else { nav.popViewController(animated: true) }
        } else {
            vc.dismiss(animated: true)
        }
    }

    // MARK: - CourseDetail delegate

    func courseDetail(_ vc: CourseDetailViewController, didChangeColor key: SlotColorKey, at location: SlotLocation) {
        SlotColorStore.set(key, for: location)
        let idx = gridIndex(for: location)
        if (0..<slotButtons.count).contains(idx) {
            configureButton(slotButtons[idx], at: idx)
        } else {
            rebuildGrid()
        }
    }

    func courseDetail(_ vc: CourseDetailViewController, requestEditFor course: Course, at location: SlotLocation) {
        vc.dismiss(animated: true) {
            let listVC = CourseListViewController(location: location)
            listVC.delegate = self
            if let nav = self.navigationController {
                nav.pushViewController(listVC, animated: true)
            } else {
                let nav = UINavigationController(rootViewController: listVC)
                nav.modalPresentationStyle = .fullScreen
                self.present(nav, animated: true)
            }
        }
    }

    func courseDetail(_ vc: CourseDetailViewController, requestDelete course: Course, at location: SlotLocation) {
        let idx = (location.period - 1) * self.dayLabels.count + location.day
        self.assigned[idx] = nil
        if let btn = self.slotButtons.first(where: { $0.tag == idx }) {
            self.configureButton(btn, at: idx)
        } else {
            self.reloadAllButtons()
        }
        vc.dismiss(animated: true)
        saveAssigned()
    }

    func courseDetail(_ vc: CourseDetailViewController, didUpdate counts: AttendanceCounts, for course: Course, at location: SlotLocation) {
        // 将来サーバ保存などあればここで
    }

    func courseDetail(_ vc: CourseDetailViewController, didDeleteAt location: SlotLocation) {
        assigned[index(for: location)] = nil
        reloadAllButtons()
        saveAssigned()
    }

    func courseDetail(_ vc: CourseDetailViewController, didEdit course: Course, at location: SlotLocation) {
        assigned[index(for: location)] = course
        reloadAllButtons()
        saveAssigned()
    }

    // MARK: - Helpers

    private func index(for loc: SlotLocation) -> Int {
        (loc.period - 1) * dayLabels.count + loc.day
    }

    // 同じ登録番号のコマを重複カウントしない
    private func uniqueCoursesInAssigned() -> [Course] {
        var seen = Set<String>()
        var out: [Course] = []
        for c in assigned.compactMap({ $0 }) {
            let key = (c.id.isEmpty ? "" : c.id) + "#" + c.title
            if seen.insert(key).inserted { out.append(c) }
        }
        return out
    }
}



// MARK: - 専用ボタンクラス（ラベルの行数と省略・CJK 改行を毎回強制）
// MARK: - timetable コマ内専用ボタン（3行までで末尾のみ「…」）

final class TimetableCellButton: UIButton {

    /// タイトルは最大 5行、教室は 1 行だけ
    var titleMaxLines: Int = 5
    var subtitleMaxLines: Int = 2

    override func layoutSubviews() {
        super.layoutSubviews()

        // configuration にも「折り返し可」を指示（ここが重要）
        if #available(iOS 15.0, *) {
            if configuration?.titleLineBreakMode != .byWordWrapping {
                configuration?.titleLineBreakMode = .byWordWrapping
            }
            if configuration?.subtitleLineBreakMode != .byTruncatingTail {
                configuration?.subtitleLineBreakMode = .byTruncatingTail
            }
        }

        // 内部 UILabel を取得
        let labels = allSubviews.compactMap { $0 as? UILabel }
        guard !labels.isEmpty else { return }

        // 大きいフォント＝タイトル想定
        let sorted = labels.sorted { $0.font.pointSize > $1.font.pointSize }
        let contentW = max(0,
                           bounds.width
                           - (configuration?.contentInsets.leading ?? 10)
                           - (configuration?.contentInsets.trailing ?? 10))

        // タイトル
        if let title = sorted.first {
            title.numberOfLines = titleMaxLines
            title.textAlignment = .center
            // 折り返しを許可しつつ、上限超え時のみ末尾省略
            title.lineBreakMode = .byTruncatingTail
            if #available(iOS 15.0, *) { title.lineBreakStrategy = .hangulWordPriority } // CJK向け
            title.preferredMaxLayoutWidth = contentW
            title.setContentHuggingPriority(.defaultLow, for: .vertical)
            title.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }

        // サブタイトル（教室など）
        for sub in sorted.dropFirst() {
            sub.numberOfLines = subtitleMaxLines
            sub.textAlignment = .center
            sub.lineBreakMode = .byTruncatingTail
            if #available(iOS 15.0, *) { sub.lineBreakStrategy = .hangulWordPriority }
            sub.preferredMaxLayoutWidth = contentW
            sub.setContentHuggingPriority(.defaultLow, for: .vertical)
            sub.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }
    }
}

private extension UIView {
    var allSubviews: [UIView] { subviews + subviews.flatMap { $0.allSubviews } }
}


// MARK: - TimetableCellContentView（コマ内のタイトル/教室を自前で描画）

final class TimetableCellContentView: UIView {
    let titleLabel = UILabel()
    let roomLabel  = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        // ★ これを追加：表示専用にしてタッチはボタンへ
        isUserInteractionEnabled = false

        let v = UIStackView(arrangedSubviews: [titleLabel, roomLabel])
        v.axis = .vertical
        v.alignment = .center
        v.spacing = 4
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
    /// 既に入っている自前ビューを取得 or 生成
    func ensureTimetableContentView() -> TimetableCellContentView {
        let tag = 987654
        if let v = viewWithTag(tag) as? TimetableCellContentView { return v }
        let v = TimetableCellContentView()
        v.tag = tag
        v.translatesAutoresizingMaskIntoConstraints = false
        
        // ★ 念押し（どのみち init で無効化しているが保険）
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

    /// 自前ビューを外す（「＋」セル用）
    func removeTimetableContentView() {
        viewWithTag(987654)?.removeFromSuperview()
    }
}

// MARK: - 学期ピッカー（年度＋前期/後期）
final class TermPickerViewController: UIViewController, UIPickerViewDataSource, UIPickerViewDelegate {

    private let years: [Int]
    private var selectedYear: Int
    private var selectedSemester: Semester
    private let onDone: (TermKey?) -> Void

    private let picker = UIPickerView()
    private let toolbar = UIToolbar()

    init(years: [Int], selected: TermKey, onDone: @escaping (TermKey?) -> Void) {
        self.years = years
        self.selectedYear = selected.year
        self.selectedSemester = selected.semester
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // Toolbar
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        let cancel = UIBarButtonItem(title: "キャンセル", style: .plain, target: self, action: #selector(cancelTap))
        let flex = UIBarButtonItem(systemItem: .flexibleSpace)
        let done = UIBarButtonItem(title: "完了", style: .done, target: self, action: #selector(doneTap))
        toolbar.items = [cancel, flex, done]
        view.addSubview(toolbar)

        // Picker
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.dataSource = self
        picker.delegate = self
        view.addSubview(picker)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            picker.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            picker.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            picker.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])

        // 初期選択
        if let yi = years.firstIndex(of: selectedYear) {
            picker.selectRow(yi, inComponent: 0, animated: false)
        }
        if let si = Semester.allCases.firstIndex(of: selectedSemester) {
            picker.selectRow(si, inComponent: 1, animated: false)
        }
    }

    @objc private func cancelTap() { onDone(nil); dismiss(animated: true) }
    @objc private func doneTap() {
        onDone(TermKey(year: selectedYear, semester: selectedSemester))
        dismiss(animated: true)
    }

    // MARK: Picker
    func numberOfComponents(in pickerView: UIPickerView) -> Int { 2 }
    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        component == 0 ? years.count : Semester.allCases.count
    }
    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        if component == 0 { return "\(years[row])年" }
        return Semester.allCases[row].display
    }
    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        if component == 0 { selectedYear = years[row] }
        else { selectedSemester = Semester.allCases[row] }
    }
}
