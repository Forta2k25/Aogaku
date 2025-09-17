import UIKit
import FirebaseAuth
import FirebaseFirestore
import GoogleMobileAds

@inline(__always)
private func makeAdaptiveAdSize(width: CGFloat) -> AdSize {
    return currentOrientationAnchoredAdaptiveBanner(width: width)
}

final class FriendRequestsViewController: UITableViewController, BannerViewDelegate {
    private var items: [FriendRequest] = []
    private let db = Firestore.firestore()

    // 送信者プロフィールの軽量キャッシュ
    private var profileCache: [String: (name: String, id: String, photoURL: String?)] = [:]
    
    // MARK: - AdMob (Banner)
    private let adContainer = UIView()
    private var bannerView: BannerView?
    private var adContainerHeight: NSLayoutConstraint?
    private var lastBannerWidth: CGFloat = 0
    private var didLoadBannerOnce = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "友だち申請"
        tableView.register(RequestCell.self, forCellReuseIdentifier: RequestCell.reuseID)
        tableView.rowHeight = 92
        reload()
        setupAdBanner()            // [ADDED]
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        loadBannerIfNeeded()       // [ADDED]
    }
    
    private func setupAdBanner() {
        // 画面下に広告コンテナを固定
        adContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(adContainer)

        adContainerHeight = adContainer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            adContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            adContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            adContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            adContainerHeight!
        ])

        // GADBannerView（プロジェクトの typealias: BannerView / Request / AdSize を使用）
        let bv = BannerView()
        bv.translatesAutoresizingMaskIntoConstraints = false
        bv.adUnitID = "ca-app-pub-3940256099942544/2934735716"   // テスト用
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

    private func loadBannerIfNeeded() {
        guard let bv = bannerView else { return }
        let safeWidth = view.safeAreaLayoutGuide.layoutFrame.width
        if safeWidth <= 0 { return }

        let useWidth = max(320, floor(safeWidth))
        if abs(useWidth - lastBannerWidth) < 0.5 { return } // 連続ロード抑止
        lastBannerWidth = useWidth

        // 1) 幅からサイズ算出
        let size = makeAdaptiveAdSize(width: useWidth)

        // 2) 先にコンテナの高さを確保（0 回避）
        adContainerHeight?.constant = size.size.height
        updateInsetsForBanner(height: size.size.height)  // テーブル下に余白
        view.layoutIfNeeded()

        // 3) 高さ 0 は不正 → ロードしない
        guard size.size.height > 0 else { return }

        // 4) サイズ反映（同一ならスキップ）
        if !CGSizeEqualToSize(bv.adSize.size, size.size) {
            bv.adSize = size
        }

        // 5) 初回だけロード
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

    private func reload() {
        FriendService.shared.fetchIncomingRequests { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let list):
                self.items = list
                self.tableView.reloadData()
            case .failure(let err):
                print("fetchIncomingRequests error:", err.localizedDescription)
                self.items = []
                self.tableView.reloadData()
            }
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let req = items[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: RequestCell.reuseID, for: indexPath) as! RequestCell

        let fallbackName = req.fromName.isEmpty ? "@\(req.fromId)" : req.fromName
        let placeholder = UIImage(systemName: "person.crop.circle.fill")

        if let p = profileCache[req.fromUid] {
            // キャッシュから即表示
            cell.configure(name: p.name.isEmpty ? fallbackName : p.name,
                           id: p.id.isEmpty ? req.fromId : p.id,
                           photoURL: p.photoURL,
                           placeholder: placeholder)
        } else {
            // まず手元の情報で描画 → 非同期で詳細取得
            cell.configure(name: fallbackName, id: req.fromId, photoURL: nil, placeholder: placeholder)
            db.collection("users").document(req.fromUid).getDocument { [weak self, weak tableView] snap, _ in
                guard let self = self, let tableView = tableView else { return }
                let data = snap?.data()
                let name = (data?["name"] as? String) ?? fallbackName
                let id   = (data?["id"] as? String) ?? req.fromId
                let url  = data?["photoURL"] as? String
                self.profileCache[req.fromUid] = (name, id, url)

                // 可視セルだけ更新
                if let visible = tableView.cellForRow(at: indexPath) as? RequestCell {
                    visible.configure(name: name, id: id, photoURL: url, placeholder: placeholder)
                }
            }
        }

        // ボタン動作
        cell.onApprove = { [weak self, weak cell] in
            guard let self = self,
                  let cell = cell,
                  let idx = tableView.indexPath(for: cell)?.row else { return }
            let r = self.items[idx]
            let cached = self.profileCache[r.fromUid]
            let user = UserPublic(uid: r.fromUid,
                                  idString: cached?.id ?? r.fromId,
                                  name: cached?.name ?? fallbackName,
                                  photoURL: cached?.photoURL)
            FriendService.shared.acceptRequest(from: user) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success:
                    if let row = self.items.firstIndex(where: { $0.fromUid == r.fromUid }) {
                        self.items.remove(at: row)
                        tableView.deleteRows(at: [IndexPath(row: row, section: 0)], with: .automatic)
                    }
                    // FriendList 側は通知で自動リロードされる
                case .failure(let err):
                    print("acceptRequest failed:", err.localizedDescription)
                    let ac = UIAlertController(title: "承認に失敗しました",
                                               message: err.localizedDescription,
                                               preferredStyle: .alert)
                    ac.addAction(UIAlertAction(title: "OK", style: .default))
                    self.present(ac, animated: true)
                    // フォールバック
                    self.reload()
                }
            }
        }
        cell.onDelete = { [weak self, weak tableView] in
            guard let self = self,
                  let tableView = tableView,
                  let me = Auth.auth().currentUser?.uid else { return }

            // いま表示しているリクエストをキャプチャ（indexPath()に頼らない）
            let r = req
            let incomingRef = self.db.collection("users").document(me)
                .collection("requestsIncoming").document(r.fromUid)
            let outgoingRef = self.db.collection("users").document(r.fromUid)
                .collection("requestsOutgoing").document(me)

            // 1) 自分側を先に消す（必ず許可される）
            incomingRef.delete { [weak self] err in
                guard let self = self else { return }
                if let err = err {
                    print("delete incoming failed:", err.localizedDescription)
                    return
                }
                // ローカルUIからも除去
                if let row = self.items.firstIndex(where: { $0.fromUid == r.fromUid }) {
                    self.items.remove(at: row)
                    tableView.deleteRows(at: [IndexPath(row: row, section: 0)], with: .automatic)
                }

                // 2) 送信者側(相手)の申請を試しに削除（権限無いと失敗する）
                outgoingRef.delete { err in
                    if let err = err {
                        print("delete sender outgoing failed (likely rules):", err.localizedDescription)
                    }
                }
            }
        }



        return cell
    }
}
