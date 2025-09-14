import UIKit
import WebKit
import FirebaseFirestore

final class SyllabusDetailViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    // 呼び出し側から受け取る
    var docID: String?
    var initialTitle: String?
    var initialTeacher: String?
    var initialCredit: String?

    // --- Storyboard Outlets（optionalで安全化） ---
    @IBOutlet weak var titleTextView: UITextView?
    @IBOutlet weak var addButton: UIButton?
    @IBOutlet weak var bookmarkButton: UIButton?
    @IBOutlet weak var closeButton: UIButton?

    // ラベル類
    @IBOutlet weak var codeLabel: UILabel?
    @IBOutlet weak var roomLabel: UILabel?
    @IBOutlet weak var teacherLabel: UILabel?
    @IBOutlet weak var creditLabel: UILabel?

    // ラベル群をまとめた Stack（← ここが重要）
    @IBOutlet weak var infoStack: UIStackView?

    /// Web を貼るコンテナ（任意）。未接続なら画面全体の view を使います。
    @IBOutlet weak var webContainer: UIView?

    // 保存キー
    private let plannedKey  = "plannedClassIDs"
    private let favoriteKey = "favoriteClassIDs"

    // Web
    private var webView: WKWebView!
    private let indicator = UIActivityIndicatorView(style: .large)

    override func viewDidLoad() {
        super.viewDidLoad()

        // タイトル表示（背景透明・白太字20pt・横中央）
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

        // 初期のラベル
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

    // タイトルの縦位置微調整（任意）
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
        let fitting = tv.sizeThatFits(CGSize(width: tv.bounds.width, height: .greatestFiniteMagnitude))
        let contentH = fitting.height
        let boxH = tv.bounds.height
        guard boxH > 0 else { return }
        let top = max(0, (boxH - contentH) / 2)
        tv.textContainerInset = UIEdgeInsets(top: top, left: 0, bottom: max(0, boxH - contentH - top), right: 0)
    }

    // MARK: - WebView を infoStack の直下に配置
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

        // 貼り付け先のビュー
        let host: UIView = webContainer ?? view
        host.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false

        // ★ いちばん下のラベル群（infoStack）の「下端」に Web の上端を合わせる
        if let stack = infoStack, stack.isDescendant(of: host.superview ?? host) {
            // stack と webView は同じ祖先の制約に乗せる
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 12),
                webView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: host.bottomAnchor)
            ])
        } else {
            // フォールバック：安全領域の上から 160pt 下げた位置から開始
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 160),
                webView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: host.bottomAnchor)
            ])
        }

        // インジケータ
        indicator.hidesWhenStopped = true
        host.addSubview(indicator)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: host.centerYAnchor)
        ])

        // ラベルの上に Web が重ならないよう、z順も一応調整
        host.sendSubviewToBack(webView)
    }

    // target="_blank" も同じ WebView で開く
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
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
            guard let data = snap?.data() else { print("❌ detail: document not found"); return }

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
        guard let id = docID, !id.isEmpty else { return }
        var set = Set(UserDefaults.standard.stringArray(forKey: plannedKey) ?? [])
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        UserDefaults.standard.set(Array(set), forKey: plannedKey)
        refreshButtons()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
        guard let id = docID, !id.isEmpty else {
            addButton?.isSelected = false
            bookmarkButton?.isSelected = false
            return
        }
        let planned  = Set(UserDefaults.standard.stringArray(forKey: plannedKey) ?? []).contains(id)
        let favorite = Set(UserDefaults.standard.stringArray(forKey: favoriteKey) ?? []).contains(id)
        addButton?.isSelected = planned
        bookmarkButton?.isSelected = favorite
    }
}
