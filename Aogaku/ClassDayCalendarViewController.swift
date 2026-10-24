// ClassDayCalendarViewController.swift — 全文置換

import UIKit
import GoogleMobileAds

/// 学事暦。Appleのカレンダーのように、月が縦に並んで、上下にスクロールする。
final class ClassDayCalendarViewController: UIViewController,
                                            UICollectionViewDataSource,
                                            UICollectionViewDelegateFlowLayout,
                                            BannerViewDelegate {

    // MARK: - Model
    private let model = AcademicCalendarRouter()
    private var campus: Campus = .aoyama

    // 表示許可する“月”の範囲（2025/4〜2027/3）
    private let allowedStartMonth = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: 2025, month: 4, day: 1))!
    private let allowedEndMonth   = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: 2027, month: 3, day: 1))!

    private var months: [Date] = []          // 各月の1日(日本時間)
    private var didScrollToToday = false

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }()
    private let tz = TimeZone(identifier: "Asia/Tokyo")!

    // UserDefaults
    private let lastCampusKey = "ClassDayCalendar.lastCampus"

    // MARK: - UI
    private var collectionView: UICollectionView!
    private let campusControl = UISegmentedControl(items: ["青山", "相模原"])
    private let weekdayStack = UIStackView()
    private let legendColumn = UIStackView()
    private let legendBackground = UIView()
    private let yearOverview = YearOverviewView()
    private var isShowingYearOverview = false
    private let disclaimerLabel = UILabel()

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

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "学事暦"
        view.backgroundColor = .systemBackground

        // 左上の × ボタン（push/present どちらでも正しく閉じる）
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(closeTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "今日", style: .plain, target: self, action: #selector(todayTapped))

        // 月の一覧
        var month = allowedStartMonth
        while month <= allowedEndMonth {
            months.append(month)
            month = cal.date(byAdding: .month, value: 1, to: month)!
        }

        // 前回のキャンパス選択を復元
        let defaults = UserDefaults.standard
        if defaults.object(forKey: lastCampusKey) != nil {
            campusControl.selectedSegmentIndex = min(max(defaults.integer(forKey: lastCampusKey), 0), 1)
        }
        campus = (campusControl.selectedSegmentIndex == 0) ? .aoyama : .sagamihara

        setupTopArea()
        setupCollection()
        setupBottomArea()
        setupYearOverview()
        setupAdBanner()
        NotificationCenter.default.addObserver(self, selector: #selector(onAdMobReady), name: .adMobReady, object: nil)
    }

    @objc private func closeTapped() {
        if let nav = navigationController, nav.viewControllers.first !== self {
            nav.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    @objc private func onAdMobReady() { loadBannerIfNeeded() }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        collectionView.collectionViewLayout.invalidateLayout()
        if !didScrollToToday, collectionView.bounds.width > 0 {
            didScrollToToday = true
            scrollToToday(animated: false)
        }
        loadBannerIfNeeded()
    }

    @objc private func todayTapped() {
        if isShowingYearOverview { yearOverview.scrollToYear(of: Date(), animated: true) } else { scrollToToday(animated: true) }
    }

    private func scrollToToday(animated: Bool) {
        let today = cal.startOfDay(for: Date())
        let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: today))!
        let index = months.firstIndex(of: thisMonth) ?? (thisMonth < allowedStartMonth ? 0 : months.count - 1)
        collectionView.layoutIfNeeded()
        guard let attrs = collectionView.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: index)) else { return }
        collectionView.setContentOffset(CGPoint(x: 0, y: max(0, attrs.frame.minY - 4)), animated: animated)
    }

    // MARK: - Top
    private func setupTopArea() {
        // キャンパス切替
        campusControl.setTitleTextAttributes([.foregroundColor: UIColor.label], for: .normal)
        campusControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        campusControl.addTarget(self, action: #selector(campusChanged), for: .valueChanged)
        view.addSubview(campusControl)
        campusControl.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            campusControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            campusControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            campusControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])

        // 曜日ヘッダー（月〜日）。スクロールしても動かない。
        weekdayStack.axis = .horizontal
        weekdayStack.distribution = .fillEqually
        ["月","火","水","木","金","土","日"].enumerated().forEach { i, w in
            let l = UILabel()
            l.text = w
            l.font = .systemFont(ofSize: 12, weight: .medium)
            l.textAlignment = .center
            l.textColor = i == 6 ? .tertiaryLabel : .secondaryLabel
            weekdayStack.addArrangedSubview(l)
        }
        view.addSubview(weekdayStack)
        weekdayStack.translatesAutoresizingMaskIntoConstraints = false
        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)
        NSLayoutConstraint.activate([
            weekdayStack.topAnchor.constraint(equalTo: campusControl.bottomAnchor, constant: 12),
            weekdayStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            weekdayStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            weekdayStack.heightAnchor.constraint(equalToConstant: 20),
            separator.topAnchor.constraint(equalTo: weekdayStack.bottomAnchor, constant: 4),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale)
        ])
    }

    // MARK: - Collection
    private func setupCollection() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = UIEdgeInsets(top: 0, left: 0, bottom: 16, right: 0)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .systemBackground
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false
        collectionView.register(DayCell.self, forCellWithReuseIdentifier: "DayCell")
        collectionView.register(MonthHeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "MonthHeader")

        view.addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: weekdayStack.bottomAnchor, constant: 5),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func springWeekSuffix(for date: Date) -> String {
        if let n = springWeekNumber(for: date, campus: campus) {
            return "【第\(n)週目】"
        } else {
            return ""
        }
    }

    private func autumnWeekSuffix(for date: Date) -> String {
        if let n = autumnWeekNumber(for: date, campus: campus) {
            return "【第\(n)週目】"
        } else {
            return ""
        }
    }
    
    private func springWeekNumber(for date: Date, campus: Campus) -> Int? {
        // 2025前期 or 2026前期で期間を切り替え
        let c = cal.dateComponents(in: tz, from: date)
        guard let y = c.year else { return nil }

        let termStartEnd: (Date, Date)?
        if y == 2025 {
            // 前期：2025-04-07 ～ 2025-07-23（7/24から試験の想定）
            guard
                let s = cal.date(from: DateComponents(timeZone: tz, year: 2025, month: 4, day: 7)),
                let e = cal.date(from: DateComponents(timeZone: tz, year: 2025, month: 7, day: 23))
            else { return nil }
            termStartEnd = (s, e)
        } else if y == 2026 {
            // 前期：2026-04-06 ～ 2026-07-23（PDFより：前期授業開始4/6、補講日7/23）
            guard
                let s = cal.date(from: DateComponents(timeZone: tz, year: 2026, month: 4, day: 6)),
                let e = cal.date(from: DateComponents(timeZone: tz, year: 2026, month: 7, day: 23))
            else { return nil }
            termStartEnd = (s, e)
        } else {
            termStartEnd = nil
        }

        guard let (termStart, termEnd) = termStartEnd else { return nil }
        if date < termStart || date > termEnd { return nil }

        let targetWeekday = cal.component(.weekday, from: date) // Sun=1
        if targetWeekday == 1 { return nil }

        let firstHit = cal.nextDate(
            after: termStart.addingTimeInterval(-1),
            matching: DateComponents(weekday: targetWeekday),
            matchingPolicy: .nextTime,
            direction: .forward
        ) ?? termStart

        var count = 0
        var cursor = firstHit
        while cursor <= date {
            if model.category(of: cursor, campus: campus) == .classDay { count += 1 }
            guard let next = cal.date(byAdding: .day, value: 7, to: cursor) else { break }
            cursor = next
        }
        return (count > 0) ? count : nil
    }


    // MARK: - Bottom (Legend, Disclaimer, Ad)
    private func setupBottomArea() {
        legendColumn.axis = .vertical
        legendColumn.alignment = .center
        legendColumn.spacing = 8

        let row1 = UIStackView(arrangedSubviews: [
            legendCircle(fill: nil, ring: nil, dot: .systemBlue, text: "授業日"),
            legendCircle(fill: UIColor.systemYellow.withAlphaComponent(0.4), ring: nil, dot: nil, text: "休講日"),
            legendCircle(fill: nil, ring: .systemGreen, dot: nil, text: "補講日")
        ])
        let row2 = UIStackView(arrangedSubviews: [
            legendCircle(fill: UIColor.systemPurple.withAlphaComponent(0.28), ring: nil, dot: nil, text: "試験期間"),
            legendCircle(fill: UIColor.systemTeal.withAlphaComponent(0.28), ring: nil, dot: nil, text: "長期休業"),
            legendCircle(fill: .systemRed, ring: nil, dot: nil, text: "今日")
        ])
        [row1, row2].forEach { $0.axis = .horizontal; $0.spacing = 20; $0.alignment = .center; legendColumn.addArrangedSubview($0) }

        view.addSubview(legendColumn)
        legendColumn.translatesAutoresizingMaskIntoConstraints = false

        disclaimerLabel.text = "※こちらのカレンダーは学事暦および指定の分類に基づいていますが、必ずしも授業実施日を保証するものではありません。日付をタップすると、授業の有無と第何週目かが表示されます。"
        disclaimerLabel.font = .systemFont(ofSize: 10)
        disclaimerLabel.textColor = .tertiaryLabel
        disclaimerLabel.numberOfLines = 0
        view.addSubview(disclaimerLabel)
        disclaimerLabel.translatesAutoresizingMaskIntoConstraints = false

        let barBackground = legendBackground
        barBackground.backgroundColor = .secondarySystemBackground
        barBackground.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(barBackground, belowSubview: legendColumn)

        NSLayoutConstraint.activate([
            collectionView.bottomAnchor.constraint(equalTo: barBackground.topAnchor),
            barBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            barBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            barBackground.bottomAnchor.constraint(equalTo: view.bottomAnchor),   // 画面の一番下(ホームバーの所)まで、背景を広げる

            legendColumn.topAnchor.constraint(equalTo: barBackground.topAnchor, constant: 12),
            legendColumn.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            disclaimerLabel.topAnchor.constraint(equalTo: legendColumn.bottomAnchor, constant: 10),
            disclaimerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            disclaimerLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])
    }

    /// 凡例の1つ(日付の見た目と同じ印と、名前)。
    private func legendCircle(fill: UIColor?, ring: UIColor?, dot: UIColor?, text: String) -> UIStackView {
        let mark = UIView()
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.widthAnchor.constraint(equalToConstant: 18).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 18).isActive = true
        mark.layer.cornerRadius = 9
        mark.backgroundColor = fill
        if let ring { mark.layer.borderColor = ring.cgColor; mark.layer.borderWidth = 2 }
        if let dot {
            let d = UIView()
            d.backgroundColor = dot
            d.layer.cornerRadius = 3
            d.translatesAutoresizingMaskIntoConstraints = false
            mark.addSubview(d)
            NSLayoutConstraint.activate([
                d.widthAnchor.constraint(equalToConstant: 6), d.heightAnchor.constraint(equalToConstant: 6),
                d.centerXAnchor.constraint(equalTo: mark.centerXAnchor), d.centerYAnchor.constraint(equalTo: mark.centerYAnchor)
            ])
        }
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [mark, label])
        stack.spacing = 6
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

    // MARK: - 年の一覧(2本指でつまむと出る)
    private func setupYearOverview() {
        yearOverview.backgroundColor = .systemBackground
        yearOverview.alpha = 0
        yearOverview.isHidden = true
        view.addSubview(yearOverview)
        yearOverview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            yearOverview.topAnchor.constraint(equalTo: campusControl.bottomAnchor, constant: 8),
            yearOverview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            yearOverview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            yearOverview.bottomAnchor.constraint(equalTo: legendBackground.topAnchor)
        ])
        yearOverview.configure(months: months, calendar: cal, categoryOf: { [weak self] date in
            guard let self else { return .classDay }
            return self.model.category(of: date, campus: self.campus)
        })
        yearOverview.onSelect = { [weak self] monthFirst in self?.hideYearOverview(to: monthFirst) }

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        view.addGestureRecognizer(pinch)
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        guard g.state == .ended else { return }
        if !isShowingYearOverview, g.scale < 0.8 { showYearOverview() }
        else if isShowingYearOverview, g.scale > 1.25 { hideYearOverview(to: yearOverview.monthNearCenter()) }
    }

    private func showYearOverview() {
        guard !isShowingYearOverview else { return }
        isShowingYearOverview = true
        let visibleSection = collectionView.indexPathForItem(at: CGPoint(x: collectionView.bounds.midX, y: collectionView.contentOffset.y + collectionView.bounds.height / 3))?.section ?? 0
        yearOverview.refresh()
        yearOverview.isHidden = false
        yearOverview.layoutIfNeeded()
        yearOverview.scrollToYear(of: months[min(visibleSection, months.count - 1)], animated: false)
        yearOverview.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut, animations: {
            self.yearOverview.alpha = 1
            self.yearOverview.transform = .identity
            self.collectionView.alpha = 0
            self.collectionView.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        })
    }

    private func hideYearOverview(to monthFirst: Date?) {
        guard isShowingYearOverview else { return }
        isShowingYearOverview = false
        if let monthFirst, let index = months.firstIndex(of: monthFirst),
           let attrs = collectionView.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: index)) {
            collectionView.setContentOffset(CGPoint(x: 0, y: max(0, attrs.frame.minY - 4)), animated: false)
        }
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut, animations: {
            self.yearOverview.alpha = 0
            self.yearOverview.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
            self.collectionView.alpha = 1
            self.collectionView.transform = .identity
        }, completion: { _ in
            self.yearOverview.isHidden = true
            self.yearOverview.transform = .identity
        })
    }

    // MARK: - Actions
    @objc private func campusChanged() {
        campus = (campusControl.selectedSegmentIndex == 0) ? .aoyama : .sagamihara
        UserDefaults.standard.set(campusControl.selectedSegmentIndex, forKey: lastCampusKey)
        collectionView.reloadData()
        yearOverview.refresh()
    }

    // MARK: - 月・日付の計算
    /// 月曜はじまりで、その月の1日の前に空ける日数。
    private func leadingBlanks(of monthFirst: Date) -> Int {
        (cal.component(.weekday, from: monthFirst) + 5) % 7
    }

    private func daysIn(_ monthFirst: Date) -> Int {
        cal.range(of: .day, in: .month, for: monthFirst)?.count ?? 30
    }

    private func date(at indexPath: IndexPath) -> Date? {
        let monthFirst = months[indexPath.section]
        let day = indexPath.item - leadingBlanks(of: monthFirst) + 1
        guard day >= 1, day <= daysIn(monthFirst) else { return nil }
        return cal.date(byAdding: .day, value: day - 1, to: monthFirst)
    }

    // MARK: - DataSource
    func numberOfSections(in collectionView: UICollectionView) -> Int { months.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        leadingBlanks(of: months[section]) + daysIn(months[section])
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "DayCell", for: indexPath) as! DayCell
        guard let date = date(at: indexPath) else { cell.configureBlank(); return cell }
        let day = cal.component(.day, from: date)
        cell.configure(day: day, category: model.category(of: date, campus: campus), isToday: cal.isDateInToday(date))
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "MonthHeader", for: indexPath) as! MonthHeaderView
        let monthFirst = months[indexPath.section]
        let c = cal.dateComponents([.year, .month], from: monthFirst)
        let isCurrent = cal.isDate(monthFirst, equalTo: Date(), toGranularity: .month)
        header.configure(text: "\(c.year!)年\(c.month!)月", isCurrent: isCurrent, leadingBlanks: leadingBlanks(of: monthFirst))
        return header
    }

    // MARK: - FlowLayout
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: floor(collectionView.bounds.width / 7), height: 52)
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        CGSize(width: collectionView.bounds.width, height: 44)
    }

    // MARK: - Delegate（タップ → 分類に沿ったアラート）＋祝日名プレフィックス
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let date = date(at: indexPath) else { return }
        let category = model.category(of: date, campus: campus)

        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.timeZone = tz
        df.dateFormat = "M月d日"

        let msg: String = {
            // ✅ 祝日なら「祝日名＋理由」を必ず明記
            if let name = holidayName(for: date) {
                return holidayNote(for: name, category: category)
            }

            // 祝日でない通常日
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

        // ✅ 前期・後期どちらも第◯週を付ける（該当しない方は空文字）
        let titleText = "\(df.string(from: date))\(springWeekSuffix(for: date))\(autumnWeekSuffix(for: date))"

        let alert = UIAlertController(title: titleText, message: msg, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func autumnWeekNumber(for date: Date, campus: Campus) -> Int? {
        // 2025後期 or 2026後期で期間を切り替え
        let c = cal.dateComponents(in: tz, from: date)
        guard let y = c.year else { return nil }

        let termStartEnd: (Date, Date)?
        if y == 2025 || (y == 2026 && c.month == 1) {
            // 後期：2025-09-19 ～ 2026-01-26(前日まで想定)
            guard
                let s = cal.date(from: DateComponents(timeZone: tz, year: 2025, month: 9, day: 19)),
                let e = cal.date(from: DateComponents(timeZone: tz, year: 2026, month: 1, day: 25))
            else { return nil }
            termStartEnd = (s, e)
        } else if y == 2026 || (y == 2027 && c.month == 1) {
            // 後期：2026-09-14 ～ 2027-01-25（PDFより：後期授業開始9/14、試験開始1/26）
            guard
                let s = cal.date(from: DateComponents(timeZone: tz, year: 2026, month: 9, day: 14)),
                let e = cal.date(from: DateComponents(timeZone: tz, year: 2027, month: 1, day: 25))
            else { return nil }
            termStartEnd = (s, e)
        } else {
            termStartEnd = nil
        }

        guard let (termStart, termEnd) = termStartEnd else { return nil }

        if date < termStart || date > termEnd { return nil }
        let targetWeekday = cal.component(.weekday, from: date) // Sun=1
        if targetWeekday == 1 { return nil }

        let firstHit = cal.nextDate(
            after: termStart.addingTimeInterval(-1),
            matching: DateComponents(weekday: targetWeekday),
            matchingPolicy: .nextTime,
            direction: .forward
        ) ?? termStart

        var count = 0
        var cursor = firstHit
        while cursor <= date {
            if model.category(of: cursor, campus: campus) == .classDay { count += 1 }
            guard let next = cal.date(byAdding: .day, value: 7, to: cursor) else { break }
            cursor = next
        }
        return (count > 0) ? count : nil
    }

    private func holidayNote(for name: String, category: DayCategory) -> String {
        switch category {
        case .classDay:
            return "\(name)は授業実施日です"
        case .kyuko:
            return "\(name)のため休講日です"
        case .sunday:
            return "\(name)ですが日曜日です"
        case .makeup:
            return "\(name)ですが補講日です"
        case .exam:
            return "\(name)ですが定期試験期間です"
        case .summerBreak, .winterBreak, .springBreak:
            return "\(name)ですが長期休業期間です"
        }
    }

    // 指定の祝日（2025/4〜2026/3）：名前を返す
    private func holidayName(for date: Date) -> String? {
        let c = cal.dateComponents(in: tz, from: date)
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }

        switch (y, m, d) {

        // === 2025年度（既存） ===
        case (2025, 4, 29): return "昭和の日"
        case (2025, 5, 3):  return "憲法記念日"
        case (2025, 5, 4):  return "みどりの日"
        case (2025, 5, 5):  return "こどもの日"
        case (2025, 7, 21): return "海の日"
        case (2025, 8, 11): return "山の日"
        case (2025, 9, 15): return "敬老の日"
        case (2025, 9, 23): return "秋分の日"
        case (2025,10, 13): return "スポーツの日"
        case (2025,11, 3):  return "文化の日"
        case (2025,11, 23): return "勤労感謝の日"
        case (2026, 1, 1):  return "元日"
        case (2026, 1, 12): return "成人の日"
        case (2026, 2, 11): return "建国記念の日"
        case (2026, 2, 23): return "天皇誕生日"
        case (2026, 3, 20): return "春分の日"

        // === 2026年度（あなたが貼ってくれた一覧） ===
        case (2026, 4, 29): return "昭和の日"
        case (2026, 5, 3):  return "憲法記念日"
        case (2026, 5, 4):  return "みどりの日"
        case (2026, 5, 5):  return "こどもの日"
        case (2026, 5, 6):  return "振替休日"
        case (2026, 7, 20): return "海の日"
        case (2026, 8, 11): return "山の日"
        case (2026, 9, 21): return "敬老の日"
        case (2026, 9, 22): return "国民の休日"
        case (2026, 9, 23): return "秋分の日"
        case (2026,10, 12): return "スポーツの日"
        case (2026,11, 3):  return "文化の日"
        case (2026,11, 23): return "勤労感謝の日"

        case (2027, 1, 1):  return "元日"
        case (2027, 1, 11): return "成人の日"
        case (2027, 2, 11): return "建国記念の日"
        case (2027, 2, 23): return "天皇誕生日"
        case (2027, 3, 21): return "春分の日"
        case (2027, 3, 22): return "振替休日"

        default:
            return nil
        }
    }
}

// MARK: - Month header
private final class MonthHeaderView: UICollectionReusableView {
    private let label = UILabel()
    private let line = UIView()
    private var labelLeading: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 20, weight: .bold)
        line.backgroundColor = .separator
        [label, line].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        labelLeading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)
        NSLayoutConstraint.activate([
            labelLeading,
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, isCurrent: Bool, leadingBlanks: Int) {
        label.text = text
        label.textColor = isCurrent ? .systemRed : .label
    }
}

// MARK: - Cell
private final class DayCell: UICollectionViewCell {
    private let dayLabel = UILabel()
    private let circle = UIView()     // 休講・試験などの印(丸)
    private let dot = UIView()        // 授業日の青い点(Appleのカレンダーの予定の点と同じ)

    override init(frame: CGRect) {
        super.init(frame: frame)
        dayLabel.font = .systemFont(ofSize: 18, weight: .regular)
        dayLabel.textAlignment = .center
        circle.isUserInteractionEnabled = false
        circle.layer.cornerRadius = 19
        dot.backgroundColor = .systemBlue
        dot.layer.cornerRadius = 2.5
        [circle, dayLabel, dot].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview($0) }
        NSLayoutConstraint.activate([
            circle.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            circle.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: -4),
            circle.widthAnchor.constraint(equalToConstant: 38),
            circle.heightAnchor.constraint(equalToConstant: 38),
            dayLabel.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            dayLabel.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 5),
            dot.heightAnchor.constraint(equalToConstant: 5),
            dot.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            dot.topAnchor.constraint(equalTo: circle.bottomAnchor, constant: 1)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configureBlank() {
        dayLabel.text = nil
        circle.backgroundColor = .clear
        circle.layer.borderWidth = 0
        dot.isHidden = true
        isUserInteractionEnabled = false
    }

    func configure(day: Int, category: DayCategory, isToday: Bool) {
        isUserInteractionEnabled = true
        dayLabel.text = "\(day)"
        dayLabel.textColor = .label
        dayLabel.font = .systemFont(ofSize: 18, weight: .regular)
        circle.backgroundColor = .clear
        circle.layer.borderWidth = 0
        dot.isHidden = true

        switch category {
        case .classDay:
            dot.isHidden = false
        case .sunday:
            dayLabel.textColor = .tertiaryLabel
        case .kyuko:
            circle.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.4)
        case .makeup:
            circle.layer.borderColor = UIColor.systemGreen.cgColor
            circle.layer.borderWidth = 2
        case .exam:
            circle.backgroundColor = UIColor.systemPurple.withAlphaComponent(0.28)
        case .summerBreak, .winterBreak, .springBreak:
            circle.backgroundColor = UIColor.systemTeal.withAlphaComponent(0.28)
        }

        if isToday {
            circle.backgroundColor = .systemRed
            circle.layer.borderWidth = 0
            dayLabel.textColor = .white
            dayLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        }
    }
}

// MARK: - 年の一覧
/// 1年を、3列×4行の小さな月で見せる(Appleのカレンダーを2本指でつまんだときの画面)。
private final class YearOverviewView: UIScrollView {
    var onSelect: ((Date) -> Void)?
    private var months: [Date] = []
    private var cal = Calendar(identifier: .gregorian)
    private var categoryOf: ((Date) -> DayCategory)?
    private var years: [Int] = []
    private var yearLabels: [UILabel] = []
    private var yearLines: [UIView] = []
    private var minis: [Int: [MiniMonthView]] = [:]   // 年 → 12か月(範囲外はnil相当で飛ばす)
    private var miniByMonth: [(date: Date, view: MiniMonthView)] = []

    private let sideMargin: CGFloat = 16
    private let columnGap: CGFloat = 14
    private let miniHeight: CGFloat = 132
    private let rowGap: CGFloat = 14

    func configure(months: [Date], calendar: Calendar, categoryOf: @escaping (Date) -> DayCategory) {
        self.months = months; self.cal = calendar; self.categoryOf = categoryOf
        alwaysBounceVertical = true
        showsVerticalScrollIndicator = false
        years = Array(Set(months.map { calendar.component(.year, from: $0) })).sorted()
        for year in years {
            let label = UILabel()
            label.text = "\(year)年"
            label.font = .systemFont(ofSize: 34, weight: .bold)
            label.textColor = year == calendar.component(.year, from: Date()) ? .systemRed : .label
            let line = UIView(); line.backgroundColor = .separator
            addSubview(label); addSubview(line)
            yearLabels.append(label); yearLines.append(line)
        }
        for monthFirst in months {
            let mini = MiniMonthView(monthFirst: monthFirst, calendar: calendar, categoryOf: categoryOf)
            let tap = UITapGestureRecognizer(target: self, action: #selector(miniTapped(_:)))
            mini.addGestureRecognizer(tap)
            addSubview(mini)
            miniByMonth.append((monthFirst, mini))
        }
        setNeedsLayout()
    }

    func refresh() { miniByMonth.forEach { $0.view.setNeedsDisplay() } }

    @objc private func miniTapped(_ g: UITapGestureRecognizer) {
        guard let mini = g.view as? MiniMonthView else { return }
        onSelect?(mini.monthFirst)
    }

    private func yearTop(_ index: Int) -> CGFloat {
        CGFloat(index) * (60 + 4 * (miniHeight + rowGap) + 24) + 8
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 0 else { return }
        let miniWidth = (width - sideMargin * 2 - columnGap * 2) / 3
        for (i, year) in years.enumerated() {
            let top = yearTop(i)
            yearLabels[i].frame = CGRect(x: sideMargin, y: top, width: width - sideMargin * 2, height: 42)
            yearLines[i].frame = CGRect(x: sideMargin, y: top + 50, width: width - sideMargin * 2, height: 1.0 / UIScreen.main.scale)
            for entry in miniByMonth where cal.component(.year, from: entry.date) == year {
                let m = cal.component(.month, from: entry.date) - 1
                entry.view.frame = CGRect(x: sideMargin + CGFloat(m % 3) * (miniWidth + columnGap),
                                          y: top + 62 + CGFloat(m / 3) * (miniHeight + rowGap),
                                          width: miniWidth, height: miniHeight)
            }
        }
        contentSize = CGSize(width: width, height: yearTop(years.count) + 40)
    }

    func scrollToYear(of date: Date, animated: Bool) {
        let year = cal.component(.year, from: date)
        guard let i = years.firstIndex(of: year) else { return }
        layoutIfNeeded()
        let maxOffset = max(0, contentSize.height - bounds.height)
        setContentOffset(CGPoint(x: 0, y: min(yearTop(i) - 4, maxOffset)), animated: animated)
    }

    /// 今見えている範囲の、真ん中あたりの月(2本指で広げたとき、そこへ戻る)。
    func monthNearCenter() -> Date? {
        let center = CGPoint(x: bounds.midX, y: contentOffset.y + bounds.height / 2)
        return miniByMonth.min { abs($0.view.frame.midY - center.y) + abs($0.view.frame.midX - center.x) * 0.2
                               < abs($1.view.frame.midY - center.y) + abs($1.view.frame.midX - center.x) * 0.2 }?.date
    }
}

private final class MiniMonthView: UIView {
    let monthFirst: Date
    private let cal: Calendar
    private let categoryOf: (Date) -> DayCategory

    init(monthFirst: Date, calendar: Calendar, categoryOf: @escaping (Date) -> DayCategory) {
        self.monthFirst = monthFirst; self.cal = calendar; self.categoryOf = categoryOf
        super.init(frame: .zero)
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        let isCurrentMonth = cal.isDate(monthFirst, equalTo: Date(), toGranularity: .month)
        let title = "\(cal.component(.month, from: monthFirst))月" as NSString
        title.draw(at: .zero, withAttributes: [
            .font: UIFont.systemFont(ofSize: 20, weight: .bold),
            .foregroundColor: (isCurrentMonth ? UIColor.systemRed : UIColor.label).resolvedColor(with: traitCollection)
        ])
        let top: CGFloat = 30
        let colW = bounds.width / 7
        let rowH = (bounds.height - top) / 6
        let blanks = (cal.component(.weekday, from: monthFirst) + 5) % 7
        let days = cal.range(of: .day, in: .month, for: monthFirst)?.count ?? 30
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        for day in 1...days {
            let slot = blanks + day - 1
            let cell = CGRect(x: CGFloat(slot % 7) * colW, y: top + CGFloat(slot / 7) * rowH, width: colW, height: rowH)
            let date = cal.date(byAdding: .day, value: day - 1, to: monthFirst)!
            let category = categoryOf(date)
            let isToday = cal.isDateInToday(date)
            let side = min(colW, rowH) - 1
            let mark = CGRect(x: cell.midX - side / 2, y: cell.midY - side / 2, width: side, height: side)
            var textColor = UIColor.label
            switch category {
            case .sunday: textColor = .tertiaryLabel
            case .kyuko: UIColor.systemYellow.withAlphaComponent(0.45).resolvedColor(with: traitCollection).setFill(); UIBezierPath(ovalIn: mark).fill()
            case .exam: UIColor.systemPurple.withAlphaComponent(0.3).resolvedColor(with: traitCollection).setFill(); UIBezierPath(ovalIn: mark).fill()
            case .summerBreak, .winterBreak, .springBreak: UIColor.systemTeal.withAlphaComponent(0.3).resolvedColor(with: traitCollection).setFill(); UIBezierPath(ovalIn: mark).fill()
            case .makeup:
                UIColor.systemGreen.resolvedColor(with: traitCollection).setStroke()
                let ring = UIBezierPath(ovalIn: mark.insetBy(dx: 0.8, dy: 0.8)); ring.lineWidth = 1.2; ring.stroke()
            case .classDay: break
            }
            if isToday {
                UIColor.systemRed.resolvedColor(with: traitCollection).setFill(); UIBezierPath(ovalIn: mark).fill()
                textColor = .white
            }
            let font = UIFont.systemFont(ofSize: 10.5, weight: isToday ? .semibold : .regular)
            let text = "\(day)" as NSString
            let size = text.size(withAttributes: [.font: font])
            text.draw(in: CGRect(x: cell.minX, y: cell.midY - size.height / 2, width: colW, height: size.height),
                      withAttributes: [.font: font, .foregroundColor: textColor.resolvedColor(with: traitCollection), .paragraphStyle: paragraph])
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsDisplay()
    }
}
