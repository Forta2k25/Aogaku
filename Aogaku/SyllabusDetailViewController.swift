import UIKit
import WebKit
import FirebaseFirestore

final class SyllabusDetailViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    // 呼び出し側から渡されることがある情報
    var targetDay: Int?      // 0=月…5=土
    var targetPeriod: Int?   // 1..7
    var docID: String?
    var initialTitle: String?
    var initialTeacher: String?
    var initialCredit: String?
    var initialURLString: String?   // ← 追加: 直接開くURL（友だち時間割から渡す）
    var initialRegNumber: String?
    var initialRoom: String?


    // MARK: - Outlets（Storyboard接続）
    @IBOutlet weak var titleTextView: UITextView?
    @IBOutlet weak var addButton: UIButton?
    @IBOutlet weak var bookmarkButton: UIButton?

    @IBOutlet weak var codeLabel: UILabel?
    @IBOutlet weak var teacherLabel: UILabel?
    @IBOutlet weak var creditLabel: UILabel?

    @IBOutlet weak var infoStack: UIStackView?      // 任意（無くてもOK）
    @IBOutlet weak var webContainer: UIView?        // 任意（無くてもOK）
    @IBOutlet weak var roomTextField: UITextField?

    // MARK: - Store Keys
    private let plannedKey  = "plannedClassIDs"
    private let favoriteKey = "favoriteClassIDs"

    // MARK: - Web
    private var webView: WKWebView!
    private let indicator = UIActivityIndicatorView(style: .large)

    // Firestore生データ（時間割登録通知で使用）
    private var lastFetched: [String: Any] = [:]

    // Navigation外観退避
    private var savedStandard: UINavigationBarAppearance?
    private var savedScrollEdge: UINavigationBarAppearance?
    private var savedTint: UIColor?

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()

        // 1) 先にUIを作る（ここで webView を必ず作成）
        setupButtonsAppearance()
        setupWebView()                 // ← 最初に呼ぶ
        refreshButtons()
        reanchorHeaderRow()

        // 2) タイトルなどの初期表示
        titleTextView?.isEditable = false
        titleTextView?.isSelectable = false
        titleTextView?.isScrollEnabled = false
        titleTextView?.backgroundColor = .clear
        titleTextView?.isOpaque = false
        titleTextView?.textColor = .white
        titleTextView?.font = .boldSystemFont(ofSize: 20)
        titleTextView?.textAlignment = .center
        titleTextView?.textContainer.lineFragmentPadding = 0
        titleTextView?.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 0, right: 0)
        titleTextView?.text = (initialTitle?.isEmpty == false) ? initialTitle! : "科目名"
        teacherLabel?.text = initialTeacher ?? ""
        // 教室プレフィル（TextFieldを置いていない場合は無視される）
        roomTextField?.text = initialRoom

        
        // 既存の初期化群の近くに
        if let code = initialRegNumber, !code.isEmpty {
            codeLabel?.text = code
        } else if let id = docID, !id.isEmpty {
            // 念のため docID をフォールバック
            codeLabel?.text = id
        }

        if let c = initialCredit, !c.isEmpty { creditLabel?.text = "\(c)単位" }

        // 3) データ表示（URL 直指定があればそれを即表示、なければ Firestore）
        if let s = initialURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: s), !s.isEmpty {
            webView.isHidden = false
            webView.load(URLRequest(url: url))
        } else if let id = docID, !id.isEmpty {
            fetchDetail(docID: id)
        } else {
            // どちらもない場合は自動で閉じる（既存の挙動を踏襲）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.dismiss(animated: true)
            }
        }

        // 4) モーダルで開かれたときの閉じるボタン
        if presentingViewController != nil,
           navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                systemItem: .close,
                primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
            )
        }
    }


    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard let nav = navigationController else { return }
        savedStandard = nav.navigationBar.standardAppearance
        savedScrollEdge = nav.navigationBar.scrollEdgeAppearance
        savedTint = nav.navigationBar.tintColor

        let app = UINavigationBarAppearance()
        app.configureWithTransparentBackground()
        nav.navigationBar.standardAppearance = app
        nav.navigationBar.scrollEdgeAppearance = app
        nav.navigationBar.compactAppearance = app
        nav.navigationBar.tintColor = .white   // 戻る矢印＆文字を白に
        navigationItem.largeTitleDisplayMode = .never
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard let nav = navigationController else { return }
        if let a = savedStandard { nav.navigationBar.standardAppearance = a }
        if let a = savedScrollEdge { nav.navigationBar.scrollEdgeAppearance = a }
        nav.navigationBar.compactAppearance = nav.navigationBar.standardAppearance
        nav.navigationBar.tintColor = savedTint
    }

    // MARK: - Buttons
    private func setupButtonsAppearance() {
        // 文字は常に空（"Addbutton"/"Bookmark"などが出ないように）
        addButton?.setTitle("", for: .normal)
        bookmarkButton?.setTitle("", for: .normal)

        // 余白・アイコンサイズ
        if #available(iOS 15.0, *) {
            var addCfg = UIButton.Configuration.plain()
            addCfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
            addButton?.configuration = addCfg
            var bmCfg = UIButton.Configuration.plain()
            bmCfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
            bookmarkButton?.configuration = bmCfg
        } else {
            addButton?.contentEdgeInsets = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
            bookmarkButton?.contentEdgeInsets = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        }
        let sym = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        addButton?.setPreferredSymbolConfiguration(sym, forImageIn: .normal)
        bookmarkButton?.setPreferredSymbolConfiguration(sym, forImageIn: .normal)
        addButton?.accessibilityLabel = "時間割に追加"
        bookmarkButton?.accessibilityLabel = "ブックマーク"
    }

    private func refreshButtons() {
        guard let id = docID else { return }
        let planned = Set(UserDefaults.standard.stringArray(forKey: plannedKey) ?? [])
        let fav     = Set(UserDefaults.standard.stringArray(forKey: favoriteKey) ?? [])

        let addSymbol = planned.contains(id) ? "checkmark.circle.fill" : "plus.circle"
        addButton?.setImage(UIImage(systemName: addSymbol), for: .normal)
        addButton?.tintColor = planned.contains(id) ? .systemGreen : .label
        addButton?.setTitle("", for: .normal)

        let bmSymbol = fav.contains(id) ? "bookmark.fill" : "bookmark"
        bookmarkButton?.setImage(UIImage(systemName: bmSymbol), for: .normal)
        bookmarkButton?.tintColor = fav.contains(id) ? .systemOrange : .label
        bookmarkButton?.setTitle("", for: .normal)

        // レイアウトを非アニメで確定（視覚揺れ抑制）
        UIView.performWithoutAnimation { self.view.layoutIfNeeded() }
    }
    
    @IBAction func tapRegisterButton(_ sender: Any) {
        // 画面の編集フィールドがあればそれを優先
        let roomFromUI = (roomTextField?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let course: [String: Any] = [
            "class_name":   (initialTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            "teacher_name": initialTeacher ?? "",
            // timetable 側が読むキー名に合わせる
            "room":         roomFromUI.isEmpty ? (initialRoom ?? "") : roomFromUI,
            "code":         (initialRegNumber ?? docID) ?? "",        // ← 登録番号は code で渡す
            "url":          initialURLString ?? ""                     // ← URL は url で渡す
            // 必要なら "credit" / "campus" / "category" もここで付与
        ]

        NotificationCenter.default.post(
            name: .registerCourseToTimetable,
            object: nil,
            userInfo: [
                "day": targetDay,
                "period": targetPeriod,
                // docID も一応渡しておく（makeCourse 内で code フォールバックに使う）
                "docID": docID ?? (initialRegNumber ?? ""),
                "course": course
            ]
        )

        dismiss(animated: true)
    }

    @IBAction func didTapAdd(_ sender: Any) {
        if lastFetched.isEmpty, let id = docID {
            fetchDetail(docID: id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.presentAddConfirmAndPost() }
        } else {
            presentAddConfirmAndPost()
        }
    }

    @IBAction func didTapBookmark(_ sender: Any) {
        guard let id = docID, !id.isEmpty else { return }
        var set = Set(UserDefaults.standard.stringArray(forKey: favoriteKey) ?? [])
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        UserDefaults.standard.set(Array(set), forKey: favoriteKey)
        refreshButtons()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func presentAddConfirmAndPost() {
        let (payload, d, p) = buildPayload(from: lastFetched)
        let name = (payload["class_name"] as? String) ?? "この授業"
        let dayText: String = { if let d = d { return ["月","火","水","木","金","土"][d] } else { return "（曜日不明）" } }()
        let periodText: String = p != nil ? "\(p!)限" : "（時限不明）"
        let ac = UIAlertController(title: "登録しますか？",
                                   message: "\(dayText) \(periodText) に\n「\(name)」を\n登録します。",
                                   preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        ac.addAction(UIAlertAction(title: "登録", style: .default, handler: { [weak self] _ in
            guard let self = self, let id = self.docID, !id.isEmpty else { return }
            var set = Set(UserDefaults.standard.stringArray(forKey: self.plannedKey) ?? [])
            if set.contains(id) { set.remove(id) } else { set.insert(id) }
            UserDefaults.standard.set(Array(set), forKey: self.plannedKey)
            self.refreshButtons()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()

            var info: [String: Any] = ["course": payload, "docID": id]
            if let d = d { info["day"] = d }
            if let p = p { info["period"] = p }
            NotificationCenter.default.post(name: .registerCourseToTimetable, object: nil, userInfo: info)
            print("➡️ payload:", payload)
        }))
        present(ac, animated: true)
    }

    // MARK: - WebView
    private func setupWebView() {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.preferredContentMode = .mobile
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if #available(iOS 11.0, *) {
            webView.scrollView.contentInsetAdjustmentBehavior = .never
        }

        if let container = webContainer {
            container.addSubview(webView)
            webView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: container.topAnchor),
                webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        } else {
            view.addSubview(webView)
            webView.translatesAutoresizingMaskIntoConstraints = false

            // ヘッダー（登録番号/ボタン群）直下から下端まで
            let topAnchor: NSLayoutYAxisAnchor = {
                if let stack = infoStack { return stack.bottomAnchor }
                if let btnHost = addButton?.superview { return btnHost.bottomAnchor }
                if let title = titleTextView { return title.bottomAnchor }
                return view.safeAreaLayoutGuide.topAnchor
            }()
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }

        indicator.hidesWhenStopped = true
        view.addSubview(indicator)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { indicator.startAnimating() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { indicator.stopAnimating() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        indicator.stopAnimating(); print("🌐 web load failed:", error.localizedDescription)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        indicator.stopAnimating(); print("🌐 web provisional failed:", error.localizedDescription)
    }

    // MARK: - Firestore
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

            // URL 取得（url / syllabusURL のどちらでも）
            let urlStr = ((data["url"] as? String) ?? (data["syllabusURL"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let url = URL(string: urlStr), !urlStr.isEmpty {
                self.webView.isHidden = false
                self.webView.load(URLRequest(url: url))
            } else {
                let html = """
                <html><head><meta name="viewport" content="width=device-width, initial-scale=1.0">
                <style>body{font: -apple-system-body; color:#666; margin:24px}</style></head>
                <body><p>リンクURLが見つかりませんでした。</p></body></html>
                """
                self.webView.isHidden = false
                self.webView.loadHTMLString(html, baseURL: nil)
            }

        }
    }

    // MARK: - Header Row re-anchoring
    /// SafeArea.Top ではなく、タイトル直下に “共通の天井” を作って登録番号・追加・ブックマークの Top を揃える
    private func reanchorHeaderRow() {
        guard let root = self.view, let title = self.titleTextView else { return }

        // 既存の Top→SafeArea 制約を無効化（Storyboard差分吸収）
        func deactivateTopToSafeArea(of v: UIView?) {
            guard let v = v else { return }
            for c in root.constraints {
                if (c.firstItem === v && c.firstAttribute == .top) {
                    if let guide = c.secondItem as? UILayoutGuide, guide === root.safeAreaLayoutGuide {
                        c.isActive = false
                    } else if (c.secondItem as? UIView) === root && c.secondAttribute == .top {
                        c.isActive = false
                    }
                }
            }
        }
        deactivateTopToSafeArea(of: codeLabel)
        deactivateTopToSafeArea(of: addButton)
        deactivateTopToSafeArea(of: bookmarkButton)

        // タイトルの「最後のベースライン」から一定距離下にガイドを作る
        let headerGuide = UILayoutGuide()
        root.addLayoutGuide(headerGuide)
        NSLayoutConstraint.activate([
            headerGuide.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerGuide.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerGuide.topAnchor.constraint(equalTo: title.lastBaselineAnchor, constant: 12)
        ])

        // 3つのTopをガイドに=で合わせる（どこからの遷移でも高さが一致）
        func pinTop(_ v: UIView?) {
            guard let v = v else { return }
            v.translatesAutoresizingMaskIntoConstraints = false
            let top = v.topAnchor.constraint(equalTo: headerGuide.topAnchor)
            top.priority = .required
            top.isActive = true
        }
        pinTop(codeLabel)
        pinTop(addButton)
        pinTop(bookmarkButton)

        UIView.performWithoutAnimation { root.layoutIfNeeded() }
    }

    // MARK: - Timetable payload
    // MARK: - Timetable payload
    private func buildPayload(from data: [String: Any]) -> (course: [String: Any], day: Int?, period: Int?) {
        // 文字列トリムのヘルパ
        func trim(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

        let name     = trim(data["class_name"] as? String).isEmpty ? (titleTextView?.text ?? "") : trim(data["class_name"] as? String)
        let teacher  = trim(data["teacher_name"] as? String).isEmpty ? (teacherLabel?.text ?? "") : trim(data["teacher_name"] as? String)

        // code: Firestore → registration_number → initialRegNumber → docID
        let code = trim(data["code"] as? String).isEmpty
            ? ( trim(data["registration_number"] as? String).isEmpty
                ? ( trim(initialRegNumber).isEmpty ? trim(docID) : trim(initialRegNumber) )
                : trim(data["registration_number"] as? String) )
            : trim(data["code"] as? String)

        // url: Firestore(url / syllabusURL) → initialURLString
        let urlStr = {
            let u1 = trim(data["url"] as? String)
            if !u1.isEmpty { return u1 }
            let u2 = trim(data["syllabusURL"] as? String)
            if !u2.isEmpty { return u2 }
            return trim(initialURLString)
        }()

        // room: TextField → initialRoom → Firestore(room)
        let roomStr = {
            let fromUI = trim(roomTextField?.text)
            if !fromUI.isEmpty { return fromUI }
            if let r = initialRoom, !trim(r).isEmpty { return trim(r) }
            return trim(data["room"] as? String)
        }()

        let credit: Int = {
            if let n = data["credit"] as? Int { return n }
            if let s = data["credit"] as? String, let n = Int(s) { return n }
            return 0
        }()

        // day / period は既に targetDay/targetPeriod が来ていればそれを優先
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

        // timetable 側が読むキー名に合わせる（url / code / room）
        let payload: [String: Any] = [
            "class_name": name,
            "teacher_name": teacher,
            "credit": credit,
            "code": code,
            "url": urlStr,
            "room": roomStr
        ]
        return (payload, d, p)
    }


    // 動的再計算は使わない（タイトルが動かないように）
    private func updateTitleVerticalInset() {}
}

// 通知名
extension Notification.Name {
    static let registerCourseToTimetable = Notification.Name("RegisterCourseToTimetable")
}
