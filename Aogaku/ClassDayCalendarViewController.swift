// ClassDayCalendarViewController.swift — 全文置換

import UIKit
import GoogleMobileAds

final class ClassDayCalendarViewController: UIViewController,
                                            UICollectionViewDataSource,
                                            UICollectionViewDelegate,
                                            BannerViewDelegate {

    // MARK: - Model
    private let model = AcademicCalendar2025()
    private var campus: Campus = .aoyama

    // 表示許可する“月”の範囲（2025/4〜2026/3）
    private let allowedStartMonth = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: 2025, month: 4, day: 1))!
    private let allowedEndMonth   = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: 2026, month: 3, day: 1))!

    private var currentMonth: Date = Date()
    private var grid: [Date] = []

    private let cal = Calendar(identifier: .gregorian)
    private let tz = TimeZone(identifier: "Asia/Tokyo")!

    // UserDefaults
    private let lastCampusKey = "ClassDayCalendar.lastCampus"

    // MARK: - UI
    private var collectionView: UICollectionView!

    // 上部（年月・キャンパス・曜日）
    private let monthLabel = UILabel()
    private let campusControl = UISegmentedControl(items: ["青山", "相模原"])
    private let weekdayStack = UIStackView()

    // カレンダー直下ヒント
    private let hintLabel = UILabel()

    // 下部（凡例＆注意書き）
    private let legendColumn = UIStackView()
    private let disclaimerLabel = UILabel()
    private let notAvailableLabel = UILabel()

    // MARK: - AdMob (Banner)
    private let adContainer = UIView()
    private var bannerView: BannerView?
    private var lastBannerWidth: CGFloat = 0
    private var adContainerHeight: NSLayoutConstraint?
    private var didLoadBannerOnce = false

    @inline(__always)
    private func makeAdaptiveAdSize(width: CGFloat) -> AdSize {
        return currentOrientationAnchoredAdaptiveBanner(width: width)
    }

    // MARK: - LifeCycle
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = "学事暦"

        setupTopArea()
        setupCollection()
        setupBottomArea()
        setupAdBanner()
        applyCalendarBackground()
        NotificationCenter.default.addObserver(self,
            selector: #selector(onAdMobReady),
            name: .adMobReady, object: nil)
        addSwipeGestures()

        // 前回のキャンパス選択を復元
        let defaults = UserDefaults.standard
        if defaults.object(forKey: lastCampusKey) != nil {
            let saved = min(max(defaults.integer(forKey: lastCampusKey), 0), 1)
            campusControl.selectedSegmentIndex = saved
        }
        campus = (campusControl.selectedSegmentIndex == 0) ? .aoyama : .sagamihara

        setMonth(clampedToAllowed(firstDay(of: Date())))
        reload()
    }
    @objc private func onAdMobReady() {
        loadBannerIfNeeded()
    }


    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            // 7列×6行の真四角セル
            let cols: CGFloat = 7, rows: CGFloat = 6
            let cellW = collectionView.bounds.width / cols
            let cellH = collectionView.bounds.height / rows
            let side = floor(min(cellW, cellH))
            layout.itemSize = CGSize(width: side, height: side)
        }
        loadBannerIfNeeded()
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyCalendarBackground()
        }
    }
    
    // ClassDayCalendarViewController.swift （クラス内どこか上の方）
    private func calendarBGColor(for trait: UITraitCollection) -> UIColor {
        // ダーク時のみ薄いグレーに。ライトは従来のシステム背景を維持
        return (trait.userInterfaceStyle == .dark) ? .systemGray5 : .systemBackground
    }

    private func applyCalendarBackground() {
        let bg = calendarBGColor(for: traitCollection)
        view.backgroundColor = bg
        collectionView?.backgroundColor = bg
        adContainer.backgroundColor = bg
    }


    // MARK: - Top
    private func setupTopArea() {
        // 年月ラベル（中央）
        monthLabel.font = .boldSystemFont(ofSize: 20)
        monthLabel.textAlignment = .center
        view.addSubview(monthLabel)
        monthLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            monthLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            monthLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])

        // キャンパス切替（中央・ワイド）
        campusControl.selectedSegmentIndex = 0
        campusControl.addTarget(self, action: #selector(campusChanged), for: .valueChanged)
        view.addSubview(campusControl)
        campusControl.translatesAutoresizingMaskIntoConstraints = false
        let campusWidth = campusControl.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.7)
        campusWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            campusControl.topAnchor.constraint(equalTo: monthLabel.bottomAnchor, constant: 12),
            campusControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            campusWidth
        ])

        // 曜日ヘッダー（月〜日）
        weekdayStack.axis = .horizontal
        weekdayStack.distribution = .fillEqually
        weekdayStack.alignment = .center
        weekdayStack.spacing = 0
        ["月","火","水","木","金","土","日"].forEach { w in
            let l = UILabel()
            l.text = w
            l.font = .systemFont(ofSize: 13, weight: .semibold)
            l.textAlignment = .center
            l.textColor = .secondaryLabel
            weekdayStack.addArrangedSubview(l)
        }
        view.addSubview(weekdayStack)
        weekdayStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            weekdayStack.topAnchor.constraint(equalTo: campusControl.bottomAnchor, constant: 12),
            weekdayStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            weekdayStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            weekdayStack.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    // MARK: - Collection
    private func setupCollection() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = .zero

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = calendarBGColor(for: traitCollection)
        collectionView.contentInset = .zero
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(DayCell.self, forCellWithReuseIdentifier: "DayCell")

        view.addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: weekdayStack.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        // 高さ＝幅×(6/7) でカレンダー直下の余白を詰める
        collectionView.heightAnchor.constraint(equalTo: collectionView.widthAnchor, multiplier: 6.0/7.0).isActive = true

        // 範囲外案内
        notAvailableLabel.text = "この期間のカレンダーは表示できません（2025年4月〜2026年3月）"
        notAvailableLabel.font = .systemFont(ofSize: 15)
        notAvailableLabel.textAlignment = .center
        notAvailableLabel.textColor = .secondaryLabel
        notAvailableLabel.numberOfLines = 0
        notAvailableLabel.isHidden = true
        view.addSubview(notAvailableLabel)
        notAvailableLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            notAvailableLabel.topAnchor.constraint(equalTo: weekdayStack.bottomAnchor, constant: 32),
            notAvailableLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            notAvailableLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])

        // カレンダー直下ヒント（より近く）
        hintLabel.text = "タップすると授業の有無と第何週目かが表示されます"
        hintLabel.font = .systemFont(ofSize: 14, weight: .medium)
        hintLabel.textColor = .secondaryLabel
        hintLabel.textAlignment = .center
        view.addSubview(hintLabel)
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
    }
    
    // MARK: - Week Counter (Autumn 2025)
    private func autumnWeekNumber(for date: Date, campus: Campus) -> Int? {
        // 後期の定義：開始 2025-09-19（金）／終了 2026-01-26（試験開始前日想定）
        guard
            let termStart = cal.date(from: DateComponents(timeZone: tz, year: 2025, month: 9, day: 19)),
            let termEnd   = cal.date(from: DateComponents(timeZone: tz, year: 2026, month: 1, day: 26))
        else { return nil }

        // 後期範囲外は表示しない
        if date < termStart || date > termEnd { return nil }

        // 日曜はカウント対象外
        let targetWeekday = cal.component(.weekday, from: date) // Sun=1 ... Sat=7
        if targetWeekday == 1 { return nil }

        // 開始日以降で「同じ曜日」の最初の出現日を求める
        // （開始日が同曜日ならその日、違えば次の同曜日）
        let firstHit = cal.nextDate(
            after: termStart.addingTimeInterval(-1),
            matching: DateComponents(weekday: targetWeekday),
            matchingPolicy: .nextTime,
            direction: .forward
        ) ?? termStart

        // 同曜日ごとに7日刻みで進め、classDay のみカウント
        var count = 0
        var cursor = firstHit
        while cursor <= date {
            if model.category(of: cursor, campus: campus) == .classDay {
                count += 1
            }
            guard let next = cal.date(byAdding: .day, value: 7, to: cursor) else { break }
            cursor = next
        }

        // まだ一度も授業が実施されていない曜日の日付（例：9/23(火)が休講のため）
        // は「第0週目」にならないよう、非表示にする
        return (count > 0) ? count : nil
    }

    private func autumnWeekSuffix(for date: Date) -> String {
        if let n = autumnWeekNumber(for: date, campus: campus) {
            return "【第\(n)週目】"
        } else {
            return ""
        }
    }

    // MARK: - Bottom (Legend, Disclaimer, Ad)
    private func setupBottomArea() {
        legendColumn.axis = .vertical
        legendColumn.alignment = .fill
        legendColumn.spacing = 16 // 段間余裕

        // 1段目
        let row1 = UIStackView()
        row1.axis = .horizontal
        row1.alignment = .center
        row1.spacing = 24
        row1.distribution = .fillProportionally
        row1.addArrangedSubview(legendSwatch(color: UIColor.systemBlue.withAlphaComponent(0.28), text: "授業日"))
        row1.addArrangedSubview(legendSwatch(color: UIColor.systemYellow.withAlphaComponent(0.28), text: "休講日"))
        row1.addArrangedSubview(legendUnderline(color: UIColor.systemGreen, text: "補講日"))

        // 2段目（長期休業は統一色）
        let row2 = UIStackView()
        row2.axis = .horizontal
        row2.alignment = .center
        row2.spacing = 24
        row2.distribution = .fillProportionally
        row2.addArrangedSubview(legendSwatch(color: UIColor.systemPurple.withAlphaComponent(0.22), text: "試験期間"))
        row2.addArrangedSubview(legendSwatch(color: UIColor.systemTeal.withAlphaComponent(0.22), text: "長期休業"))
        row2.addArrangedSubview(legendDot(color: .systemRed, text: "今日"))

        legendColumn.addArrangedSubview(row1)
        legendColumn.addArrangedSubview(row2)
        legendColumn.setCustomSpacing(8, after: row1) // 2段目を1段目から8ptだけ離す

        view.addSubview(legendColumn)
        legendColumn.translatesAutoresizingMaskIntoConstraints = false

        // 注意書き（バナーの“上”に移動）
        disclaimerLabel.text = "※こちらのカレンダーは学事暦および指定の分類に基づいていますが、必ずしも授業実施日を保証するものではありません。"
        disclaimerLabel.font = .systemFont(ofSize: 10)
        disclaimerLabel.textColor = .secondaryLabel
        disclaimerLabel.numberOfLines = 0
        view.addSubview(disclaimerLabel)
        disclaimerLabel.translatesAutoresizingMaskIntoConstraints = false

        // 先にヒント・凡例までを配置
        NSLayoutConstraint.activate([
            hintLabel.topAnchor.constraint(equalTo: collectionView.bottomAnchor, constant: 12),
            hintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            legendColumn.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 12),
            legendColumn.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            legendColumn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])

        // adContainer は最下部（setupAdBanner() で制約を完了）
        // 注意書きはバナーの直上
        NSLayoutConstraint.activate([
            disclaimerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            disclaimerLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
    }

    private func legendSwatch(color: UIColor, text: String) -> UIStackView {
        let swatch = UIView()
        swatch.backgroundColor = color
        swatch.layer.cornerRadius = 6
        swatch.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            swatch.widthAnchor.constraint(equalToConstant: 24),
            swatch.heightAnchor.constraint(equalToConstant: 16),
        ])
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 14)
        let stack = UIStackView(arrangedSubviews: [swatch, label])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        return stack
    }

    private func legendUnderline(color: UIColor, text: String) -> UIStackView {
        let container = UIView()
        let underline = UIView()
        underline.backgroundColor = color
        underline.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(underline)
        NSLayoutConstraint.activate([
            underline.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            underline.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            underline.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            underline.heightAnchor.constraint(equalToConstant: 2),
            container.widthAnchor.constraint(equalToConstant: 24),
            container.heightAnchor.constraint(equalToConstant: 16)
        ])
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 14)
        let stack = UIStackView(arrangedSubviews: [container, label])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        return stack
    }

    private func legendDot(color: UIColor, text: String) -> UIStackView {
        let dot = UIView()
        dot.backgroundColor = color
        dot.layer.cornerRadius = 7
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 14),
            dot.heightAnchor.constraint(equalToConstant: 14),
        ])
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 14)
        let stack = UIStackView(arrangedSubviews: [dot, label])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        return stack
    }

    // MARK: - Ad setup
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

        // 注意書きの“下端”はバナーの“上端”に吸着
        disclaimerLabel.bottomAnchor.constraint(equalTo: adContainer.topAnchor, constant: -8).isActive = true

        
        // RCで広告を止めているときはUIも消す
          guard AdsConfig.enabled else {
              adContainer.isHidden = true
              adContainerHeight?.constant = 0
              return
      }
        // バナー本体
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

    private func loadBannerIfNeeded() {
        guard let bv = bannerView else { return }
        let safeWidth = view.safeAreaLayoutGuide.layoutFrame.width
        if safeWidth <= 0 { return }

        let useWidth = max(320, floor(safeWidth))
        if abs(useWidth - lastBannerWidth) < 0.5 { return }
        lastBannerWidth = useWidth

        let size = makeAdaptiveAdSize(width: useWidth)
        adContainerHeight?.constant = size.size.height
        view.layoutIfNeeded()

        guard size.size.height > 0 else { return }
        if !CGSizeEqualToSize(bv.adSize.size, size.size) { bv.adSize = size }
        if !didLoadBannerOnce { didLoadBannerOnce = true; bv.load(Request()) }
    }

    // MARK: - BannerViewDelegate
    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        let h = bannerView.adSize.size.height
        adContainerHeight?.constant = h
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
    }

    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        adContainerHeight?.constant = 0
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
        print("Ad failed:", error.localizedDescription)
    }

    // MARK: - Swipe & animation
    private func addSwipeGestures() {
        let left = UISwipeGestureRecognizer(target: self, action: #selector(didSwipeLeft))
        left.direction = .left
        let right = UISwipeGestureRecognizer(target: self, action: #selector(didSwipeRight))
        right.direction = .right
        collectionView.addGestureRecognizer(left)
        collectionView.addGestureRecognizer(right)
    }
    @objc private func didSwipeLeft()  { changeMonth(by: +1, animatedFrom: .fromRight) }
    @objc private func didSwipeRight() { changeMonth(by: -1, animatedFrom: .fromLeft) }

    private func changeMonth(by delta: Int, animatedFrom subtype: CATransitionSubtype) {
        guard let next = cal.date(byAdding: .month, value: delta, to: currentMonth) else { return }
        let target = firstDay(of: next)
        if !isAllowedMonth(target) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }
        let t = CATransition()
        t.type = .push
        t.subtype = subtype
        t.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        t.duration = 0.25
        collectionView.layer.add(t, forKey: "monthSlide")
        monthLabel.layer.add(t, forKey: "monthSlideLabel")
        setMonth(target)
        reload()
    }

    // MARK: - Month helpers
    private func firstDay(of date: Date) -> Date {
        let c = cal.dateComponents(in: tz, from: date)
        return cal.date(from: DateComponents(timeZone: tz, year: c.year, month: c.month, day: 1))!
    }
    private func isAllowedMonth(_ monthFirst: Date) -> Bool {
        return monthFirst >= allowedStartMonth && monthFirst <= allowedEndMonth
    }
    private func clampedToAllowed(_ monthFirst: Date) -> Date {
        if monthFirst < allowedStartMonth { return allowedStartMonth }
        if monthFirst > allowedEndMonth { return allowedEndMonth }
        return monthFirst
    }

    private func setMonth(_ monthFirst: Date) {
        currentMonth = monthFirst
        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.timeZone = tz
        df.dateFormat = "yyyy年M月"
        monthLabel.text = df.string(from: currentMonth)
        grid = model.gridDays(for: currentMonth)

        let allowed = isAllowedMonth(currentMonth)
        collectionView.isHidden = !allowed
        weekdayStack.isHidden = !allowed
        hintLabel.isHidden = !allowed
        legendColumn.isHidden = !allowed
        disclaimerLabel.isHidden = !allowed
        notAvailableLabel.isHidden = allowed
    }

    private func reload() { collectionView.reloadData() }

    // MARK: - Actions
    @objc private func campusChanged() {
        campus = (campusControl.selectedSegmentIndex == 0) ? .aoyama : .sagamihara
        UserDefaults.standard.set(campusControl.selectedSegmentIndex, forKey: lastCampusKey)
        reload()
    }

    // MARK: - DataSource
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { grid.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let date = grid[indexPath.item]
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "DayCell", for: indexPath) as! DayCell

        let comps = cal.dateComponents(in: tz, from: date)
        cell.dayLabel.text = "\(comps.day!)"

        // 2026/4/1〜4/5 は非表示（3月カレンダー末尾に出る先取りセルを隠す）
        cell.isHidden = (comps.year == 2026 && comps.month == 4 && (1...5).contains(comps.day ?? 0))

        let curMonth = cal.component(.month, from: currentMonth)
        let isCurrentMonth = (comps.month == curMonth)

        let category = model.category(of: date, campus: campus)
        let isToday = cal.isDateInToday(date)

        cell.configure(category: category, isCurrentMonth: isCurrentMonth, isToday: isToday)
        return cell
    }

    // MARK: - Delegate（タップ → 分類に沿ったアラート）＋祝日名プレフィックス
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let date = grid[indexPath.item]
        let category = model.category(of: date, campus: campus)

        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.timeZone = tz
        df.dateFormat = "M月d日"

        var msg: String = {
            switch category {
            case .classDay:      return "授業実施日です"
            case .sunday:        return "日曜日のため授業実施日ではありません"
            case .kyuko:         return "休講日のため授業実施日ではありません"
            case .makeup:        return "補講日のため授業実施日ではありません"
            case .exam:          return "定期試験期間のため授業実施日ではありません"
            case .summerBreak, .winterBreak, .springBreak:
                                  return "長期休業期間のため授業実施日ではありません"
            }
        }()

        if let name = holidayName(for: date) {
            msg = "\(name)は" + msg   // 祝日名を文頭に
        }

        // ← ここを拡張：後期の週番号サフィックスを付ける
        let titleText = "\(df.string(from: date))\(autumnWeekSuffix(for: date))"

        let alert = UIAlertController(title: titleText, message: msg, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }


    // 指定の祝日（2025/4〜2026/3）：名前を返す
    private func holidayName(for date: Date) -> String? {
        let c = cal.dateComponents(in: tz, from: date)
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        switch (y, m, d) {
        case (2025, 4, 29): return "昭和の日"
        case (2025, 5, 3):  return "憲法記念日"
        case (2025, 5, 4):  return "みどりの日"
        case (2025, 5, 5):  return "こどもの日"
        case (2025, 7, 21): return "海の日"
        case (2025, 8, 11): return "山の日"
        case (2025, 9, 15): return "敬老の日"
        case (2025, 9, 23): return "秋分の日"
        case (2025,10, 13): return "スポーツの日"
        case (2025,11, 3): return "文化の日"
        case (2025,11, 23): return "勤労感謝の日"
        case (2026, 1, 1):  return "元日"
        case (2026, 1, 12): return "成人の日"
        case (2026, 2, 11): return "建国記念の日"
        case (2026, 2, 23): return "天皇誕生日"
        case (2026, 3, 20): return "春分の日"
        default: return nil
        }
    }
}

// MARK: - Cell
private final class DayCell: UICollectionViewCell {
    let dayLabel = UILabel()
    private let todayBadge = UIView()    // 今日：数字の背後に赤い“塗り”丸
    private let underlineView = UIView() // 補講日: 緑の下線

    // 長期休業の統一色
    private let unifiedBreakColor = UIColor.systemTeal.withAlphaComponent(0.22)

    override init(frame: CGRect) {
        super.init(frame: frame)

        // 真四角・隣接
        contentView.layer.cornerRadius = 0
        contentView.clipsToBounds = true

        // 1pxの白い枠線（Retina対応）
        contentView.layer.borderWidth = 1.0 / UIScreen.main.scale
        contentView.layer.borderColor = UIColor.white.cgColor

        dayLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        dayLabel.textAlignment = .center

        todayBadge.backgroundColor = .systemRed
        todayBadge.isHidden = true
        todayBadge.isUserInteractionEnabled = false
        todayBadge.layer.cornerRadius = 16 // 直径32pt

        underlineView.backgroundColor = .systemGreen
        underlineView.isHidden = true

        contentView.addSubview(todayBadge)
        contentView.addSubview(dayLabel)
        contentView.addSubview(underlineView)

        dayLabel.translatesAutoresizingMaskIntoConstraints = false
        todayBadge.translatesAutoresizingMaskIntoConstraints = false
        underlineView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            dayLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            dayLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            todayBadge.centerXAnchor.constraint(equalTo: dayLabel.centerXAnchor),
            todayBadge.centerYAnchor.constraint(equalTo: dayLabel.centerYAnchor),
            todayBadge.widthAnchor.constraint(equalToConstant: 32),
            todayBadge.heightAnchor.constraint(equalToConstant: 32),

            underlineView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            underlineView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            underlineView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            underlineView.heightAnchor.constraint(equalToConstant: 2)
        ])
        contentView.sendSubviewToBack(todayBadge)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(category: DayCategory, isCurrentMonth: Bool, isToday: Bool) {
        // 背景色 & 文字色
        switch category {
        case .classDay:
            contentView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.28)
            dayLabel.textColor = .white
            underlineView.isHidden = true

        case .kyuko:
            contentView.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.28)
            dayLabel.textColor = isCurrentMonth ? UIColor.label : UIColor.secondaryLabel
            underlineView.isHidden = true

        case .makeup:
            contentView.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.18)
            dayLabel.textColor = isCurrentMonth ? UIColor.label : UIColor.secondaryLabel
            underlineView.isHidden = false    // 緑の下線で補講日を強調

        case .exam:
            contentView.backgroundColor = UIColor.systemPurple.withAlphaComponent(0.22)
            dayLabel.textColor = .white
            underlineView.isHidden = true

        case .summerBreak, .winterBreak, .springBreak:
            contentView.backgroundColor = unifiedBreakColor // 統一色
            dayLabel.textColor = .white
            underlineView.isHidden = true

        case .sunday:
            contentView.backgroundColor = UIColor.systemGray6
            dayLabel.textColor = UIColor.secondaryLabel
            underlineView.isHidden = true
        }

        // 今日バッジ（数字の背後に赤い塗り丸）
        todayBadge.isHidden = !isToday
        if isToday { dayLabel.textColor = .white }
    }
}
