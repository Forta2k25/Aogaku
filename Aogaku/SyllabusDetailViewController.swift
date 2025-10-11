import UIKit
import WebKit
import FirebaseFirestore

final class SyllabusDetailViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    // MARK: - Inputs (caller may set)
    var targetDay: Int?          // 0=Mon ... 5=Sat
    var targetPeriod: Int?       // 1..7
    var docID: String?
    var initialTitle: String?
    var initialTeacher: String?
    var initialCredit: String?   // "2" など
    var initialURLString: String?
    var initialRegNumber: String?
    var initialRoom: String?

    // MARK: - IBOutlets (all optional; safe even if not connected)
    @IBOutlet weak var titleTextView: UITextView?
    @IBOutlet weak var addButton: UIButton?
    @IBOutlet weak var bookmarkButton: UIButton?
    @IBOutlet weak var codeLabel: UILabel?
    @IBOutlet weak var teacherLabel: UILabel?
    @IBOutlet weak var creditLabel: UILabel?
    @IBOutlet weak var infoStack: UIStackView?
    @IBOutlet weak var webContainer: UIView?
    @IBOutlet weak var roomTextField: UITextField?

    // MARK: - UserDefaults keys
    private let plannedKey  = "plannedClassIDs"
    private let favoriteKey = "favoriteClassIDs"

    // MARK: - Web
    private var webView: WKWebView!
    private let indicator = UIActivityIndicatorView(style: .large)

    // Firestore raw (used to build payload)
    private var lastFetched: [String: Any] = [:]

    // Navigation appearance backup
    private var savedStandard: UINavigationBarAppearance?
    private var savedScrollEdge: UINavigationBarAppearance?
    private var savedTint: UIColor?

    // MARK: - New UI
    private let roomInfoLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.textAlignment = .left
        l.font = .boldSystemFont(ofSize: 17)
        l.textColor = .label            // ← 動的色：ダークで白、ライトで黒
        l.numberOfLines = 1
        l.backgroundColor = .clear      // 念のため
        l.setContentCompressionResistancePriority(.required, for: .vertical)
        l.setContentHuggingPriority(.required, for: .vertical)
        return l
    }()

    // MARK: - Add flow guard（二重アラート/二重起動防止）
    private var isAddFlowBusy = false

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()

        setupButtonsAppearance()
        setupWebView()
        refreshButtons()
        reanchorHeaderRow()

        // Prefill UI
        titleTextView?.isEditable = false
        titleTextView?.isSelectable = false
        titleTextView?.isScrollEnabled = false
        titleTextView?.backgroundColor = .clear
        titleTextView?.textColor = .white
        titleTextView?.font = .boldSystemFont(ofSize: 20)
        titleTextView?.textAlignment = .center
        titleTextView?.text = (initialTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? initialTitle : "科目名"

        teacherLabel?.text = initialTeacher ?? ""
        if let c = initialCredit, !c.isEmpty { creditLabel?.text = "\(c)単位" }

        // ---- 登録番号ラベルは一行・中央・見切れ防止で戻す
        codeLabel?.textAlignment = .center
        codeLabel?.numberOfLines = 1
        codeLabel?.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        codeLabel?.adjustsFontSizeToFitWidth = true
        codeLabel?.minimumScaleFactor = 0.7
        codeLabel?.lineBreakMode = .byTruncatingMiddle
        codeLabel?.text = ((initialRegNumber ?? "").isEmpty ? "-" : initialRegNumber)

        // ---- 新しい「教室番号」ラベルを登録番号の直下へ追加
        attachRoomInfoLabelBelowCode()

        // 初期値でセット
        updateCodeAndRoomLabels(code: initialRegNumber, room: initialRoom)

        // TextField編集 → 2行目にライブ反映
        roomTextField?.addTarget(self, action: #selector(roomFieldChanged(_:)), for: .editingChanged)

        // Load content
        if let s = initialURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty, let url = URL(string: s) {
            webView.isHidden = false
            webView.load(URLRequest(url: url))
        } else if let id = docID, !id.isEmpty {
            fetchDetail(docID: id)
        }

        // Close button when presented modally
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
        savedStandard   = nav.navigationBar.standardAppearance
        savedScrollEdge = nav.navigationBar.scrollEdgeAppearance
        savedTint       = nav.navigationBar.tintColor

        let a = UINavigationBarAppearance()
        a.configureWithOpaqueBackground()
        a.backgroundColor = .systemBackground
        nav.navigationBar.standardAppearance = a
        nav.navigationBar.scrollEdgeAppearance = a
        nav.navigationBar.compactAppearance = a
        nav.navigationBar.tintColor = .label
        navigationItem.largeTitleDisplayMode = .never
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard let nav = navigationController else { return }
        if let x = savedStandard { nav.navigationBar.standardAppearance = x }
        if let x = savedScrollEdge { nav.navigationBar.scrollEdgeAppearance = x }
        nav.navigationBar.compactAppearance = nav.navigationBar.standardAppearance
        nav.navigationBar.tintColor = savedTint
    }

    private func isAlreadyInTimetable() -> Bool {
        // timetable と同じ保存先（TermStore / Course 型は既存のものを使用）
        let term = TermStore.loadSelected()
        guard let data = UserDefaults.standard.data(forKey: term.storageKey),
              let assigned = try? JSONDecoder().decode([Course?].self, from: data) else {
            return false
        }
        let ids = Set(assigned.compactMap { $0?.id })

        // timetable では Course.id に登録番号（code）を入れて送っています
        let codeFromFetched: String? =
            (lastFetched["registration_number"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (lastFetched["code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? initialRegNumber?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let code = codeFromFetched, ids.contains(code) { return true }
        if let doc = docID, ids.contains(doc) { return true }   // code が無い授業の保険
        return false
    }

    // MARK: - Buttons
    private func setupButtonsAppearance() {
        addButton?.setTitle("", for: .normal)
        bookmarkButton?.setTitle("", for: .normal)
        let sym = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        addButton?.setPreferredSymbolConfiguration(sym, forImageIn: .normal)
        bookmarkButton?.setPreferredSymbolConfiguration(sym, forImageIn: .normal)
        addButton?.accessibilityLabel = "時間割に追加"
        bookmarkButton?.accessibilityLabel = "ブックマーク"
    }

    private func refreshButtons() {
        let fav = Set(UserDefaults.standard.stringArray(forKey: favoriteKey) ?? [])

        // 「時間割に入っているか」だけで決める（planned は参照しない）
        let inTimetable = isAlreadyInTimetable()

        let addSymbol = inTimetable ? "checkmark.circle.fill" : "plus.circle"
        addButton?.setImage(UIImage(systemName: addSymbol), for: .normal)
        addButton?.tintColor = inTimetable ? .systemGreen : .label


        let isFav: Bool = {
            guard let s = docID else { return false }
            return fav.contains(s)
        }()
        let bmSymbol = isFav ? "bookmark.fill" : "bookmark"
        bookmarkButton?.setImage(UIImage(systemName: bmSymbol), for: .normal)
        bookmarkButton?.tintColor = isFav ? .systemOrange : .label

        UIView.performWithoutAnimation { self.view.layoutIfNeeded() }
    }

    // MARK: - Add flow（＋押下時の共通フロー）
    private func startAddFlow() {
        // 多重起動防止
        guard !isAddFlowBusy else { return }
        isAddFlowBusy = true

        // まだ詳細未取得なら取得してから続行
        if lastFetched.isEmpty, let id = docID {
            fetchDetail(docID: id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.continueAddFlow()
            }
        } else {
            continueAddFlow()
        }
    }

    private func continueAddFlow() {
        let (payload, dOpt, pOpt) = buildPayload(from: lastFetched)

        // 曜日 or 時限が未確定なら選択シートを出す
        if let d = dOpt, let p = pOpt {
            presentAddConfirmAndPost(payload: payload, day: d, period: p)
        } else {
            presentDayPeriodPicker(
                defaultDay: targetDay ?? 0,     // 月(0)で初期表示
                defaultPeriod: targetPeriod ?? 1 // 1限で初期表示
            ) { [weak self] day, period in
                guard let self = self else { return }
                self.targetDay = day
                self.targetPeriod = period
                self.presentAddConfirmAndPost(payload: payload, day: day, period: period)
            }
        }
    }

    // 右上の「＋」をStoryboardで繋いでいる場合はこちらを使う
    @IBAction func tapRegisterButton(_ sender: Any) {
        startAddFlow()
    }

    @IBAction func didTapAdd(_ sender: Any) {
        startAddFlow()
    }

    @IBAction func didTapBookmark(_ sender: Any) {
        guard let id = docID, !id.isEmpty else { return }
        var set = Set(UserDefaults.standard.stringArray(forKey: favoriteKey) ?? [])
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        UserDefaults.standard.set(Array(set), forKey: favoriteKey)
        refreshButtons()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func presentAddConfirmAndPost(payload: [String: Any], day: Int, period: Int) {
        let name = (payload["class_name"] as? String) ?? "この授業"
        let dayText = ["月","火","水","木","金","土"][max(0, min(day, 5))]
        let periodText = "\(period)限"

        let ac = UIAlertController(
            title: "登録しますか？",
            message: "\(dayText) \(periodText) に\n「\(name)」を\n登録します。",
            preferredStyle: .alert
        )
        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel, handler: { [weak self] _ in
            self?.isAddFlowBusy = false
        }))
        ac.addAction(UIAlertAction(title: "登録", style: .default, handler: { [weak self] _ in
            guard let self = self, let id = self.docID, !id.isEmpty else { return }

            // planned は使わない。＋からの登録時だけチェックに「楽観更新」
            self.addButton?.setImage(UIImage(systemName: "checkmark.circle.fill"), for: .normal)
            self.addButton?.tintColor = .systemGreen

            UIImpactFeedbackGenerator(style: .light).impactOccurred()

            var info: [String: Any] = ["course": payload, "docID": id, "day": day, "period": period]
            NotificationCenter.default.post(
                name: Notification.Name("RegisterCourseToTimetable"),
                object: nil,
                userInfo: info
            )
            print("➡️ payload:", payload, " day:", day, " period:", period)
            self.isAddFlowBusy = false
        }))

        // 何かが前面にいるならそこから出す（ピッカー閉鎖後でも安全）
        DispatchQueue.main.async {
            let host = self.presentedViewController ?? self
            host.present(ac, animated: true)
        }
    }

    // MARK: - 曜日・時限ピッカー
    private func presentDayPeriodPicker(
        defaultDay: Int = 0,
        defaultPeriod: Int = 1,
        onDone: @escaping (_ day: Int, _ period: Int) -> Void
    ) {
        let vc = DayPeriodPickerVC()
        vc.modalPresentationStyle = .pageSheet
        vc.selectedDay = max(0, min(defaultDay, 5))
        vc.selectedPeriod = max(1, min(defaultPeriod, 7))
        vc.onDone = onDone
        vc.onCancel = { [weak self] in self?.isAddFlowBusy = false } // ← キャンセル時も解除

        if let sheet = vc.sheetPresentationController {
            // タイトル(~44) + 間隔8 + ピッカー216 + 下余白4 + (提示VCの)セーフエリア下
            let customID = UISheetPresentationController.Detent.Identifier("fit")
            sheet.detents = [
                .custom(identifier: customID) { [weak vc] _ in
                    let headerHeight: CGFloat = 44
                    let spacing: CGFloat = 8
                    let pickerHeight: CGFloat = 216
                    let bottomPadding: CGFloat = 4
                    let bottomInset = vc?.view.safeAreaInsets.bottom ?? 0
                    return headerHeight + spacing + pickerHeight + bottomPadding + bottomInset
                }
            ]
            sheet.selectedDetentIdentifier = customID
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            sheet.largestUndimmedDetentIdentifier = customID
        }
        present(vc, animated: true)
    }

    // ピッカーVC本体
    fileprivate final class DayPeriodPickerVC: UIViewController, UIPickerViewDataSource, UIPickerViewDelegate {
        private let days = ["月","火","水","木","金","土"]
        private let periods = Array(1...7)

        var selectedDay: Int = 0
        var selectedPeriod: Int = 1
        var onDone:   ((_ day: Int, _ period: Int) -> Void)?
        var onCancel: (() -> Void)?

        private let picker = UIPickerView()
        private let titleLabel: UILabel = {
            let l = UILabel()
            l.text = "曜日と時限を選択"
            l.textAlignment = .center
            l.font = .boldSystemFont(ofSize: 18)
            return l
        }()
        private let cancelButton: UIButton = {
            let b = UIButton(type: .system)
            b.setTitle("キャンセル", for: .normal)
            return b
        }()
        private let doneButton: UIButton = {
            let b = UIButton(type: .system)
            b.setTitle("決定", for: .normal)
            b.titleLabel?.font = .boldSystemFont(ofSize: 17)
            return b
        }()

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground

            // ヘッダー
            let header = UIStackView(arrangedSubviews: [cancelButton, titleLabel, doneButton])
            header.axis = .horizontal
            header.alignment = .center
            header.distribution = .equalCentering

            // ピッカー設定（0列=曜日, 1列=時限）
            picker.dataSource = self
            picker.delegate = self

            let container = UIStackView(arrangedSubviews: [header, picker])
            container.axis = .vertical
            container.spacing = 8
            container.translatesAutoresizingMaskIntoConstraints = false

            view.addSubview(container)
            // —— 下詰め：下端はsafeAreaにピッタリ／上側は≧制約で余白を吸収
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                container.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
                picker.heightAnchor.constraint(equalToConstant: 216)
            ])
            let topGE = container.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 12)
            topGE.priority = .defaultLow
            topGE.isActive = true
            container.setContentHuggingPriority(.required, for: .vertical)

            // 初期選択
            picker.selectRow(max(0, min(selectedDay, 5)), inComponent: 0, animated: false)
            let pIndex = max(0, min(selectedPeriod - 1, periods.count - 1))
            picker.selectRow(pIndex, inComponent: 1, animated: false)

            // ボタン
            cancelButton.addAction(UIAction { [weak self] _ in
                guard let self = self else { return }
                let cb = self.onCancel
                self.dismiss(animated: true) { cb?() }
            }, for: .touchUpInside)

            doneButton.addAction(UIAction { [weak self] _ in
                guard let self = self else { return }
                let day = self.picker.selectedRow(inComponent: 0)              // 0...5
                let period = self.periods[self.picker.selectedRow(inComponent: 1)] // 1...7
                // 先に閉じてから onDone（= 確認アラート表示）
                self.dismiss(animated: true) { [weak self] in
                    self?.onDone?(day, period)
                }
            }, for: .touchUpInside)
        }

        // MARK: UIPickerViewDataSource/Delegate
        func numberOfComponents(in pickerView: UIPickerView) -> Int { 2 }
        func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
            return (component == 0) ? days.count : periods.count
        }
        func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
            return (component == 0) ? days[row] : "\(periods[row])限"
        }
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
            let topAnchor: NSLayoutYAxisAnchor = {
                if let stack = infoStack { return stack.bottomAnchor }
                // infoStack が無い場合でも新ラベルの直下から開始できるようにする
                if view.subviews.contains(roomInfoLabel) { return roomInfoLabel.bottomAnchor }
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

            if let name = data["class_name"] as? String, (self.titleTextView?.text ?? "").isEmpty {
                self.titleTextView?.text = name
            }
            if let t = data["teacher_name"] as? String, (self.teacherLabel?.text ?? "").isEmpty {
                self.teacherLabel?.text = t
            }
            if let c = data["credit"] as? Int {
                self.creditLabel?.text = "\(c)単位"
            } else if let cStr = data["credit"] as? String, !cStr.isEmpty {
                self.creditLabel?.text = "\(cStr)単位"
            }

            let code = (data["registration_number"] as? String)
                ?? (data["code"] as? String)
                ?? (data["class_code"] as? String)
                ?? (data["course_code"] as? String)
            let room = (data["room"] as? String) ?? self.initialRoom

            self.updateCodeAndRoomLabels(code: code, room: room)

            // TextField 側も未入力なら埋めて同期
            if (self.roomTextField?.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
               let r = data["room"] as? String {
                self.roomTextField?.text = r
            }

            let urlStr = ((data["url"] as? String) ?? (data["syllabusURL"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: urlStr), !urlStr.isEmpty {
                self.webView.isHidden = false
                self.webView.load(URLRequest(url: url))
            }
        }
    }

    // MARK: - Layout helper
    private func reanchorHeaderRow() {
        guard let root = self.view, let title = self.titleTextView else { return }
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

        let headerGuide = UILayoutGuide()
        root.addLayoutGuide(headerGuide)
        NSLayoutConstraint.activate([
            headerGuide.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerGuide.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerGuide.topAnchor.constraint(equalTo: title.lastBaselineAnchor, constant: 12)
        ])

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

    // MARK: - Payload builder（category/credit を必ず載せる）
    private func buildPayload(from data: [String: Any]) -> (course: [String: Any], day: Int?, period: Int?) {

        func trim(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

        // name / teacher: UI > Firestore > initial
        let name: String = {
            let ui = trim(titleTextView?.text); if !ui.isEmpty { return ui }
            let v  = trim(data["class_name"] as? String); if !v.isEmpty { return v }
            return trim(initialTitle)
        }()
        let teacher: String = {
            let ui = trim(teacherLabel?.text); if !ui.isEmpty { return ui }
            let v  = trim(data["teacher_name"] as? String); if !v.isEmpty { return v }
            return trim(initialTeacher)
        }()

        // code: Firestore → registration_number → initial → docID
        let code: String = {
            let c1 = trim(data["code"] as? String); if !c1.isEmpty { return c1 }
            let c2 = trim(data["registration_number"] as? String); if !c2.isEmpty { return c2 }
            let c3 = trim(initialRegNumber); if !c3.isEmpty { return c3 }
            return trim(docID)
        }()

        // url: Firestore(url / syllabusURL) → initial
        let urlStr: String = {
            let u1 = trim(data["url"] as? String); if !u1.isEmpty { return u1 }
            let u2 = trim(data["syllabusURL"] as? String); if !u2.isEmpty { return u2 }
            return trim(initialURLString)
        }()

        // room: TextField → initial → Firestore(room)
        let roomStr: String = {
            let fromUI = trim(roomTextField?.text); if !fromUI.isEmpty { return fromUI }
            let r0 = trim(initialRoom); if !r0.isEmpty { return r0 }
            return trim(data["room"] as? String)
        }()

        // credit: Int / String / initial
        let credit: Int = {
            if let n = data["credit"] as? Int { return n }
            if let s = data["credit"] as? String, let n = Int(s) { return n }
            if let s = initialCredit, let n = Int(s) { return n }
            return 0
        }()

        // category: category → course_category → tags["教職課程科目"]
        let categoryStr: String = {
            let c1 = trim(data["category"] as? String); if !c1.isEmpty { return c1 }
            let c2 = trim(data["course_category"] as? String); if !c2.isEmpty { return c2 }
            if let tags = data["tags"] as? [String], tags.contains("教職課程科目") { return "教職課程科目" }
            return ""
        }()

        // day/period: explicit > Firestore["time"]
        var d = targetDay
        var p = targetPeriod
        if (d == nil || p == nil), let time = data["time"] as? [String: Any] {
            if d == nil {
                if let single = time["day"] as? Int { d = single }
                else if let arr = time["days"] as? [Int], let first = arr.first { d = first }
                else if let dayJ = time["day"] as? String {
                    let ch = dayJ.trimmingCharacters(in: .whitespaces).first
                    d = ["月":0,"火":1,"水":2,"木":3,"金":4,"土":5][ch ?? " "]
                }
            }
            if p == nil {
                if let single = time["period"] as? Int { p = single }
                else if let arr = time["periods"] as? [Int], let first = arr.first { p = first }
            }
        }

        var payload: [String: Any] = [
            "class_name":   name,
            "teacher_name": teacher,
            "code":         code,
            "url":          urlStr,
            "room":         roomStr
        ]
        if credit > 0 { payload["credit"] = credit }
        if !categoryStr.isEmpty { payload["category"] = categoryStr }

        return (payload, d, p)
    }

    private func updateTitleVerticalInset() {}

    // MARK: - New helpers
    private func attachRoomInfoLabelBelowCode() {
        // infoStack があればその直後に差し込む
        if let stack = infoStack {
            if let code = codeLabel, let idx = stack.arrangedSubviews.firstIndex(of: code) {
                stack.insertArrangedSubview(roomInfoLabel, at: idx + 1)
            } else {
                stack.addArrangedSubview(roomInfoLabel)
            }
            // 多少の縦の詰めを効かせる（必要ならStack側のspacingで微調整）
            if stack.spacing < 4 { stack.spacing = 4 }
        } else {
            // infoStack が無い場合は手動で下に固定
            guard let root = view else { return }
            root.addSubview(roomInfoLabel)
            if let code = codeLabel {
                NSLayoutConstraint.activate([
                    roomInfoLabel.topAnchor.constraint(equalTo: code.bottomAnchor, constant: 2),
                    roomInfoLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
                    roomInfoLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16)
                ])
            } else {
                NSLayoutConstraint.activate([
                    roomInfoLabel.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
                    roomInfoLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
                    roomInfoLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16)
                ])
            }
        }
    }

    private func updateCodeAndRoomLabels(code: String?, room: String?) {
        // 登録番号（1行・中央・見切れ防止）
        let codeText = (code?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? code!.trimmingCharacters(in: .whitespacesAndNewlines) : "-"
        codeLabel?.text = codeText

        // 教室番号（空なら「-」／ラベルは常に表示）
        let roomText = (room ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        roomInfoLabel.text = "教室番号：" + (roomText.isEmpty ? "-" : roomText)
    }

    @objc private func roomFieldChanged(_ tf: UITextField) {
        // 取得済み or 初期値から登録番号を再構成
        let code = (lastFetched["registration_number"] as? String)
            ?? (lastFetched["code"] as? String)
            ?? (lastFetched["class_code"] as? String)
            ?? (lastFetched["course_code"] as? String)
            ?? initialRegNumber
        updateCodeAndRoomLabels(code: code, room: tf.text)
    }
}
