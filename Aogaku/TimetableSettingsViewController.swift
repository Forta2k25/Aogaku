import UIKit
import GoogleMobileAds

@inline(__always)
private func makeAdaptiveAdSize(width: CGFloat) -> AdSize {
    return currentOrientationAnchoredAdaptiveBanner(width: width)
}


final class TimetableSettingsViewController: UIViewController, BannerViewDelegate {

    private var settings = TimetableSettings.load()

    private let periodsSeg = UISegmentedControl(items: ["5", "6", "7"])
    private let daysSeg = UISegmentedControl(items: ["平日のみ", "平日＋土"])
    
    // [ADD] AdMob バナー用
    private let adContainer = UIView()
    private var bannerView: BannerView?
    private var adContainerHeight: NSLayoutConstraint?
    private var lastBannerWidth: CGFloat = 0
    private var didLoadBannerOnce = false
    private let bannerTopPadding: CGFloat = 60   // ← ここで「ちょっと下げる」量を調整
    
    
    // ▼ 追加：どのバナー形式を使うか
    private var bannerStyle: BannerStyle { AdsSwitchboard.shared.style }

    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "表示設定"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "閉じる", style: .plain, target: self, action: #selector(close)
        )

        // 初期値
        periodsSeg.selectedSegmentIndex = [5,6,7].firstIndex(of: settings.periods) ?? 0
        daysSeg.selectedSegmentIndex = settings.includeSaturday ? 1 : 0

        periodsSeg.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
        daysSeg.addTarget(self, action: #selector(valueChanged), for: .valueChanged)

        // 簡単レイアウト
        let stack = UIStackView(arrangedSubviews: [
            labeled("時限数", periodsSeg),
            labeled("曜日", daysSeg),
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
        ])
        
        setupAdBanner()        // [ADD]
        NotificationCenter.default.addObserver(self,
            selector: #selector(onAdMobReady),
            name: .adMobReady, object: nil)
        
        NotificationCenter.default.addObserver(self,
            selector: #selector(onAdsConfigUpdated),
            name: AdsSwitchboard.didUpdate, object: nil)
    }
    @objc private func onAdsConfigUpdated() {
        // スタイル or ユニットIDが変わったら作り直し
        removeBannerIfNeeded()
        setupAdBanner()
        loadBannerIfNeeded()
    }
    private func removeBannerIfNeeded() {
        bannerView?.removeFromSuperview()
        bannerView = nil
        didLoadBannerOnce = false
        lastBannerWidth = 0
    }


    @objc private func onAdMobReady() {
        loadBannerIfNeeded()
    }


    // [ADD]
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        loadBannerIfNeeded()
    }
    
    // [ADD]
    private func setupAdBanner() {
        adContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(adContainer)
        
        // 広告OFFなら領域を畳む
        if !AdsSwitchboard.shared.enabled {
            adContainerHeight?.constant = 0
            updateBottomInset(0)
            return
        }


        adContainerHeight = adContainer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            adContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            adContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            adContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            adContainerHeight!
        ])
        
        let bv = BannerView()
        bv.translatesAutoresizingMaskIntoConstraints = false
        //bv.adUnitID = AdsConfig.bannerUnitID     // ← RCの本番/テストIDを自動選択
        bv.adUnitID = AdsSwitchboard.shared.unitID(for: bannerStyle)
        bv.rootViewController = self
       // bv.adSize = AdSizeBanner
        bv.delegate = self

        
        adContainer.addSubview(bv)

        // ★ MREC と Adaptive でレイアウトを切り替え
        switch bannerStyle {
        case .mrec:
          bv.adSize = AdSizeMediumRectangle // 300x250
          let w = bv.adSize.size.width, h = bv.adSize.size.height
          NSLayoutConstraint.activate([
            bv.topAnchor.constraint(equalTo: adContainer.topAnchor, constant: bannerTopPadding),
            bv.centerXAnchor.constraint(equalTo: adContainer.centerXAnchor),
            bv.widthAnchor.constraint(equalToConstant: w),
            bv.heightAnchor.constraint(equalToConstant: h)
          ])
          adContainerHeight?.constant = h + bannerTopPadding



        case .adaptive:
            bv.adSize = AdSizeBanner // 初期値。実サイズは viewDidLayoutSubviews で上書き
            NSLayoutConstraint.activate([
                bv.leadingAnchor.constraint(equalTo: adContainer.leadingAnchor),
                bv.trailingAnchor.constraint(equalTo: adContainer.trailingAnchor),
                bv.bottomAnchor.constraint(equalTo: adContainer.bottomAnchor),
                bv.topAnchor.constraint(equalTo: adContainer.topAnchor, constant: bannerTopPadding)
            ])
            let safeWidth = view.safeAreaLayoutGuide.layoutFrame.width
            let useWidth = max(320, floor(safeWidth))
            let size = makeAdaptiveAdSize(width: useWidth)
            adContainerHeight?.constant = size.size.height + bannerTopPadding
        }

        /*
        adContainer.addSubview(bv)
        NSLayoutConstraint.activate([
            bv.leadingAnchor.constraint(equalTo: adContainer.leadingAnchor),
            bv.trailingAnchor.constraint(equalTo: adContainer.trailingAnchor),
            bv.bottomAnchor.constraint(equalTo: adContainer.bottomAnchor),
            bv.topAnchor.constraint(equalTo: adContainer.topAnchor, constant: bannerTopPadding)  // ← 少し下げる
        ])

        // ▼▼ ここが [FIX]：useWidth をこのスコープで作る
        let safeWidth = view.safeAreaLayoutGuide.layoutFrame.width
        let useWidth = max(320, floor(safeWidth))
        let size = makeAdaptiveAdSize(width: useWidth)
        adContainerHeight?.constant = size.size.height + bannerTopPadding // ← 余白ぶんも確保
        // ▲▲
        */
        bannerView = bv
    }
    private func loadBannerIfNeeded() {
        guard let bv = bannerView else { return }

        switch bannerStyle {
        case .mrec:
            guard !didLoadBannerOnce else { return }
            didLoadBannerOnce = true
            adContainerHeight?.constant = 250 + bannerTopPadding
            updateBottomInset(250 + bannerTopPadding)
            view.layoutIfNeeded()        // ← これで frame が 300×250 になる
            bv.load(Request())


        case .adaptive:
            let safeWidth = view.safeAreaLayoutGuide.layoutFrame.width
            guard safeWidth > 0 else { return }
            let useWidth = max(320, floor(safeWidth))
            if abs(useWidth - lastBannerWidth) < 0.5 { return }  // 同幅連続ロード防止
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
    }



/*    private func loadBannerIfNeeded() {
        guard let bv = bannerView else { return }
        let safeWidth = view.safeAreaLayoutGuide.layoutFrame.width
        guard safeWidth > 0 else { return }

        let useWidth = max(320, floor(safeWidth))
        if abs(useWidth - lastBannerWidth) < 0.5 { return }  // 同幅連続ロード防止
        lastBannerWidth = useWidth

        let size = makeAdaptiveAdSize(width: useWidth)
        adContainerHeight?.constant = size.size.height + bannerTopPadding   // [FIX]

        view.layoutIfNeeded()

        guard size.size.height > 0 else { return }
        if !CGSizeEqualToSize(bv.adSize.size, size.size) {
            bv.adSize = size
        }
        if !didLoadBannerOnce {
            didLoadBannerOnce = true
            bv.load(Request())
        }
    }*/

    // 表示/非表示時に下インセットを調整（TableView or ScrollView）
    private func updateBottomInset(_ h: CGFloat) {
        if let tv = (self as? UITableViewController)?.tableView
            ?? view.subviews.compactMap({ $0 as? UITableView }).first {
            tv.contentInset.bottom = h
            tv.scrollIndicatorInsets.bottom = h
        } else if let sv = view.subviews.compactMap({ $0 as? UIScrollView }).first {
            sv.contentInset.bottom = h
            sv.scrollIndicatorInsets.bottom = h
        }
    }

    // MARK: - BannerViewDelegate
/*    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        let h = bannerView.adSize.size.height
        adContainerHeight?.constant = h + bannerTopPadding                  // [FIX]
        updateBottomInset(h + bannerTopPadding)                             // [FIX]
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
    }*/
    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        let h: CGFloat
        switch bannerStyle {
        case .mrec:     h = 250
        case .adaptive: h = bannerView.adSize.size.height
        }
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


    private func labeled(_ title: String, _ control: UIView) -> UIStackView {
        let l = UILabel()
        l.text = title
        l.font = .systemFont(ofSize: 14, weight: .semibold)
        let v = UIStackView(arrangedSubviews: [l, control])
        v.axis = .vertical
        v.spacing = 8
        return v
    }

    @objc private func valueChanged() {
        let ps = [5,6,7][periodsSeg.selectedSegmentIndex]
        let sat = (daysSeg.selectedSegmentIndex == 1)
        settings.periods = ps
        settings.includeSaturday = sat
        settings.save()

        // timetable に通知
        NotificationCenter.default.post(name: .timetableSettingsChanged, object: nil)
    }

    @objc private func close() { dismiss(animated: true) }
}
