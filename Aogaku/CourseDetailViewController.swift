
import UIKit
import WebKit
import FirebaseFirestore
import FirebaseAuth
import GoogleMobileAds

// すでに別所で定義済みなら削除OK
struct AttendanceCounts: Codable {
    var attended: Int
    var late: Int
    var absent: Int
}

protocol CourseDetailViewControllerDelegate: AnyObject {
    func courseDetail(_ vc: CourseDetailViewController,
                      requestEditFor course: Course,
                      at location: SlotLocation)
    func courseDetail(_ vc: CourseDetailViewController,
                      requestDelete course: Course,
                      at location: SlotLocation)
    func courseDetail(_ vc: CourseDetailViewController,
                      didUpdate counts: AttendanceCounts,
                      for course: Course,
                      at location: SlotLocation)
    func courseDetail(_ vc: CourseDetailViewController,
                      didChangeColor key: SlotColorKey,
                      at location: SlotLocation)
    func courseDetail(_ vc: CourseDetailViewController,
                      didEdit course: Course,
                      at location: SlotLocation) // [ADDED] 教室編集の反映に使う
}

final class CourseDetailViewController: UIViewController {

    // MARK: - Inputs
    weak var delegate: CourseDetailViewControllerDelegate?
    private let course: Course
    private let location: SlotLocation
    private let titleHeader = UIView()   // 緑の帯コンテナ
    private let showsAttendanceControls: Bool
    private let allowsCourseManagement: Bool
    private let showsEnrolledFriends: Bool
    private let showsMoodleAssignments: Bool

    // MARK: - Color Picker
    private let colorKeys: [SlotColorKey] = [.blue, .green, .orange, .red, .teal, .gray, .purple]
    private var colorButtons: [UIButton] = []

    // MARK: - UI
    private let scroll = UIScrollView()
    private let stack  = UIStackView()

    private let titleLabel = UILabel()
    private let infoLabel  = UILabel()
    private let roomLabel = UILabel()          // editRoomTapped で text を更新（旧ビューとの互換用）
    private weak var roomSyllabusPillLabel: UILabel?  // シラバスピル内ラベル（編集後に即時反映）
    
    private let term: TermKey

    private let summaryRow = UIStackView()
    private let metaCard   = UIView()


    private let countersRow = UIStackView()
    private let attendBtn = UIButton(type: .system)
    private let lateBtn   = UIButton(type: .system)
    private let absentBtn = UIButton(type: .system)

    private let webView = WKWebView()
    private let webContainer = UIView()          // ← プロパティのコンテナを使う（ローカルで再定義しない）
    private var webHeightConstraint: NSLayoutConstraint!

    // MARK: - Syllabus native extraction
    private let syllabusSection      = UIStackView()
    private let syllabusLoadingRow   = UIView()
    private let syllabusSpinner      = UIActivityIndicatorView(style: .medium)
    private let syllabusLoadingHint  = UILabel()   // 初回ロード時のみ表示するヒント
    private let syllabusDetailToggle = UIButton(type: .system)
    private let syllabusDetailStack  = UIStackView()
    private var isSyllabusDetailOpen = false
    private var syllabusPageURL: URL?

    private let editButton   = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)

    // MARK: - AdMob
    private let adContainer = UIView()
    private var bannerView: BannerView?
    private var adContainerHeight: NSLayoutConstraint?
    private var lastBannerWidth: CGFloat = 0
    private var didLoadBannerOnce = false
    
    // 「コマの色を変更」の横に置くボタン
    private let memoButton = UIButton(type: .system)

    
    //色変更
    private let colorToggle = UIButton(type: .system)
    private let colorRow = UIStackView()
    private var isColorRowOpen = false
    private let actionsRow = UIStackView()

    // MARK: - Friends in Course
    private let friendsCourseSection = UIView()
    private let friendsCourseScroll  = UIScrollView()
    private let friendsCourseStack   = UIStackView()
    
    //下端のバー

    // MARK: - Syllabus Actions (シラバスTabから開いたとき)
    private let showsSyllabusActions: Bool
    private let syllabusDocID: String?        // Firestore docID（ブックマーク用）
    private var isAddFlowBusy = false
    private weak var syllabusAddButton: UIButton?
    private weak var syllabusBookmarkButton: UIButton?
    private let syllabusBookmarkKey = "favoriteClassIDs"

    // MARK: - Moodle Assignments
    private let moodleSection = UIView()
    private var courseAssignments: [MoodleEvent] = []
    private var moodlePastContainer: UIStackView?  // 期限切れ行の親スタック
    private var moodlePastExpanded = false          // 折りたたみ状態

    // MARK: - Attendance
    private var counts = AttendanceCounts(attended: 0, late: 0, absent: 0)
    private var attendanceKey: String {
        "attendance.\(term.storageKey).d\(location.day).p\(location.period)"
    }

    // MARK: - Init
    // 変更（引数を term: TermKey 付きに）
    init(course: Course,
         location: SlotLocation,
         term: TermKey,
         showsAttendanceControls: Bool = true,
         allowsCourseManagement: Bool = true,
         showsEnrolledFriends: Bool = true,
         showsMoodleAssignments: Bool = true,
         showsSyllabusActions: Bool = false,
         syllabusDocID: String? = nil) {
        self.course = course
        self.location = location
        self.term = term
        self.showsAttendanceControls = showsAttendanceControls
        self.allowsCourseManagement = allowsCourseManagement
        self.showsEnrolledFriends = showsEnrolledFriends
        self.showsMoodleAssignments = showsMoodleAssignments
        self.showsSyllabusActions = showsSyllabusActions
        self.syllabusDocID = syllabusDocID
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle
    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let sheet = sheetPresentationController {
            sheet.prefersGrabberVisible = true
        }
        buildLayout()
        if showsSyllabusActions {
            buildSyllabusActionButtons()
        }
        if showsAttendanceControls {
            loadCounts()
            updateCounterButtons()
        }
        loadSyllabus()         // URL検証つき読込
        if allowsCourseManagement {
            buildColorPickerRow()  // タイトル直下に設置
        }
        if showsEnrolledFriends {
            loadFriendsInCourse()  // この授業を履修してる友だち
        }
        if showsMoodleAssignments {
            loadMoodleAssignments() // Moodle 課題
        }
        setupAdBanner()
        NotificationCenter.default.addObserver(self, selector: #selector(onAdMobReady),
                                               name: .adMobReady, object: nil)
        
        
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if #available(iOS 16.0, *),
           let sheet = sheetPresentationController {
            sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
        }
    }


    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        loadBannerIfNeeded()
    }

    // MARK: - Layout
    private func buildLayout() {
        // スクロール + 縦スタック
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentInsetAdjustmentBehavior = .never
        view.addSubview(scroll)
        scroll.addSubview(stack)
        
        let headerContainer = UIView()
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(headerContainer)

        // adContainer（バナー広告）を画面下部に配置
        adContainer.translatesAutoresizingMaskIntoConstraints = false
        adContainer.backgroundColor = .systemBackground
        view.addSubview(adContainer)
        adContainerHeight = adContainer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            adContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            adContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            adContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            adContainerHeight!,
        ])

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 0),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: adContainer.topAnchor),

            stack.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            headerContainer.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            headerContainer.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor)
        ])

        // ===== 緑のタイトル帯 =====
        titleHeader.backgroundColor = UIColor(red: 0/255, green: 120/255, blue: 87/255, alpha: 1)
        
        titleHeader.layer.cornerRadius = 0
        titleHeader.layer.masksToBounds = true
        titleHeader.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(titleHeader)

        titleLabel.text = course.title
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.numberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleHeader.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: titleHeader.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: titleHeader.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: titleHeader.trailingAnchor, constant: -16),
            titleLabel.bottomAnchor.constraint(equalTo: titleHeader.bottomAnchor, constant: -16),
            titleHeader.heightAnchor.constraint(greaterThanOrEqualToConstant: 72),
            titleHeader.topAnchor.constraint(equalTo: headerContainer.topAnchor),
            titleHeader.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            titleHeader.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            titleHeader.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor)
        ])
        
        // 追加：セーフエリア上部の白い帯を緑で覆う
        let topCap = UIView()
        topCap.backgroundColor = UIColor(red: 0/255, green: 120/255, blue: 87/255, alpha: 1)
        topCap.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topCap)
        NSLayoutConstraint.activate([
            topCap.topAnchor.constraint(equalTo: view.topAnchor),
            topCap.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topCap.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topCap.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        ])


        // ◆ 担当教員や科目名の重複表示は出さない
        infoLabel.isHidden = true

        if showsEnrolledFriends {
            // ===== この授業を履修してる友だち（最上部）=====
            buildFriendsCourseSection()
        }

        if showsAttendanceControls {
            // 出欠カウンター
            countersRow.axis         = .horizontal
            countersRow.alignment    = .fill
            countersRow.distribution = .fillEqually
            countersRow.spacing      = 8
            countersRow.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(countersRow)

            setupCounterButton(attendBtn, tag: 0, label: "出席")
            setupCounterButton(lateBtn,   tag: 1, label: "遅刻")
            setupCounterButton(absentBtn, tag: 2, label: "欠席")
            countersRow.addArrangedSubview(attendBtn)
            countersRow.addArrangedSubview(lateBtn)
            countersRow.addArrangedSubview(absentBtn)
        }

        if showsMoodleAssignments {
            // ──── Moodle 課題セクション ────
            moodleSection.translatesAutoresizingMaskIntoConstraints = false
            moodleSection.backgroundColor = .secondarySystemBackground
            moodleSection.layer.cornerRadius = 12
            moodleSection.layer.masksToBounds = true
            moodleSection.isHidden = true
            stack.addArrangedSubview(moodleSection)
        }

        // ──── シラバスセクション（JS抽出のネイティブカード） ────
        syllabusSection.axis = .vertical
        syllabusSection.spacing = 10
        syllabusSection.isHidden = true
        stack.addArrangedSubview(syllabusSection)

        // ローディング行（スピナー + 初回ヒントラベル）
        syllabusLoadingRow.translatesAutoresizingMaskIntoConstraints = false
        syllabusSpinner.translatesAutoresizingMaskIntoConstraints = false
        syllabusSpinner.hidesWhenStopped = true

        syllabusLoadingHint.text          = "初回のみ数秒かかります"
        syllabusLoadingHint.font          = .systemFont(ofSize: 11)
        syllabusLoadingHint.textColor     = .tertiaryLabel
        syllabusLoadingHint.textAlignment = .center
        syllabusLoadingHint.isHidden      = true   // loadSyllabus() で初回時のみ表示
        syllabusLoadingHint.translatesAutoresizingMaskIntoConstraints = false

        syllabusLoadingRow.addSubview(syllabusSpinner)
        syllabusLoadingRow.addSubview(syllabusLoadingHint)
        NSLayoutConstraint.activate([
            syllabusSpinner.centerXAnchor.constraint(equalTo: syllabusLoadingRow.centerXAnchor),
            syllabusSpinner.topAnchor.constraint(equalTo: syllabusLoadingRow.topAnchor, constant: 14),

            syllabusLoadingHint.topAnchor.constraint(equalTo: syllabusSpinner.bottomAnchor, constant: 6),
            syllabusLoadingHint.centerXAnchor.constraint(equalTo: syllabusLoadingRow.centerXAnchor),
            syllabusLoadingHint.bottomAnchor.constraint(equalTo: syllabusLoadingRow.bottomAnchor, constant: -14)
        ])
        syllabusSection.addArrangedSubview(syllabusLoadingRow)

        // WebView（プロパティの webContainer を使用）
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webContainer.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor)
        ])
        webHeightConstraint = webContainer.heightAnchor.constraint(equalToConstant: 600)
        webHeightConstraint.isActive = true
        stack.addArrangedSubview(webContainer)
        webContainer.isHidden = true  // JSでデータ抽出するが生WebViewはUIに出さない

        if allowsCourseManagement {
            // 編集・削除ボタン（スクロール末尾）
            buildActionButtonsInScroll()
        }
    }
    

    // MARK: - Friends in Course

    private func buildFriendsCourseSection() {
        friendsCourseSection.translatesAutoresizingMaskIntoConstraints = false
        friendsCourseSection.isHidden = true   // 該当する友だちが見つかるまで非表示
        stack.addArrangedSubview(friendsCourseSection)

        // セクションラベル
        let label = UILabel()
        label.text = "この授業を履修してる友だち"
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        friendsCourseSection.addSubview(label)

        // 下線
        let underline = UIView()
        underline.backgroundColor = UIColor.label.withAlphaComponent(0.15)
        underline.translatesAutoresizingMaskIntoConstraints = false
        friendsCourseSection.addSubview(underline)

        // 横スクロール
        friendsCourseScroll.translatesAutoresizingMaskIntoConstraints = false
        friendsCourseScroll.showsHorizontalScrollIndicator = false
        friendsCourseSection.addSubview(friendsCourseScroll)

        // 横並びスタック（名前付きアイコン）
        friendsCourseStack.axis = .horizontal
        friendsCourseStack.spacing = 16
        friendsCourseStack.alignment = .top
        friendsCourseStack.translatesAutoresizingMaskIntoConstraints = false
        friendsCourseScroll.addSubview(friendsCourseStack)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: friendsCourseSection.topAnchor),
            label.leadingAnchor.constraint(equalTo: friendsCourseSection.leadingAnchor),

            underline.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 3),
            underline.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            underline.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            underline.heightAnchor.constraint(equalToConstant: 1),

            friendsCourseScroll.topAnchor.constraint(equalTo: underline.bottomAnchor, constant: 10),
            friendsCourseScroll.leadingAnchor.constraint(equalTo: friendsCourseSection.leadingAnchor),
            friendsCourseScroll.trailingAnchor.constraint(equalTo: friendsCourseSection.trailingAnchor),
            friendsCourseScroll.bottomAnchor.constraint(equalTo: friendsCourseSection.bottomAnchor),
            friendsCourseScroll.heightAnchor.constraint(equalToConstant: 76),

            friendsCourseStack.topAnchor.constraint(equalTo: friendsCourseScroll.contentLayoutGuide.topAnchor),
            friendsCourseStack.leadingAnchor.constraint(equalTo: friendsCourseScroll.contentLayoutGuide.leadingAnchor),
            friendsCourseStack.trailingAnchor.constraint(equalTo: friendsCourseScroll.contentLayoutGuide.trailingAnchor),
            friendsCourseStack.bottomAnchor.constraint(equalTo: friendsCourseScroll.contentLayoutGuide.bottomAnchor),
            friendsCourseStack.heightAnchor.constraint(equalTo: friendsCourseScroll.frameLayoutGuide.heightAnchor)
        ])
    }

    private func loadFriendsInCourse() {
        guard Auth.auth().currentUser != nil else { return }
        let db = Firestore.firestore()
        let docId = term.storageKey

        FriendService.shared.fetchFriends { [weak self] result in
            guard let self else { return }
            guard case .success(let friends) = result, !friends.isEmpty else { return }

            DispatchQueue.main.async {
                self.friendsCourseSection.isHidden = true
                self.friendsCourseStack.arrangedSubviews.forEach {
                    self.friendsCourseStack.removeArrangedSubview($0)
                    $0.removeFromSuperview()
                }

                // All mutations to matched/pending happen on the main thread
                var matched: [(uid: String, name: String)] = []
                var pending = friends.count

                func onMain_checkDone() {
                    // Must be called on main thread
                    pending -= 1
                    guard pending <= 0 else { return }
                    guard !matched.isEmpty else { return }
                    self.friendsCourseSection.isHidden = false
                    for m in matched { self.addFriendChip(uid: m.uid, name: m.name) }
                }

                for friend in friends {
                    let uid = friend.friendUid
                    let name = friend.friendName
                    db.collection("users").document(uid)
                      .collection("timetable").document(docId)
                      .getDocument { snap, _ in
                          DispatchQueue.main.async {
                              guard let data = snap?.data() else { onMain_checkDone(); return }
                              let found = self.courseCells(from: data).contains {
                                  self.courseCell($0, matches: self.course)
                              }
                              if found { matched.append((uid: uid, name: name)) }
                              onMain_checkDone()
                          }
                      }
                }
            }
        }
    }

    private func courseCells(from data: [String: Any]) -> [[String: Any]] {
        var cells: [[String: Any]] = []

        // Current flat shape: ["cells.d0p1": courseMap, "cells.d0p0_hash": courseMap]
        for (key, value) in data {
            guard key.hasPrefix("cells.d"), !key.hasSuffix(".u"),
                  let cell = value as? [String: Any] else { continue }
            cells.append(cell)
        }

        // Firestore can also materialize dotted writes as nested maps:
        // ["cells": ["d0p1": courseMap]] or ["cells": ["d0": ["p1": courseMap]]]
        if let nested = data["cells"] as? [String: Any] {
            for (key, value) in nested {
                if key.hasPrefix("d"),
                   let cell = value as? [String: Any],
                   isCourseCell(cell) {
                    cells.append(cell)
                    continue
                }

                guard let dayMap = value as? [String: Any] else { continue }
                for (_, periodValue) in dayMap {
                    if let cell = periodValue as? [String: Any], isCourseCell(cell) {
                        cells.append(cell)
                    }
                }
            }
        }

        return cells
    }

    private func isCourseCell(_ cell: [String: Any]) -> Bool {
        let id = normalizedCourseText(cell["id"] as? String)
        let title = normalizedCourseText(cell["title"] as? String)
        return !id.isEmpty || !title.isEmpty
    }

    private func courseCell(_ cell: [String: Any], matches target: Course) -> Bool {
        let cellId = normalizedCourseText(cell["id"] as? String)
        let targetId = normalizedCourseText(target.id)
        let cellTitle = normalizedCourseText(cell["title"] as? String)
        let targetTitle = normalizedCourseText(target.title)
        let cellTeacher = normalizedCourseText(cell["teacher"] as? String)
        let targetTeacher = normalizedCourseText(target.teacher)

        if !targetId.isEmpty, !cellId.isEmpty, cellId != targetId { return false }
        if !targetTitle.isEmpty, !cellTitle.isEmpty, cellTitle != targetTitle { return false }
        if !targetTeacher.isEmpty, !cellTeacher.isEmpty, cellTeacher != targetTeacher { return false }

        if !targetId.isEmpty, !cellId.isEmpty { return true }
        if !targetTitle.isEmpty, !cellTitle.isEmpty {
            return targetTeacher.isEmpty || cellTeacher.isEmpty || cellTeacher == targetTeacher
        }
        return false
    }

    private func normalizedCourseText(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
    }

    private func addFriendChip(uid: String, name: String) {
        // 外コンテナ（縦：アイコン＋名前）
        let chip = UIStackView()
        chip.axis = .vertical
        chip.alignment = .center
        chip.spacing = 4

        // アバター画像ビュー
        let av = UIImageView()
        av.translatesAutoresizingMaskIntoConstraints = false
        av.widthAnchor.constraint(equalToConstant: 44).isActive = true
        av.heightAnchor.constraint(equalToConstant: 44).isActive = true
        av.layer.cornerRadius = 22
        av.layer.masksToBounds = true
        av.contentMode = .scaleAspectFill
        av.backgroundColor = .systemGray5
        av.image = UIImage(systemName: "person.crop.circle.fill")
        av.tintColor = .systemGray3
        av.contentMode = .scaleAspectFit

        // 名前ラベル
        let nameLabel = UILabel()
        nameLabel.text = name
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = .secondaryLabel
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 52).isActive = true

        chip.addArrangedSubview(av)
        chip.addArrangedSubview(nameLabel)
        friendsCourseStack.addArrangedSubview(chip)

        // ディスクキャッシュ確認 → なければネット取得
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diskImg = AvatarCache.shared.anyImage(uid: uid)
            DispatchQueue.main.async {
                if let img = diskImg {
                    av.image = img
                    av.contentMode = .scaleAspectFill
                    av.backgroundColor = .systemGray5
                    return
                }
                // FirestoreからphotoURLを取得してダウンロード
                self?.fetchAvatarForChip(uid: uid, imageView: av)
            }
        }
    }

    private func fetchAvatarForChip(uid: String, imageView: UIImageView) {
        let db = Firestore.firestore()
        db.collection("users").document(uid).getDocument { snap, _ in
            guard let urlString = snap?.data()?["photoURL"] as? String else { return }
            ImageFetcher.fetch(urlString: urlString) { img in
                guard let img else { return }
                DispatchQueue.global(qos: .background).async {
                    AvatarCache.shared.store(img, uid: uid, version: nil)
                }
                DispatchQueue.main.async {
                    imageView.image = img
                    imageView.contentMode = .scaleAspectFill
                    imageView.backgroundColor = .systemGray5
                }
            }
        }
    }

    // MARK: - Color Picker Row（「コマの色を変更」ボタン → 折りたたみ展開）
    private func buildColorPickerRow() {
        // === トグルボタン（小さめ） ===
        var cfg = UIButton.Configuration.plain()
        cfg.title = "コマの色を変更"
        cfg.image = UIImage(systemName: "chevron.down")
        cfg.imagePlacement = .trailing
        cfg.imagePadding = 4
        cfg.contentInsets = .init(top: 4, leading: 10, bottom: 4, trailing: 10)
        colorToggle.configuration = cfg
        colorToggle.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        colorToggle.backgroundColor = .secondarySystemBackground
        colorToggle.layer.cornerRadius = 12
        colorToggle.layer.masksToBounds = true
        colorToggle.setContentHuggingPriority(.required, for: .horizontal)
        colorToggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        colorToggle.addTarget(self, action: #selector(toggleColorPicker), for: .touchUpInside)

        // === 右上に寄せる行（[spacer][button]） ===
        actionsRow.axis = .horizontal
        actionsRow.alignment = .center
        actionsRow.distribution = .fill
        actionsRow.isLayoutMarginsRelativeArrangement = true
        actionsRow.layoutMargins = .init(top: 0, left: 0, bottom: 0, right: 0)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 「教室番号を編集」ボタン
        var editRoomCfg = UIButton.Configuration.plain()
        editRoomCfg.title = "教室番号を編集"
        editRoomCfg.image = UIImage(systemName: "pencil")
        editRoomCfg.imagePlacement = .leading
        editRoomCfg.imagePadding = 6
        editRoomCfg.contentInsets = .init(top: 4, leading: 10, bottom: 4, trailing: 10)
        memoButton.configuration = editRoomCfg
        memoButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        memoButton.backgroundColor = .secondarySystemBackground
        memoButton.layer.cornerRadius = 12
        memoButton.layer.masksToBounds = true
        memoButton.setContentHuggingPriority(.required, for: .horizontal)
        memoButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        memoButton.addTarget(self, action: #selector(editRoomTapped), for: .touchUpInside)

        actionsRow.spacing = 8
        actionsRow.addArrangedSubview(spacer)
        actionsRow.addArrangedSubview(memoButton)
        actionsRow.addArrangedSubview(colorToggle)


        // stack のいちばん上に差し込む（緑ヘッダーの直下）
        stack.insertArrangedSubview(actionsRow, at: 0)

        // === 色ボタンの行（最初は閉じておく） ===
        colorRow.axis = .horizontal
        colorRow.alignment = .center
        colorRow.distribution = .equalSpacing
        colorRow.spacing = 12
        colorRow.isLayoutMarginsRelativeArrangement = true
        colorRow.layoutMargins = .init(top: 4, left: 8, bottom: 8, right: 8)
        colorRow.isHidden = true
        colorRow.alpha  = 0
        stack.insertArrangedSubview(colorRow, at: 1)

        // 色ボタンを並べる
        colorButtons = colorKeys.enumerated().map { (i, key) in
            let b = UIButton(type: .system)
            b.tag = i
            b.backgroundColor = key.cellDisplayColor
            b.layer.cornerRadius = 18
            b.layer.borderWidth = 1
            b.layer.borderColor = UIColor.separator.cgColor
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 36).isActive = true
            b.heightAnchor.constraint(equalToConstant: 36).isActive = true
            b.addTarget(self, action: #selector(colorTapped(_:)), for: .touchUpInside)
            colorRow.addArrangedSubview(b)
            return b
        }

        // 現在色の選択状態を反映
        if let current = SlotColorStore.color(for: location) {
            updateSelectedColorUI(selected: current)
        }
    }


    @objc private func toggleColorPicker() {
        isColorRowOpen.toggle()

        // 閉じている→開く ときは先に表示してからフェード
        if isColorRowOpen { colorRow.isHidden = false }

        // タイトルと矢印を差し替え
        var cfg = colorToggle.configuration ?? .plain()
        cfg.title = isColorRowOpen ? "閉じる" : "コマの色を変更"
        cfg.image = UIImage(systemName: isColorRowOpen ? "chevron.up" : "chevron.down")
        colorToggle.configuration = cfg

        UIView.animate(withDuration: 0.25, animations: {
            self.colorRow.alpha = self.isColorRowOpen ? 1 : 0
            self.view.layoutIfNeeded()
        }, completion: { _ in
            // 開いていた→閉じる ときはアニメ後に非表示
            if !self.isColorRowOpen { self.colorRow.isHidden = true }
        })
    }
    /// TermKey から (year, termCode) を作る
    /// termCode: "S"=前期, "F"=後期, "Y"=通年/その他
    private func yearAndTermCode() -> (Int, String) {
        let term = TermStore.loadSelected()  // 現在選択中の学期
        let title = term.displayTitle        // 例: "2025年前期"

        // 年（先頭の西暦4桁を拾う。取れなければ今年）
        let y = Int(title.prefix(4)) ?? Calendar.current.component(.year, from: Date())

        // 学期コード
        let code: String
        if title.contains("前期") { code = "S" }
        else if title.contains("後期") { code = "F" }
        else if title.contains("通年") { code = "Y" }
        else { code = "Y" } // 不明な場合は通年扱い

        return (y, code)
    }

    
    @objc private func openMemoTasks() {
        // 年度・学期コード
        let (year, termCode) = yearAndTermCode()

        // 0=月…の day を 1=Mon… に変換 / 時限はそのまま
        let weekday = location.day + 1
        let period  = location.period

        let slot = SlotContext(year: year, termCode: termCode, weekday: weekday, period: period)

        let vc = MemoTaskViewController(
            courseId: "\(course.id)",
            courseTitle: course.title,
            slot: slot
        )
        if let nav = navigationController {
            nav.pushViewController(vc, animated: true)
        } else {
            let nav = UINavigationController(rootViewController: vc)
            present(nav, animated: true)
        }
    }




    
    @objc private func editRoomTapped() { // [ADDED]
        let ac = UIAlertController(title: "教室を編集",
                                   message: "例: D314, 1号館304 など",
                                   preferredStyle: .alert)
        ac.addTextField { tf in
            tf.placeholder = "教室"
            tf.text = self.course.room.trimmingCharacters(in: .whitespacesAndNewlines)
            tf.clearButtonMode = .whileEditing
            tf.returnKeyType = .done
        }
        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        ac.addAction(UIAlertAction(title: "保存", style: .default, handler: { [weak self] _ in
            guard let self = self else { return }
            let raw = ac.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let newRoom = raw.isEmpty ? "-" : raw

            // 画面は即時更新
            self.roomLabel.text = "教室  \(newRoom)"
            self.roomSyllabusPillLabel?.text = "教室： \(newRoom)"

            // 親へ更新済み Course を通知（親側でローカル配列更新＋Firestore upsert）
            var edited = self.course            // Course が struct でプロパティが var の想定
            edited.room = newRoom               // ここだけ差し替え
            self.delegate?.courseDetail(self, didEdit: edited, at: self.location)
        }))
        present(ac, animated: true)
    }


    @objc private func colorTapped(_ sender: UIButton) {
        let key = colorKeys[sender.tag]
        let name: String = {
            switch key {
            case .blue: return "青"
            case .green: return "緑"
            case .orange: return "オレンジ"
            case .red: return "赤"
            case .teal: return "エメラルドグリーン"
            case .gray: return "グレー"
            case .purple: return "紫"
            }
        }()

        let ac = UIAlertController(
            title: "色の変更",
            message: "このコマの色を「\(name)」に変更しますか？",
            preferredStyle: .alert
        )
        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        ac.addAction(UIAlertAction(title: "OK", style: .default, handler: { [weak self] _ in
            guard let self = self else { return }
            // 時間割へ通知（裏のセル色が即時変わる）
            self.delegate?.courseDetail(self, didChangeColor: key, at: self.location)
            // 自身のUI（選択リング）も更新
            self.updateSelectedColorUI(selected: key)
        }))
        present(ac, animated: true)
    }
    
    

    private func updateSelectedColorUI(selected: SlotColorKey) {
        for (i, b) in colorButtons.enumerated() {
            b.layer.borderWidth = (colorKeys[i] == selected) ? 3 : 1
        }
    }

    // MARK: - Web
    private func loadSyllabus() {
        guard
            let s = course.syllabusURL?.trimmingCharacters(in: .whitespacesAndNewlines),
            let url = URL(string: s),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            syllabusSection.isHidden = true
            webContainer.isHidden = true
            return
        }
        syllabusPageURL = url
        syllabusSection.isHidden = false

        // ── キャッシュがあればオフライン表示 ──
        // URLをキーにすることで、同じ登録番号の別授業（担当教員違い）でもキャッシュが混在しない
        let cacheKey: String = {
            let u = (course.syllabusURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return u.isEmpty ? course.id : u
        }()
        if let cached = SyllabusDataCache.shared.load(for: cacheKey) {
            buildSyllabusUI(fields: cached)
            return
        }

        // ── キャッシュなし → WebView で読み込む（初回ヒントを表示）──
        syllabusLoadingHint.isHidden = false
        syllabusSpinner.startAnimating()
        webContainer.isHidden = true
        webView.navigationDelegate = self
        webView.load(URLRequest(url: url))
    }

    // MARK: - Syllabus UI Building
    private func buildSyllabusUI(fields: [String: String]) {
        syllabusSpinner.stopAnimating()
        syllabusLoadingRow.isHidden = true

        let currentWeek = currentSyllabusWeek()

        // セクションタイトル行（ラベル + キャッシュ済みなら「更新」ボタン）
        let headerRow = UIStackView()
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = 8

        let header = UILabel()
        header.text = "シラバス"
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.textColor = .secondaryLabel
        headerRow.addArrangedSubview(header)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerRow.addArrangedSubview(spacer)

        // キャッシュ済みのとき「更新」ボタンを表示
        let syllabusKey: String = {
            let u = (course.syllabusURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return u.isEmpty ? course.id : u
        }()
        if SyllabusDataCache.shared.exists(for: syllabusKey) {
            var cfg = UIButton.Configuration.plain()
            cfg.title = "更新"
            cfg.image = UIImage(systemName: "arrow.clockwise")
            cfg.imagePlacement = .leading
            cfg.imagePadding = 4
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0)
            cfg.baseForegroundColor = .tertiaryLabel
            cfg.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 10)
            let refreshBtn = UIButton(type: .system)
            refreshBtn.configuration = cfg
            refreshBtn.titleLabel?.font = .systemFont(ofSize: 11)
            refreshBtn.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                let ck: String = {
                    let u = (self.course.syllabusURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return u.isEmpty ? self.course.id : u
                }()
                SyllabusDataCache.shared.clear(for: ck)
                // シラバスセクションをリセットして再読み込み
                self.syllabusSection.arrangedSubviews.forEach { $0.removeFromSuperview() }
                self.syllabusLoadingRow.isHidden = false
                self.syllabusSection.addArrangedSubview(self.syllabusLoadingRow)
                self.isSyllabusDetailOpen = false
                self.loadSyllabus()
            }, for: .touchUpInside)
            headerRow.addArrangedSubview(refreshBtn)
        }

        syllabusSection.addArrangedSubview(headerRow)

        // ── メタ情報（成績評価の上に常時表示） ──
        // 担当教員を1行目、年度・学期・単位を2行目に縦並び
        var usedKeys = Set<String>()

        let metaBlock = UIStackView()
        metaBlock.axis = .vertical
        metaBlock.spacing = 6
        metaBlock.alignment = .leading
        var metaBlockHasContent = false

        // 1行目: 担当教員
        if let teacher = fields["__教員名"], !teacher.isEmpty {
            let teacherRow = UIStackView()
            teacherRow.axis = .horizontal
            teacherRow.spacing = 8
            teacherRow.alignment = .center
            teacherRow.addArrangedSubview(makeSyllabusPill(label: "担当教員", value: teacher))
            let tsp = UIView()
            tsp.setContentHuggingPriority(.defaultLow, for: .horizontal)
            teacherRow.addArrangedSubview(tsp)
            metaBlock.addArrangedSubview(teacherRow)
            metaBlockHasContent = true
        }

        // 2行目: 年度・学期・単位
        let subPills: [(String, String?)] = [
            ("年度", fields["__年度"]),
            ("学期", fields["__学期"]),
            ("単位", fields["__単位"].flatMap { $0.isEmpty ? nil : $0 + "単位" })
        ]
        let filteredSub = subPills.compactMap { (label, val) -> (String, String)? in
            guard let v = val, !v.isEmpty else { return nil }
            return (label, v)
        }
        if !filteredSub.isEmpty {
            let subRow = UIStackView()
            subRow.axis = .horizontal
            subRow.spacing = 8
            subRow.alignment = .center
            for (label, val) in filteredSub {
                subRow.addArrangedSubview(makeSyllabusPill(label: label, value: val))
            }
            let ssp = UIView()
            ssp.setContentHuggingPriority(.defaultLow, for: .horizontal)
            subRow.addArrangedSubview(ssp)
            metaBlock.addArrangedSubview(subRow)
            metaBlockHasContent = true
        }

        // 3行目: 教室・ID（担当教員・年度と同じスタイル）
        let roomText = course.room.trimmingCharacters(in: .whitespaces)
        let roomVal  = roomText.isEmpty ? "-" : roomText

        // 教室ピルは編集後に即時更新できるようラベルを保持
        let roomInnerLbl = UILabel()
        roomInnerLbl.text          = "教室： \(roomVal)"
        roomInnerLbl.font          = .systemFont(ofSize: 13, weight: .medium)
        roomInnerLbl.numberOfLines = 1
        roomInnerLbl.lineBreakMode = .byTruncatingTail
        roomSyllabusPillLabel = roomInnerLbl

        let roomSyllabusPill = makeSyllabusPillWithLabel(roomInnerLbl)
        if allowsCourseManagement {
            roomSyllabusPill.isUserInteractionEnabled = true
            roomSyllabusPill.addGestureRecognizer(
                UITapGestureRecognizer(target: self, action: #selector(editRoomTapped)))
        }

        let idSyllabusPill = makeSyllabusPill(label: "ID", value: course.id)

        let courseInfoRow = UIStackView(arrangedSubviews: [roomSyllabusPill, idSyllabusPill])
        courseInfoRow.axis      = .horizontal
        courseInfoRow.spacing   = 8
        courseInfoRow.alignment = .center
        let csp = UIView()
        csp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        courseInfoRow.addArrangedSubview(csp)

        metaBlock.addArrangedSubview(courseInfoRow)
        metaBlockHasContent = true

        if metaBlockHasContent {
            syllabusSection.addArrangedSubview(metaBlock)
        }

        // ── 優先表示フィールド（授業計画 + 成績評価）── 常時展開
        let priorityKeywords: [(String, [String])] = [
            ("成績評価", ["成績評価", "成績評価方法", "評価方法", "Evaluation"]),
            ("授業計画", ["授業計画", "講義計画", "Lectureplan", "授業スケジュール"])
        ]
        var priorityEntries: [(String, String)] = []
        for (displayLabel, keywords) in priorityKeywords {
            if let entry = fields.first(where: { k, _ in
                !usedKeys.contains(k) &&
                keywords.contains(where: { k.contains($0) || $0.contains(k) })
            }) {
                guard !entry.value.isEmpty else { continue }
                priorityEntries.append((displayLabel, entry.value))
                usedKeys.insert(entry.key)
            }
        }

        if !priorityEntries.isEmpty {
            let cardWrap = UIView()
            cardWrap.backgroundColor = .secondarySystemBackground
            cardWrap.layer.cornerRadius = 12
            cardWrap.layer.masksToBounds = true
            cardWrap.translatesAutoresizingMaskIntoConstraints = false

            let cardStack = UIStackView()
            cardStack.axis = .vertical
            cardStack.spacing = 0
            cardStack.translatesAutoresizingMaskIntoConstraints = false
            cardWrap.addSubview(cardStack)
            NSLayoutConstraint.activate([
                cardStack.topAnchor.constraint(equalTo: cardWrap.topAnchor),
                cardStack.leadingAnchor.constraint(equalTo: cardWrap.leadingAnchor, constant: 16),
                cardStack.trailingAnchor.constraint(equalTo: cardWrap.trailingAnchor, constant: -16),
                cardStack.bottomAnchor.constraint(equalTo: cardWrap.bottomAnchor)
            ])

            for (i, (label, body)) in priorityEntries.enumerated() {
                cardStack.addArrangedSubview(
                    makeSyllabusFieldCard(label: label, body: body, isFirst: i == 0, currentWeek: currentWeek)
                )
            }
            syllabusSection.addArrangedSubview(cardWrap)
        }

        // ── 残りのフィールド（折りたたみ）──
        buildStructuredSecondarySection(fields: fields)

        addOpenInBrowserButton()
    }

    private func makeSyllabusPill(label: String, value: String) -> UIView {
        let lbl = UILabel()
        lbl.text = "\(label)： \(value)"
        lbl.font = .systemFont(ofSize: 13, weight: .medium)
        lbl.numberOfLines = 1
        lbl.lineBreakMode = .byTruncatingTail
        return makeSyllabusPillWithLabel(lbl)
    }

    /// 外部から生成したラベルをピルに包む（ラベルへの参照を保持したい場合に使用）
    private func makeSyllabusPillWithLabel(_ lbl: UILabel) -> UIView {
        let pill = UIView()
        pill.backgroundColor = .secondarySystemBackground
        pill.layer.cornerRadius = 10
        pill.layer.masksToBounds = true

        lbl.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.topAnchor.constraint(equalTo: pill.topAnchor, constant: 6),
            lbl.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
            lbl.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),
            lbl.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -6)
        ])
        return pill
    }

    // MARK: - Field Card Rendering

    /// 種類を判定してカードを返すディスパッチャー
    private func makeSyllabusFieldCard(label: String, body: String, isFirst: Bool, currentWeek: Int? = nil) -> UIView {
        let lines = body.components(separatedBy: "\n").filter { !$0.isEmpty }
        let isPercent  = lines.contains { $0.contains("\t") && $0.contains("%") }
        let isNumbered = !isPercent && (lines.first.map {
            let parts = $0.components(separatedBy: ". ")
            return parts.count >= 2 && Int(parts[0]) != nil
        } ?? false)

        if isPercent   { return makeGradingBarCard(label: label, lines: lines, isFirst: isFirst) }
        if isNumbered  { return makeNumberedListCard(label: label, lines: lines, isFirst: isFirst, currentWeek: currentWeek) }
        return makeDefaultCard(label: label, body: body, isFirst: isFirst)
    }

    /// 仕切り線
    private func makeCardDivider() -> UIView {
        let v = UIView()
        v.backgroundColor = UIColor.label.withAlphaComponent(0.08)
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    /// キャプションラベル
    private func makeFieldCapLabel(text: String) -> UILabel {
        let l = UILabel()
        l.text = text.uppercased()
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .tertiaryLabel
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    /// デフォルト（プレーンテキスト）カード
    private func makeDefaultCard(label: String, body: String, isFirst: Bool) -> UIView {
        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        var topRef: NSLayoutYAxisAnchor = wrap.topAnchor
        if !isFirst {
            let d = makeCardDivider()
            wrap.addSubview(d)
            NSLayoutConstraint.activate([
                d.topAnchor.constraint(equalTo: wrap.topAnchor),
                d.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                d.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
                d.heightAnchor.constraint(equalToConstant: 0.5)
            ])
            topRef = d.bottomAnchor
        }
        let cap = makeFieldCapLabel(text: label)
        let bodyLbl = UILabel()
        bodyLbl.text = body
        bodyLbl.font = .systemFont(ofSize: 14)
        bodyLbl.textColor = .label
        bodyLbl.numberOfLines = 0
        bodyLbl.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(cap); wrap.addSubview(bodyLbl)
        NSLayoutConstraint.activate([
            cap.topAnchor.constraint(equalTo: topRef, constant: 12),
            cap.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            cap.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            bodyLbl.topAnchor.constraint(equalTo: cap.bottomAnchor, constant: 4),
            bodyLbl.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            bodyLbl.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            bodyLbl.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -12)
        ])
        return wrap
    }

    /// 番号付きリストカード（授業計画用）。currentWeek が指定されていれば該当行をハイライト
    private func makeNumberedListCard(label: String, lines: [String], isFirst: Bool, currentWeek: Int? = nil) -> UIView {
        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        var topRef: NSLayoutYAxisAnchor = wrap.topAnchor
        if !isFirst {
            let d = makeCardDivider()
            wrap.addSubview(d)
            NSLayoutConstraint.activate([
                d.topAnchor.constraint(equalTo: wrap.topAnchor),
                d.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                d.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
                d.heightAnchor.constraint(equalToConstant: 0.5)
            ])
            topRef = d.bottomAnchor
        }
        let cap = makeFieldCapLabel(text: label)
        wrap.addSubview(cap)

        // 今週バッジ（ラベルの右横に配置）
        var capTrailingRef: NSLayoutXAxisAnchor = cap.trailingAnchor
        if let w = currentWeek {
            let weekBadge = UILabel()
            weekBadge.text = "\(w)週目"
            weekBadge.font = .systemFont(ofSize: 10, weight: .bold)
            weekBadge.textColor = .white
            weekBadge.backgroundColor = HackColors.accent
            weekBadge.layer.cornerRadius = 7
            weekBadge.layer.masksToBounds = true
            weekBadge.textAlignment = .center
            weekBadge.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(weekBadge)
            NSLayoutConstraint.activate([
                weekBadge.leadingAnchor.constraint(equalTo: cap.trailingAnchor, constant: 6),
                weekBadge.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
                weekBadge.heightAnchor.constraint(equalToConstant: 16),
                weekBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 38)
            ])
            capTrailingRef = weekBadge.trailingAnchor
        }

        NSLayoutConstraint.activate([
            cap.topAnchor.constraint(equalTo: topRef, constant: 12),
            cap.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            capTrailingRef.constraint(lessThanOrEqualTo: wrap.trailingAnchor)
        ])

        let listStack = UIStackView()
        listStack.axis = .vertical
        listStack.spacing = 2
        listStack.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(listStack)

        for line in lines {
            let parts = line.components(separatedBy: ". ")
            let weekNum = (parts.count >= 2) ? Int(parts[0]) : nil
            let isThisWeek = currentWeek != nil && weekNum == currentWeek

            let rowContainer = UIView()
            rowContainer.translatesAutoresizingMaskIntoConstraints = false

            if isThisWeek {
                rowContainer.backgroundColor = HackColors.accent.withAlphaComponent(0.10)
                rowContainer.layer.cornerRadius = 7
                rowContainer.layer.masksToBounds = true
            }

            let lbl = UILabel()
            lbl.numberOfLines = 0
            lbl.translatesAutoresizingMaskIntoConstraints = false

            if let _ = weekNum, parts.count >= 2 {
                let numStr = parts[0] + ".  "
                let contentStr = parts.dropFirst().joined(separator: ". ")
                let astr = NSMutableAttributedString(
                    string: numStr,
                    attributes: [
                        .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                        .foregroundColor: isThisWeek ? HackColors.accent : UIColor.secondaryLabel
                    ]
                )
                astr.append(NSAttributedString(
                    string: contentStr,
                    attributes: [.font: UIFont.systemFont(ofSize: 13),
                                 .foregroundColor: UIColor.label]
                ))
                lbl.attributedText = astr
            } else {
                lbl.text = line
                lbl.font = .systemFont(ofSize: 13)
                lbl.textColor = .secondaryLabel
            }

            rowContainer.addSubview(lbl)
            let pad: CGFloat = isThisWeek ? 5 : 3
            let hPad: CGFloat = isThisWeek ? 8 : 0

            var rowCs: [NSLayoutConstraint] = [
                lbl.topAnchor.constraint(equalTo: rowContainer.topAnchor, constant: pad),
                lbl.leadingAnchor.constraint(equalTo: rowContainer.leadingAnchor, constant: hPad),
                lbl.bottomAnchor.constraint(equalTo: rowContainer.bottomAnchor, constant: -pad)
            ]

            if isThisWeek {
                // 「今週」バッジ
                let badge = UILabel()
                badge.text = "今週"
                badge.font = .systemFont(ofSize: 10, weight: .bold)
                badge.textColor = .white
                badge.backgroundColor = HackColors.accent
                badge.layer.cornerRadius = 6
                badge.layer.masksToBounds = true
                badge.textAlignment = .center
                badge.translatesAutoresizingMaskIntoConstraints = false
                rowContainer.addSubview(badge)
                rowCs += [
                    badge.centerYAnchor.constraint(equalTo: rowContainer.centerYAnchor),
                    badge.trailingAnchor.constraint(equalTo: rowContainer.trailingAnchor, constant: -6),
                    badge.widthAnchor.constraint(equalToConstant: 34),
                    badge.heightAnchor.constraint(equalToConstant: 18),
                    lbl.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -4)
                ]
            } else {
                rowCs.append(lbl.trailingAnchor.constraint(equalTo: rowContainer.trailingAnchor))
            }

            NSLayoutConstraint.activate(rowCs)
            listStack.addArrangedSubview(rowContainer)
        }

        NSLayoutConstraint.activate([
            listStack.topAnchor.constraint(equalTo: cap.bottomAnchor, constant: 6),
            listStack.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -12)
        ])
        return wrap
    }

    /// 成績評価グラフカード — 横棒グラフ＋凡例
    private func makeGradingBarCard(label: String, lines: [String], isFirst: Bool) -> UIView {
        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        var topRef: NSLayoutYAxisAnchor = wrap.topAnchor
        if !isFirst {
            let d = makeCardDivider()
            wrap.addSubview(d)
            NSLayoutConstraint.activate([
                d.topAnchor.constraint(equalTo: wrap.topAnchor),
                d.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                d.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
                d.heightAnchor.constraint(equalToConstant: 0.5)
            ])
            topRef = d.bottomAnchor
        }
        let cap = makeFieldCapLabel(text: label)
        wrap.addSubview(cap)
        NSLayoutConstraint.activate([
            cap.topAnchor.constraint(equalTo: topRef, constant: 12),
            cap.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            cap.trailingAnchor.constraint(equalTo: wrap.trailingAnchor)
        ])

        // パレット（最大8色）
        let palette: [UIColor] = [
            UIColor(red: 0/255, green: 120/255, blue: 87/255, alpha: 1),
            .systemOrange, .systemBlue, .systemPurple,
            .systemRed, .systemIndigo, .systemTeal, .systemBrown
        ]

        struct GItem { let name: String; let pct: Double; let pctStr: String; let desc: String }
        var items: [GItem] = []
        for line in lines.filter({ !$0.isEmpty }) {
            let parts = line.components(separatedBy: "\t")
            let name    = parts.count > 0 ? parts[0].trimmingCharacters(in: .whitespaces) : ""
            let pctStr  = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            let desc    = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
            guard !name.isEmpty else { continue }
            let numStr  = pctStr.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
            let pct     = Double(numStr) ?? 0
            items.append(GItem(name: name, pct: pct, pctStr: pctStr, desc: desc))
        }

        let denom = items.reduce(0.0) { $0 + $1.pct }
        guard !items.isEmpty else {
            NSLayoutConstraint.activate([cap.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -12)])
            return wrap
        }

        // ── 横棒グラフ ──
        let barH: CGFloat = 28
        let barContainer = UIView()
        barContainer.translatesAutoresizingMaskIntoConstraints = false
        barContainer.layer.cornerRadius = barH / 2
        barContainer.layer.masksToBounds = true
        barContainer.backgroundColor = .systemGray5
        wrap.addSubview(barContainer)
        NSLayoutConstraint.activate([
            barContainer.topAnchor.constraint(equalTo: cap.bottomAnchor, constant: 10),
            barContainer.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            barContainer.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            barContainer.heightAnchor.constraint(equalToConstant: barH)
        ])

        var prevTrailing: NSLayoutXAxisAnchor = barContainer.leadingAnchor
        let safeTotal = denom > 0 ? denom : 100.0
        for (i, item) in items.enumerated() {
            let seg = UIView()
            seg.translatesAutoresizingMaskIntoConstraints = false
            seg.backgroundColor = palette[i % palette.count]
            barContainer.addSubview(seg)
            NSLayoutConstraint.activate([
                seg.topAnchor.constraint(equalTo: barContainer.topAnchor),
                seg.bottomAnchor.constraint(equalTo: barContainer.bottomAnchor),
                seg.leadingAnchor.constraint(equalTo: prevTrailing)
            ])
            if i == items.count - 1 {
                seg.trailingAnchor.constraint(equalTo: barContainer.trailingAnchor).isActive = true
            } else {
                let ratio = CGFloat(item.pct / safeTotal)
                seg.widthAnchor.constraint(equalTo: barContainer.widthAnchor, multiplier: ratio).isActive = true
            }
            prevTrailing = seg.trailingAnchor
        }

        // ── 凡例 ──
        let legendStack = UIStackView()
        legendStack.axis = .vertical
        legendStack.spacing = 6
        legendStack.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(legendStack)

        for (i, item) in items.enumerated() {
            let color = palette[i % palette.count]

            let dot = UIView()
            dot.backgroundColor = color
            dot.layer.cornerRadius = 5
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 10).isActive = true

            let nameLbl = UILabel()
            nameLbl.text = item.name
            nameLbl.font = .systemFont(ofSize: 13)
            nameLbl.textColor = .label
            nameLbl.numberOfLines = 2
            nameLbl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let pctLbl = UILabel()
            pctLbl.text = item.pctStr
            pctLbl.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            pctLbl.textColor = color
            pctLbl.setContentHuggingPriority(.required, for: .horizontal)
            pctLbl.setContentCompressionResistancePriority(.required, for: .horizontal)

            let row = UIStackView(arrangedSubviews: [dot, nameLbl, pctLbl])
            row.axis = .horizontal
            row.spacing = 8
            row.alignment = .center

            if item.desc.isEmpty {
                legendStack.addArrangedSubview(row)
            } else {
                let descLbl = UILabel()
                descLbl.text = item.desc
                descLbl.font = .systemFont(ofSize: 12)
                descLbl.textColor = .secondaryLabel
                descLbl.numberOfLines = 0
                // ドット(10pt) + spacing(8pt) = 18pt のインデント
                let descWrap = UIView()
                descWrap.translatesAutoresizingMaskIntoConstraints = false
                descLbl.translatesAutoresizingMaskIntoConstraints = false
                descWrap.addSubview(descLbl)
                NSLayoutConstraint.activate([
                    descLbl.topAnchor.constraint(equalTo: descWrap.topAnchor),
                    descLbl.leadingAnchor.constraint(equalTo: descWrap.leadingAnchor, constant: 18),
                    descLbl.trailingAnchor.constraint(equalTo: descWrap.trailingAnchor),
                    descLbl.bottomAnchor.constraint(equalTo: descWrap.bottomAnchor)
                ])
                let itemVStack = UIStackView(arrangedSubviews: [row, descWrap])
                itemVStack.axis = .vertical
                itemVStack.spacing = 3
                legendStack.addArrangedSubview(itemVStack)
            }
        }

        NSLayoutConstraint.activate([
            legendStack.topAnchor.constraint(equalTo: barContainer.bottomAnchor, constant: 12),
            legendStack.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            legendStack.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            legendStack.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -12)
        ])
        return wrap
    }

    private func addOpenInBrowserButton() {
        var cfg = UIButton.Configuration.plain()
        cfg.title = "ブラウザで全文を見る"
        cfg.image = UIImage(systemName: "arrow.up.right.square")
        cfg.imagePlacement = .trailing
        cfg.imagePadding = 6
        cfg.contentInsets = .zero
        cfg.baseForegroundColor = .secondaryLabel
        let btn = UIButton(type: .system)
        btn.configuration = cfg
        btn.contentHorizontalAlignment = .leading
        btn.addTarget(self, action: #selector(openSyllabusInBrowser), for: .touchUpInside)
        syllabusSection.addArrangedSubview(btn)
    }

    private func showSyllabusFallback() {
        syllabusSpinner.stopAnimating()
        syllabusLoadingRow.isHidden = true
        addOpenInBrowserButton()
    }

    @objc private func toggleSyllabusDetail() {
        isSyllabusDetailOpen.toggle()
        if isSyllabusDetailOpen { syllabusDetailStack.isHidden = false }

        var cfg = syllabusDetailToggle.configuration ?? .plain()
        cfg.title = isSyllabusDetailOpen ? "閉じる" : "詳細シラバス情報"
        cfg.image = UIImage(systemName: isSyllabusDetailOpen ? "chevron.up" : "chevron.down")
        syllabusDetailToggle.configuration = cfg

        UIView.animate(withDuration: 0.25, animations: {
            self.syllabusDetailStack.alpha = self.isSyllabusDetailOpen ? 1 : 0
            self.view.layoutIfNeeded()
        }, completion: { _ in
            if !self.isSyllabusDetailOpen { self.syllabusDetailStack.isHidden = true }
        })
    }

    @objc private func openSyllabusInBrowser() {
        guard let url = syllabusPageURL else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Action Buttons（スクロール末尾）
    private func buildActionButtonsInScroll() {
        var editCfg = UIButton.Configuration.filled()
        editCfg.title = "編集"
        editCfg.baseBackgroundColor = .systemBlue.withAlphaComponent(0.15)
        editCfg.baseForegroundColor = .systemBlue
        editCfg.cornerStyle = .large
        editCfg.contentInsets = .init(top: 12, leading: 0, bottom: 12, trailing: 0)

        var delCfg = UIButton.Configuration.filled()
        delCfg.title = "削除"
        delCfg.baseBackgroundColor = .systemRed.withAlphaComponent(0.12)
        delCfg.baseForegroundColor = .systemRed
        delCfg.cornerStyle = .large
        delCfg.contentInsets = .init(top: 12, leading: 0, bottom: 12, trailing: 0)

        let fontTF = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming; out.font = .systemFont(ofSize: 17, weight: .semibold); return out
        }
        editCfg.titleTextAttributesTransformer = fontTF
        delCfg.titleTextAttributesTransformer  = fontTF

        editButton.configuration = editCfg
        deleteButton.configuration = delCfg
        editButton.addTarget(self, action: #selector(editTapped), for: .touchUpInside)
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)

        let hStack = UIStackView(arrangedSubviews: [editButton, deleteButton])
        hStack.axis         = .horizontal
        hStack.distribution = .fillEqually
        hStack.spacing      = 12

        stack.addArrangedSubview(hStack)

        // ボタン下の余白
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 10).isActive = true
        stack.addArrangedSubview(spacer)
    }


    // MARK: - Counters
    private func setupCounterButton(_ b: UIButton, tag: Int, label: String) {
        b.tag = tag
        b.layer.cornerRadius = 12
        b.layer.masksToBounds = true
        b.layer.borderWidth = 1
        b.layer.borderColor = UIColor.separator.cgColor
        b.backgroundColor = .systemGray6
        b.heightAnchor.constraint(equalToConstant: 56).isActive = true

        b.addTarget(self, action: #selector(counterTapped(_:)), for: .touchUpInside)
        b.configuration = nil

        let lp = UILongPressGestureRecognizer(target: self, action: #selector(counterLongPressed(_:)))
        lp.minimumPressDuration = 0.5
        b.addGestureRecognizer(lp)

        setCounterButtonTitle(b, count: 0, label: label)
    }

    private func setCounterButtonTitle(_ b: UIButton, count: Int, label: String) {
        // ボタン内に 2 ラベル（キャプション・数値）を縦に並べる
        let numTag = 9001
        let capTag = 9002

        let capL: UILabel = (b.viewWithTag(capTag) as? UILabel) ?? {
            let l = UILabel()
            l.tag = capTag
            l.translatesAutoresizingMaskIntoConstraints = false
            l.font = .systemFont(ofSize: 11, weight: .medium)
            l.textAlignment = .center
            b.addSubview(l)
            NSLayoutConstraint.activate([
                l.centerXAnchor.constraint(equalTo: b.centerXAnchor),
                l.topAnchor.constraint(equalTo: b.topAnchor, constant: 10)
            ])
            return l
        }()

        let numL: UILabel = (b.viewWithTag(numTag) as? UILabel) ?? {
            let l = UILabel()
            l.tag = numTag
            l.translatesAutoresizingMaskIntoConstraints = false
            l.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
            l.textAlignment = .center
            b.addSubview(l)
            NSLayoutConstraint.activate([
                l.centerXAnchor.constraint(equalTo: b.centerXAnchor),
                l.topAnchor.constraint(equalTo: capL.bottomAnchor, constant: 2)
            ])
            return l
        }()

        // 欠席数に応じた色コーディング
        let (bgColor, fgColor, borderAlpha): (UIColor, UIColor, CGFloat) = {
            switch b.tag {
            case 0: // 出席 — 多いほど良い（緑）
                return count > 0
                    ? (UIColor.systemGreen.withAlphaComponent(0.14), .systemGreen, 0.5)
                    : (.systemGray6, .secondaryLabel, 0.0)
            case 1: // 遅刻 — 警告（アンバー）
                return count > 0
                    ? (UIColor.systemOrange.withAlphaComponent(0.14), .systemOrange, 0.5)
                    : (.systemGray6, .secondaryLabel, 0.0)
            default: // 欠席 — 即レッド（1回から危険）
                return count >= 1
                    ? (UIColor.systemRed.withAlphaComponent(0.14), .systemRed, 0.6)
                    : (.systemGray6, .secondaryLabel, 0.0)
            }
        }()

        b.backgroundColor = bgColor
        numL.textColor = fgColor
        capL.textColor = fgColor
        b.layer.borderWidth = borderAlpha > 0 ? 1.5 : 1.0
        b.layer.borderColor = borderAlpha > 0
            ? fgColor.withAlphaComponent(borderAlpha).cgColor
            : UIColor.separator.cgColor

        numL.text = "\(count)"
        capL.text = label
    }

    private func updateCounterButtons() {
        setCounterButtonTitle(attendBtn, count: counts.attended, label: "出席")
        setCounterButtonTitle(lateBtn,   count: counts.late,     label: "遅刻")
        setCounterButtonTitle(absentBtn, count: counts.absent,   label: "欠席")
    }

    @objc private func counterTapped(_ sender: UIButton) {
        switch sender.tag {
        case 0: counts.attended += 1
        case 1: counts.late     += 1
        default: counts.absent  += 1
        }
        saveCounts()
        updateCounterButtons()
        delegate?.courseDetail(self, didUpdate: counts, for: course, at: location)
    }

    @objc private func counterLongPressed(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began, let b = gr.view as? UIButton else { return }

        let current: Int
        let title: String
        switch b.tag {
        case 0: current = counts.attended; title = "出席を調整"
        case 1: current = counts.late;     title = "遅刻を調整"
        default: current = counts.absent;  title = "欠席を調整"
        }

        let ac = UIAlertController(title: title, message: "現在 \(current) 回", preferredStyle: .actionSheet)
        ac.addAction(UIAlertAction(title: "+1", style: .default, handler: { _ in
            self.counterTapped(b)
        }))
        ac.addAction(UIAlertAction(title: "−1", style: .default, handler: { _ in
            switch b.tag {
            case 0: self.counts.attended = max(0, self.counts.attended - 1)
            case 1: self.counts.late     = max(0, self.counts.late - 1)
            default: self.counts.absent  = max(0, self.counts.absent - 1)
            }
            self.saveCounts()
            self.updateCounterButtons()
            self.delegate?.courseDetail(self, didUpdate: self.counts, for: self.course, at: self.location)
        }))
        ac.addAction(UIAlertAction(title: "リセット", style: .destructive, handler: { _ in
            switch b.tag {
            case 0: self.counts.attended = 0
            case 1: self.counts.late     = 0
            default: self.counts.absent  = 0
            }
            self.saveCounts()
            self.updateCounterButtons()
            self.delegate?.courseDetail(self, didUpdate: self.counts, for: self.course, at: self.location)
        }))
        ac.addAction(UIAlertAction(title: "数を入力…", style: .default, handler: { _ in
            self.promptManualInput(for: b.tag, current: current)
        }))
        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        present(ac, animated: true)
    }

    private func promptManualInput(for tag: Int, current: Int) {
        let ac = UIAlertController(title: "回数を入力", message: nil, preferredStyle: .alert)
        ac.addTextField { tf in
            tf.keyboardType = .numberPad
            tf.text = "\(current)"
        }
        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        ac.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
            let v = Int(ac.textFields?.first?.text ?? "") ?? current
            switch tag {
            case 0: self.counts.attended = max(0, v)
            case 1: self.counts.late     = max(0, v)
            default: self.counts.absent  = max(0, v)
            }
            self.saveCounts()
            self.updateCounterButtons()
            self.delegate?.courseDetail(self, didUpdate: self.counts, for: self.course, at: self.location)
        }))
        present(ac, animated: true)
    }

    // MARK: - Edit / Delete Buttons
    @objc private func editTapped() {
        delegate?.courseDetail(self, requestEditFor: course, at: location)
    }

    @objc private func deleteTapped() {
        let ac = UIAlertController(
            title: "削除しますか？",
            message: "\(location.dayName) \(location.period)限の「\(course.title)」を削除します。",
            preferredStyle: .alert
        )
        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        ac.addAction(UIAlertAction(title: "削除", style: .destructive, handler: { _ in
            self.delegate?.courseDetail(self, requestDelete: self.course, at: self.location)
        }))
        present(ac, animated: true)
    }

    // MARK: - Persistence
    private func saveCounts() {
        let array = [counts.attended, counts.late, counts.absent]
        UserDefaults.standard.set(array, forKey: attendanceKey)
    }

    private func loadCounts() {
        let d = UserDefaults.standard
        if let arr = d.array(forKey: attendanceKey) as? [Int], arr.count == 3 {
            counts = AttendanceCounts(attended: arr[0], late: arr[1], absent: arr[2])
        } else if let legacy = d.array(forKey: "attendance.\(course.id)") as? [Int], legacy.count == 3 {
            // 旧仕様で入っている値があれば、初回だけ新キーにコピー
            counts = AttendanceCounts(attended: legacy[0], late: legacy[1], absent: legacy[2])
            saveCounts()
        }
    }


    // MARK: - Helpers

    /// 現在の学期において今日が何週目かを返す（計算できない場合は nil）
    /// 開始日は AcademicCalendar*.swift の springTermStart / autumnTermStart に合わせて管理。
    private func currentSyllabusWeek() -> Int? {

        // ── 学事暦に基づく学期開始日（月曜日）一覧 ──
        // 年度を追加するときはここに (前期月, 前期日, 後期月, 後期日) を追記する。
        // 2025: 前期 4/7（月）、後期 9/22（月）
        // 2026: AcademicCalendar2026 より 前期 4/6（月）、後期 9/14（月）
        let termStartDays: [Int: (fm: Int, fd: Int, bm: Int, bd: Int)] = [
            2025: (fm: 4, fd:  7, bm: 9, bd: 22),
            2026: (fm: 4, fd:  6, bm: 9, bd: 14),
        ]

        let termInfo = TermStore.loadSelected()
        let title = termInfo.displayTitle   // e.g. "2026年前期"
        guard let year = Int(title.prefix(4)) else { return nil }
        let isFront = title.contains("前期")
        let isBack  = title.contains("後期")
        guard isFront || isBack else { return nil }

        let cal = Calendar(identifier: .gregorian)
        var startComps = DateComponents()
        startComps.year = year

        if let k = termStartDays[year] {
            // 既知の開始日を直接使用
            startComps.month = isFront ? k.fm : k.bm
            startComps.day   = isFront ? k.fd : k.bd
        } else {
            // 未登録年度: 4月1日 / 9月7日 以降の最初の月曜を推計
            startComps.month = isFront ? 4 : 9
            startComps.day   = isFront ? 1 : 7
            guard let anchor = cal.date(from: startComps) else { return nil }
            let wd    = cal.component(.weekday, from: anchor)
            let shift = (9 - wd) % 7
            guard let est = cal.date(byAdding: .day, value: shift, to: anchor) else { return nil }
            let ec = cal.dateComponents([.month, .day], from: est)
            startComps.month = ec.month ?? startComps.month
            startComps.day   = ec.day   ?? startComps.day
        }

        guard let semesterStart = cal.date(from: startComps) else { return nil }
        let today = Date()
        guard today >= semesterStart else { return nil }
        let daysPassed = cal.dateComponents([.day], from: semesterStart, to: today).day ?? 0
        let week = daysPassed / 7 + 1
        return week <= 16 ? week : nil
    }

    private func courseCreditsText() -> String? {
        let m = Mirror(reflecting: course)
        if let child = m.children.first(where: { $0.label == "credits" }) {
            if let n = child.value as? Int    { return "\(n)" }
            if let s = child.value as? String { return s }
        }
        return nil
    }

    // MARK: - Structured Secondary Section

    /// 詳細シラバス情報を常時表示で syllabusSection に追加する
    private func buildStructuredSecondarySection(fields: [String: String]) {
        let contentKeys = ["__講義概要", "__達成目標", "__履修条件",
                           "__授業方法", "__教科書", "__参考書"]
        guard contentKeys.contains(where: { !(fields[$0] ?? "").isEmpty }) else { return }

        // ── 講義概要 / 達成目標 / 履修条件 まとめカード ──
        let textDefs: [(String, String)] = [
            ("__講義概要", "講義概要"),
            ("__達成目標", "達成目標"),
            ("__履修条件", "履修条件")
        ]
        let textEntries = textDefs.compactMap { (key, label) -> (String, String)? in
            guard let v = fields[key], !v.isEmpty else { return nil }
            return (label, v)
        }
        if !textEntries.isEmpty {
            syllabusSection.addArrangedSubview(makeStyledTextCard(entries: textEntries))
        }

        // ── 活用される授業方法 ──
        if let methodStr = fields["__授業方法"], !methodStr.isEmpty {
            let methods = methodStr.components(separatedBy: "\n").filter { !$0.isEmpty }
            syllabusSection.addArrangedSubview(makeMethodChipsCard(methods: methods))
        }

        // ── 教科書 ──
        if let bookStr = fields["__教科書"], !bookStr.isEmpty {
            let items = bookStr.components(separatedBy: "\n").filter { !$0.isEmpty }
            syllabusSection.addArrangedSubview(makeBookListCard(label: "教科書", items: items))
        }

        // ── 参考書 ──
        if let refStr = fields["__参考書"], !refStr.isEmpty {
            let items = refStr.components(separatedBy: "\n").filter { !$0.isEmpty }
            syllabusSection.addArrangedSubview(makeBookListCard(label: "参考書", items: items))
        }
    }

    /// 講義概要・達成目標・履修条件をまとめた角丸カード
    private func makeStyledTextCard(entries: [(String, String)]) -> UIView {
        let outer = UIView()
        outer.backgroundColor = .secondarySystemBackground
        outer.layer.cornerRadius = 12
        outer.layer.masksToBounds = true
        outer.translatesAutoresizingMaskIntoConstraints = false

        let inner = UIStackView()
        inner.axis = .vertical
        inner.spacing = 0
        inner.isLayoutMarginsRelativeArrangement = true
        inner.layoutMargins = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        inner.translatesAutoresizingMaskIntoConstraints = false
        outer.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: outer.topAnchor),
            inner.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
            inner.bottomAnchor.constraint(equalTo: outer.bottomAnchor)
        ])

        for (i, (label, body)) in entries.enumerated() {
            inner.addArrangedSubview(makeDefaultCard(label: label, body: body, isFirst: i == 0))
        }
        return outer
    }

    /// 活用される授業方法チップカード
    /// items の各要素は "1\t名前"（該当）または "0\t名前"（非該当）形式
    private func makeMethodChipsCard(methods: [String]) -> UIView {
        let outer = UIView()
        outer.backgroundColor = .secondarySystemBackground
        outer.layer.cornerRadius = 12
        outer.layer.masksToBounds = true
        outer.translatesAutoresizingMaskIntoConstraints = false

        let cap = makeFieldCapLabel(text: "活用される授業方法")
        cap.translatesAutoresizingMaskIntoConstraints = false
        outer.addSubview(cap)

        let chipStack = UIStackView()
        chipStack.axis = .vertical
        chipStack.spacing = 6
        chipStack.alignment = .leading
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        outer.addSubview(chipStack)

        for raw in methods {
            let parts = raw.components(separatedBy: "\t")
            let isChecked = parts[0] == "1"
            let name = parts.count >= 2 ? parts[1] : raw

            let chip = UIView()
            if isChecked {
                chip.backgroundColor = HackColors.accent.withAlphaComponent(0.12)
            } else {
                chip.backgroundColor = UIColor.tertiarySystemFill
            }
            chip.layer.cornerRadius = 8
            chip.layer.masksToBounds = true
            chip.translatesAutoresizingMaskIntoConstraints = false

            // チェック済みにはチェックマークアイコンを追加
            let iconView = UIImageView()
            if isChecked {
                let cfg = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                iconView.image = UIImage(systemName: "checkmark", withConfiguration: cfg)
                iconView.tintColor = HackColors.accent
            }
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.setContentHuggingPriority(.required, for: .horizontal)
            iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

            let lbl = UILabel()
            lbl.text = name
            lbl.font = .systemFont(ofSize: 13, weight: isChecked ? .medium : .regular)
            lbl.textColor = isChecked ? HackColors.accent : .secondaryLabel
            lbl.numberOfLines = 0
            lbl.translatesAutoresizingMaskIntoConstraints = false

            chip.addSubview(iconView)
            chip.addSubview(lbl)

            if isChecked {
                NSLayoutConstraint.activate([
                    iconView.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 10),
                    iconView.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
                    lbl.topAnchor.constraint(equalTo: chip.topAnchor, constant: 5),
                    lbl.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
                    lbl.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -10),
                    lbl.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -5)
                ])
            } else {
                NSLayoutConstraint.activate([
                    iconView.widthAnchor.constraint(equalToConstant: 0),
                    iconView.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 10),
                    iconView.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
                    lbl.topAnchor.constraint(equalTo: chip.topAnchor, constant: 5),
                    lbl.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 10),
                    lbl.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -10),
                    lbl.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -5)
                ])
            }
            chipStack.addArrangedSubview(chip)
        }

        NSLayoutConstraint.activate([
            cap.topAnchor.constraint(equalTo: outer.topAnchor, constant: 12),
            cap.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: 16),
            cap.trailingAnchor.constraint(equalTo: outer.trailingAnchor, constant: -16),
            chipStack.topAnchor.constraint(equalTo: cap.bottomAnchor, constant: 8),
            chipStack.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: 16),
            chipStack.trailingAnchor.constraint(equalTo: outer.trailingAnchor, constant: -16),
            chipStack.bottomAnchor.constraint(equalTo: outer.bottomAnchor, constant: -12)
        ])
        return outer
    }

    /// 教科書・参考書リストカード（著者名＋タイトルのみ）
    private func makeBookListCard(label: String, items: [String]) -> UIView {
        let outer = UIView()
        outer.backgroundColor = .secondarySystemBackground
        outer.layer.cornerRadius = 12
        outer.layer.masksToBounds = true
        outer.translatesAutoresizingMaskIntoConstraints = false

        let cap = makeFieldCapLabel(text: label)
        cap.translatesAutoresizingMaskIntoConstraints = false
        outer.addSubview(cap)

        let listStack = UIStackView()
        listStack.axis = .vertical
        listStack.spacing = 10
        listStack.translatesAutoresizingMaskIntoConstraints = false
        outer.addSubview(listStack)

        var visibleIndex = 0
        for item in items {
            let parts = item.components(separatedBy: "\t")
            let author = parts.count >= 2 ? parts[0].trimmingCharacters(in: .whitespaces) : ""
            let title  = (parts.count >= 2 ? parts[1] : parts[0]).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            visibleIndex += 1

            let wrap = UIView()
            wrap.translatesAutoresizingMaskIntoConstraints = false

            // 番号
            let numLbl = UILabel()
            numLbl.text = "\(visibleIndex)"
            numLbl.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            numLbl.textColor = .tertiaryLabel
            numLbl.translatesAutoresizingMaskIntoConstraints = false
            numLbl.setContentHuggingPriority(.required, for: .horizontal)
            numLbl.setContentCompressionResistancePriority(.required, for: .horizontal)

            // タイトル
            let titleLbl = UILabel()
            titleLbl.text = "『\(title)』"
            titleLbl.font = .systemFont(ofSize: 13, weight: .medium)
            titleLbl.textColor = .label
            titleLbl.numberOfLines = 2
            titleLbl.translatesAutoresizingMaskIntoConstraints = false

            wrap.addSubview(numLbl)
            wrap.addSubview(titleLbl)

            var cs: [NSLayoutConstraint] = [
                numLbl.topAnchor.constraint(equalTo: wrap.topAnchor),
                numLbl.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                titleLbl.topAnchor.constraint(equalTo: wrap.topAnchor),
                titleLbl.leadingAnchor.constraint(equalTo: numLbl.trailingAnchor, constant: 6),
                titleLbl.trailingAnchor.constraint(equalTo: wrap.trailingAnchor)
            ]

            if author.isEmpty {
                cs.append(titleLbl.bottomAnchor.constraint(equalTo: wrap.bottomAnchor))
            } else {
                let authorLbl = UILabel()
                authorLbl.text = author
                authorLbl.font = .systemFont(ofSize: 11)
                authorLbl.textColor = .secondaryLabel
                authorLbl.numberOfLines = 1
                authorLbl.translatesAutoresizingMaskIntoConstraints = false
                wrap.addSubview(authorLbl)
                cs += [
                    authorLbl.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 2),
                    authorLbl.leadingAnchor.constraint(equalTo: titleLbl.leadingAnchor),
                    authorLbl.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
                    authorLbl.bottomAnchor.constraint(equalTo: wrap.bottomAnchor)
                ]
            }
            NSLayoutConstraint.activate(cs)
            listStack.addArrangedSubview(wrap)
        }

        NSLayoutConstraint.activate([
            cap.topAnchor.constraint(equalTo: outer.topAnchor, constant: 12),
            cap.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: 16),
            cap.trailingAnchor.constraint(equalTo: outer.trailingAnchor, constant: -16),
            listStack.topAnchor.constraint(equalTo: cap.bottomAnchor, constant: 8),
            listStack.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: 16),
            listStack.trailingAnchor.constraint(equalTo: outer.trailingAnchor, constant: -16),
            listStack.bottomAnchor.constraint(equalTo: outer.bottomAnchor, constant: -12)
        ])
        return outer
    }

    // MARK: - Moodle Assignments

    private func loadMoodleAssignments() {
        let moodleGreen = UIColor(red: 0/255, green: 150/255, blue: 108/255, alpha: 1)
        let events = MoodleService.shared.cachedEvents()
        let courseId = course.id.trimmingCharacters(in: .whitespacesAndNewlines)

        let matching = events.filter { event in
            if let regNum = MoodleService.shared.registrationNumber(from: event.courseCode) {
                if regNum.trimmingCharacters(in: .whitespacesAndNewlines) == courseId { return true }
            }
            if let mapped = MoodleService.shared.manualCourseMapping[event.courseCode] {
                let a = mapped.folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
                let b = course.title.folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
                if a == b { return true }
            }
            return false
        }

        let sorted = matching.sorted { a, b in
            if a.isPast != b.isPast { return !a.isPast }
            return (a.dueDate ?? .distantFuture) < (b.dueDate ?? .distantFuture)
        }
        courseAssignments = sorted

        moodleSection.subviews.forEach { $0.removeFromSuperview() }
        moodlePastContainer = nil
        guard !sorted.isEmpty else {
            moodleSection.isHidden = true
            return
        }

        let outerStack = UIStackView()
        outerStack.axis = .vertical
        outerStack.spacing = 0
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        moodleSection.addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: moodleSection.topAnchor),
            outerStack.leadingAnchor.constraint(equalTo: moodleSection.leadingAnchor),
            outerStack.trailingAnchor.constraint(equalTo: moodleSection.trailingAnchor),
            outerStack.bottomAnchor.constraint(equalTo: moodleSection.bottomAnchor)
        ])

        // ヘッダー行
        let headerRow = UIView()
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let iconCfg = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let iconView = UIImageView(image: UIImage(systemName: "checkmark.circle.fill",
                                                  withConfiguration: iconCfg))
        iconView.tintColor = moodleGreen
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        let headerLabel = UILabel()
        headerLabel.text = "Moodle 課題"
        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = .secondaryLabel
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        headerRow.addSubview(iconView)
        headerRow.addSubview(headerLabel)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            headerLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            headerLabel.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            headerRow.heightAnchor.constraint(equalToConstant: 36)
        ])
        outerStack.addArrangedSubview(headerRow)

        let topDiv = UIView()
        topDiv.backgroundColor = UIColor.label.withAlphaComponent(0.08)
        topDiv.translatesAutoresizingMaskIntoConstraints = false
        topDiv.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        outerStack.addArrangedSubview(topDiv)

        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "M/d(EEE) HH:mm"

        let upcomingItems = sorted.enumerated().filter { !$0.element.isPast }
        let pastItems     = sorted.enumerated().filter {  $0.element.isPast }

        // ─── 期限未来の課題 ───
        for (pos, (i, event)) in upcomingItems.enumerated() {
            if pos > 0 { outerStack.addArrangedSubview(makeDivider()) }
            outerStack.addArrangedSubview(makeMoodleRow(event: event, tag: i, df: df))
        }

        // ─── 期限切れの折りたたみ ───
        if !pastItems.isEmpty {
            // 区切り線
            if !upcomingItems.isEmpty { outerStack.addArrangedSubview(makeDivider()) }

            // 「期限切れ X 件 ▼」トグルボタン
            let toggleBtn = UIButton(type: .system)
            let chevronName = moodlePastExpanded ? "chevron.up" : "chevron.down"
            let btnTitle = "期限切れ \(pastItems.count) 件"
            var cfg = UIButton.Configuration.plain()
            cfg.title = btnTitle
            cfg.image = UIImage(systemName: chevronName,
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
            cfg.imagePlacement = .trailing
            cfg.imagePadding = 6
            cfg.baseForegroundColor = .tertiaryLabel
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs; a.font = UIFont.systemFont(ofSize: 12); return a
            }
            toggleBtn.configuration = cfg
            toggleBtn.contentHorizontalAlignment = .left
            toggleBtn.addTarget(self, action: #selector(toggleMoodlePastSection(_:)), for: .touchUpInside)
            toggleBtn.translatesAutoresizingMaskIntoConstraints = false
            outerStack.addArrangedSubview(toggleBtn)

            // 期限切れ行のコンテナ（初期は非表示）
            let pastStack = UIStackView()
            pastStack.axis = .vertical
            pastStack.spacing = 0
            pastStack.isHidden = !moodlePastExpanded
            for (pos, (i, event)) in pastItems.enumerated() {
                if pos > 0 { pastStack.addArrangedSubview(makeDivider()) }
                pastStack.addArrangedSubview(makeMoodleRow(event: event, tag: i, df: df))
            }
            outerStack.addArrangedSubview(pastStack)
            moodlePastContainer = pastStack
        }

        moodleSection.isHidden = false
    }

    private func makeDivider() -> UIView {
        let div = UIView()
        div.backgroundColor = UIColor.label.withAlphaComponent(0.08)
        div.translatesAutoresizingMaskIntoConstraints = false
        div.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return div
    }

    private func makeMoodleRow(event: MoodleEvent, tag: Int, df: DateFormatter) -> UIView {
        let moodleGreen = UIColor(red: 0/255, green: 150/255, blue: 108/255, alpha: 1)
        let isSubmitted = MoodleService.shared.isSubmitted(uid: event.uid)

        let row = UIView()
        row.tag = tag
        row.translatesAutoresizingMaskIntoConstraints = false
        row.isUserInteractionEnabled = true
        row.accessibilityTraits.insert(.button)

        let statusIcon = UIImageView()
        let iconName = isSubmitted ? "checkmark.circle.fill" : "square.and.arrow.up"
        let iconWeight: UIImage.SymbolWeight = isSubmitted ? .medium : .light
        statusIcon.image = UIImage(systemName: iconName,
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: iconWeight))
        statusIcon.tintColor = isSubmitted ? .systemGreen : .tertiaryLabel
        statusIcon.alpha = event.isPast && !isSubmitted ? 0.4 : 1.0
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)

        let titleLbl = UILabel()
        titleLbl.text = event.cleanTitle
        titleLbl.font = .systemFont(ofSize: 14, weight: .medium)
        titleLbl.textColor = isSubmitted ? .secondaryLabel : (event.isPast ? .systemGray3 : moodleGreen)
        titleLbl.numberOfLines = 2
        titleLbl.translatesAutoresizingMaskIntoConstraints = false

        let dateLbl = UILabel()
        dateLbl.text = isSubmitted ? "提出済み" : (event.dueDate.map { df.string(from: $0) } ?? "日時未定")
        dateLbl.font = isSubmitted
            ? .systemFont(ofSize: 11, weight: .semibold)
            : .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        dateLbl.textColor = isSubmitted ? .systemGreen : (event.isPast ? .systemGray4 : .secondaryLabel)
        dateLbl.translatesAutoresizingMaskIntoConstraints = false

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right",
                                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)))
        chevron.tintColor = .tertiaryLabel
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        row.addSubview(statusIcon)
        row.addSubview(titleLbl)
        row.addSubview(dateLbl)
        row.addSubview(chevron)
        NSLayoutConstraint.activate([
            statusIcon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            statusIcon.topAnchor.constraint(equalTo: row.topAnchor, constant: 12),
            statusIcon.widthAnchor.constraint(equalToConstant: 18),
            statusIcon.heightAnchor.constraint(equalToConstant: 18),
            titleLbl.leadingAnchor.constraint(equalTo: statusIcon.trailingAnchor, constant: 8),
            titleLbl.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -8),
            titleLbl.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
            dateLbl.leadingAnchor.constraint(equalTo: titleLbl.leadingAnchor),
            dateLbl.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 3),
            dateLbl.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10),
            chevron.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])

        let tap = UITapGestureRecognizer(target: self,
                                         action: #selector(moodleAssignmentTapped(_:)))
        row.addGestureRecognizer(tap)
        return row
    }

    @objc private func toggleMoodlePastSection(_ sender: UIButton) {
        moodlePastExpanded.toggle()

        // シェブロンとコンテナを更新
        let chevronName = moodlePastExpanded ? "chevron.up" : "chevron.down"
        var cfg = sender.configuration
        cfg?.image = UIImage(systemName: chevronName,
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        sender.configuration = cfg

        UIView.animate(withDuration: 0.25) {
            self.moodlePastContainer?.isHidden = !self.moodlePastExpanded
            self.moodlePastContainer?.superview?.layoutIfNeeded()
        }
    }

    @objc private func moodleAssignmentTapped(_ sender: UITapGestureRecognizer) {
        guard let row = sender.view, row.tag < courseAssignments.count else { return }
        let event = courseAssignments[row.tag]
        let detail = MoodleEventDetailViewController(
            event: event,
            courseTitle: course.title,
            pickerTitles: moodleAssignmentPickerTitles()
        )
        detail.onCourseChanged = { [weak self] _ in
            self?.loadMoodleAssignments()
        }
        detail.onSubmittedChanged = { [weak self] in
            self?.loadMoodleAssignments()
        }

        if let nav = navigationController {
            nav.pushViewController(detail, animated: true)
        } else {
            let nav = UINavigationController(rootViewController: detail)
            nav.modalPresentationStyle = .pageSheet
            if let sheet = nav.sheetPresentationController {
                sheet.detents = [.large()]
                sheet.prefersGrabberVisible = true
            }
            present(nav, animated: true)
        }
    }

    private func moodleAssignmentPickerTitles() -> [String] {
        let termCourses = TermStore.loadAssigned(for: term)
        let customCourses = CourseStore.load()
        var titles = Set<String>()
        for item in termCourses + customCourses {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { titles.insert(title) }
        }
        let currentTitle = course.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentTitle.isEmpty { titles.insert(currentTitle) }
        return titles.sorted()
    }

    // MARK: - AdMob Banner

    private func setupAdBanner() {
        guard AdsConfig.enabled else {
            adContainer.isHidden = true
            adContainerHeight?.constant = 0
            return
        }
        let bv = BannerView()
        bv.translatesAutoresizingMaskIntoConstraints = false
        bv.adUnitID = AdsConfig.bannerUnitID
        bv.rootViewController = self
        bv.adSize = AdSizeBanner
        bv.delegate = self
        adContainer.addSubview(bv)
        NSLayoutConstraint.activate([
            bv.leadingAnchor.constraint(equalTo: adContainer.leadingAnchor),
            bv.trailingAnchor.constraint(equalTo: adContainer.trailingAnchor),
            bv.topAnchor.constraint(equalTo: adContainer.topAnchor),
            bv.bottomAnchor.constraint(equalTo: adContainer.bottomAnchor),
        ])
        bannerView = bv
    }

    private func loadBannerIfNeeded() {
        guard let bv = bannerView else { return }
        let safeWidth = view.safeAreaLayoutGuide.layoutFrame.width
        guard safeWidth > 0 else { return }
        let useWidth = max(320, floor(safeWidth))
        guard abs(useWidth - lastBannerWidth) >= 0.5 else { return }
        lastBannerWidth = useWidth
        let size = currentOrientationAnchoredAdaptiveBanner(width: useWidth)
        adContainerHeight?.constant = size.size.height
        updateScrollInsetForBanner(height: size.size.height)
        view.layoutIfNeeded()
        guard size.size.height > 0 else { return }
        if !CGSizeEqualToSize(bv.adSize.size, size.size) { bv.adSize = size }
        if !didLoadBannerOnce {
            didLoadBannerOnce = true
            bv.load(Request())
        }
    }

    private func updateScrollInsetForBanner(height: CGFloat) {
        var inset = scroll.contentInset
        inset.bottom = height
        scroll.contentInset = inset
        scroll.verticalScrollIndicatorInsets.bottom = height
    }

    @objc private func onAdMobReady() { loadBannerIfNeeded() }
}

// MARK: - BannerViewDelegate
extension CourseDetailViewController: BannerViewDelegate {
    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        let h = bannerView.adSize.size.height
        adContainerHeight?.constant = h
        updateScrollInsetForBanner(height: h)
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
    }
    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        adContainerHeight?.constant = 0
        updateScrollInsetForBanner(height: 0)
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
    }
}

// MARK: - WKNavigationDelegate
extension CourseDetailViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // SPAレンダリング完了を待つため2秒後に抽出
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.extractSyllabusFields()
        }
    }

    private func extractSyllabusFields() {
        let js = """
        (function() {
          var data = {};
          var lectureItems = [];
          var evalItems    = [];
          function clean(s)    { return s.trim().replace(/[\\s\\u3000\\n\\r]+/g, ''); }
          function cleanVal(s) { return s.trim().replace(/[ \\t\\u3000]+\\n/g, '\\n').replace(/\\n{3,}/g, '\\n\\n'); }
          function cleanLine(s){ return (s || '').replace(/[\\s\\u3000\\n\\r]+/g, ' ').trim(); }
          function isNum(s)    { return /^\\d+$/.test(s.trim()); }

          // ── 青山専用: CPH1_gvKeikaku_* ID パターンで授業計画を直接抽出 ──
          // ASP.NET は ctl00_ プレフィックスが付く場合があるため属性セレクタで検索
          (function() {
            // 番号ラベルを全て取得（ID に "gvKeikaku_lblSQ_NO_" を含むもの）
            var numEls     = Array.from(document.querySelectorAll('[id*="gvKeikaku_lblSQ_NO_"]'));
            var contentEls = Array.from(document.querySelectorAll('[id*="gvKeikaku_lblKeikaku_"]'));
            // インデックス順にソート（末尾の数字で並べ替え）
            function rowIdx(el) { return parseInt(el.id.match(/\\d+$/) || [0], 10); }
            numEls.sort(function(a,b){ return rowIdx(a) - rowIdx(b); });
            contentEls.sort(function(a,b){ return rowIdx(a) - rowIdx(b); });
            var len = Math.min(numEls.length, contentEls.length);
            for (var i = 0; i < len; i++) {
              var num     = (numEls[i].textContent || '').trim();
              var content = cleanLine(contentEls[i].innerText || contentEls[i].textContent || '');
              if (num && content) lectureItems.push(num + '. ' + content);
            }
          })();

          // ── 青山専用: table.table-seiseki で成績評価を直接抽出 ──
          (function() {
            var rows = document.querySelectorAll('table.table-seiseki tr');
            rows.forEach(function(row) {
              var c1 = row.querySelector('td.col1');
              var c2 = row.querySelector('td.col2');
              var c3 = row.querySelector('td.col3');
              var c4 = row.querySelector('td.col4');
              if (!c1 || !c2 || !c3) return;
              if (!isNum((c1.textContent || '').trim())) return;
              var nm   = cleanLine(c2.innerText || c2.textContent || '');
              var pct  = (c3.textContent || '').trim();
              var desc = c4 ? cleanLine(c4.innerText || c4.textContent || '') : '';
              if (nm && pct.includes('%')) evalItems.push(nm + '\\t' + pct + '\\t' + desc);
            });
          })();

          // ── 汎用テーブル抽出 ──
          document.querySelectorAll('table tr').forEach(function(row) {
            // keikakuDetail / table-seiseki 内の行はスキップ
            if (row.closest && row.closest('table.keikakuDetail')) return;
            if (row.closest && row.closest('table.table-seiseki')) return;

            var ths = row.querySelectorAll('th');
            var tds = row.querySelectorAll('td');
            if (ths.length > 0 && tds.length > 0) {
              var k = clean(ths[0].innerText); var v = cleanVal(tds[0].innerText);
              if (k && v && v !== k && k.length < 30) data[k] = v;
              return;
            }
            if (tds.length < 2) return;
            var t0 = tds[0].innerText.trim();
            var t1 = tds[1].innerText.trim();
            var t2 = tds.length >= 3 ? tds[2].innerText.trim() : '';
            var t3 = tds.length >= 4 ? tds[3].innerText.trim() : '';
            if (isNum(t0) && tds.length >= 3) {
              // 授業計画行（CPH1 ID 形式以外の3列形式: 番号|ラベル|内容）
              if (lectureItems.length === 0 &&
                  (t1.includes('授業計画') || t1.includes('Lecture') || t1.includes('Class'))) {
                if (t2) lectureItems.push(t0 + '. ' + t2.replace(/[\\n\\r]+/g, ' ').trim());
              }
              // 成績評価行（3列）: 番号 | 項目名 | %
              else if (t2.includes('%') && evalItems.length === 0) {
                var nm  = t1.replace(/[\\n\\r]+/g, ' ').trim();
                var dsc = t3.replace(/[\\n\\r]+/g, ' ').trim();
                if (nm) evalItems.push(nm + '\\t' + t2 + '\\t' + dsc);
              }
              // 成績評価行（4列）: 番号 | 項目名 | 何か | %
              else if (t3.includes('%') && evalItems.length === 0) {
                var nm  = t1.replace(/[\\n\\r]+/g, ' ').trim();
                var dsc = t2.replace(/[\\n\\r]+/g, ' ').trim();
                if (nm) evalItems.push(nm + '\\t' + t3 + '\\t' + dsc);
              }
            } else {
              var k = clean(t0); var v = cleanVal(t1);
              if (k && v && v !== k && k.length < 30 && !data[k]) data[k] = v;
            }
          });

          if (lectureItems.length > 0) {
            data['授業計画'] = lectureItems.join('\\n');
            // 旧抽出で残った「授業計画/Class」等の重複キーを削除
            Object.keys(data).forEach(function(k) {
              if (k !== '授業計画' && k.indexOf('授業計画') >= 0) delete data[k];
            });
          }
          if (evalItems.length > 0) data['成績評価'] = evalItems.join('\\n');

          // dl/dt/dd
          document.querySelectorAll('dt').forEach(function(dt) {
            var dd = dt.nextElementSibling;
            if (dd && dd.tagName === 'DD') {
              var k = clean(dt.innerText); var v = cleanVal(dd.innerText);
              if (k && v) data[k] = v;
            }
          });

          // ── 青山専用: 構造化フィールドを __キー で抽出 ──
          (function() {
            function xtrim(s) { return (s || '').trim(); }

            // 年度・授業科目名・担当教員名（日本語）を editTable の th/td パターンから抽出
            document.querySelectorAll('table.editTable tr').forEach(function(row) {
              var th = row.querySelector('th');
              if (!th) return;
              var k = (th.textContent || '').replace(/[\\s\\u3000\\n\\r\\/]+/g, '');
              var td = row.querySelector('td');
              if (!td) return;
              var v = xtrim(td.textContent);
              if (!v) return;
              if (!data['__年度']      && k.includes('年度'))      data['__年度']      = v;
              if (!data['__授業科目名'] && k.includes('授業科目名')) data['__授業科目名'] = v;
              // 教員名（日本語）: 「教員名/Instructor (Japanese)」行。英文氏名行は英字キーのみなので除外
              if (!data['__教員名'] && k.includes('教員名') && !k.includes('英文')) data['__教員名'] = v;
            });

            // 学期・単位（CPH1_trGakki）
            var gakkiRow = document.getElementById('CPH1_trGakki');
            if (gakkiRow) {
              var tds = gakkiRow.querySelectorAll('td');
              if (tds.length >= 2) {
                data['__学期'] = xtrim(tds[0].textContent);
                data['__単位'] = xtrim(tds[1].textContent);
              }
            }

            // 講義概要
            var gaiyou = document.getElementById('CPH1_lblGaiyou');
            if (gaiyou) data['__講義概要'] = xtrim(gaiyou.textContent);

            // 達成目標（br タグを改行として保持するため innerText を使用）
            var moku = document.getElementById('CPH1_lblMokuhyou');
            if (moku) data['__達成目標'] = xtrim(moku.innerText || moku.textContent);

            // 履修条件
            var jouken = document.getElementById('CPH1_lblJouken');
            if (jouken) data['__履修条件'] = xtrim(jouken.textContent);

            // 活用される授業方法（全件・チェック有無を "1\t名前" / "0\t名前" で格納）
            var methods = [];
            document.querySelectorAll('[id*="rptHouhou_chkHouhou_"]').forEach(function(chk) {
              var lbl = chk.nextElementSibling;
              if (lbl) {
                var t = xtrim((lbl.innerText || lbl.textContent || '').split('\\n')[0]);
                if (t) methods.push((chk.checked ? '1' : '0') + '\\t' + t);
              }
            });
            if (methods.length) data['__授業方法'] = methods.join('\\n');

            // 教科書（著者名 + タイトルのみ、タブ区切り）※ th ヘッダ行は td. で除外
            var books = [];
            document.querySelectorAll('#CPH1_gvKyoukasho tr').forEach(function(row) {
              var a = row.querySelector('td.books-author');
              var t = row.querySelector('td.books-title');
              if (!a || !t) return;
              var av = xtrim(a.textContent);
              var tv = xtrim(t.textContent);
              if (!tv) return;
              books.push(av + '\\t' + tv);
            });
            if (books.length) data['__教科書'] = books.join('\\n');

            // 参考書（著者名 + タイトルのみ、タブ区切り）※ th ヘッダ行は td. で除外
            var refs = [];
            document.querySelectorAll('#CPH1_gvSankousho tr').forEach(function(row) {
              var a = row.querySelector('td.books-author');
              var t = row.querySelector('td.books-title');
              if (!a || !t) return;
              var av = xtrim(a.textContent);
              var tv = xtrim(t.textContent);
              if (!tv) return;
              refs.push(av + '\\t' + tv);
            });
            if (refs.length) data['__参考書'] = refs.join('\\n');
          })();

          return JSON.stringify(data);
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let jsonStr = result as? String,
                   let data = jsonStr.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                   !dict.isEmpty {
                    print("🟢 Syllabus keys found: \(Array(dict.keys))")
                    // 抽出成功 → キャッシュに保存してオフライン化（URLキーで保存）
                    let saveCK: String = {
                        let u = (self.course.syllabusURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        return u.isEmpty ? self.course.id : u
                    }()
                    SyllabusDataCache.shared.save(dict, for: saveCK)
                    self.buildSyllabusUI(fields: dict)
                } else {
                    print("🔴 Syllabus extraction empty or failed")
                    self.showSyllabusFallback()
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DispatchQueue.main.async { self.showSyllabusFallback() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        DispatchQueue.main.async { self.showSyllabusFallback() }
    }

    // MARK: - Syllabus Actions（シラバスTabからの＋・ブックマーク）

    private func buildSyllabusActionButtons() {
        let sym = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)

        // ＋ボタン
        var addCfg = UIButton.Configuration.filled()
        addCfg.image = UIImage(systemName: "plus.circle", withConfiguration: sym)
        addCfg.title = "時間割に追加"
        addCfg.imagePadding = 6
        addCfg.baseBackgroundColor = UIColor(red: 0/255, green: 120/255, blue: 87/255, alpha: 1)
        addCfg.baseForegroundColor = .white
        addCfg.cornerStyle = .medium
        addCfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        let addBtn = UIButton(configuration: addCfg)
        addBtn.addAction(UIAction { [weak self] _ in self?.startAddFlowForSyllabus() }, for: .touchUpInside)
        syllabusAddButton = addBtn

        // ブックマークボタン
        let isBookmarked = isSyllabusBookmarked()
        var bkCfg = UIButton.Configuration.filled()
        bkCfg.image = UIImage(systemName: isBookmarked ? "bookmark.fill" : "bookmark", withConfiguration: sym)
        bkCfg.title = isBookmarked ? "保存済み" : "保存"
        bkCfg.imagePadding = 6
        bkCfg.baseBackgroundColor = .secondarySystemBackground
        bkCfg.baseForegroundColor = isBookmarked ? .systemYellow : .secondaryLabel
        bkCfg.cornerStyle = .medium
        bkCfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        let bookmarkBtn = UIButton(configuration: bkCfg)
        bookmarkBtn.addAction(UIAction { [weak self] _ in self?.tapSyllabusBookmark() }, for: .touchUpInside)
        syllabusBookmarkButton = bookmarkBtn

        // ボタン行をスタックの先頭に挿入（タイトルの直下、シラバスセクションの上）
        let row = UIStackView(arrangedSubviews: [addBtn, bookmarkBtn, UIView()])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        stack.insertArrangedSubview(row, at: 0)
    }

    private func isSyllabusBookmarked() -> Bool {
        let key = syllabusDocID ?? course.id
        guard !key.isEmpty else { return false }
        let favs = Set(UserDefaults.standard.stringArray(forKey: syllabusBookmarkKey) ?? [])
        return favs.contains(key)
    }

    private func tapSyllabusBookmark() {
        let key = syllabusDocID ?? course.id
        guard !key.isEmpty else { return }
        var favs = Set(UserDefaults.standard.stringArray(forKey: syllabusBookmarkKey) ?? [])
        if favs.contains(key) { favs.remove(key) } else { favs.insert(key) }
        UserDefaults.standard.set(Array(favs), forKey: syllabusBookmarkKey)
        let isNow = favs.contains(key)
        let sym = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        var cfg = syllabusBookmarkButton?.configuration
        cfg?.image = UIImage(systemName: isNow ? "bookmark.fill" : "bookmark", withConfiguration: sym)
        cfg?.title = isNow ? "保存済み" : "保存"
        cfg?.baseForegroundColor = isNow ? .systemYellow : .secondaryLabel
        syllabusBookmarkButton?.configuration = cfg
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func startAddFlowForSyllabus() {
        guard !isAddFlowBusy else { return }
        isAddFlowBusy = true
        // シラバスに記載された曜日・時限をそのまま使う（ピッカー不要）
        let day    = location.day
        let period = location.period > 0 ? location.period : 1
        presentSyllabusAddConfirm(day: day, period: period)
    }

    private func presentSyllabusAddConfirm(day: Int, period: Int) {
        let dayText    = ["月","火","水","木","金","土"][max(0, min(day, 5))]
        let periodText = "\(period)限"
        let name       = course.title.isEmpty ? "この授業" : course.title
        let ac = UIAlertController(
            title: "登録しますか？",
            message: "\(dayText) \(periodText) に\n「\(name)」を\n登録します。",
            preferredStyle: .alert
        )
        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { [weak self] _ in
            self?.isAddFlowBusy = false
        })
        ac.addAction(UIAlertAction(title: "登録", style: .default) { [weak self] _ in
            guard let self else { return }
            let sym = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
            var addCfg = self.syllabusAddButton?.configuration
            addCfg?.image = UIImage(systemName: "checkmark.circle.fill", withConfiguration: sym)
            addCfg?.title = "追加済み"
            addCfg?.baseBackgroundColor = .systemGray4
            self.syllabusAddButton?.configuration = addCfg
            self.syllabusAddButton?.isEnabled = false
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            let payload: [String: Any] = [
                "class_name":   self.course.title,
                "teacher_name": self.course.teacher,
                "code":         self.course.id,
                "url":          self.course.syllabusURL ?? "",
                "room":         self.course.room,
                "credit":       self.course.credits ?? 0,
                "category":     self.course.category ?? ""
            ]
            let docId = self.syllabusDocID ?? self.course.id
            NotificationCenter.default.post(
                name: Notification.Name("RegisterCourseToTimetable"),
                object: nil,
                userInfo: ["course": payload, "docID": docId, "day": day, "period": period]
            )
            self.isAddFlowBusy = false
        })
        DispatchQueue.main.async {
            let host = self.presentedViewController ?? self
            host.present(ac, animated: true)
        }
    }
}

