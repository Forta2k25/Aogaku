
import UIKit
import WebKit
import FirebaseFirestore

final class SyllabusDetailViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    // 呼び出し側から貰える場合（検索リストや「水2限」など）
    var targetDay: Int?      // 0=月…5=土
    var targetPeriod: Int?   // 1..7

    // ドキュメントID & 初期表示
    var docID: String?
    var initialTitle: String?
    var initialTeacher: String?
    var initialCredit: String?

    // Storyboard Outlets（未接続でも落ちないように Optional）
    @IBOutlet weak var titleTextView: UITextView?
    @IBOutlet weak var addButton: UIButton?
    @IBOutlet weak var bookmarkButton: UIButton?
    @IBOutlet weak var closeButton: UIButton?

    @IBOutlet weak var codeLabel: UILabel?
    @IBOutlet weak var roomLabel: UILabel?
    @IBOutlet weak var teacherLabel: UILabel?
    @IBOutlet weak var creditLabel: UILabel?
    @IBOutlet weak var infoStack: UIStackView?     // ← ラベル群の親Stack
    @IBOutlet weak var webContainer: UIView?

    // 保存キー
    private let plannedKey  = "plannedClassIDs"
    private let favoriteKey = "favoriteClassIDs"

    // Web
    private var webView: WKWebView!
    private let indicator = UIActivityIndicatorView(style: .large)

    // Firestore の生データを保持（通知payload用）
    private var lastFetched: [String: Any] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()

        // タイトルの見栄え
        titleTextView?.isEditable = false
        titleTextView?.isSelectable = false
        titleTextView?.isScrollEnabled = false
        titleTextView?.backgroundColor = .clear
        titleTextView?.isOpaque = false
        titleTextView?.textColor = .white
        titleTextView?.font = .boldSystemFont(ofSize: 20)
        titleTextView?.textAlignment = .center
        titleTextView?.textContainerInset = .zero
        titleTextView?.textContainer.lineFragmentPadding = 0
        titleTextView?.text = (initialTitle?.isEmpty == false) ? initialTitle! : "科目名"

        // 初期ラベル
        teacherLabel?.text = initialTeacher ?? ""
        creditLabel?.text  = (initialCredit?.isEmpty == false) ? "\(initialCredit!)単位" : ""
        roomLabel?.text    = "-"
        codeLabel?.text    = "-"

        setupWebView()
        refreshButtons()

        guard let id = docID, !id.isEmpty else {
            print("❌ detail open failed: docID is nil/empty")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.dismiss(animated: true) }
            return
        }
        fetchDetail(docID: id)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateTitleVerticalInset()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateTitleVerticalInset()
    }
    private func updateTitleVerticalInset() {
        guard let tv = titleTextView else { return }
        let fit = tv.sizeThatFits(CGSize(width: tv.bounds.width, height: .greatestFiniteMagnitude))
        let top = max(0, (tv.bounds.height - fit.height)/2)
        tv.textContainerInset = UIEdgeInsets(top: top, left: 0, bottom: max(0, tv.bounds.height - fit.height - top), right: 0)
    }

    // MARK: - WebView（infoStackの直下に貼る）
    private func setupWebView() {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.preferredContentMode = .mobile
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.alwaysBounceVertical = true

        let host: UIView = webContainer ?? view
        host.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false

        if let stack = infoStack, stack.isDescendant(of: host.superview ?? host) {
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 12),
                webView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: host.bottomAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 160),
                webView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: host.bottomAnchor)
            ])
        }

        indicator.hidesWhenStopped = true
        host.addSubview(indicator)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: host.centerYAnchor)
        ])
        host.sendSubviewToBack(webView)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { indicator.startAnimating() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { indicator.stopAnimating() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { indicator.stopAnimating(); print("🌐 web load failed:", error.localizedDescription) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { indicator.stopAnimating(); print("🌐 web provisional failed:", error.localizedDescription) }

    // MARK: - Firestore 読み込み
    private func fetchDetail(docID: String) {
        Firestore.firestore().collection("classes").document(docID).getDocument { [weak self] snap, err in
            guard let self = self else { return }
            if let err = err { print("❌ detail fetch error:", err); return }
            guard let data = snap?.data() else { print("❌ detail: not found"); return }

            self.lastFetched = data

            if let name = data["class_name"] as? String { self.titleTextView?.text = name }
            if let t = data["teacher_name"] as? String { self.teacherLabel?.text = t }

            if let c = data["credit"] as? Int {
                self.creditLabel?.text = "\(c)単位"
            } else if let cStr = data["credit"] as? String, !cStr.isEmpty {
                self.creditLabel?.text = "\(cStr)単位"
            }

            let code = (data["registration_number"] as? String)
                ?? (data["code"] as? String)
                ?? (data["class_code"] as? String)
                ?? (data["course_code"] as? String)
            self.codeLabel?.text = code ?? "-"

            let room = (data["room"] as? String) ?? (data["classroom"] as? String)
            self.roomLabel?.text = (room?.isEmpty == false) ? room! : "-"

            if let urlString = (data["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let url = URL(string: urlString) {
                self.webView.load(URLRequest(url: url))
            } else {
                let html = """
                <html><head><meta name="viewport" content="width=device-width, initial-scale=1.0">
                <style>body{font: -apple-system-body; color:#666; margin:24px}</style></head>
                <body><p>リンクURLが見つかりませんでした。</p></body></html>
                """
                self.webView.loadHTMLString(html, baseURL: nil)
            }
            DispatchQueue.main.async { [weak self] in self?.updateTitleVerticalInset() }
        }
    }

    // MARK: - Buttons
    @IBAction func didTapClose(_ sender: Any) { dismiss(animated: true) }

    @IBAction func didTapAdd(_ sender: Any) {
        // まだ Firestore 読み込みが終わっていない場合は読み込み→アラートへ
        if lastFetched.isEmpty, let id = docID {
            // 読み直してからアラートを出す
            fetchDetail(docID: id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.presentAddConfirmAndPost()
            }
        } else {
            presentAddConfirmAndPost()
        }
    }
    /// 確認アラートを出し、OK なら timetable へ通知して追加
    private func presentAddConfirmAndPost() {
        let (payload, d, p) = buildPayload(from: lastFetched)

        // 表示用文言
        let name = (payload["class_name"] as? String) ?? "この授業"
        let dayText: String = {
            if let d = d { return ["月","火","水","木","金","土"][d] } else { return "（曜日不明）" }
        }()
        let periodText: String = p != nil ? "\(p!)限" : "（時限不明）"
        let message = "\(dayText) \(periodText) に\n「\(name)」を\n登録します。"

        let ac = UIAlertController(title: "登録しますか？", message: message, preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))

        ac.addAction(UIAlertAction(title: "登録", style: .default, handler: { [weak self] _ in
            guard let self = self, let id = self.docID, !id.isEmpty else { return }

            // planned フラグ（任意・従来動作維持）
            var set = Set(UserDefaults.standard.stringArray(forKey: self.plannedKey) ?? [])
            if set.contains(id) { set.remove(id) } else { set.insert(id) }
            UserDefaults.standard.set(Array(set), forKey: self.plannedKey)
            self.refreshButtons()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()

            // timetable へ通知（既存の受信側がコマへ登録してくれる）
            var info: [String: Any] = ["course": payload, "docID": id]
            if let d = d { info["day"] = d }
            if let p = p { info["period"] = p }
            NotificationCenter.default.post(name: .registerCourseToTimetable, object: nil, userInfo: info)
        }))

        present(ac, animated: true)
    }

    @IBAction func didTapBookmark(_ sender: Any) {
        guard let id = docID, !id.isEmpty else { return }
        var set = Set(UserDefaults.standard.stringArray(forKey: favoriteKey) ?? [])
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        UserDefaults.standard.set(Array(set), forKey: favoriteKey)
        refreshButtons()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func refreshButtons() {
        guard let id = docID else { return }
        let planned = Set(UserDefaults.standard.stringArray(forKey: plannedKey) ?? [])
        let fav     = Set(UserDefaults.standard.stringArray(forKey: favoriteKey) ?? [])
        addButton?.setTitle(planned.contains(id) ? "登録済み" : "AddButton", for: .normal)
        bookmarkButton?.setTitle(fav.contains(id) ? "Bookmarked" : "Bookmark", for: .normal)
    }

    // MARK: - Payload 構築
    private func dayIndex(from japanese: String) -> Int? {
        let t = japanese.trimmingCharacters(in: .whitespaces)
        guard let ch = t.first else { return nil }
        return ["月":0,"火":1,"水":2,"木":3,"金":4,"土":5][ch]
    }

    /// Firestoreデータ→payload＋(day/period)抽出
    private func buildPayload(from data: [String: Any]) -> (course: [String: Any], day: Int?, period: Int?) {
        let name   = data["class_name"]   as? String ?? (titleTextView?.text ?? "")
        let code   = (data["code"] as? String)
                  ?? (data["registration_number"] as? String)
                  ?? "-"
        let room   = (data["room"] as? String) ?? (data["classroom"] as? String) ?? (roomLabel?.text ?? "")
        let teacher = (data["teacher_name"] as? String) ?? (teacherLabel?.text ?? "")
        let urlStr = (data["url"] as? String) ?? ""

        // credit は Int/String どちらでも来るので Int に丸める
        let credit: Int = {
            if let n = data["credit"] as? Int { return n }
            if let s = data["credit"] as? String { return Int(s) ?? 0 }
            return 0
        }()

        // 可能なら campus / category も拾う（任意）
        let campus = data["campus"] as? String
        let category = data["category"] as? String

        // day / period 推定
        var d = targetDay
        var p = targetPeriod
        if (d == nil || p == nil), let time = data["time"] as? [String: Any] {
            if d == nil, let dayJ = time["day"] as? String {
                let ch = dayJ.trimmingCharacters(in: .whitespaces).first
                d = ["月":0,"火":1,"水":2,"木":3,"金":4,"土":5][ch ?? " "]
            }
            if p == nil {
                if let single = time["period"] as? Int { p = single }
                else if let arr = time["periods"] as? [Int], let first = arr.first { p = first }
            }
        }

        return ([
            "class_name": name,
            "code": code,
            "credit": credit,              // ← timetable 側で Int/Int? を受けられるよう実装済み
            "room": room,
            "teacher_name": teacher,
            "url": urlStr,
            "campus": campus as Any,
            "category": category as Any
        ], d, p)
    }

}

// 通知名（共通化）
extension Notification.Name {
    static let registerCourseToTimetable = Notification.Name("RegisterCourseToTimetable")
}
