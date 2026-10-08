
import UIKit
import WebKit
import FirebaseFirestore
import FirebaseAuth
import GoogleMobileAds
import UniformTypeIdentifiers
import PhotosUI

// すでに別所で定義済みなら削除OK
struct AttendanceCounts: Codable {
    var attended: Int
    var late: Int
    var absent: Int
}

/// 「ノート」タブの授業回カード(チャット内容は未実装のため回数と日付のみ保持)
private struct NoteSessionCard {
    /// チャットなどの保存キー。授業日(日本時間)を「1970年からの日数」にしたもの。休講・補講で番号が変わっても動かない。
    let dayID: Int
    /// 表示用の「第N回」。休講の日はnil。毎回、休講の印を除いて数え直す。
    let number: Int?
    let date: Date
    let isCancelled: Bool
    let isExtra: Bool
}

private enum NoteSortMode: String {
    case session   // 授業が新しい順(新しい回が上)。保存値は従来どおり "session"
    case oldest    // 授業が古い順(古い回が上)
    case chat      // チャット順(最後に送信した順。チャットが無いものは下。同率は授業回順)
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
    private let titleSubLabel = UILabel()   // チャット表示中だけ「第N回授業 · 9/29 火」を出す
    private var titleLabelBottomConstraint: NSLayoutConstraint?
    private var noteChatHeader: UIView?
    private var noteChatEditingIndex: Int?
    private let noteChatSendButton = UIButton(type: .system)
    private weak var noteChatGuideLabel: UILabel?

    /// ガイド文を、ゆっくり上下にふわふわ浮かせる。
    private func startGuideFloating() {
        guard let layer = noteChatGuideLabel?.layer else { return }
        layer.removeAnimation(forKey: "float")
        let float = CABasicAnimation(keyPath: "transform.translation.y")
        float.fromValue = -5
        float.toValue = 5
        float.duration = 2.6
        float.autoreverses = true
        float.repeatCount = .infinity
        float.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(float, forKey: "float")
    }
    /// 大きなカードが省略版(ヘッダーのボタン)に畳まれている状態か
    private var noteChatActionsCompact = false
    private var noteChatMorphing = false
    private var noteLastSentAt: [Int: Date] = [:]
    private let noteBackdrop = NoteBackdropView()
    private var noteSchedule: [NoteSessionCard] = []
    private var noteRecordingSession = 0

    /// 録音ボタン(大きいカード/ヘッダーの省略版)ごとの、更新が必要な部品
    private final class NoteUsageParts {
        let remainingLabel = UILabel()
        let bar = UsageBarView()
        let waveform = WaveformView()
        var idleViews: [UIView] = []
        var recordingViews: [UIView] = []
        var isCompact = false
    }
    private var noteUsageParts: [NoteUsageParts] = []

    private static let noteBubbleBackground = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.16, green: 0.27, blue: 0.19, alpha: 1)
            : UIColor(red: 0.79, green: 0.86, blue: 0.80, alpha: 1)
    }
    private static let noteBubbleText = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.74, green: 0.90, blue: 0.77, alpha: 1)
            : UIColor(red: 0.16, green: 0.40, blue: 0.20, alpha: 1)
    }

    fileprivate static func timeText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
    private let noteChatEditBanner = UIView()
    private var noteChatEditBannerHeight: NSLayoutConstraint?
    private let noteChatHeaderFade = NoteHeaderFadeView()
    private let showsAttendanceControls: Bool
    private let allowsCourseManagement: Bool
    private let showsEnrolledFriends: Bool
    private let showsMoodleAssignments: Bool
    private let showsLectureNotes: Bool
    // セグメント直下の共有ヘッダー行: 「授業レビューを書く」(左) + ノート用の並び替え/資料ボタン(右)を同じ行に並べる
    private let actionHeaderRow = UIStackView()

    // MARK: - 授業ノート(タブの土台。チャット内容は未実装)
    private let noteSection = UIStackView()
    private let noteListContainer = UIStackView()
    private let noteChatContainer = NoteChatStackView()
    private let noteCardStack = UIStackView()
    private let noteEmptyLabel = UILabel()
    private let noteSortButton = UIButton(type: .system)
    private let noteMoreButton = UIButton(type: .system)
    private let noteAttachmentsButton = UIButton(type: .system)
    private let noteChatBackButton = UIButton(type: .system)
    private let noteChatAttachmentsButton = UIButton(type: .system)
    private let noteMutedGreen = UIColor(red: 0x93/255.0, green: 0xbf/255.0, blue: 0xa0/255.0, alpha: 1)
    private let noteDeepGreen = UIColor(red: 0/255, green: 120/255, blue: 87/255, alpha: 1)
    private var noteShowsChatDetail = false
    // 個別チャット画面: AIはまだ未実装。送信したメッセージをその場で吹き出し表示するだけの土台。
    private let noteChatActionRow = UIStackView()
    private let noteChatGuideContainer = UIView()
    private let noteChatMessageStack = UIStackView()
    private let detectionView = AIDetectionResultView()
    private var detectionSourceID: String?
    private var detectionTask: Task<Void, Never>?
    private var aiSessionTask: Task<Void, Never>?

    private let noteChatTextField = UITextField()
    /// チャットの1メッセージ。写真は表示用の縮小版と、送信用の高画質JPEGを両方持つ。
    private enum NoteChatMessage {
        case text(String)
        case document(String)
        case photos([CapturedPhoto])
        case recording(url: URL, duration: TimeInterval)

        var previewSymbol: String {
            switch self {
            case .document: return "doc.text"
            case .text: return "text.bubble"
            case .photos: return "photo"
            case .recording: return "waveform"
            }
        }

        var previewText: String {
            switch self {
            case .document(let name): return name
            case .text(let t): return t
            case .photos(let items): return "写真 \(items.count)枚"
            case .recording(_, let duration): return "録音 \(CourseDetailViewController.timeText(duration))"
            }
        }
    }
    private var aiAuthHandle: AuthStateDidChangeListenerHandle?
    private var aiSessionUID: String?
    private var aiMessageIDs: [Int: [String]] = [:]
    private var noteChatMessagesBySession: [Int: [NoteChatMessage]] = [:]
    private var noteChatCurrentSession: Int = 0
    private let noteChatCompactActions = UIStackView()
    private var noteChatInputBar: UIView?
    private var noteKeyboardOverlap: CGFloat = 0
    private static let noteInputBarMinHeight: CGFloat = 46
    private static let noteAttachmentThumb: CGFloat = 76
    /// 送信前にメッセージ欄へ追加した写真(授業回ごと)
    private var noteChatPendingBySession: [Int: CapturedPhotoSet] = [:]
    /// 録音を止めたあと、送信前にメッセージ欄へ追加してある録音(授業回ごと)
    private var noteChatPendingRecordingsBySession: [Int: [NoteRecordingResult]] = [:]
    private let noteChatAttachmentScroll = UIScrollView()
    private let noteChatAttachmentStack = UIStackView()
    private var noteChatAttachmentHeight: NSLayoutConstraint?
    private var noteChatAttachmentTopPad: NSLayoutConstraint?
    private var noteSortMode: NoteSortMode {
        get {
            UserDefaults.standard.string(forKey: "note.sortMode.\(course.id)").flatMap(NoteSortMode.init(rawValue:)) ?? .session
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "note.sortMode.\(course.id)") }
    }

    private func aiContext(day: Int) throws -> AIInputContext {
        guard let uid = aiSessionUID, AppBackend.currentUID == uid else {
            throw AIInputError.message("資料の接続を準備しています。少し待ってもう一度お試しください")
        }
        guard let uuid = course.localCourseUUID, UUID(uuidString: uuid) != nil else {
            throw AIInputError.message("授業の保存IDを確認できませんでした。時間割を開き直してください")
        }
        let context = AIInputContext(ownerUID: uid, localCourseId: uuid, classDocId: course.firestoreDocID,
                                     year: term.year, semester: term.semester == .spring ? "spring" : "fall", dayID: day,
                                     localCourseUUID: uuid, syllabusUrl: course.syllabusURL,
                                     courseName: course.title, teacherName: course.teacher)
        return try SourceIngestionService.shared.store(uid: uid).contextForInput(context)
    }

    deinit { if let handle = aiAuthHandle { Auth.auth().removeStateDidChangeListener(handle) } }

    private func prepareAIInputSession() {
        guard aiSessionTask == nil else { return }
        aiSessionTask = Task { [weak self] in
            do {
                let uid = try await AIInputSession.shared.ensure()
                try Task.checkCancellation()
                guard let self, AppBackend.currentUID == uid else { return }
                self.aiSessionUID = uid; self.restoreAIInput(); self.updateDetectionSources(restart: true)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.detectionView.showState("接続を準備できませんでした。通信を確認し、授業を開き直してください。")
            }
            self?.aiSessionTask = nil
        }
    }
    @objc private func aiDetectionSourcesChanged() { updateDetectionSources(restart: false) }
    private func updateDetectionSources(restart: Bool) {
        guard noteShowsChatDetail, let context = try? aiContext(day: noteChatCurrentSession),
              let store = try? SourceIngestionService.shared.store(uid: context.ownerUID) else { return }
        let sources = store.ledger.sources.filter {
            $0.context.courseKey == context.courseKey && $0.context.dayID == context.dayID && $0.submitted && !$0.wantsDeletion &&
                !["deleted", "deleting"].contains($0.remote?.status ?? "")
        }.sorted { $0.createdAt < $1.createdAt }
        let prior = detectionSourceID
        if !sources.contains(where: { $0.id == detectionSourceID }) { detectionSourceID = sources.last?.id }
        guard let source = sources.first(where: { $0.id == detectionSourceID }) else { detectionTask?.cancel(); detectionView.clear(); return }
        detectionView.selector.setTitle(source.title + (sources.count > 1 ? " ▾" : ""), for: .normal)
        detectionView.selector.menu = UIMenu(children: sources.map { item in
            UIAction(title: item.title, state: item.id == source.id ? .on : .off) { [weak self] _ in
                self?.detectionSourceID = item.id; self?.updateDetectionSources(restart: true)
            }
        })
        if restart || prior != detectionSourceID || detectionTask == nil { beginDetection(source, uid: context.ownerUID) }
    }
    private func beginDetection(_ selected: AIStoredSource, uid: String) {
        detectionTask?.cancel()
        if AppBackend.isOffline {
            detectionView.showState("ローカル確認モードです。本文の解析はDev接続で確認できます。")
            return
        }
        detectionView.showState("AIが資料を読み取っています…")
        let localID = selected.id
        detectionTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(360)
            while !Task.isCancelled && Date() < deadline {
                guard let self, self.detectionSourceID == localID, AppBackend.currentUID == uid,
                      let store = try? SourceIngestionService.shared.store(uid: uid),
                      let item = store.ledger.sources.first(where: { $0.id == localID }), !item.wantsDeletion else { return }
                if item.localState == "failed" || item.remote?.status == "failed" {
                    self.detectionView.showState("読み取りに失敗しました。再試行してください。", retry: true); return
                }
                do {
                    if let remote = item.remote, ["ready", "partial_ready"].contains(remote.status) {
                        let result = try await SourceIngestionService.shared.detectionResult(sourceId: remote.sourceId, uid: uid)
                        try Task.checkCancellation()
                        guard self.detectionSourceID == localID, AppBackend.currentUID == uid else { return }
                        self.detectionView.show(result)
                        return
                    }
                    await SourceIngestionService.shared.refreshSource(localID: localID, uid: uid)
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                } catch {
                    if Task.isCancelled { return }
                    self.detectionView.showState("本文を読み込めませんでした。再試行してください。", retry: true); return
                }
            }
            if !Task.isCancelled { self?.detectionView.showState("解析を続けています。後でもう一度確認してください。", retry: true) }
        }
    }
    @objc private func retryDetection() {
        guard let uid = aiSessionUID, let store = try? SourceIngestionService.shared.store(uid: uid),
              let item = store.ledger.sources.first(where: { $0.id == detectionSourceID }) else { return }
        Task { [weak self] in
            do { try await SourceIngestionService.shared.retry(item); self?.updateDetectionSources(restart: true) }
            catch { self?.detectionView.showState(error.localizedDescription, retry: true) }
        }
    }
    private func stageAIPhoto(_ photo: CapturedPhoto, context: AIInputContext) throws -> AIStoredSource {
        try SourceIngestionService.shared.store(uid: context.ownerUID).stage(context: context, kind: .image, title: "授業の写真", mime: "image/jpeg", data: photo.jpeg)
    }

    private func restoreAIInput() {
        guard let context = try? aiContext(day: noteChatCurrentSession) else { return }
        do {
            if !NoteRecorder.shared.isRecording { try RecordingRecovery.finish(uid: context.ownerUID) }
            let store = try SourceIngestionService.shared.store(uid: context.ownerUID)
            noteChatMessagesBySession = [:]; aiMessageIDs = [:]
            noteChatPendingBySession = [:]; noteChatPendingRecordingsBySession = [:]
            func photo(_ source: AIStoredSource) -> CapturedPhoto? {
                guard let url = store.fileURL(source), let data = try? Data(contentsOf: url),
                      let thumb = PhotoCodec.downsample(data, maxPixel: 256) else { return nil }
                return CapturedPhoto(jpeg: data, thumb: thumb)
            }
            let visibleSources = store.ledger.sources.filter { !$0.wantsDeletion }
            for message in store.ledger.messages where message.context.courseKey == context.courseKey && !message.hidden {
                let selected = message.sourceIDs.compactMap { id in visibleSources.first { $0.id == id } }
                let rendered: NoteChatMessage
                switch message.kind {
                case "image":
                    let photos = selected.compactMap(photo)
                    rendered = photos.isEmpty ? .document("削除した写真") : .photos(photos)
                case "audio":
                    if let source = selected.first, let url = store.fileURL(source) {
                        rendered = .recording(url: url, duration: Double(source.durationSeconds ?? 0))
                    } else { rendered = .document("削除した録音") }
                case "pdf": rendered = .document("PDF · \(selected.first?.title ?? "削除した資料")")
                case "note": rendered = .document("メモ · \(selected.first?.text ?? "削除したメモ")")
                default: rendered = .text(message.text ?? "")
                }
                noteChatMessagesBySession[message.context.dayID, default: []].append(rendered)
                aiMessageIDs[message.context.dayID, default: []].append(message.id)
                noteLastSentAt[message.context.dayID] = message.createdAt
            }
            for source in visibleSources where source.context.courseKey == context.courseKey && !source.submitted {
                if source.kind == .image, let image = photo(source) {
                    let set = noteChatPendingBySession[source.context.dayID] ?? CapturedPhotoSet()
                    set.items.append(image); noteChatPendingBySession[source.context.dayID] = set
                } else if source.kind == .audio, let url = store.fileURL(source) {
                    noteChatPendingRecordingsBySession[source.context.dayID, default: []].append(NoteRecordingResult(url: url, duration: Double(source.durationSeconds ?? 0)))
                }
            }
            loadNoteSessionCards()
            if noteShowsChatDetail {
                noteChatMessageStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
                let messages = noteChatMessagesBySession[noteChatCurrentSession] ?? []
                for message in messages { noteChatMessageStack.addArrangedSubview(makeNoteChatBubble(message)) }
                noteChatMessageStack.isHidden = messages.isEmpty
                syncNoteChatActions()
                reloadNoteChatAttachments(animated: false)
            }
        } catch { showNoteAlert(title: "保存した資料を読み込めませんでした", message: error.localizedDescription) }
    }
    @objc private func eraseDeletedAIAccount(_ notification: Notification) {
        guard let uid = notification.object as? String, aiSessionUID == uid else { return }
        aiSessionUID = nil
        aiSessionTask?.cancel(); detectionTask?.cancel(); detectionSourceID = nil; detectionView.clear()
        noteChatMessagesBySession.removeAll(); aiMessageIDs.removeAll(); noteLastSentAt.removeAll()
        noteChatPendingBySession.values.forEach { $0.items.removeAll() }
        noteChatPendingBySession.removeAll(); noteChatPendingRecordingsBySession.removeAll()
        noteChatEditingIndex = nil; noteChatTextField.text = ""
        noteChatMessageStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        noteChatAttachmentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        noteCardStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        noteSchedule.removeAll()
        noteChatSendButton.isEnabled = false
        NoteAudioPlayer.shared.stop()
        presentedViewController?.dismiss(animated: false)
    }
#if DEBUG
    var hasRetainedAIInput: Bool {
        !noteChatMessagesBySession.isEmpty || !noteChatPendingBySession.isEmpty ||
        !noteChatPendingRecordingsBySession.isEmpty || !aiMessageIDs.isEmpty || !(noteChatTextField.text ?? "").isEmpty
    }
#endif

    private func openAISources(allDays: Bool) {
        do {
            let context = try aiContext(day: noteChatCurrentSession >= 10000 ? noteChatCurrentSession : Self.noteDayID(Date()))
            present(UINavigationController(rootViewController: SourceLibraryViewController(context: context, allDays: allDays)), animated: true)
        } catch { showNoteAlert(title: "資料を開けませんでした", message: error.localizedDescription) }
    }

    private func pickAIPhotos() {
        var configuration = PHPickerConfiguration(); configuration.filter = .images; configuration.selectionLimit = 10
        let picker = PHPickerViewController(configuration: configuration); picker.delegate = self
        present(picker, animated: true)
    }

    private func pickAIPDF() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: true)
        picker.delegate = self; picker.allowsMultipleSelection = true
        if AppBackend.isOffline {
            picker.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("AIInputSamples")
        }
        present(picker, animated: true)
    }

    private func saveAIMemo() {
        let text = (noteChatTextField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { showNoteAlert(title: "メモを入力してください", message: "入力欄に書いた文章を授業の資料として保存します。"); return }
        do {
            let context = try aiContext(day: noteChatCurrentSession)
            let store = try SourceIngestionService.shared.store(uid: context.ownerUID)
            let source = try store.stage(context: context, kind: .note, title: String(text.prefix(50)), mime: "text/plain", text: text)
            try store.submit(context: context, snapshots: [AIChatSnapshot(id: UUID().uuidString, context: context, kind: "note", text: nil, sourceIDs: [source.id], createdAt: Date())])
            noteChatTextField.text = ""; restoreAIInput(); updateNoteChatSendButton(animated: true)
            SourceIngestionService.shared.resume(uid: context.ownerUID)
        } catch { showNoteAlert(title: "メモを保存できませんでした", message: error.localizedDescription) }
    }

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
    private let syllabusViewToggle = PixelToggleControl(items: ["ポータル"])
    private var syllabusDisplayMode: Int {
        get { UserDefaults.standard.object(forKey: "syllabus.displayMode.v2") as? Int ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: "syllabus.displayMode.v2") }
    }
    private var syllabusWebPageLoaded = false
    private var didRetryLocalSyllabusIndex = false

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
    private let courseManagementSpacer = UIView()

    // MARK: - Friends in Course
    private let friendsCourseSection = UIStackView()
    private let friendsCourseScroll  = UIScrollView()
    private let friendsCourseStack   = UIStackView()
    private var friendsCourseChevron: UIImageView?
    private var friendsCourseContentContainer: UIView?
    private var isFriendsCourseSectionExpanded: Bool {
        get { UserDefaults.standard.object(forKey: "friends.section.expanded") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "friends.section.expanded") }
    }
    
    //下端のバー

    // MARK: - Syllabus Actions (シラバスTabから開いたとき)
    private let showsSyllabusActions: Bool
    private let syllabusDocID: String?        // Firestore docID（ブックマーク用）
    private let showsReview: Bool
    private weak var reviewWriteButton: UIButton?
    private var resolvedReviewDocID: String?
    private var isAddFlowBusy = false
    private weak var syllabusAddButton: UIButton?
    private weak var syllabusBookmarkButton: UIButton?
    private let syllabusBookmarkKey = "favoriteClassIDs"

    // MARK: - Moodle Assignments
    private let moodleSection = UIView()
    private var courseAssignments: [MoodleEvent] = []
    private var moodlePastContainer: UIStackView?  // 期限切れ行の親スタック
    private var moodlePastExpanded = false          // 折りたたみ状態
    private var moodleContentContainer: UIView?     // セクション全体の折りたたみコンテナ
    private var moodleSectionChevron: UIImageView?  // ヘッダーのシェブロン
    private var moodleSectionExpanded: Bool {       // 授業ごとに UserDefaults で永続化
        get { UserDefaults.standard.object(forKey: "moodle.expanded.\(course.id)") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "moodle.expanded.\(course.id)") }
    }

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
         syllabusDocID: String? = nil,
         showsReview: Bool = false,
         showsLectureNotes: Bool = false) {
        self.course = course
        self.location = location
        self.term = term
        self.showsAttendanceControls = showsAttendanceControls
        self.allowsCourseManagement = allowsCourseManagement
        self.showsEnrolledFriends = showsEnrolledFriends
        self.showsMoodleAssignments = showsMoodleAssignments
        self.showsSyllabusActions = showsSyllabusActions
        self.syllabusDocID = syllabusDocID
        self.showsReview = showsReview
        self.showsLectureNotes = showsLectureNotes
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
        aiSessionUID = AppBackend.currentUID
        if showsLectureNotes { prepareAIInputSession() }
        NotificationCenter.default.addObserver(self, selector: #selector(eraseDeletedAIAccount(_:)), name: .aiAccountDeleted, object: nil)
        buildLayout()
        if showsLectureNotes && !AppBackend.isOffline {
            aiAuthHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
                guard let self, self.aiSessionUID != user?.uid else { return }
                if let previousUID = self.aiSessionUID {
                    let recorder = NoteRecorder.shared
                    if recorder.inputContext?.ownerUID == previousUID {
                        _ = recorder.stop() // Preserve the old account's recovery receipt, never attach it to the new UID.
                        recorder.inputContext = nil; recorder.onLevel = nil; recorder.onTick = nil; recorder.onAutoStopped = nil
                    }
                    self.eraseDeletedAIAccount(Notification(name: .aiAccountDeleted, object: previousUID))
                }
                self.aiSessionUID = user?.uid
                if user != nil { self.restoreAIInput(); self.updateDetectionSources(restart: true) }
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(aiDetectionSourcesChanged), name: .aiSourcesChanged, object: nil)
        restoreAIInput()
        if showsSyllabusActions {
            buildSyllabusActionButtons()
        }
        if showsAttendanceControls {
            loadCounts()
            updateCounterButtons()
        }
        if !AppBackend.isOffline { loadSyllabus() }
        else {
            syllabusSpinner.stopAnimating()
            syllabusLoadingHint.text = "ローカル確認ではポータルに接続しません"
            applySyllabusDisplayMode()
        }
        if allowsCourseManagement {
            buildColorPickerRow()  // タイトル直下に設置
        }
        if showsEnrolledFriends {
            loadFriendsInCourse()  // この授業を履修してる友だち
        }
        if showsMoodleAssignments {
            loadMoodleAssignments() // Moodle 課題
        }
        scroll.keyboardDismissMode = .onDrag
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.startGuideFloating()   // バックグラウンドから戻ると、アニメーションが止まっていることがあるため
        }
        scroll.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(noteKeyboardWillChangeFrame(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(noteKeyboardWillHide(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
        setupAdBanner()
        NotificationCenter.default.addObserver(self, selector: #selector(onAdMobReady),
                                               name: .adMobReady, object: nil)
        if showsReview {
            resolveReviewDocIDThenBuild()   // セグメント直下に表示（firestoreDocID未設定時はクエリで解決）
            if showsSyllabusActions {
                loadAndBuildReviewSummary() // 公開後にサマリー追加
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        view.endEditing(true)
        if isBeingDismissed || isMovingFromParent {
            detectionTask?.cancel(); aiSessionTask?.cancel()
            // 授業詳細を閉じたら、録音と再生も止める(使用時間は加算される)
            noteRecordingStopped(NoteRecorder.shared.stop(), auto: false)
            NoteAudioPlayer.shared.stop()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        restoreAIInput()
        updateDetectionSources(restart: true)
        if let uid = aiSessionUID { SourceIngestionService.shared.resume(uid: uid) }
        if #available(iOS 16.0, *),
           let sheet = sheetPresentationController {
            sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
        }
    }


    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        loadBannerIfNeeded()
        updateStickyNoteChatHeader()
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
        noteBackdrop.alpha = 0
        noteBackdrop.isUserInteractionEnabled = false
        noteBackdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(noteBackdrop)
        NSLayoutConstraint.activate([
            noteBackdrop.topAnchor.constraint(equalTo: view.topAnchor),
            noteBackdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            noteBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            noteBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
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
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.numberOfLines = 1
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.75
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleHeader.addSubview(titleLabel)
        titleSubLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleSubLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        titleSubLabel.textAlignment = .center
        titleSubLabel.alpha = 0
        titleSubLabel.translatesAutoresizingMaskIntoConstraints = false
        titleHeader.addSubview(titleSubLabel)
        NSLayoutConstraint.activate([
            titleSubLabel.leadingAnchor.constraint(equalTo: titleHeader.leadingAnchor, constant: 52),
            titleSubLabel.trailingAnchor.constraint(equalTo: titleHeader.trailingAnchor, constant: -52),
            titleSubLabel.bottomAnchor.constraint(equalTo: titleHeader.bottomAnchor, constant: -9)
        ])

        let titleLabelTopC = titleLabel.topAnchor.constraint(equalTo: titleHeader.topAnchor, constant: 12)
        let titleLabelBottomC = titleLabel.bottomAnchor.constraint(equalTo: titleHeader.bottomAnchor, constant: -12)
        titleLabelBottomConstraint = titleLabelBottomC
        let titleHeaderMinHeightC = titleHeader.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        NSLayoutConstraint.activate([
            titleLabelTopC,
            titleLabel.leadingAnchor.constraint(equalTo: titleHeader.leadingAnchor, constant: 52),
            titleLabel.trailingAnchor.constraint(equalTo: titleHeader.trailingAnchor, constant: -52),
            titleLabelBottomC,
            titleHeaderMinHeightC,
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
            // 出欠カウンター（セグメントの直下に配置するため、stackへの追加はトグル構築後に行う）
            countersRow.axis         = .horizontal
            countersRow.alignment    = .fill
            countersRow.distribution = .fillEqually
            countersRow.spacing      = 8
            countersRow.translatesAutoresizingMaskIntoConstraints = false

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

        // ──── シラバス表示切り替えトグル（Moodle課題の直下）────
        syllabusViewToggle.setTitleTextAttributes([.foregroundColor: UIColor.label], for: .normal)
        syllabusViewToggle.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        syllabusViewToggle.addTarget(self, action: #selector(syllabusViewModeChanged), for: .valueChanged)
        if showsLectureNotes {
            syllabusViewToggle.insertSegment(withTitle: "ノート", at: syllabusViewToggle.numberOfSegments, animated: false)
        }
        syllabusViewToggle.accessibilityLabel = "授業内容の表示"
        syllabusViewToggle.accessibilityHint = showsLectureNotes
            ? "ポータルとAIハックを切り替えます"
            : "ポータルを表示します"
        var displayActions = [
            UIAccessibilityCustomAction(
                name: "ポータルを表示",
                target: self,
                selector: #selector(showPortalAccessibilityAction)
            )
        ]
        if showsLectureNotes {
            displayActions.append(
                UIAccessibilityCustomAction(
                    name: "AIハックを表示",
                    target: self,
                    selector: #selector(showNoteAccessibilityAction)
                )
            )
        }
        syllabusViewToggle.accessibilityCustomActions = displayActions
        syllabusViewToggle.selectedSegmentIndex = min(syllabusDisplayMode, syllabusViewToggle.numberOfSegments - 1)
        // ノートタブがあるときは常にトグルを即表示する(シラバス解決を待たせると
        // 他のボタン群に対してだけ遅れて出現し、見た目のノイズになるため)。
        // ノートタブが無い場合は、ポータル単体のセグメントが無意味にならないよう
        // 従来通りシラバスURLが判明するまで隠す。
        syllabusViewToggle.isHidden = !showsLectureNotes
        stack.addArrangedSubview(syllabusViewToggle)

        // 「授業レビューを書く」(resolveReviewDocIDThenBuildで左端に非同期挿入)と、
        // ノートの並び替え/資料ボタン(buildNoteSectionで右端に追加)を同じ行に並べる
        actionHeaderRow.axis = .horizontal
        actionHeaderRow.alignment = .center
        actionHeaderRow.spacing = 8
        stack.addArrangedSubview(actionHeaderRow)

        if showsAttendanceControls {
            stack.addArrangedSubview(countersRow)
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
        if showsLectureNotes {
            // トグルと同じタイミングで即表示する。loadSyllabus()が終わるまでの間、
            // 空白ではなくスピナーが出ている状態にして「一瞬何も無い」フラッシュを防ぐ。
            syllabusSection.isHidden = false
            syllabusSpinner.startAnimating()
        }

        // WebView（プロパティの webContainer を使用）
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.isScrollEnabled = false   // 外側 ScrollView に任せる
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
        webContainer.isHidden = true   // ポータルモード時のみ表示

        // ──── ノート（授業回カード一覧の土台。チャット内容は未実装）────
        if showsLectureNotes {
            buildNoteSection()
        }

        if allowsCourseManagement {
            // 編集・削除ボタン（スクロール末尾）
            buildActionButtonsInScroll()
        }
    }
    

    // MARK: - Friends in Course

    private func buildFriendsCourseSection() {
        // UIStackView なので arranged subview を isHidden にするとスペースが自動で詰まる
        friendsCourseSection.axis = .vertical
        friendsCourseSection.spacing = 0
        friendsCourseSection.translatesAutoresizingMaskIntoConstraints = false
        friendsCourseSection.isHidden = true   // 該当する友だちが見つかるまで非表示
        stack.addArrangedSubview(friendsCourseSection)

        // ── ヘッダー行（タップで折りたたみ）──
        let headerRow = UIView()
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.isUserInteractionEnabled = true

        let label = UILabel()
        label.text = "この授業を履修してる友だち"
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addSubview(label)

        let chevronCfg = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        let chevronName = isFriendsCourseSectionExpanded ? "chevron.up" : "chevron.down"
        let chevronView = UIImageView(image: UIImage(systemName: chevronName, withConfiguration: chevronCfg))
        chevronView.tintColor = .tertiaryLabel
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.setContentHuggingPriority(.required, for: .horizontal)
        friendsCourseChevron = chevronView
        headerRow.addSubview(chevronView)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor),
            label.topAnchor.constraint(equalTo: headerRow.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: -2),
            chevronView.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor),
            chevronView.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
        ])

        let headerTap = UITapGestureRecognizer(target: self, action: #selector(toggleFriendsCourseSection))
        headerRow.addGestureRecognizer(headerTap)
        friendsCourseSection.addArrangedSubview(headerRow)

        // ── コンテンツコンテナ（折りたたみ対象）──
        // isHidden = true にすると UIStackView がスペースを詰めてくれる
        let contentContainer = UIView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.clipsToBounds = true
        contentContainer.isHidden = !isFriendsCourseSectionExpanded
        friendsCourseContentContainer = contentContainer

        // 下線
        let underline = UIView()
        underline.backgroundColor = UIColor.label.withAlphaComponent(0.15)
        underline.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(underline)

        // 横スクロール
        friendsCourseScroll.translatesAutoresizingMaskIntoConstraints = false
        friendsCourseScroll.showsHorizontalScrollIndicator = false
        contentContainer.addSubview(friendsCourseScroll)

        // 横並びスタック（名前付きアイコン）
        friendsCourseStack.axis = .horizontal
        friendsCourseStack.spacing = 16
        friendsCourseStack.alignment = .top
        friendsCourseStack.translatesAutoresizingMaskIntoConstraints = false
        friendsCourseScroll.addSubview(friendsCourseStack)

        NSLayoutConstraint.activate([
            underline.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 3),
            underline.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            underline.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            underline.heightAnchor.constraint(equalToConstant: 1),

            friendsCourseScroll.topAnchor.constraint(equalTo: underline.bottomAnchor, constant: 10),
            friendsCourseScroll.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            friendsCourseScroll.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            friendsCourseScroll.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            friendsCourseScroll.heightAnchor.constraint(equalToConstant: 76),

            friendsCourseStack.topAnchor.constraint(equalTo: friendsCourseScroll.contentLayoutGuide.topAnchor),
            friendsCourseStack.leadingAnchor.constraint(equalTo: friendsCourseScroll.contentLayoutGuide.leadingAnchor),
            friendsCourseStack.trailingAnchor.constraint(equalTo: friendsCourseScroll.contentLayoutGuide.trailingAnchor),
            friendsCourseStack.bottomAnchor.constraint(equalTo: friendsCourseScroll.contentLayoutGuide.bottomAnchor),
            friendsCourseStack.heightAnchor.constraint(equalTo: friendsCourseScroll.frameLayoutGuide.heightAnchor)
        ])

        friendsCourseSection.addArrangedSubview(contentContainer)
    }

    @objc private func toggleFriendsCourseSection() {
        isFriendsCourseSectionExpanded.toggle()

        let chevronName = isFriendsCourseSectionExpanded ? "chevron.up" : "chevron.down"
        let chevronCfg = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        friendsCourseChevron?.image = UIImage(systemName: chevronName, withConfiguration: chevronCfg)

        UIView.animate(withDuration: 0.25) {
            self.friendsCourseContentContainer?.isHidden = !self.isFriendsCourseSectionExpanded
            self.friendsCourseSection.superview?.layoutIfNeeded()
        }
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
        // === 歯車ボタンを緑ヘッダー右上に追加 ===
        let sym = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let gear = UIButton(type: .system)
        gear.setImage(UIImage(systemName: "gearshape.fill", withConfiguration: sym), for: .normal)
        gear.tintColor = UIColor.white.withAlphaComponent(0.75)
        gear.translatesAutoresizingMaskIntoConstraints = false
        gear.addTarget(self, action: #selector(gearTapped), for: .touchUpInside)
        titleHeader.addSubview(gear)
        NSLayoutConstraint.activate([
            gear.trailingAnchor.constraint(equalTo: titleHeader.trailingAnchor, constant: -10),
            gear.centerYAnchor.constraint(equalTo: titleHeader.centerYAnchor),
            gear.widthAnchor.constraint(equalToConstant: 32),
            gear.heightAnchor.constraint(equalToConstant: 32)
        ])

        // === 色ボタンの行（最初は閉じておく） ===
        colorRow.axis = .horizontal
        colorRow.alignment = .center
        colorRow.distribution = .equalSpacing
        colorRow.spacing = 12
        colorRow.isLayoutMarginsRelativeArrangement = true
        colorRow.layoutMargins = .init(top: 4, left: 8, bottom: 8, right: 8)
        colorRow.isHidden = true
        colorRow.alpha  = 0
        stack.insertArrangedSubview(colorRow, at: 0)

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
        if let current = SlotColorStore.color(for: location, term: term) {
            updateSelectedColorUI(selected: current)
        }
    }


    @objc private func gearTapped() {
        let ac = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        ac.addAction(UIAlertAction(title: "教室番号を編集", style: .default) { [weak self] _ in
            self?.editRoomTapped()
        })
        ac.addAction(UIAlertAction(title: "コマの色を変更", style: .default) { [weak self] _ in
            self?.toggleColorPicker()
        })
        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        present(ac, animated: true)
    }

    @objc private func toggleColorPicker() {
        isColorRowOpen.toggle()
        if isColorRowOpen { colorRow.isHidden = false }
        UIView.animate(withDuration: 0.25, animations: {
            self.colorRow.alpha = self.isColorRowOpen ? 1 : 0
            self.view.layoutIfNeeded()
        }, completion: { _ in
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
        let resolvedSyllabusString = resolvedSyllabusURLString()
        let cacheKey: String = {
            let u = resolvedSyllabusString.trimmingCharacters(in: .whitespacesAndNewlines)
            return u.isEmpty ? course.id : u
        }()

        if let cached = SyllabusDataCache.shared.load(for: cacheKey) {
            syllabusPageURL = URL(string: resolvedSyllabusString)
            syllabusSection.isHidden = false
            webContainer.isHidden = true
            buildSyllabusUI(fields: cached)
            return
        }

        guard
            !resolvedSyllabusString.isEmpty,
            let url = URL(string: resolvedSyllabusString),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            if !didRetryLocalSyllabusIndex, !LocalSyllabusIndex.shared.isReady {
                didRetryLocalSyllabusIndex = true
                LocalSyllabusIndex.shared.prepare()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.loadSyllabus()
                }
                // インデックス準備中なのでスピナーだけ出す
                syllabusSection.isHidden = false
                syllabusSpinner.startAnimating()
            } else {
                // URL解決完全失敗: id/URLを見せてデバッグしやすくする
                syllabusSection.isHidden = false
                syllabusSpinner.stopAnimating()
                syllabusLoadingRow.isHidden = true
                let dbg = UILabel()
                dbg.font = .systemFont(ofSize: 11)
                dbg.textColor = .tertiaryLabel
                dbg.numberOfLines = 0
                dbg.text = "[シラバスURL未解決] id=\(course.id) syllabusURL=\(course.syllabusURL ?? "nil")"
                syllabusSection.addArrangedSubview(dbg)
            }
            webContainer.isHidden = true
            return
        }
        syllabusPageURL = url
        syllabusSection.isHidden = false

        // ── キャッシュがあればオフライン表示 ──
        // URLをキーにすることで、同じ登録番号の別授業（担当教員違い）でもキャッシュが混在しない
        // ── キャッシュなし → WebView で読み込む（初回ヒントを表示）──
        syllabusLoadingHint.isHidden = false
        syllabusSpinner.startAnimating()
        webContainer.isHidden = true
        webView.navigationDelegate = self
        webView.load(URLRequest(url: url))
    }

    // MARK: - Syllabus URL resolution
    // 優先順位:
    //   1. course.syllabusURL が公開URL (syllabus.aoyama.ac.jp) → そのまま使う
    //   2. course.syllabusURL が非公開URL (aguinfo/Shousai.aspx) → FN+YR+BQ で変換
    //   3. course.syllabusURL が空 → course.id (= 登録番号/FN) で LocalSyllabusIndex 直接検索
    //   4. 直接検索でヒットしない → 科目名＋曜日時限の fuzzy 検索
    //   5. すべて失敗 → "" を返す（呼び出し側がエラー表示）
    private func resolvedSyllabusURLString() -> String {
        let rawURL = (course.syllabusURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let indexReady = LocalSyllabusIndex.shared.isReady

        print("[SyllabusResolve] course='\(course.title)' id='\(course.id)'"
            + " syllabusURL='\(rawURL)'"
            + " LocalSyllabusIndex.isReady=\(indexReady)")

        // ── 1. 既に公開URL ──────────────────────────────────────────
        if !rawURL.isEmpty,
           let comps = URLComponents(string: rawURL),
           comps.host == "syllabus.aoyama.ac.jp" {
            print("[SyllabusResolve] → (1) existing public URL")
            return rawURL
        }

        // ── 2. 非公開URL → FN/YR+BQ で変換 ───────────────────────
        if !rawURL.isEmpty, let converted = publicSyllabusURLString(from: rawURL) {
            let fn = URLComponents(string: rawURL)?.queryItems?
                .first(where: { $0.name == "FN" })?.value ?? "?"
            let yr = URLComponents(string: rawURL)?.queryItems?
                .first(where: { $0.name == "YR" })?.value ?? "?"
            print("[SyllabusResolve] → (2) aguinfo→public FN=\(fn) YR=\(yr)")
            return converted
        }

        // その他 URL（非空だが変換不要）
        if !rawURL.isEmpty {
            print("[SyllabusResolve] → (other) non-empty raw URL, use as-is")
            return rawURL
        }

        // ── 3. course.id が登録番号形式(FN)なら YR+FN+BQ で直接URL構築 ─
        // LocalSyllabusIndex に URL が入っていなくても動く。
        // rishuu/jugyou_kamoku ソースで course.id = "1611100-0072" 形式のもの。
        let courseID = course.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeFN(courseID) {
            let yr = String(term.year)
            var comps = URLComponents()
            comps.scheme = "https"
            comps.host = "syllabus.aoyama.ac.jp"
            comps.path = "/shousai.ashx"
            comps.queryItems = [
                URLQueryItem(name: "YR", value: yr),
                URLQueryItem(name: "FN", value: courseID),
                URLQueryItem(name: "KW", value: ""),
                URLQueryItem(name: "BQ", value: Self.publicSyllabusBQ)
            ]
            if let builtURL = comps.url?.absoluteString {
                print("[SyllabusResolve] → (3) FN+YR direct build id='\(courseID)' YR=\(yr) → \(builtURL)")
                return builtURL
            }
        }

        // ── LocalSyllabusIndex を使う（FN構築できなかったケース） ────
        if !indexReady {
            LocalSyllabusIndex.shared.prepare()
            print("[SyllabusResolve] → LocalSyllabusIndex not ready, triggered prepare()")
            return ""
        }

        // ── 3b. course.id で LocalSyllabusIndex 直接検索（URL付きなら優先）
        if !courseID.isEmpty, !courseID.hasPrefix("portal_") {
            if let directURL = LocalSyllabusIndex.shared.url(forRegistrationNumber: courseID) {
                let resolved = publicSyllabusURLString(from: directURL) ?? directURL
                print("[SyllabusResolve] → (3b) index FN hit id='\(courseID)' → \(resolved)")
                return resolved
            }
            print("[SyllabusResolve] → (3b) index FN: no URL for id='\(courseID)'")
        }

        // ── 4. fuzzy fallback ─────────────────────────────────────────
        var criteria = SyllabusSearchCriteria()
        criteria.day = location.dayName
        criteria.periods = [location.period]
        criteria.term = term.semester.rawValue
        if let campus = course.campus, !campus.isEmpty {
            criteria.campus = campus
        }

        // url が空でも regNumber がFN形式なら後で構築できる。フィルタしない。
        let matches = LocalSyllabusIndex.shared.search(text: course.title, criteria: criteria)

        print("[SyllabusResolve] → (4) fuzzy: candidates=\(matches.count)"
            + " title='\(course.title)' day=\(location.dayName) period=\(location.period)"
            + " term=\(term.semester.rawValue)")

        guard !matches.isEmpty else {
            print("[SyllabusResolve] → (5) no matches, giving up")
            return ""
        }

        func compact(_ value: String) -> String {
            value
                .lowercased()
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "　", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\t", with: "")
        }

        let titleKey   = compact(course.title)
        let teacherKey = compact(course.teacher)
        let idKey      = compact(course.id)
        let best = matches.max { lhs, rhs in
            func score(_ item: syllabus.SyllabusData) -> Int {
                var v = 0
                if compact(item.class_name) == titleKey { v += 100 }
                if !teacherKey.isEmpty && compact(item.teacher_name).contains(teacherKey) { v += 40 }
                if !idKey.isEmpty && compact(item.regNumber) == idKey { v += 30 }
                if let credits = course.credits, item.credit == String(credits) { v += 10 }
                return v
            }
            return score(lhs) < score(rhs)
        }

        let bestURL    = best?.url.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bestRegNum = best?.regNumber.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // URLが入っていればそのまま使う（aguinfo形式なら変換）
        if !bestURL.isEmpty {
            let resolved = publicSyllabusURLString(from: bestURL) ?? bestURL
            print("[SyllabusResolve] → (4) fuzzy best='\(best?.class_name ?? "")'"
                + " regNum='\(bestRegNum)' url → \(resolved)")
            return resolved
        }

        // URLが空でも regNumber がFN形式 (NNNNNNN-NNNN) なら直接構築
        if looksLikeFN(bestRegNum) {
            let yr = String(term.year)
            var comps = URLComponents()
            comps.scheme = "https"
            comps.host = "syllabus.aoyama.ac.jp"
            comps.path = "/shousai.ashx"
            comps.queryItems = [
                URLQueryItem(name: "YR", value: yr),
                URLQueryItem(name: "FN", value: bestRegNum),
                URLQueryItem(name: "KW", value: ""),
                URLQueryItem(name: "BQ", value: Self.publicSyllabusBQ)
            ]
            if let built = comps.url?.absoluteString {
                print("[SyllabusResolve] → (4) fuzzy regNum→FN build '\(bestRegNum)' → \(built)")
                return built
            }
        }

        print("[SyllabusResolve] → (5) fuzzy found '\(best?.class_name ?? "")' but no usable URL/FN")
        return ""
    }

    private func publicSyllabusURLString(from rawURLString: String) -> String? {
        guard
            let rawComponents = URLComponents(string: rawURLString),
            rawComponents.path.contains("/kouginaiyou/Shousai.aspx")
        else {
            return nil
        }

        let params = rawComponents.queryItems ?? []
        guard
            let fn = params.first(where: { $0.name == "FN" })?.value,
            let yr = params.first(where: { $0.name == "YR" })?.value
        else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "syllabus.aoyama.ac.jp"
        components.path = "/shousai.ashx"
        components.queryItems = [
            URLQueryItem(name: "YR", value: yr),
            URLQueryItem(name: "FN", value: fn),
            URLQueryItem(name: "KW", value: ""),
            URLQueryItem(name: "BQ", value: Self.publicSyllabusBQ)
        ]
        return components.url?.absoluteString
    }

    private static let publicSyllabusBQ = "3f5e5d46524048535c48584c4959336c647d22233127225448512b3e2e296c6f54714344415772021a1d495f401d180a02055e5d5f7b534f4c1f6564796b7b7114001004110803091c746c14131b070a0702061200101112161c081a08120c62542350205423205e4e2b3f562e385f493b264f553f384b513330475d3f2d4f42efefa4c0d4b1bbe8e6afcdc9bdcfd1bfadb7d5d8d6a8b0d3d4a4f0fabacecaa286f1e59e969d80f7eb949f989a8bfee68d8384"

    // ポータル登録番号（FN）形式かどうかを判定する。
    // 例: "1611100-0072"。数字とハイフンのみ、かつ数字4桁以上含む。
    // AGU シラバスFNの形式: "NNNNNNN-NNNN"（例: 1611100-0072）
    // 数字のみ（13301 = 履修登録番号）はFNではないのでハイフン必須
    private func looksLikeFN(_ s: String) -> Bool {
        guard !s.isEmpty, !s.hasPrefix("portal_"), s.contains("-") else { return false }
        let allowed = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: "-"))
        return s.unicodeScalars.allSatisfy({ allowed.contains($0) })
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

        // トグルを表示して現在のモードを適用
        syllabusViewToggle.isHidden = !showsLectureNotes && (syllabusPageURL == nil)
        applySyllabusDisplayMode()
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
            weekBadge.backgroundColor = HackColors.weekBadge
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
                rowContainer.backgroundColor = HackColors.weekBadge.withAlphaComponent(0.12)
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
                        .foregroundColor: isThisWeek ? HackColors.weekBadge : UIColor.secondaryLabel
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
                badge.backgroundColor = HackColors.weekBadge
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
        // ポータルには表示できるかもしれないのでトグルを出す
        syllabusViewToggle.isHidden = !showsLectureNotes && (syllabusPageURL == nil)
        applySyllabusDisplayMode()
    }

    // MARK: - Syllabus Display Mode Toggle

    @objc private func syllabusViewModeChanged() {
        view.endEditing(true)
        let old = syllabusDisplayMode
        syllabusDisplayMode = syllabusViewToggle.selectedSegmentIndex
        UIView.animate(withDuration: 0.2) { self.applySyllabusDisplayMode() }
        slideInDisplayModeContent(direction: syllabusDisplayMode > old ? 1 : -1)
    }

    /// ポータル⇄AIハックの切り替え時、新しい内容を切り替えた向きから滑り込ませる。
    private func slideInDisplayModeContent(direction: CGFloat) {
        let candidates: [UIView] = [noteSection, syllabusSection, webContainer, countersRow]
        let moving = candidates.filter { !$0.isHidden && $0.superview != nil }
        moving.forEach {
            $0.transform = CGAffineTransform(translationX: 48 * direction, y: 0)
            $0.alpha = 0
        }
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut]) {
            moving.forEach {
                $0.transform = .identity
                $0.alpha = 1
            }
        }
    }

    /// 横スワイプで、ポータルとAIハックを行き来する(左へ=AIハック、右へ=ポータル)。
    @objc private func handleDisplayModeSwipe(_ gesture: UISwipeGestureRecognizer) {
        guard showsLectureNotes, !noteShowsChatDetail, !noteChatTextField.isFirstResponder else { return }
        let last = syllabusViewToggle.numberOfSegments - 1
        let current = syllabusViewToggle.selectedSegmentIndex
        if gesture.direction == .left, current < last {
            _ = selectSyllabusDisplayMode(current + 1)
        } else if gesture.direction == .right, current > 0 {
            _ = selectSyllabusDisplayMode(current - 1)
        }
    }

    @objc private func showNativeSyllabusAccessibilityAction() -> Bool {
        false
    }

    @objc private func showPortalAccessibilityAction() -> Bool {
        selectSyllabusDisplayMode(0)
    }

    @objc private func showNoteAccessibilityAction() -> Bool {
        selectSyllabusDisplayMode(syllabusViewToggle.numberOfSegments - 1)
    }

    private func selectSyllabusDisplayMode(_ index: Int) -> Bool {
        guard syllabusViewToggle.selectedSegmentIndex != index else { return true }
        syllabusViewToggle.selectedSegmentIndex = index
        syllabusViewModeChanged()
        UIAccessibility.post(notification: .layoutChanged, argument: syllabusViewToggle)
        return true
    }

    private func applySyllabusDisplayMode() {
        let mode = syllabusViewToggle.selectedSegmentIndex
        if showsAttendanceControls {
            countersRow.isHidden = (mode != 0)
        }
        let inNoteChat = showsLectureNotes && mode == syllabusViewToggle.numberOfSegments - 1 && noteShowsChatDetail
        noteChatInputBar?.isHidden = !inNoteChat
        updateScrollInsetForBanner(height: adContainerHeight?.constant ?? 0)

        if showsLectureNotes && mode == syllabusViewToggle.numberOfSegments - 1 {
            // 一覧(チャット一覧)表示中はセグメントを出したまま、個別チャット画面の時だけ隠す
            syllabusViewToggle.isHidden = noteShowsChatDetail
            actionHeaderRow.isHidden = noteShowsChatDetail
            noteSortButton.isHidden = noteShowsChatDetail
            noteAttachmentsButton.isHidden = noteShowsChatDetail
            noteMoreButton.isHidden = noteShowsChatDetail
            syllabusSection.isHidden = true
            webContainer.isHidden = true
            noteSection.isHidden = false
            noteBackdrop.alpha = 1
            reviewWriteButton?.isHidden = true
            actionsRow.isHidden = true
            courseManagementSpacer.isHidden = true
            return
        }
        syllabusViewToggle.isHidden = !showsLectureNotes && (syllabusPageURL == nil)
        actionHeaderRow.isHidden = false
        noteSortButton.isHidden = true
        noteAttachmentsButton.isHidden = true
        noteBackdrop.alpha = 0
        noteMoreButton.isHidden = true
        noteSection.isHidden = true
        reviewWriteButton?.isHidden = false
        actionsRow.isHidden = !allowsCourseManagement
        courseManagementSpacer.isHidden = !allowsCourseManagement

        syllabusSection.isHidden = true
        guard let url = syllabusPageURL else {
            webContainer.isHidden = true
            return
        }
        if !syllabusWebPageLoaded {
            webView.navigationDelegate = self
            webView.load(URLRequest(url: url))
            syllabusWebPageLoaded = true
        }
        webContainer.isHidden = false
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

        actionsRow.addArrangedSubview(editButton)
        actionsRow.addArrangedSubview(deleteButton)
        actionsRow.axis         = .horizontal
        actionsRow.distribution = .fillEqually
        actionsRow.spacing      = 12

        stack.addArrangedSubview(actionsRow)

        // ボタン下の余白
        courseManagementSpacer.translatesAutoresizingMaskIntoConstraints = false
        courseManagementSpacer.heightAnchor.constraint(equalToConstant: 10).isActive = true
        stack.addArrangedSubview(courseManagementSpacer)
    }

    // MARK: - ノート

    private static let noteIconButtonSize: CGFloat = 44

    private func buildNoteSection() {
        noteSection.axis = .vertical
        noteSection.spacing = 16
        noteSection.isHidden = true
        stack.addArrangedSubview(noteSection)

        buildNoteListContainer()
        buildNoteChatPlaceholder()
        noteSection.addArrangedSubview(noteListContainer)
        noteSection.addArrangedSubview(noteChatContainer)
        noteChatContainer.isHidden = true

        let edgeSwipe = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleNoteChatEdgeSwipe(_:)))
        edgeSwipe.edges = .left
        view.addGestureRecognizer(edgeSwipe)

        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleDisplayModeSwipe(_:)))
            swipe.direction = direction
            swipe.cancelsTouchesInView = false
            swipe.delegate = self
            view.addGestureRecognizer(swipe)
        }

        let tapOutside = UITapGestureRecognizer(target: self, action: #selector(handleNoteChatTapOutside))
        tapOutside.cancelsTouchesInView = false
        tapOutside.delegate = self
        view.addGestureRecognizer(tapOutside)

        loadNoteSessionCards()
    }

    private func buildNoteListContainer() {
        noteListContainer.axis = .vertical
        noteListContainer.spacing = 12

        let iconButtonSize = Self.noteIconButtonSize

        var sortCfg = UIButton.Configuration.plain()
        sortCfg.image = UIImage(systemName: "arrow.up.arrow.down")
        sortCfg.baseForegroundColor = .label
        sortCfg.cornerStyle = .capsule
        noteSortButton.configuration = sortCfg
        noteSortButton.backgroundColor = .systemBackground
        noteSortButton.layer.cornerRadius = iconButtonSize / 2
        noteSortButton.layer.masksToBounds = true
        noteSortButton.layer.borderWidth = 1
        noteSortButton.layer.borderColor = UIColor.separator.cgColor
        noteSortButton.accessibilityLabel = "並び替え"
        noteSortButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            noteSortButton.widthAnchor.constraint(equalToConstant: iconButtonSize),
            noteSortButton.heightAnchor.constraint(equalToConstant: iconButtonSize)
        ])
        updateNoteSortMenu()

        var attachCfg = UIButton.Configuration.plain()
        attachCfg.image = UIImage(systemName: "photo")
        attachCfg.baseForegroundColor = .label
        attachCfg.cornerStyle = .capsule
        noteAttachmentsButton.configuration = attachCfg
        noteAttachmentsButton.backgroundColor = .systemBackground
        noteAttachmentsButton.layer.cornerRadius = iconButtonSize / 2
        noteAttachmentsButton.layer.masksToBounds = true
        noteAttachmentsButton.layer.borderWidth = 1
        noteAttachmentsButton.layer.borderColor = UIColor.separator.cgColor
        noteAttachmentsButton.accessibilityLabel = "送信した画像・資料"
        noteAttachmentsButton.addTarget(self, action: #selector(noteLibraryTapped), for: .touchUpInside)
        noteAttachmentsButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            noteAttachmentsButton.widthAnchor.constraint(equalToConstant: iconButtonSize),
            noteAttachmentsButton.heightAnchor.constraint(equalToConstant: iconButtonSize)
        ])
        // 将来、チャットで送った画像・資料の一覧を開くボタンにする予定。現時点では未実装(no-op)。

        // 並び替え/ライブラリは、セグメント直下の共有行(授業レビューと同じ行)の右端に置く。
        // 専用の行を作らないので、上下の余白が増えない。
        let headerSpacer = UIView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actionHeaderRow.addArrangedSubview(headerSpacer)
        actionHeaderRow.addArrangedSubview(noteSortButton)
        actionHeaderRow.addArrangedSubview(noteAttachmentsButton)

        var moreCfg = UIButton.Configuration.plain()
        moreCfg.image = UIImage(systemName: "ellipsis")
        moreCfg.baseForegroundColor = .label
        moreCfg.cornerStyle = .capsule
        noteMoreButton.configuration = moreCfg
        noteMoreButton.backgroundColor = .systemBackground
        noteMoreButton.layer.cornerRadius = iconButtonSize / 2
        noteMoreButton.layer.masksToBounds = true
        noteMoreButton.layer.borderWidth = 1
        noteMoreButton.layer.borderColor = UIColor.separator.cgColor
        noteMoreButton.accessibilityLabel = "その他"
        noteMoreButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            noteMoreButton.widthAnchor.constraint(equalToConstant: iconButtonSize),
            noteMoreButton.heightAnchor.constraint(equalToConstant: iconButtonSize)
        ])
        noteMoreButton.menu = UIMenu(children: [
            UIAction(title: "補講日を追加", image: UIImage(systemName: "calendar.badge.plus")) { [weak self] _ in
                self?.noteAddExtraDayTapped()
            }
        ])
        noteMoreButton.showsMenuAsPrimaryAction = true
        actionHeaderRow.addArrangedSubview(noteMoreButton)

        noteCardStack.axis = .vertical
        noteCardStack.spacing = 10
        noteListContainer.addArrangedSubview(noteCardStack)

        noteEmptyLabel.text = "まだ授業の記録がありません"
        noteEmptyLabel.font = .systemFont(ofSize: 14)
        noteEmptyLabel.textColor = .secondaryLabel
        noteEmptyLabel.textAlignment = .center
        noteEmptyLabel.isHidden = true
        noteListContainer.addArrangedSubview(noteEmptyLabel)
    }

    private func buildNoteChatPlaceholder() {
        noteChatContainer.axis = .vertical
        noteChatContainer.spacing = 16

        let iconButtonSize = Self.noteIconButtonSize
        let chatHeader = UIView()
        chatHeader.translatesAutoresizingMaskIntoConstraints = false
        noteChatHeader = chatHeader
        noteChatContainer.priorityHitView = chatHeader

        var backCfg = UIButton.Configuration.plain()
        backCfg.image = UIImage(systemName: "chevron.left")
        backCfg.baseForegroundColor = .label
        noteChatBackButton.configuration = backCfg
        noteChatBackButton.accessibilityLabel = "チャット一覧に戻る"
        noteChatBackButton.addTarget(self, action: #selector(noteChatBackButtonTapped), for: .touchUpInside)
        noteChatBackButton.translatesAutoresizingMaskIntoConstraints = false

        var headerAttachCfg = UIButton.Configuration.plain()
        headerAttachCfg.image = UIImage(systemName: "photo")
        headerAttachCfg.baseForegroundColor = .label
        headerAttachCfg.cornerStyle = .capsule
        noteChatAttachmentsButton.configuration = headerAttachCfg
        noteChatAttachmentsButton.backgroundColor = .systemBackground
        noteChatAttachmentsButton.layer.cornerRadius = iconButtonSize / 2
        noteChatAttachmentsButton.layer.masksToBounds = true
        noteChatAttachmentsButton.layer.borderWidth = 1
        noteChatAttachmentsButton.layer.borderColor = UIColor.separator.cgColor
        noteChatAttachmentsButton.accessibilityLabel = "送信した画像・資料"
        noteChatAttachmentsButton.addTarget(self, action: #selector(noteChatLibraryTapped), for: .touchUpInside)
        noteChatAttachmentsButton.translatesAutoresizingMaskIntoConstraints = false

        chatHeader.addSubview(noteChatBackButton)
        chatHeader.addSubview(noteChatAttachmentsButton)
        NSLayoutConstraint.activate([
            chatHeader.heightAnchor.constraint(equalToConstant: iconButtonSize),

            noteChatBackButton.leadingAnchor.constraint(equalTo: chatHeader.leadingAnchor, constant: -10),
            noteChatBackButton.centerYAnchor.constraint(equalTo: chatHeader.centerYAnchor),
            noteChatBackButton.widthAnchor.constraint(equalToConstant: iconButtonSize),
            noteChatBackButton.heightAnchor.constraint(equalToConstant: iconButtonSize),

            noteChatAttachmentsButton.trailingAnchor.constraint(equalTo: chatHeader.trailingAnchor),
            noteChatAttachmentsButton.centerYAnchor.constraint(equalTo: chatHeader.centerYAnchor),
            noteChatAttachmentsButton.widthAnchor.constraint(equalToConstant: iconButtonSize),
            noteChatAttachmentsButton.heightAnchor.constraint(equalToConstant: iconButtonSize)
        ])
        noteChatCompactActions.axis = .horizontal
        noteChatCompactActions.spacing = 8
        noteChatCompactActions.alignment = .center
        noteChatCompactActions.distribution = .fill
        noteChatCompactActions.alpha = 0
        noteChatCompactActions.isHidden = true
        noteChatCompactActions.translatesAutoresizingMaskIntoConstraints = false
        noteChatCompactActions.addArrangedSubview(makeCompactUsageButton())
        noteChatCompactActions.addArrangedSubview(makeCompactSilentButton())
        chatHeader.addSubview(noteChatCompactActions)
        NSLayoutConstraint.activate([
            noteChatCompactActions.trailingAnchor.constraint(equalTo: noteChatAttachmentsButton.leadingAnchor, constant: -8),
            noteChatCompactActions.leadingAnchor.constraint(equalTo: noteChatBackButton.trailingAnchor, constant: 4),
            noteChatCompactActions.centerYAnchor.constraint(equalTo: chatHeader.centerYAnchor)
        ])
        // 上端に貼り付く(スティッキー)ヘッダー。背後の内容は上へフェードアウトする。
        noteChatHeaderFade.translatesAutoresizingMaskIntoConstraints = false
        noteChatHeaderFade.isUserInteractionEnabled = false
        noteChatHeaderFade.alpha = 0
        chatHeader.insertSubview(noteChatHeaderFade, at: 0)
        NSLayoutConstraint.activate([
            noteChatHeaderFade.leadingAnchor.constraint(equalTo: chatHeader.leadingAnchor, constant: -16),
            noteChatHeaderFade.trailingAnchor.constraint(equalTo: chatHeader.trailingAnchor, constant: 16),
            noteChatHeaderFade.topAnchor.constraint(equalTo: chatHeader.topAnchor, constant: -16),
            noteChatHeaderFade.bottomAnchor.constraint(equalTo: chatHeader.bottomAnchor, constant: 40)
        ])
        noteChatContainer.addArrangedSubview(chatHeader)
        // スタックの並び順に関係なく、ヘッダーを常にメッセージより手前に描く
        chatHeader.layer.zPosition = 100

        noteChatActionRow.axis = .horizontal
        noteChatActionRow.distribution = .fillEqually
        noteChatActionRow.spacing = 14
        noteChatActionRow.addArrangedSubview(makeNoteActionCard(
            title: "授業を聞かせる",
            imageNames: ["mic.fill"],
            showsUsage: true,
            action: #selector(noteChatRecordTapped)
        ))
        noteChatActionRow.addArrangedSubview(makeNoteActionCard(
            title: "無音で資料を撮る",
            imageNames: ["speaker.slash.fill", "camera.fill"],
            showsUsage: false,
            action: #selector(noteChatSilentCameraTapped)
        ))
        noteChatContainer.addArrangedSubview(noteChatActionRow)

        let messageLabel = UILabel()
        messageLabel.text = "授業を聞かせたり資料を送ったりして\nAIに学習させよう"
        messageLabel.font = .systemFont(ofSize: 16, weight: .medium)
        messageLabel.textColor = UIColor.secondaryLabel.withAlphaComponent(0.4)
        noteChatGuideLabel = messageLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        noteChatGuideContainer.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        noteChatGuideContainer.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            noteChatGuideContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            messageLabel.centerXAnchor.constraint(equalTo: noteChatGuideContainer.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: noteChatGuideContainer.centerYAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: noteChatGuideContainer.leadingAnchor, constant: 16),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: noteChatGuideContainer.trailingAnchor, constant: -16)
        ])
        noteChatContainer.addArrangedSubview(noteChatGuideContainer)

        noteChatMessageStack.axis = .vertical
        noteChatMessageStack.spacing = 12
        noteChatMessageStack.isHidden = true
        noteChatContainer.addArrangedSubview(noteChatMessageStack)
        noteChatContainer.addArrangedSubview(detectionView)
        detectionView.retryButton.addTarget(self, action: #selector(retryDetection), for: .touchUpInside)

        let inputBar = makeNoteInputBar()
        inputBar.isHidden = true
        view.addSubview(inputBar)
        let followKeyboard = inputBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8)
        followKeyboard.priority = .defaultHigh
        NSLayoutConstraint.activate([
            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            inputBar.bottomAnchor.constraint(lessThanOrEqualTo: adContainer.topAnchor, constant: -8),
            followKeyboard
        ])
        noteChatInputBar = inputBar
    }

    private var noteChatPending: CapturedPhotoSet {
        if let set = noteChatPendingBySession[noteChatCurrentSession] { return set }
        let set = CapturedPhotoSet()
        noteChatPendingBySession[noteChatCurrentSession] = set
        return set
    }

    @objc private func noteChatTextChanged() {
        updateNoteChatSendButton(animated: true)
    }

    /// 送れる内容(文字・写真・録音)があるときは濃い緑、空のときは淡いグレー。
    private func updateNoteChatSendButton(animated: Bool) {
        let hasText = !(noteChatTextField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPhotos = !(noteChatPendingBySession[noteChatCurrentSession]?.items.isEmpty ?? true)
        let hasRecordings = !(noteChatPendingRecordingsBySession[noteChatCurrentSession]?.isEmpty ?? true)
        let canSend = hasText || hasPhotos || hasRecordings
        let apply = {
            self.noteChatSendButton.backgroundColor = canSend ? self.noteDeepGreen : .systemGray5
            self.noteChatSendButton.tintColor = canSend ? .white : .tertiaryLabel
        }
        if animated { UIView.animate(withDuration: 0.15, animations: apply) } else { apply() }
    }

    @objc private func noteChatSendTapped() {
        let text = (noteChatTextField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = noteChatPending.items
        let recordings = noteChatPendingRecordingsBySession[noteChatCurrentSession] ?? []
        guard !text.isEmpty || !pending.isEmpty || !recordings.isEmpty else { return }
        if noteChatEditingIndex != nil && text.isEmpty { return }
        do {
            let context = try aiContext(day: noteChatCurrentSession)
            let store = try SourceIngestionService.shared.store(uid: context.ownerUID)
            var snapshots: [AIChatSnapshot] = []
            var messages: [NoteChatMessage] = []
            if !pending.isEmpty {
                let ids = try pending.map { try stageAIPhoto($0, context: context).id }
                snapshots.append(AIChatSnapshot(id: UUID().uuidString, context: context, kind: "image", text: nil, sourceIDs: ids, createdAt: Date()))
                messages.append(.photos(pending))
            }
            for recording in recordings {
                let source = try store.stage(context: context, kind: .audio, title: "授業の録音", mime: "audio/mp4", fileURL: recording.url, duration: recording.duration)
                snapshots.append(AIChatSnapshot(id: UUID().uuidString, context: context, kind: "audio", text: nil, sourceIDs: [source.id], createdAt: Date()))
                messages.append(.recording(url: store.fileURL(source)!, duration: recording.duration))
            }
            if !text.isEmpty {
                snapshots.append(AIChatSnapshot(id: UUID().uuidString, context: context, kind: "question", text: text, sourceIDs: [], createdAt: Date()))
                messages.append(.text(text))
            }
            let replacing = noteChatEditingIndex.flatMap { index in
                let ids = aiMessageIDs[noteChatCurrentSession] ?? []
                return ids.indices.contains(index) ? ids[index] : nil
            }
            try store.submit(context: context, snapshots: snapshots, replacingFrom: replacing)
            if let index = noteChatEditingIndex { truncateNoteChat(from: index); setNoteChatEditing(nil) }
            aiMessageIDs[noteChatCurrentSession] = store.messages(context: context).map(\.id)
            noteChatTextField.text = ""
            noteChatPending.items.removeAll()
            noteChatPendingRecordingsBySession[noteChatCurrentSession] = []
            reloadNoteChatAttachments(animated: true)
            appendNoteChatMessages(messages)
            detectionSourceID = snapshots.flatMap(\.sourceIDs).last
            updateDetectionSources(restart: true)
            updateNoteChatSendButton(animated: true)
            SourceIngestionService.shared.resume(uid: context.ownerUID)
        } catch { showNoteAlert(title: "保存できませんでした", message: error.localizedDescription) }
    }

    /// 送信した順に吹き出しを追加する。最初の1通のときは大きなカードを小さなボタンへ変形させる。
    private func appendNoteChatMessages(_ messages: [NoteChatMessage]) {
        guard !messages.isEmpty else { return }
        let isFirst = (noteChatMessagesBySession[noteChatCurrentSession] ?? []).isEmpty
        if isFirst {
            noteChatMessageStack.alpha = 0
            noteChatMessageStack.isHidden = false
        }
        noteChatMessagesBySession[noteChatCurrentSession, default: []].append(contentsOf: messages)
        noteLastSentAt[noteChatCurrentSession] = Date()
        loadNoteSessionCards()   // 一覧カードの副題を最新の送信内容に更新

        var bubbles: [UIView] = []
        for message in messages {
            let bubble = makeNoteChatBubble(message)
            bubble.alpha = 0
            bubble.transform = CGAffineTransform(translationX: 0, y: 36).scaledBy(x: 0.9, y: 0.9)
            noteChatMessageStack.addArrangedSubview(bubble)
            bubbles.append(bubble)
        }
        view.layoutIfNeeded()
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.82,
                       initialSpringVelocity: 0.4, options: [.curveEaseOut]) {
            self.noteChatMessageStack.alpha = 1
            bubbles.forEach {
                $0.alpha = 1
                $0.transform = .identity
            }
        }
        syncNoteChatActions()   // 1通目なら、大きなカードを省略ボタンへ畳む(キーボード中は既に畳まれている)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        scrollNoteChatToBottom(animated: true)
    }

    // MARK: メッセージの長押し(コピー/編集)
    private func noteChatMessageIndex(for view: UIView) -> Int? {
        var current: UIView? = view
        while let candidate = current, candidate.superview !== noteChatMessageStack {
            current = candidate.superview
        }
        guard let row = current else { return nil }
        return noteChatMessageStack.arrangedSubviews.firstIndex(of: row)
    }

    private func setNoteChatEditing(_ index: Int?) {
        noteChatEditingIndex = index
        noteChatEditBannerHeight?.constant = index == nil ? 0 : 34
        UIView.animate(withDuration: 0.2) {
            self.view.layoutIfNeeded()
            self.updateScrollInsetForBanner(height: self.adContainerHeight?.constant ?? 0)
        }
    }

    @objc private func noteChatCancelEditTapped() {
        noteChatTextField.text = ""
        updateNoteChatSendButton(animated: true)
        setNoteChatEditing(nil)
    }

    private func beginEditingNoteMessage(at index: Int) {
        guard let messages = noteChatMessagesBySession[noteChatCurrentSession], messages.indices.contains(index),
              case .text(let text) = messages[index] else { return }
        setNoteChatEditing(index)
        noteChatTextField.text = text
        updateNoteChatSendButton(animated: false)
        noteChatTextField.becomeFirstResponder()
    }

    /// index以降のメッセージを消す(画面も作り直す)。全部消えたら最初の状態に戻す。
    private func truncateNoteChat(from index: Int) {
        var messages = noteChatMessagesBySession[noteChatCurrentSession] ?? []
        guard messages.indices.contains(index) else { return }
        messages.removeSubrange(index...)
        noteChatMessagesBySession[noteChatCurrentSession] = messages
        noteChatMessageStack.arrangedSubviews.forEach {
            noteChatMessageStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for message in messages { noteChatMessageStack.addArrangedSubview(makeNoteChatBubble(message)) }
        if messages.isEmpty {
            noteChatMessageStack.isHidden = true
            noteChatActionRow.isHidden = false
            noteChatActionRow.alpha = 1
            noteChatActionRow.arrangedSubviews.forEach { $0.transform = .identity; $0.alpha = 1 }
            noteChatGuideContainer.isHidden = false
            noteChatGuideContainer.alpha = 1
            noteChatCompactActions.arrangedSubviews.forEach { $0.transform = .identity; $0.alpha = 0 }
            noteChatCompactActions.isHidden = true
            noteChatActionsCompact = false
        }
        view.layoutIfNeeded()
    }

    // MARK: 録音
    private func usageText(minutes: Int, compact: Bool) -> NSAttributedString {
        let small = UIFont.systemFont(ofSize: compact ? 10 : 11, weight: .medium)
        let big = UIFont.systemFont(ofSize: compact ? 16 : 18, weight: .bold)
        let text = NSMutableAttributedString(string: "残り", attributes: [.font: small])
        text.append(NSAttributedString(string: "\(minutes)", attributes: [.font: big]))
        text.append(NSAttributedString(string: "分", attributes: [.font: small]))
        return text
    }

    /// 残り時間・利用状況バー・録音中/待機中の表示を、全ての録音ボタンで更新する。
    private func refreshNoteUsageUI() {
        let recorder = NoteRecorder.shared
        let recording = recorder.isRecording
        let minutes = Int(recorder.remainingSeconds / 60)
        let progress = CGFloat(recorder.usedSeconds / NoteRecordingUsage.limitSeconds)
        for parts in noteUsageParts {
            parts.remainingLabel.attributedText = usageText(minutes: minutes, compact: parts.isCompact)
            parts.bar.progress = progress
            parts.idleViews.forEach { $0.isHidden = recording }
            parts.recordingViews.forEach { $0.isHidden = !recording }
            if !recording { parts.waveform.reset() }
        }
    }

    @objc private func noteChatRecordTapped() {
        let recorder = NoteRecorder.shared
        if recorder.isRecording {
            noteRecordingStopped(recorder.stop(), auto: false)
            return
        }
        view.endEditing(true)
        do { recorder.inputContext = try aiContext(day: noteChatCurrentSession) }
        catch { showNoteAlert(title: "録音できませんでした", message: error.localizedDescription); return }
        noteRecordingSession = noteChatCurrentSession
        recorder.onLevel = { [weak self] level in self?.noteUsageParts.forEach { $0.waveform.push(level) } }
        recorder.onTick = { [weak self] in self?.refreshNoteUsageUI() }
        recorder.onAutoStopped = { [weak self] result in self?.noteRecordingStopped(result, auto: true) }
        NoteAudioPlayer.shared.stop()
        recorder.activityCourseTitle = course.title
        recorder.activitySessionLabel = noteSessionTitle(dayID: noteRecordingSession)
        recorder.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.refreshNoteUsageUI()
            case .failure(.limitReached):
                self.showNoteAlert(title: "今週の録音上限に達しました",
                                   message: "録音は1週間に180分までです。来週になるとまた録音できます。")
            case .failure(.permissionDenied):
                let alert = UIAlertController(title: "マイクを使えません",
                                              message: "設定アプリで「青山ハック」のマイクを許可してください。",
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "設定を開く", style: .default) { _ in
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                })
                alert.addAction(UIAlertAction(title: "閉じる", style: .cancel))
                self.present(alert, animated: true)
            case .failure(.failed):
                self.showNoteAlert(title: "録音を開始できませんでした", message: "もう一度お試しください。")
            }
        }
    }

    private func showNoteAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func noteRecordingStopped(_ result: NoteRecordingResult?, auto: Bool) {
        refreshNoteUsageUI()
        if let result {
            do {
                let context = try aiContext(day: noteRecordingSession)
                _ = try SourceIngestionService.shared.store(uid: context.ownerUID).stage(context: context, kind: .audio, title: "授業の録音", mime: "audio/mp4", fileURL: result.url, duration: result.duration)
            } catch { showNoteAlert(title: "録音の紐づけを保存できませんでした", message: error.localizedDescription + "。音声ファイルは端末に残っています。") }
            // 写真と同じく、すぐには送らずメッセージ欄に追加する
            noteChatPendingRecordingsBySession[noteRecordingSession, default: []].append(result)
            if noteShowsChatDetail && noteChatCurrentSession == noteRecordingSession {
                reloadNoteChatAttachments(animated: true)
            }
        }
        if auto && NoteRecorder.shared.remainingSeconds <= 0 {
            showNoteAlert(title: "今週の録音上限に達しました", message: "録音は1週間に180分までです。録音を停止しました。")
        }
    }

    private func makeNoteRecordingBubble(url: URL, duration: TimeInterval) -> UIView {
        let bubble = NoteRecordingBubbleView(url: url, duration: duration,
                                             background: Self.noteBubbleBackground, tint: Self.noteBubbleText)
        bubble.addTarget(self, action: #selector(noteRecordingBubbleTapped(_:)), for: .touchUpInside)
        NoteAudioPlayer.shared.onChange = { [weak self] in self?.refreshNoteAudioControls() }
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [spacer, bubble])
        row.axis = .horizontal
        return row
    }

    @objc private func noteRecordingBubbleTapped(_ sender: NoteRecordingBubbleView) {
        NoteAudioPlayer.shared.toggle(sender.url)
    }

    // MARK: ライブラリ(送信した写真)
    private func sentPhotos(session: Int) -> [CapturedPhoto] {
        (noteChatMessagesBySession[session] ?? []).flatMap { message -> [CapturedPhoto] in
            if case .photos(let items) = message { return items }
            return []
        }
    }

    /// 一覧画面から: 授業回ごとに区切って、全ての回の写真を表示する(新しい回が上)。
    @objc private func noteLibraryTapped() {
        openAISources(allDays: true)
    }

    /// 個別チャットから: この回の写真だけを表示する。
    @objc private func noteChatLibraryTapped() {
        openAISources(allDays: false)
    }

    /// ＋メニュー「ライブラリから追加」: 送信済みの写真から選んで、メッセージ欄に追加する。
    private func noteChatPickFromLibrary() {
        view.endEditing(true)
        let sections = noteChatMessagesBySession.keys.sorted(by: >).compactMap { session -> NoteLibraryViewController.Section? in
            let photos = sentPhotos(session: session)
            return photos.isEmpty ? nil : .init(title: noteSessionTitle(dayID: session), photos: photos)
        }
        let library = NoteLibraryViewController(title: "ライブラリから追加", sections: sections, showsSectionHeaders: true)
        library.onPick = { [weak self] photos in self?.addNotePhotosToComposer(photos) }
        library.modalPresentationStyle = .fullScreen
        present(library, animated: true)
    }

    /// チャットのヘッダー(戻る・録音・撮影・ライブラリ)は、スクロールしても上端に貼り付ける。
    fileprivate func updateStickyNoteChatHeader() {
        guard let header = noteChatHeader else { return }
        guard noteShowsChatDetail else {
            header.transform = .identity
            noteChatHeaderFade.alpha = 0
            return
        }
        header.transform = .identity
        let naturalY = scroll.convert(header.bounds.origin, from: header).y
        let top = scroll.contentOffset.y + 4
        let shift = max(0, top - naturalY)
        header.transform = CGAffineTransform(translationX: 0, y: shift)
        noteChatHeaderFade.alpha = min(1, shift / 12)
    }

    // MARK: 無音カメラ
    @objc private func noteChatSilentCameraTapped() {
        view.endEditing(true)
        let camera = SilentCameraViewController()
        camera.modalPresentationStyle = .fullScreen
        camera.onFinish = { [weak self] photos in
            self?.addNotePhotosToComposer(photos)
        }
        present(camera, animated: true)
    }

    /// カメラで撮った写真は、すぐには送らずメッセージ欄に追加する。
    private func addNotePhotosToComposer(_ photos: [CapturedPhoto]) {
        guard !photos.isEmpty else { return }
        do {
            let context = try aiContext(day: noteChatCurrentSession)
            for photo in photos { _ = try stageAIPhoto(photo, context: context) }
        } catch { showNoteAlert(title: "写真を保存できませんでした", message: error.localizedDescription); return }
        noteChatPending.items.append(contentsOf: photos)
        reloadNoteChatAttachments(animated: true)
    }

    /// メッセージ欄(入力欄の上)の添付サムネイルを、現在の追加済み写真に合わせて作り直す。
    private func reloadNoteChatAttachments(animated: Bool) {
        let items = noteChatPending.items
        noteChatAttachmentStack.arrangedSubviews.forEach {
            noteChatAttachmentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, photo) in items.enumerated() {
            noteChatAttachmentStack.addArrangedSubview(makeAttachmentThumb(photo, index: index))
        }
        let recordings = noteChatPendingRecordingsBySession[noteChatCurrentSession] ?? []
        for (index, recording) in recordings.enumerated() {
            noteChatAttachmentStack.addArrangedSubview(makeAttachmentRecordingChip(recording, index: index))
        }
        let show = !items.isEmpty || !recordings.isEmpty
        noteChatAttachmentHeight?.constant = show ? Self.noteAttachmentThumb : 0
        noteChatAttachmentTopPad?.constant = show ? 12 : 0
        updateNoteChatSendButton(animated: animated)
        let apply = {
            self.view.layoutIfNeeded()
            self.updateScrollInsetForBanner(height: self.adContainerHeight?.constant ?? 0)
        }
        if animated {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut], animations: apply)
        } else {
            apply()
        }
    }

    private func makeAttachmentThumb(_ photo: CapturedPhoto, index: Int) -> UIView {
        let side = Self.noteAttachmentThumb
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let imageView = UIImageView(image: photo.thumb)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 12
        imageView.isUserInteractionEnabled = true
        imageView.tag = index
        imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(noteChatAttachmentTapped(_:))))
        imageView.translatesAutoresizingMaskIntoConstraints = false

        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        cfg.baseForegroundColor = .white
        let remove = UIButton(configuration: cfg)
        remove.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        remove.layer.cornerRadius = 10
        remove.tag = index
        remove.accessibilityLabel = "この写真を外す"
        remove.addTarget(self, action: #selector(noteChatAttachmentRemoveTapped(_:)), for: .touchUpInside)
        remove.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(imageView)
        container.addSubview(remove)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: side),
            container.heightAnchor.constraint(equalToConstant: side),
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            remove.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            remove.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            remove.widthAnchor.constraint(equalToConstant: 20),
            remove.heightAnchor.constraint(equalToConstant: 20)
        ])
        return container
    }

    /// 入力欄の上に並べる録音のチップ(タップで再生、×で外す)
    private func makeAttachmentRecordingChip(_ recording: NoteRecordingResult, index: Int) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let chip = NoteRecordingBubbleView(url: recording.url, duration: recording.duration,
                                           background: Self.noteBubbleBackground, tint: Self.noteBubbleText)
        chip.addTarget(self, action: #selector(noteRecordingBubbleTapped(_:)), for: .touchUpInside)
        NoteAudioPlayer.shared.onChange = { [weak self] in self?.refreshNoteAudioControls() }

        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        cfg.baseForegroundColor = .white
        let remove = UIButton(configuration: cfg)
        remove.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        remove.layer.cornerRadius = 10
        remove.tag = index
        remove.accessibilityLabel = "この録音を外す"
        remove.addTarget(self, action: #selector(noteChatRecordingRemoveTapped(_:)), for: .touchUpInside)
        remove.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(chip)
        container.addSubview(remove)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: Self.noteAttachmentThumb),
            chip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            chip.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            chip.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            remove.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            remove.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            remove.widthAnchor.constraint(equalToConstant: 20),
            remove.heightAnchor.constraint(equalToConstant: 20)
        ])
        return container
    }

    @objc private func noteChatRecordingRemoveTapped(_ sender: UIButton) {
        var recordings = noteChatPendingRecordingsBySession[noteChatCurrentSession] ?? []
        guard recordings.indices.contains(sender.tag) else { return }
        let removed = recordings.remove(at: sender.tag)
        do {
            let context = try aiContext(day: noteChatCurrentSession)
            let store = try SourceIngestionService.shared.store(uid: context.ownerUID)
            let source = try store.stage(context: context, kind: .audio, title: "授業の録音", mime: "audio/mp4", fileURL: removed.url, duration: removed.duration)
            try store.discard(source.id)
        } catch { showNoteAlert(title: "変更を保存できませんでした", message: error.localizedDescription) }
        noteChatPendingRecordingsBySession[noteChatCurrentSession] = recordings
        if NoteAudioPlayer.shared.isPlaying(removed.url) { NoteAudioPlayer.shared.stop() }
        try? FileManager.default.removeItem(at: removed.url)
        reloadNoteChatAttachments(animated: true)
    }

    /// 再生状態の変化を、チャット内の録音吹き出しと入力欄のチップに反映する。
    private func refreshNoteAudioControls() {
        func refresh(in view: UIView) {
            if let bubble = view as? NoteRecordingBubbleView { bubble.refresh() }
            view.subviews.forEach(refresh(in:))
        }
        refresh(in: noteChatMessageStack)
        refresh(in: noteChatAttachmentStack)
    }

    @objc private func noteChatAttachmentRemoveTapped(_ sender: UIButton) {
        let set = noteChatPending
        guard set.items.indices.contains(sender.tag) else { return }
        set.items.remove(at: sender.tag)
        do {
            let context = try aiContext(day: noteChatCurrentSession)
            try SourceIngestionService.shared.store(uid: context.ownerUID).retainDraftPhotos(context: context, photos: set.items.map(\.jpeg))
        } catch { showNoteAlert(title: "変更を保存できませんでした", message: error.localizedDescription) }
        reloadNoteChatAttachments(animated: true)
    }

    @objc private func noteChatAttachmentTapped(_ gesture: UITapGestureRecognizer) {
        guard let index = gesture.view?.tag else { return }
        // 送信前は、全画面で確認しながら取り消しもできる
        presentNotePhotoViewer(photoSet: noteChatPending, index: index, allowsDelete: true) { [weak self] in
            guard let self else { return }
            do {
                let context = try self.aiContext(day: self.noteChatCurrentSession)
                try SourceIngestionService.shared.store(uid: context.ownerUID).retainDraftPhotos(context: context, photos: self.noteChatPending.items.map(\.jpeg))
            } catch { self.showNoteAlert(title: "変更を保存できませんでした", message: error.localizedDescription) }
            self.reloadNoteChatAttachments(animated: false)
        }
    }

    private func presentNotePhotoViewer(photoSet: CapturedPhotoSet, index: Int, allowsDelete: Bool,
                                        onDismiss: (() -> Void)? = nil) {
        view.endEditing(true)
        let pager = SilentCameraPagerViewController(photoSet: photoSet, startIndex: index, allowsDelete: allowsDelete)
        pager.modalPresentationStyle = .fullScreen
        pager.onDismiss = onDismiss
        present(pager, animated: true)
    }

    @objc private func noteChatSentPhotoTapped(_ gesture: UITapGestureRecognizer) {
        guard let imageView = gesture.view as? UIImageView,
              let row = imageView.superview?.superview as? NotePhotoRowScrollView else { return }
        presentNotePhotoViewer(photoSet: CapturedPhotoSet(items: row.photos), index: imageView.tag, allowsDelete: false)
    }

    private func morphTransform(from source: CGRect, to target: CGRect) -> CGAffineTransform {
        CGAffineTransform(translationX: target.midX - source.midX, y: target.midY - source.midY)
            .scaledBy(x: target.width / max(source.width, 1), y: target.height / max(source.height, 1))
    }

    /// 大きいカードを出すべきか(会話が空でキーボードも閉じている)、省略ボタンに畳むべきか(会話がある/入力中)を合わせる。
    private func syncNoteChatActions() {
        guard noteShowsChatDetail, !noteChatMorphing else { return }
        let hasMessages = !(noteChatMessagesBySession[noteChatCurrentSession] ?? []).isEmpty
        let desiredCompact = hasMessages || noteChatTextField.isFirstResponder
        guard desiredCompact != noteChatActionsCompact else { return }
        noteChatActionsCompact = desiredCompact
        noteChatMorphing = true
        let finished = { [weak self] in
            guard let self else { return }
            self.noteChatMorphing = false
            self.syncNoteChatActions()   // アニメーション中に状態が変わっていたら追従する
        }
        if desiredCompact {
            noteChatCompactActions.isHidden = false
            noteChatCompactActions.alpha = 1
            noteChatCompactActions.arrangedSubviews.forEach { $0.alpha = 0; $0.transform = .identity }
            morphActionCardsIntoCompactButtons(completion: finished)
        } else {
            morphCompactButtonsIntoActionCards(completion: finished)
        }
    }

    /// 大きい2枚のカードが、ヘッダーの小さいボタンへ縮みながら移動する。
    private func morphActionCardsIntoCompactButtons(completion: @escaping () -> Void) {
        let bigCards = noteChatActionRow.arrangedSubviews
        let smallButtons = noteChatCompactActions.arrangedSubviews
        guard bigCards.count == smallButtons.count else {
            finishNoteActionMorph(completion: completion)
            return
        }
        view.layoutIfNeeded()
        let pairs: [(big: UIView, small: UIView, from: CGRect, to: CGRect)] = zip(bigCards, smallButtons).map { big, small in
            (big, small,
             big.convert(big.bounds, to: view),
             small.convert(small.bounds, to: view))
        }
        // 小さいボタンは、大きいカードの位置・大きさから出発する
        pairs.forEach { $0.small.transform = morphTransform(from: $0.to, to: $0.from) }

        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9,
                       initialSpringVelocity: 0.2, options: [.curveEaseInOut], animations: {
            self.noteChatGuideContainer.alpha = 0
            pairs.forEach {
                $0.big.transform = self.morphTransform(from: $0.from, to: $0.to)
                $0.big.alpha = 0
                $0.small.transform = .identity
                $0.small.alpha = 1
            }
        }, completion: { _ in
            self.finishNoteActionMorph(completion: completion)
        })
    }

    private func finishNoteActionMorph(completion: @escaping () -> Void) {
        noteChatActionRow.arrangedSubviews.forEach { $0.transform = .identity }
        UIView.animate(withDuration: 0.18, animations: {
            self.noteChatActionRow.isHidden = true
            self.noteChatGuideContainer.isHidden = true
            self.noteChatCompactActions.alpha = 1
            self.view.layoutIfNeeded()
        }, completion: { _ in completion() })
    }

    /// 逆向き: 省略ボタンが膨らんで、大きい2枚のカードに戻る。
    private func morphCompactButtonsIntoActionCards(completion: @escaping () -> Void) {
        let bigCards = noteChatActionRow.arrangedSubviews
        let smallButtons = noteChatCompactActions.arrangedSubviews
        noteChatActionRow.isHidden = false
        noteChatGuideContainer.isHidden = false
        noteChatActionRow.alpha = 1
        noteChatGuideContainer.alpha = 0
        bigCards.forEach { $0.transform = .identity; $0.alpha = 0 }
        view.layoutIfNeeded()
        guard bigCards.count == smallButtons.count else {
            bigCards.forEach { $0.alpha = 1 }
            noteChatGuideContainer.alpha = 1
            noteChatCompactActions.isHidden = true
            completion()
            return
        }
        let pairs: [(big: UIView, small: UIView, big0: CGRect, small0: CGRect)] = zip(bigCards, smallButtons).map { big, small in
            (big, small, big.convert(big.bounds, to: view), small.convert(small.bounds, to: view))
        }
        // 大きいカードは、省略ボタンの位置・大きさから広がる
        pairs.forEach { $0.big.transform = morphTransform(from: $0.big0, to: $0.small0) }

        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9,
                       initialSpringVelocity: 0.2, options: [.curveEaseInOut], animations: {
            self.noteChatGuideContainer.alpha = 1
            pairs.forEach {
                $0.big.transform = .identity
                $0.big.alpha = 1
                $0.small.transform = self.morphTransform(from: $0.small0, to: $0.big0)
                $0.small.alpha = 0
            }
        }, completion: { _ in
            self.noteChatCompactActions.arrangedSubviews.forEach { $0.transform = .identity }
            self.noteChatCompactActions.isHidden = true
            self.startGuideFloating()
            completion()
        })
    }

    private func makeNoteChatBubble(_ message: NoteChatMessage) -> UIView {
        if case .photos(let photos) = message {
            return makeNotePhotoRow(photos)
        }
        if case .recording(let url, let duration) = message {
            return makeNoteRecordingBubble(url: url, duration: duration)
        }
        return makeNoteTextBubble(message.previewText)
    }

    /// 送信済みの写真は、横1列(はみ出す分は横スクロール)で右寄せに並べる。
    private func makeNotePhotoRow(_ photos: [CapturedPhoto]) -> UIView {
        let side: CGFloat = 128
        let scroll = NotePhotoRowScrollView()
        scroll.photos = photos
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        for (index, photo) in photos.enumerated() {
            let imageView = UIImageView(image: photo.thumb)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 16
            imageView.isUserInteractionEnabled = true
            imageView.tag = index
            imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(noteChatSentPhotoTapped(_:))))
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.widthAnchor.constraint(equalToConstant: side).isActive = true
            imageView.heightAnchor.constraint(equalToConstant: side).isActive = true
            stack.addArrangedSubview(imageView)
        }
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(equalToConstant: side),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        return scroll
    }

    private func makeNoteTextBubble(_ text: String) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 15)
        label.textColor = Self.noteBubbleText
        label.numberOfLines = 0

        let bubble = UIView()
        bubble.backgroundColor = Self.noteBubbleBackground
        bubble.layer.cornerRadius = 16
        bubble.addInteraction(UIContextMenuInteraction(delegate: self))   // 長押しでコピー/編集
        label.translatesAutoresizingMaskIntoConstraints = false
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10)
        ])

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [spacer, bubble])
        row.axis = .horizontal
        bubble.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        return row
    }

    /// メッセージ送信後にヘッダーへ出す省略版。録音ボタン(マイク+残り時間+利用状況バー)。
    /// 録音中は、マイクと残り時間が「● + 波形」に切り替わる。
    private func makeCompactUsageButton() -> UIView {
        let button = UIButton(type: .system)
        button.backgroundColor = noteMutedGreen
        button.layer.cornerRadius = 12
        button.clipsToBounds = true
        button.accessibilityLabel = "授業を聞かせる"
        button.addTarget(self, action: #selector(noteChatRecordTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false

        let parts = NoteUsageParts()
        parts.isCompact = true

        let icon = UIImageView(image: UIImage(systemName: "mic.fill"))
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        icon.isUserInteractionEnabled = false
        icon.translatesAutoresizingMaskIntoConstraints = false

        let remaining = parts.remainingLabel
        remaining.textColor = .white
        remaining.isUserInteractionEnabled = false
        remaining.translatesAutoresizingMaskIntoConstraints = false

        let track = parts.bar
        track.trackColor = UIColor.white.withAlphaComponent(0.3)
        track.fillColor = noteDeepGreen.withAlphaComponent(0.6)
        track.isUserInteractionEnabled = false
        track.translatesAutoresizingMaskIntoConstraints = false

        let dot = UIView()
        dot.backgroundColor = .systemRed
        dot.layer.cornerRadius = 7
        dot.isHidden = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        let waveform = parts.waveform
        waveform.isHidden = true
        waveform.translatesAutoresizingMaskIntoConstraints = false

        button.addSubview(icon)
        button.addSubview(remaining)
        button.addSubview(dot)
        button.addSubview(waveform)
        button.addSubview(track)
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 44),
            icon.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: button.topAnchor, constant: 18),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            remaining.leadingAnchor.constraint(greaterThanOrEqualTo: icon.trailingAnchor, constant: 8),
            remaining.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -12),
            remaining.centerYAnchor.constraint(equalTo: icon.centerYAnchor),

            dot.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 14),
            dot.heightAnchor.constraint(equalToConstant: 14),
            waveform.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            waveform.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -12),
            waveform.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            waveform.heightAnchor.constraint(equalToConstant: 20),

            track.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 4),
            track.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -4),
            track.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -7),
            track.heightAnchor.constraint(equalToConstant: 5)
        ])
        parts.idleViews = [icon, remaining]
        parts.recordingViews = [dot, waveform]
        noteUsageParts.append(parts)
        refreshNoteUsageUI()
        return button
    }

    /// 省略版の「無音で資料を撮る」ボタン(アイコンのみ)
    private func makeCompactSilentButton() -> UIView {
        let button = UIButton(type: .system)
        button.backgroundColor = noteMutedGreen
        button.layer.cornerRadius = 12
        button.clipsToBounds = true
        button.accessibilityLabel = "無音で資料を撮る"
        button.addTarget(self, action: #selector(noteChatSilentCameraTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        for name in ["speaker.slash.fill", "camera.fill"] {
            let iv = UIImageView(image: UIImage(systemName: name))
            iv.tintColor = .white
            iv.contentMode = .scaleAspectFit
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: 22).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 22).isActive = true
            row.addArrangedSubview(iv)
        }
        button.addSubview(row)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 84),
            button.heightAnchor.constraint(equalToConstant: 44),
            row.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        return button
    }

    private func makeNoteActionCard(title: String, imageNames: [String], showsUsage: Bool, action: Selector? = nil) -> UIView {
        let button = UIButton(type: .system)
        if let action { button.addTarget(self, action: action, for: .touchUpInside) }
        button.backgroundColor = noteMutedGreen
        button.layer.cornerRadius = 18
        button.clipsToBounds = true
        button.accessibilityLabel = title
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 114).isActive = true

        let content = UIStackView()
        content.axis = .vertical
        content.alignment = .center
        content.spacing = showsUsage ? 2 : 8
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(content)

        // 利用状況パネルより下の領域(パネルが無ければカード全体)の中央に、アイコンとタイトルを置く
        let body = UILayoutGuide()
        button.addLayoutGuide(body)
        var bodyTop = body.topAnchor.constraint(equalTo: button.topAnchor)
        var usageParts: NoteUsageParts?

        if showsUsage {
            let usageContainer = UIView()
            usageContainer.backgroundColor = UIColor.white.withAlphaComponent(0.5)
            usageContainer.layer.cornerRadius = 10
            usageContainer.translatesAutoresizingMaskIntoConstraints = false
            usageContainer.isUserInteractionEnabled = false
            usageContainer.layer.cornerRadius = 0   // 角はカード側のclipsToBoundsで丸める
            button.addSubview(usageContainer)
            NSLayoutConstraint.activate([
                usageContainer.topAnchor.constraint(equalTo: button.topAnchor),
                usageContainer.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                usageContainer.trailingAnchor.constraint(equalTo: button.trailingAnchor)
            ])
            bodyTop = body.topAnchor.constraint(equalTo: usageContainer.bottomAnchor)

            let usageRow = UIStackView()
            usageRow.axis = .horizontal
            usageRow.alignment = .lastBaseline
            usageRow.spacing = 4
            usageRow.translatesAutoresizingMaskIntoConstraints = false

            let usageTitle = UILabel()
            usageTitle.text = "今週の利用状況"
            usageTitle.font = .systemFont(ofSize: 12, weight: .medium)
            usageTitle.adjustsFontSizeToFitWidth = true
            usageTitle.minimumScaleFactor = 0.75
            usageTitle.textColor = noteDeepGreen
            usageTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let parts = NoteUsageParts()
            let usageRemaining = parts.remainingLabel
            usageRemaining.textColor = noteDeepGreen
            usageRemaining.textAlignment = .right
            usageRemaining.setContentCompressionResistancePriority(.required, for: .horizontal)
            usageRemaining.setContentHuggingPriority(.required, for: .horizontal)

            usageRow.addArrangedSubview(usageTitle)
            usageRow.addArrangedSubview(usageRemaining)

            let track = parts.bar
            track.trackColor = noteMutedGreen.withAlphaComponent(0.6)
            track.fillColor = noteDeepGreen.withAlphaComponent(0.6)
            track.translatesAutoresizingMaskIntoConstraints = false
            track.heightAnchor.constraint(equalToConstant: 10).isActive = true
            usageParts = parts

            let usageInnerStack = UIStackView(arrangedSubviews: [usageRow, track])
            usageInnerStack.axis = .vertical
            usageInnerStack.spacing = 4
            usageInnerStack.translatesAutoresizingMaskIntoConstraints = false
            usageContainer.addSubview(usageInnerStack)
            NSLayoutConstraint.activate([
                usageInnerStack.topAnchor.constraint(equalTo: usageContainer.topAnchor, constant: 5),
                usageInnerStack.leadingAnchor.constraint(equalTo: usageContainer.leadingAnchor, constant: 10),
                usageInnerStack.trailingAnchor.constraint(equalTo: usageContainer.trailingAnchor, constant: -10),
                usageInnerStack.bottomAnchor.constraint(equalTo: usageContainer.bottomAnchor, constant: -6)
            ])
        }

        let iconRow = UIStackView()
        iconRow.axis = .horizontal
        iconRow.alignment = .center
        iconRow.spacing = 14
        let iconSize: CGFloat = showsUsage ? 28 : 28
        imageNames.forEach { name in
            let imageView = UIImageView(image: UIImage(systemName: name))
            imageView.tintColor = .white
            imageView.contentMode = .scaleAspectFit
            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: iconSize),
                imageView.heightAnchor.constraint(equalToConstant: iconSize)
            ])
            iconRow.addArrangedSubview(imageView)
        }
        content.addArrangedSubview(iconRow)

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.82
        content.addArrangedSubview(titleLabel)

        NSLayoutConstraint.activate([
            bodyTop,
            body.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            content.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            content.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -12)
        ])

        // 録音中の表示: 波形と「● 録音中」
        if let parts = usageParts {
            let waveform = parts.waveform
            waveform.translatesAutoresizingMaskIntoConstraints = false
            let dot = UIView()
            dot.backgroundColor = .systemRed
            dot.layer.cornerRadius = 5
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
            let status = UILabel()
            status.text = "録音中"
            status.font = .systemFont(ofSize: 14, weight: .bold)
            status.textColor = .systemRed
            let statusRow = UIStackView(arrangedSubviews: [dot, status])
            statusRow.axis = .horizontal
            statusRow.alignment = .center
            statusRow.spacing = 8

            let recording = UIStackView(arrangedSubviews: [waveform, statusRow])
            recording.axis = .vertical
            recording.alignment = .center
            recording.spacing = 3
            recording.isUserInteractionEnabled = false
            recording.isHidden = true
            recording.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(recording)
            NSLayoutConstraint.activate([
                waveform.heightAnchor.constraint(equalToConstant: 26),
                waveform.widthAnchor.constraint(equalTo: recording.widthAnchor),
                recording.centerYAnchor.constraint(equalTo: body.centerYAnchor),
                recording.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 14),
                recording.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -14)
            ])
            parts.idleViews = [content]
            parts.recordingViews = [recording]
            noteUsageParts.append(parts)
            refreshNoteUsageUI()
        }
        return button
    }

    /// キーボードの高さぶん下余白を増やし、一番下のメッセージが入力欄のすぐ上に来るようスクロールする。
    @objc private func noteKeyboardWillChangeFrame(_ note: Notification) {
        guard noteShowsChatDetail, noteChatTextField.isFirstResponder,
              let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let local = view.convert(end, from: nil)
        noteKeyboardOverlap = max(0, view.bounds.maxY - local.minY)
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curve = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 7
        UIView.animate(withDuration: duration, delay: 0, options: UIView.AnimationOptions(rawValue: curve << 16)) {
            self.updateScrollInsetForBanner(height: self.adContainerHeight?.constant ?? 0)
            self.view.layoutIfNeeded()
            self.scrollNoteChatToBottom(animated: false)
        }
    }

    @objc private func noteKeyboardWillHide(_ note: Notification) {
        guard noteKeyboardOverlap > 0 else { return }
        noteKeyboardOverlap = 0
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        UIView.animate(withDuration: duration) {
            self.updateScrollInsetForBanner(height: self.adContainerHeight?.constant ?? 0)
            self.view.layoutIfNeeded()
            // 余白が減ってコンテンツが範囲外に出ないよう、下端に収める
            let maxOffset = max(-self.scroll.contentInset.top,
                                self.scroll.contentSize.height + self.scroll.contentInset.bottom - self.scroll.bounds.height)
            if self.scroll.contentOffset.y > maxOffset { self.scroll.contentOffset.y = maxOffset }
        }
    }

    /// コンテンツの下端(=最新メッセージ)が、下の余白の直前に見える位置までスクロールする。
    private func scrollNoteChatToBottom(animated: Bool) {
        guard noteShowsChatDetail else { return }
        // まだ何も送っていないときは動かさない(授業名の帯が一瞬スクロールアウトしてしまうため)
        guard !(noteChatMessagesBySession[noteChatCurrentSession] ?? []).isEmpty else { return }
        view.layoutIfNeeded()
        let visibleHeight = scroll.bounds.height - scroll.contentInset.bottom
        let target = scroll.contentSize.height - visibleHeight
        guard target > -scroll.contentInset.top, scroll.contentSize.height > visibleHeight else { return }
        scroll.setContentOffset(CGPoint(x: 0, y: target), animated: animated)
    }

    @objc private func handleNoteChatTapOutside() {
        guard noteChatTextField.isFirstResponder else { return }
        view.endEditing(true)
    }

    @objc private func noteChatBackButtonTapped() {
        showNoteChatDetail(false)
    }

    @objc private func handleNoteChatEdgeSwipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended, noteShowsChatDetail else { return }
        showNoteChatDetail(false)
    }

    /// UIVisualEffectView(ガラスのカード)を含むビューは snapshotView だと黒っぽく写るため、描画結果を画像にして使う。
    private static func blurSafeSnapshot(of view: UIView) -> UIView? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let imageView = UIImageView(image: image)
        imageView.frame = view.bounds
        return imageView
    }

    private func showNoteChatDetail(_ show: Bool) {
        guard show != noteShowsChatDetail else { return }
        view.endEditing(true)

        let incoming = show ? noteChatContainer : noteListContainer
        let outgoing = show ? noteListContainer : noteChatContainer
        let width = max(noteSection.bounds.width, view.bounds.width)

        // 退場側は見た目だけ(スナップショット)を残して即座にレイアウトから外す。
        // 両方がスタックに残ると、入場側が退場側の下に押し下げられて上に余白ができるため。
        let snapshot = Self.blurSafeSnapshot(of: outgoing)
        // noteSection自体がヘッダーの出入りで上下に動くため、動かない親(stack)に載せて位置を固定する
        let snapshotHost: UIView = stack
        snapshot?.frame = outgoing.convert(outgoing.bounds, to: snapshotHost)

        // セグメント(ポータル/AIハック)と授業レビュー行も、一覧と一緒に横へスライドさせる
        let headerViews: [UIView] = [syllabusViewToggle, actionHeaderRow]
        var headerSnapshots: [UIView] = []
        if show {
            for header in headerViews where !header.isHidden {
                guard let host = header.superview,
                      let snap = header.snapshotView(afterScreenUpdates: false) else { continue }
                snap.frame = header.frame
                headerSnapshots.append(snap)
                host.addSubview(snap)
            }
        }

        noteShowsChatDetail = show
        noteChatInputBar?.isHidden = !show
        updateTitleSubtitle(animated: false)
        updateStickyNoteChatHeader()
        updateScrollInsetForBanner(height: adContainerHeight?.constant ?? 0)
        syllabusViewToggle.isHidden = show
        actionHeaderRow.isHidden = show
        noteSortButton.isHidden = show
        noteAttachmentsButton.isHidden = show
        noteMoreButton.isHidden = show
        if !show {
            headerViews.forEach { $0.transform = CGAffineTransform(translationX: -width, y: 0) }
        }

        outgoing.isHidden = true
        incoming.isHidden = false
        incoming.transform = CGAffineTransform(translationX: show ? width : -width, y: 0)
        if let snapshot { snapshotHost.addSubview(snapshot) }
        view.layoutIfNeeded()

        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            options: [.curveEaseInOut],
            animations: {
                incoming.transform = .identity
                snapshot?.transform = CGAffineTransform(translationX: show ? -width : width, y: 0)
                headerSnapshots.forEach { $0.transform = CGAffineTransform(translationX: -width, y: 0) }
                if !show { headerViews.forEach { $0.transform = .identity } }
            },
            completion: { _ in
                snapshot?.removeFromSuperview()
                headerSnapshots.forEach { $0.removeFromSuperview() }
            }
        )
    }

    private func makeNoteInputBar() -> UIView {
        let bar = UIView()
        bar.backgroundColor = .systemBackground
        bar.layer.cornerRadius = 24
        bar.layer.borderWidth = 1
        bar.layer.borderColor = UIColor.separator.cgColor
        bar.clipsToBounds = true
        bar.translatesAutoresizingMaskIntoConstraints = false

        // 上段: 追加した写真のサムネイル(無いときは高さ0)
        noteChatAttachmentScroll.showsHorizontalScrollIndicator = false
        noteChatAttachmentScroll.alwaysBounceHorizontal = true
        noteChatAttachmentScroll.translatesAutoresizingMaskIntoConstraints = false
        noteChatAttachmentStack.axis = .horizontal
        noteChatAttachmentStack.spacing = 8
        noteChatAttachmentStack.translatesAutoresizingMaskIntoConstraints = false
        noteChatAttachmentScroll.addSubview(noteChatAttachmentStack)
        bar.addSubview(noteChatAttachmentScroll)

        // 下段: +  入力欄  送信
        let fieldRow = UIView()
        fieldRow.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(fieldRow)

        let plus = UIButton(type: .system)
        plus.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)), for: .normal)
        plus.tintColor = .secondaryLabel
        plus.accessibilityLabel = "追加"
        plus.accessibilityIdentifier = "ai-input-add"
        plus.showsMenuAsPrimaryAction = true
        plus.menu = UIMenu(children: [
            UIAction(title: "撮影", image: UIImage(systemName: "camera")) { [weak self] _ in
                self?.noteChatSilentCameraTapped()
            },
            UIAction(title: "写真から選ぶ", image: UIImage(systemName: "photo")) { [weak self] _ in self?.pickAIPhotos() },
            UIAction(title: "ライブラリから追加", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
                self?.noteChatPickFromLibrary()
            },
            UIAction(title: "PDFを追加", image: UIImage(systemName: "doc")) { [weak self] _ in self?.pickAIPDF() },
            UIAction(title: "入力した文章をメモとして保存", image: UIImage(systemName: "note.text")) { [weak self] _ in self?.saveAIMemo() },
            UIAction(title: "資料と送信状況", image: UIImage(systemName: "tray")) { [weak self] _ in self?.openAISources(allDays: false) }
        ])
        plus.translatesAutoresizingMaskIntoConstraints = false

        noteChatTextField.placeholder = "リアクションペーパーを書いて"
        noteChatTextField.font = .systemFont(ofSize: 15)
        noteChatTextField.returnKeyType = .send
        noteChatTextField.delegate = self
        noteChatTextField.addTarget(self, action: #selector(noteChatTextChanged), for: .editingChanged)
        noteChatTextField.translatesAutoresizingMaskIntoConstraints = false

        let sendButton = noteChatSendButton
        sendButton.layer.cornerRadius = 18
        sendButton.setImage(UIImage(systemName: "arrow.up"), for: .normal)
        sendButton.accessibilityLabel = "送信"
        sendButton.addTarget(self, action: #selector(noteChatSendTapped), for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        fieldRow.addSubview(plus)
        fieldRow.addSubview(noteChatTextField)
        fieldRow.addSubview(sendButton)

        // 最上段: 「編集中」バナー(編集していないときは高さ0)
        noteChatEditBanner.clipsToBounds = true
        noteChatEditBanner.translatesAutoresizingMaskIntoConstraints = false
        let editIcon = UIImageView(image: UIImage(systemName: "pencil"))
        editIcon.tintColor = .secondaryLabel
        editIcon.translatesAutoresizingMaskIntoConstraints = false
        let editLabel = UILabel()
        editLabel.text = "メッセージを編集中(これ以降の会話は新しくなります)"
        editLabel.font = .systemFont(ofSize: 12, weight: .medium)
        editLabel.textColor = .secondaryLabel
        editLabel.translatesAutoresizingMaskIntoConstraints = false
        var cancelCfg = UIButton.Configuration.plain()
        cancelCfg.image = UIImage(systemName: "xmark.circle.fill")
        cancelCfg.baseForegroundColor = .tertiaryLabel
        let cancelEdit = UIButton(configuration: cancelCfg)
        cancelEdit.accessibilityLabel = "編集をやめる"
        cancelEdit.addTarget(self, action: #selector(noteChatCancelEditTapped), for: .touchUpInside)
        cancelEdit.translatesAutoresizingMaskIntoConstraints = false
        noteChatEditBanner.addSubview(editIcon)
        noteChatEditBanner.addSubview(editLabel)
        noteChatEditBanner.addSubview(cancelEdit)
        bar.addSubview(noteChatEditBanner)
        let bannerHeight = noteChatEditBanner.heightAnchor.constraint(equalToConstant: 0)
        noteChatEditBannerHeight = bannerHeight
        NSLayoutConstraint.activate([
            noteChatEditBanner.topAnchor.constraint(equalTo: bar.topAnchor),
            noteChatEditBanner.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            noteChatEditBanner.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            bannerHeight,
            editIcon.leadingAnchor.constraint(equalTo: noteChatEditBanner.leadingAnchor, constant: 16),
            editIcon.centerYAnchor.constraint(equalTo: noteChatEditBanner.centerYAnchor),
            editLabel.leadingAnchor.constraint(equalTo: editIcon.trailingAnchor, constant: 6),
            editLabel.centerYAnchor.constraint(equalTo: noteChatEditBanner.centerYAnchor),
            cancelEdit.trailingAnchor.constraint(equalTo: noteChatEditBanner.trailingAnchor, constant: -8),
            cancelEdit.centerYAnchor.constraint(equalTo: noteChatEditBanner.centerYAnchor),
            cancelEdit.widthAnchor.constraint(equalToConstant: 32),
            cancelEdit.heightAnchor.constraint(equalToConstant: 32),
            editLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelEdit.leadingAnchor, constant: -4)
        ])

        let heightConstraint = noteChatAttachmentScroll.heightAnchor.constraint(equalToConstant: 0)
        let topPad = noteChatAttachmentScroll.topAnchor.constraint(equalTo: noteChatEditBanner.bottomAnchor, constant: 0)
        noteChatAttachmentHeight = heightConstraint
        noteChatAttachmentTopPad = topPad

        NSLayoutConstraint.activate([
            topPad,
            noteChatAttachmentScroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            noteChatAttachmentScroll.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            heightConstraint,
            noteChatAttachmentStack.topAnchor.constraint(equalTo: noteChatAttachmentScroll.contentLayoutGuide.topAnchor),
            noteChatAttachmentStack.bottomAnchor.constraint(equalTo: noteChatAttachmentScroll.contentLayoutGuide.bottomAnchor),
            noteChatAttachmentStack.leadingAnchor.constraint(equalTo: noteChatAttachmentScroll.contentLayoutGuide.leadingAnchor),
            noteChatAttachmentStack.trailingAnchor.constraint(equalTo: noteChatAttachmentScroll.contentLayoutGuide.trailingAnchor),
            noteChatAttachmentStack.heightAnchor.constraint(equalTo: noteChatAttachmentScroll.frameLayoutGuide.heightAnchor),

            fieldRow.topAnchor.constraint(equalTo: noteChatAttachmentScroll.bottomAnchor),
            fieldRow.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            fieldRow.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            fieldRow.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            fieldRow.heightAnchor.constraint(equalToConstant: Self.noteInputBarMinHeight),

            plus.leadingAnchor.constraint(equalTo: fieldRow.leadingAnchor, constant: 8),
            plus.centerYAnchor.constraint(equalTo: fieldRow.centerYAnchor),
            plus.widthAnchor.constraint(equalToConstant: 40),
            plus.heightAnchor.constraint(equalToConstant: 40),

            sendButton.trailingAnchor.constraint(equalTo: fieldRow.trailingAnchor, constant: -6),
            sendButton.centerYAnchor.constraint(equalTo: fieldRow.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 36),
            sendButton.heightAnchor.constraint(equalToConstant: 36),

            noteChatTextField.leadingAnchor.constraint(equalTo: plus.trailingAnchor, constant: 4),
            noteChatTextField.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -10),
            noteChatTextField.centerYAnchor.constraint(equalTo: fieldRow.centerYAnchor)
        ])
        return bar
    }

    // MARK: 休講・補講(授業日ごとの印)
    private static let noteJST = TimeZone(identifier: "Asia/Tokyo") ?? .current

    fileprivate static func noteDayID(_ date: Date) -> Int {
        Int(floor((date.timeIntervalSince1970 + TimeInterval(noteJST.secondsFromGMT(for: date))) / 86400))
    }

    fileprivate static func noteDate(dayID: Int) -> Date {
        let utcMidnight = Date(timeIntervalSince1970: TimeInterval(dayID) * 86400)
        return utcMidnight.addingTimeInterval(-TimeInterval(noteJST.secondsFromGMT(for: utcMidnight)))
    }

    private var noteCancelledDays: Set<Int> {
        get { Set(UserDefaults.standard.array(forKey: "note.cancelled.\(course.id)") as? [Int] ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "note.cancelled.\(course.id)") }
    }

    private var noteExtraDays: Set<Int> {
        get { Set(UserDefaults.standard.array(forKey: "note.extra.\(course.id)") as? [Int] ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "note.extra.\(course.id)") }
    }

    private func setNoteDay(_ dayID: Int, cancelled: Bool) {
        var days = noteCancelledDays
        if cancelled { days.insert(dayID) } else { days.remove(dayID) }
        noteCancelledDays = days
        reloadNoteCardsAnimated()
    }

    private func addNoteExtraDay(_ date: Date) {
        let dayID = Self.noteDayID(date)
        if let existing = noteSchedule.first(where: { $0.dayID == dayID }) {
            if existing.isCancelled {
                setNoteDay(dayID, cancelled: false)   // 休講にしていた日なら、授業日に戻す
            } else {
                showNoteAlert(title: "その日はすでに授業日です", message: "別の日を選んでください。")
            }
            return
        }
        var days = noteExtraDays
        days.insert(dayID)
        noteExtraDays = days
        reloadNoteCardsAnimated()
    }

    private func removeNoteExtraDay(_ dayID: Int) {
        var days = noteExtraDays
        days.remove(dayID)
        noteExtraDays = days
        reloadNoteCardsAnimated()
    }

    private func reloadNoteCardsAnimated() {
        UIView.transition(with: noteCardStack, duration: 0.25, options: [.transitionCrossDissolve]) {
            self.loadNoteSessionCards()
        }
    }

    /// 「第N回授業」(休講の日は「10/8 休講」)。
    private func noteSessionTitle(dayID: Int) -> String {
        if let entry = noteSchedule.first(where: { $0.dayID == dayID }), let number = entry.number {
            return "第\(number)回授業"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d"
        return "\(formatter.string(from: Self.noteDate(dayID: dayID))) 休講"
    }

    @objc private func noteAddExtraDayTapped() {
        let picker = NoteExtraDatePickerViewController()
        picker.onPick = { [weak self] date in self?.addNoteExtraDay(date) }
        present(picker, animated: true)
    }

    private func loadNoteSessionCards() {
        let cal = Calendar(identifier: .gregorian)
        // 箱は「前日の時点で」用意しておきたいので、翌日までの授業回を対象にする
        // (例: 今日が木曜なら、今日の回に加えて明日=金曜の回もすでに表示する)
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) else { return }

        let baseDates = LectureSessionNumbering.sessionDates(
            upTo: tomorrow,
            weekday: location.day,
            term: term,
            campus: LectureSessionNumbering.campus(for: course)
        )
        // 学事暦の授業日 + 補講日。日付(dayID)で重複を除いて古い順に並べる。
        var datesByID: [Int: Date] = [:]
        for date in baseDates { datesByID[Self.noteDayID(date)] = date }
        let extras = noteExtraDays
        for id in extras where datesByID[id] == nil { datesByID[id] = Self.noteDate(dayID: id) }

        let cancelled = noteCancelledDays
        var number = 0
        var cards: [NoteSessionCard] = datesByID.keys.sorted().map { id in
            let isCancelled = cancelled.contains(id)
            if !isCancelled { number += 1 }
            return NoteSessionCard(dayID: id, number: isCancelled ? nil : number, date: datesByID[id]!,
                                   isCancelled: isCancelled, isExtra: extras.contains(id))
        }
        noteSchedule = cards

        switch noteSortMode {
        case .session:
            cards.sort { $0.dayID > $1.dayID }
        case .oldest:
            cards.sort { $0.dayID < $1.dayID }
        case .chat:
            // 最後に送信した順(新しい方が上)。まだ送っていない回は日付順で後ろに並べる。
            cards.sort { lhs, rhs in
                switch (noteLastSentAt[lhs.dayID], noteLastSentAt[rhs.dayID]) {
                case let (l?, r?): return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.dayID > rhs.dayID
                }
            }
        }

        noteCardStack.arrangedSubviews.forEach {
            noteCardStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        cards.forEach { noteCardStack.addArrangedSubview(makeNoteCard($0)) }
        noteEmptyLabel.isHidden = !cards.isEmpty
    }

    private func makeNoteCard(_ card: NoteSessionCard) -> UIView {
        let messages = noteChatMessagesBySession[card.dayID] ?? []

        let classDateFormatter = DateFormatter()
        classDateFormatter.locale = Locale(identifier: "ja_JP")
        classDateFormatter.dateFormat = "M/d E"
        let classDateText = classDateFormatter.string(from: card.date)
        let sentText = noteSentTimeText(dayID: card.dayID)   // 送信済みのときだけ。授業日と同じ表示を重ねない

        // 最後のメッセージ(種類アイコン付き)。無ければ薄い文言。
        let previewIcon = UIImageView()
        previewIcon.contentMode = .scaleAspectFit
        previewIcon.tintColor = .tertiaryLabel
        previewIcon.setContentHuggingPriority(.required, for: .horizontal)
        previewIcon.translatesAutoresizingMaskIntoConstraints = false
        previewIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        previewIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let previewLabel = UILabel()
        previewLabel.numberOfLines = 1
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.font = .systemFont(ofSize: 13)
        if let last = messages.last {
            previewIcon.image = UIImage(systemName: last.previewSymbol,
                                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .medium))
            previewLabel.text = last.previewText
            previewLabel.textColor = .secondaryLabel
        } else {
            previewLabel.text = card.isCancelled ? "タップで休講を取り消せます" : "まだ記録がありません"
            previewLabel.textColor = .tertiaryLabel
        }
        let previewRow = UIStackView(arrangedSubviews: messages.isEmpty ? [previewLabel] : [previewIcon, previewLabel])
        previewRow.axis = .horizontal
        previewRow.alignment = .center
        previewRow.spacing = 5

        let titleLabel = UILabel()
        let titleText = card.number.map { "第\($0)回授業" } ?? classDateText
        titleLabel.text = card.isExtra && card.number != nil ? "\(titleText) · 補講" : titleText
        let timeLabel = UILabel()
        timeLabel.textColor = .tertiaryLabel
        timeLabel.textAlignment = .right
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        let content: UIView
        let cardView: NoteSessionCardControl

        if card.isCancelled {
            // ── 休講: 淡く、点線の枠。番号は付けない ──
            cardView = NoteSessionCardControl(cornerRadius: 24, tint: nil)
            cardView.setDashedStyle()
            cardView.alpha = 0.6
            titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
            titleLabel.attributedText = NSAttributedString(string: titleLabel.text ?? "", attributes: [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: UIColor.secondaryLabel,
                .font: UIFont.systemFont(ofSize: 15, weight: .medium)
            ])
            let badgeTag = UILabel()
            badgeTag.text = "  休講  "
            badgeTag.font = .systemFont(ofSize: 11, weight: .medium)
            badgeTag.textColor = .secondaryLabel
            badgeTag.backgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.15)
            badgeTag.layer.cornerRadius = 9
            badgeTag.layer.masksToBounds = true
            badgeTag.setContentHuggingPriority(.required, for: .horizontal)
            let titleRow = UIStackView(arrangedSubviews: [titleLabel, badgeTag, UIView()])
            titleRow.axis = .horizontal
            titleRow.alignment = .center
            titleRow.spacing = 8
            let icon = NoteSessionCircleBadge(symbol: "calendar.badge.minus", size: 44, deep: noteDeepGreen)
            let titles = UIStackView(arrangedSubviews: [titleRow, previewRow])
            titles.axis = .vertical
            titles.spacing = 2
            let row = UIStackView(arrangedSubviews: [icon, titles])
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 12
            content = row
        } else {
            // ── 通常: 浮かぶガラスの行 ──
            cardView = NoteSessionCardControl(cornerRadius: 24, tint: nil)
            titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
            timeLabel.font = .systemFont(ofSize: 12)
            timeLabel.text = sentText ?? classDateText   // 送信済みは送信時刻、未送信は授業日
            let badge = NoteSessionCircleBadge(number: card.number ?? 0, size: 44, solid: false,
                                               deep: noteDeepGreen, fontSize: 17)
            let titles = UIStackView(arrangedSubviews: [titleLabel, previewRow])
            titles.axis = .vertical
            titles.spacing = 2
            // 右: 時刻(未送信なら授業日)と、写真・録音の件数
            let trailing = UIStackView(arrangedSubviews: [timeLabel] + (makeNoteCountPills(messages: messages).map { [$0] } ?? []))
            trailing.axis = .vertical
            trailing.alignment = .trailing
            trailing.spacing = 5
            trailing.setContentHuggingPriority(.required, for: .horizontal)
            let row = UIStackView(arrangedSubviews: [badge, titles, trailing])
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 12
            content = row
        }

        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        cardView.tag = card.dayID
        cardView.addTarget(self, action: #selector(noteCardTapped(_:)), for: .touchUpInside)
        // 長押しで休講/補講の操作。システムのコンテキストメニューは、タップ時にも周りを暗くしてしまうため使わない。
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(noteCardLongPressed(_:)))
        longPress.minimumPressDuration = 0.45
        cardView.addGestureRecognizer(longPress)
        cardView.accessibilityLabel = noteSessionTitle(dayID: card.dayID)
        cardView.addSubview(content)
        let inset: CGFloat = 12
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: cardView.topAnchor, constant: inset),
            content.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -14),
            content.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -inset)
        ])
        return cardView
    }

    /// 写真・録音の件数を小さなカプセルで並べる(どちらも無ければnil)。
    private func makeNoteCountPills(messages: [NoteChatMessage]) -> UIView? {
        var photoCount = 0
        var recordingCount = 0
        for message in messages {
            switch message {
            case .photos(let items): photoCount += items.count
            case .recording: recordingCount += 1
            case .text, .document: break
            }
        }
        guard photoCount > 0 || recordingCount > 0 else { return nil }
        let pills = UIStackView()
        pills.axis = .horizontal
        pills.spacing = 4
        if photoCount > 0 { pills.addArrangedSubview(makeNoteCountPill(symbol: "photo", count: photoCount)) }
        if recordingCount > 0 { pills.addArrangedSubview(makeNoteCountPill(symbol: "waveform", count: recordingCount)) }
        return pills
    }

    private func makeNoteCountPill(symbol: String, count: Int) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: symbol,
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)))
        icon.tintColor = Self.noteBubbleText
        let label = UILabel()
        label.text = "\(count)"
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = Self.noteBubbleText
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 3
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 3, left: 7, bottom: 3, right: 8)
        stack.backgroundColor = Self.noteBubbleBackground
        stack.layer.cornerRadius = 10
        stack.layer.masksToBounds = true
        return stack
    }

    @objc private func noteCardTapped(_ sender: UIControl) {
        let dayID = sender.tag
        guard let card = noteSchedule.first(where: { $0.dayID == dayID }) else { return }
        if card.isCancelled {
            // 休講のカード: 取り消すか、(チャットがあれば)開くかを選ぶ
            let sheet = UIAlertController(title: noteSessionTitle(dayID: dayID), message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "休講を取り消す", style: .default) { [weak self] _ in
                self?.setNoteDay(dayID, cancelled: false)
            })
            if !(noteChatMessagesBySession[dayID] ?? []).isEmpty {
                sheet.addAction(UIAlertAction(title: "チャットを開く", style: .default) { [weak self] _ in
                    self?.openNoteChat(session: dayID)
                })
            }
            sheet.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
            sheet.popoverPresentationController?.sourceView = sender
            sheet.popoverPresentationController?.sourceRect = sender.bounds
            present(sheet, animated: true)
            return
        }
        openNoteChat(session: dayID)
    }

    /// カード長押しで出す操作の一覧。
    private func noteCardActions(dayID: Int) -> [(title: String, destructive: Bool, enabled: Bool, handler: () -> Void)] {
        guard let card = noteSchedule.first(where: { $0.dayID == dayID }) else { return [] }
        let hasMessages = !(noteChatMessagesBySession[dayID] ?? []).isEmpty
        var actions: [(title: String, destructive: Bool, enabled: Bool, handler: () -> Void)] = []
        if card.isCancelled {
            actions.append(("休講を取り消す", false, true, { [weak self] in self?.setNoteDay(dayID, cancelled: false) }))
        } else {
            actions.append(("休講にする", false, true, { [weak self] in self?.setNoteDay(dayID, cancelled: true) }))
        }
        if !card.isCancelled || hasMessages {
            actions.append(("チャットを開く", false, true, { [weak self] in self?.openNoteChat(session: dayID) }))
        }
        if card.isExtra {
            actions.append(("補講を削除", true, !hasMessages, { [weak self] in self?.removeNoteExtraDay(dayID) }))
        }
        return actions
    }

    @objc private func noteCardLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let card = gesture.view else { return }
        let actions = noteCardActions(dayID: card.tag)
        guard !actions.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let sheet = UIAlertController(title: noteSessionTitle(dayID: card.tag), message: nil, preferredStyle: .actionSheet)
        for action in actions {
            let item = UIAlertAction(title: action.title, style: action.destructive ? .destructive : .default) { _ in action.handler() }
            item.isEnabled = action.enabled
            sheet.addAction(item)
        }
        sheet.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        sheet.popoverPresentationController?.sourceView = card
        sheet.popoverPresentationController?.sourceRect = card.bounds
        present(sheet, animated: true)
    }

    /// 授業回ごとに別チャット。開く回のメッセージで画面を作り直してから遷移する。
    private func openNoteChat(session: Int) {
        noteChatCurrentSession = session
        noteChatTextField.text = ""
        updateNoteChatSendButton(animated: false)
        updateTitleSubtitle(animated: false)
        if noteChatEditingIndex != nil { setNoteChatEditing(nil) }
        reloadNoteChatAttachments(animated: false)
        noteChatMessageStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let messages = noteChatMessagesBySession[session] ?? []
        for message in messages {
            noteChatMessageStack.addArrangedSubview(makeNoteChatBubble(message))
        }
        let isEmpty = messages.isEmpty
        noteChatMessageStack.alpha = 1
        noteChatMessageStack.isHidden = isEmpty
        noteChatActionRow.alpha = 1
        noteChatActionRow.arrangedSubviews.forEach { $0.transform = .identity; $0.alpha = 1 }
        noteChatCompactActions.arrangedSubviews.forEach { $0.transform = .identity; $0.alpha = 1 }
        noteChatActionRow.isHidden = !isEmpty
        noteChatGuideContainer.alpha = 1
        noteChatGuideContainer.isHidden = !isEmpty
        startGuideFloating()
        noteChatCompactActions.isHidden = isEmpty
        noteChatCompactActions.alpha = isEmpty ? 0 : 1
        noteChatActionsCompact = !isEmpty
        noteChatMorphing = false
        showNoteChatDetail(true)
        detectionSourceID = nil; updateDetectionSources(restart: true)
    }

    /// チャット表示中は、緑の帯に「第N回授業 · 9/29 火」を小さく出す(どの回のチャットか分かるように)。
    private func updateTitleSubtitle(animated: Bool) {
        let show = noteShowsChatDetail
        if show, let entry = noteSchedule.first(where: { $0.dayID == noteChatCurrentSession }) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ja_JP")
            formatter.dateFormat = "M/d E"
            titleSubLabel.text = "\(noteSessionTitle(dayID: entry.dayID)) · \(formatter.string(from: entry.date))"
        }
        titleLabelBottomConstraint?.constant = show ? -28 : -12
        let changes = {
            self.titleSubLabel.alpha = show ? 1 : 0
            self.view.layoutIfNeeded()
        }
        if animated { UIView.animate(withDuration: 0.25, animations: changes) } else { changes() }
    }

    /// 最後に送った時刻(今日は時:分、昨日は「昨日」、それ以前は月/日)。まだ送っていなければnil。
    private func noteSentTimeText(dayID: Int) -> String? {
        guard let sent = noteLastSentAt[dayID] else { return nil }
        let cal = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        if cal.isDateInToday(sent) {
            formatter.dateFormat = "H:mm"
        } else if cal.isDateInYesterday(sent) {
            return "昨日"
        } else {
            formatter.dateFormat = "M/d"
        }
        return formatter.string(from: sent)
    }

    private func relativeDateString(from date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        // card.dateは授業当日の0時なので、メッセージが無いうちは時刻(0:00)を出さず「今日」「明日」で表す。
        // メッセージが実装されたら、ここは最終送信日時ベースの表示に差し替える(他のTODOと同じ箇所)。
        if cal.isDateInToday(date) { return "今日" }
        if cal.isDateInTomorrow(date) { return "明日" }
        if cal.isDateInYesterday(date) { return "昨日" }
        if let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: Date()), cal.isDate(date, inSameDayAs: twoDaysAgo) {
            return "一昨日"
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = cal.isDate(date, equalTo: Date(), toGranularity: .year) ? "M/d" : "yyyy/M/d"
        return f.string(from: date)
    }

    /// 並び替えメニュー(新しい順/古い順/チャット順)。選択中の項目にチェックを付ける。
    private func updateNoteSortMenu() {
        func action(_ title: String, _ image: String, _ mode: NoteSortMode) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: image),
                     state: noteSortMode == mode ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.noteSortMode = mode
                self.updateNoteSortMenu()
                UIView.transition(with: self.noteCardStack, duration: 0.25, options: [.transitionCrossDissolve]) {
                    self.loadNoteSessionCards()
                }
            }
        }
        noteSortButton.menu = UIMenu(title: "並び替え", children: [
            action("授業が新しい順", "arrow.down", .session),
            action("授業が古い順", "arrow.up", .oldest),
            action("チャット順", "bubble.left.and.bubble.right", .chat)
        ])
        noteSortButton.showsMenuAsPrimaryAction = true
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
        // TermStore.knownTermStartDays が唯一のソース（年度を追加するときはそちらに追記する）。
        let termStartDays = TermStore.knownTermStartDays

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
            startComps.month = isFront ? k.springMonth : k.fallMonth
            startComps.day   = isFront ? k.springDay   : k.fallDay
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
        moodleContentContainer = nil
        moodleSectionChevron = nil
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

        // ─── ヘッダー行（タップで折りたたみ） ───
        let headerRow = UIView()
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.isUserInteractionEnabled = true

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

        let chevronCfg = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        let chevronName = moodleSectionExpanded ? "chevron.up" : "chevron.down"
        let chevronView = UIImageView(image: UIImage(systemName: chevronName, withConfiguration: chevronCfg))
        chevronView.tintColor = .tertiaryLabel
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.setContentHuggingPriority(.required, for: .horizontal)
        moodleSectionChevron = chevronView

        headerRow.addSubview(iconView)
        headerRow.addSubview(headerLabel)
        headerRow.addSubview(chevronView)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            headerLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            headerLabel.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            chevronView.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor, constant: -14),
            chevronView.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            headerRow.heightAnchor.constraint(equalToConstant: 36)
        ])

        let headerTap = UITapGestureRecognizer(target: self, action: #selector(toggleMoodleSection))
        headerRow.addGestureRecognizer(headerTap)
        outerStack.addArrangedSubview(headerRow)

        // ─── コンテンツコンテナ（折りたたみ対象） ───
        let contentContainer = UIView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.clipsToBounds = true
        contentContainer.isHidden = !moodleSectionExpanded
        moodleContentContainer = contentContainer

        let contentStack = UIStackView()
        contentStack.axis = .vertical
        contentStack.spacing = 0
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])

        let topDiv = UIView()
        topDiv.backgroundColor = UIColor.label.withAlphaComponent(0.08)
        topDiv.translatesAutoresizingMaskIntoConstraints = false
        topDiv.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        contentStack.addArrangedSubview(topDiv)

        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "M/d(EEE) HH:mm"

        let upcomingItems = sorted.enumerated().filter { !$0.element.isPast }
        let pastItems     = sorted.enumerated().filter {  $0.element.isPast }

        // ─── 期限未来の課題 ───
        for (pos, (i, event)) in upcomingItems.enumerated() {
            if pos > 0 { contentStack.addArrangedSubview(makeDivider()) }
            contentStack.addArrangedSubview(makeMoodleRow(event: event, tag: i, df: df))
        }

        // ─── 期限切れの折りたたみ ───
        if !pastItems.isEmpty {
            // 区切り線
            if !upcomingItems.isEmpty { contentStack.addArrangedSubview(makeDivider()) }

            // 「期限切れ X 件 ▼」トグルボタン
            let toggleBtn = UIButton(type: .system)
            let pastChevronName = moodlePastExpanded ? "chevron.up" : "chevron.down"
            let btnTitle = "期限切れ \(pastItems.count) 件"
            var cfg = UIButton.Configuration.plain()
            cfg.title = btnTitle
            cfg.image = UIImage(systemName: pastChevronName,
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
            contentStack.addArrangedSubview(toggleBtn)

            // 期限切れ行のコンテナ（初期は非表示）
            let pastStack = UIStackView()
            pastStack.axis = .vertical
            pastStack.spacing = 0
            pastStack.isHidden = !moodlePastExpanded
            for (pos, (i, event)) in pastItems.enumerated() {
                if pos > 0 { pastStack.addArrangedSubview(makeDivider()) }
                pastStack.addArrangedSubview(makeMoodleRow(event: event, tag: i, df: df))
            }
            contentStack.addArrangedSubview(pastStack)
            moodlePastContainer = pastStack
        }

        outerStack.addArrangedSubview(contentContainer)
        moodleSection.isHidden = false
    }

    @objc private func toggleMoodleSection() {
        moodleSectionExpanded.toggle()

        let chevronName = moodleSectionExpanded ? "chevron.up" : "chevron.down"
        let chevronCfg = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        moodleSectionChevron?.image = UIImage(systemName: chevronName, withConfiguration: chevronCfg)

        UIView.animate(withDuration: 0.25) {
            self.moodleContentContainer?.isHidden = !self.moodleSectionExpanded
            self.moodleContentContainer?.superview?.layoutIfNeeded()
        }
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
        guard !AppBackend.isOffline, AdsConfig.enabled else {
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
        let barVisible = noteChatInputBar.map { !$0.isHidden } ?? false
        let barHeight = max(Self.noteInputBarMinHeight, noteChatInputBar?.bounds.height ?? 0)
        inset.bottom = max(height, noteKeyboardOverlap) + (barVisible ? barHeight + 8 + 12 : 0)
        scroll.contentInset = inset
        scroll.verticalScrollIndicatorInsets.bottom = inset.bottom
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

// MARK: - UITextFieldDelegate (ノートチャットの入力欄)
extension CourseDetailViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer is UISwipeGestureRecognizer {
            // 横にスクロールできる部品(友だち一覧・写真の列・添付欄)の上では、画面切り替えスワイプを使わない
            var current: UIView? = touch.view
            while let candidate = current {
                if let scrollView = candidate as? UIScrollView, scrollView !== scroll,
                   !(scrollView.superview is WKWebView),   // ポータル(WKWebView)の上でも切り替えられるようにする
                   scrollView.contentSize.width > scrollView.bounds.width + 1 { return false }
                if candidate is UITextField || candidate is PixelToggleControl { return false }
                current = candidate.superview
            }
            return true
        }
        guard let bar = noteChatInputBar else { return true }
        return !(touch.view?.isDescendant(of: bar) ?? false)
    }
}

extension CourseDetailViewController: UITextFieldDelegate {
    /// 入力を始めると、まだ何も送っていなくても大きなカードを省略ボタンに畳む。
    /// 何も送らずにキーボードを閉じたら、また大きなカードに戻す(どちらもアニメーション)。
    func textFieldDidBeginEditing(_ textField: UITextField) {
        guard textField === noteChatTextField else { return }
        syncNoteChatActions()
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        guard textField === noteChatTextField else { return }
        syncNoteChatActions()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        noteChatSendTapped()
        return true
    }
}

// MARK: - WKNavigationDelegate
extension CourseDetailViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        syllabusWebPageLoaded = true
        // 以前は固定2秒待ってから抽出していたが、対象ページはASP.NET側で完全にレンダリングされた
        // HTMLが返るため、ほとんどの場合didFinish時点で既に準備できている。
        // 準備完了を短い間隔でポーリングし、できるだけ早く抽出する(最大2秒まで待つ安全策は維持)。
        pollSyllabusReadyThenExtract(webView: webView, attempt: 0)
    }

    private func pollSyllabusReadyThenExtract(webView: WKWebView, attempt: Int) {
        let maxAttempts = 10
        let pollInterval = 0.2
        let readinessCheck = """
        document.readyState === 'complete' &&
        (document.querySelectorAll('[id*="gvKeikaku_lblSQ_NO_"]').length > 0 ||
         document.querySelectorAll('table').length > 0)
        """
        webView.evaluateJavaScript(readinessCheck) { [weak self] result, _ in
            guard let self else { return }
            let ready = (result as? Bool) ?? false
            if ready || attempt >= maxAttempts {
                self.extractSyllabusFields()
                // ページの実際の高さに合わせてコンテナを広げる
                webView.evaluateJavaScript("document.documentElement.scrollHeight") { result, _ in
                    DispatchQueue.main.async {
                        if let h = result as? CGFloat, h > 200 {
                            self.webHeightConstraint.constant = h + 40
                            UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() }
                        }
                    }
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
                    self?.pollSyllabusReadyThenExtract(webView: webView, attempt: attempt + 1)
                }
            }
        }
    }

    private func extractSyllabusFields() {
        // キャッシュ済みならポータル表示で再ロードされても再抽出しない
        let existingCK: String = {
            let u = syllabusPageURL?.absoluteString
                ?? (course.syllabusURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return u.isEmpty ? course.id : u
        }()
        if SyllabusDataCache.shared.exists(for: existingCK) { return }

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
                    // load と同じキー（resolved URL or course.id）で保存してキャッシュが効くようにする
                    let saveCK: String = {
                        let u = self.syllabusPageURL?.absoluteString
                            ?? (self.course.syllabusURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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

    // MARK: - Review

    // classes コレクションの Firestore document ID を優先使用。
    // 時間割登録時に Course.firestoreDocID として保持される。
    // syllabusDocID はシラバスタブから渡される同じ値。
    // どちらも nil の場合のみコード+教員名の複合キーにフォールバック。
    private var reviewCourseCode: String {
        if let docID = resolvedReviewDocID ?? syllabusDocID ?? course.firestoreDocID, !docID.isEmpty {
            return docID
        }
        let raw = "\(course.id)_\(course.teacher)"
        return raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "　", with: "_")
    }

    // firestoreDocID が nil のとき classes コレクションをクエリして解決してからボタンを構築する
    private func resolveReviewDocIDThenBuild() {
        if syllabusDocID != nil || course.firestoreDocID != nil {
            buildReviewWriteButton()
            return
        }
        let db = Firestore.firestore()
        db.collection("classes")
            .whereField("code", isEqualTo: course.id)
            .whereField("teacher_name", isEqualTo: course.teacher)
            .limit(to: 1)
            .getDocuments { [weak self] snap, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.resolvedReviewDocID = snap?.documents.first?.documentID
                    self.buildReviewWriteButton()
                }
            }
    }

    private func buildReviewWriteButton() {
        let submitted = WriteReviewViewController.hasSubmitted(courseCode: reviewCourseCode)

        // 既存の「教室番号を編集」「コマ色を変更」と同じスタイル
        var cfg = UIButton.Configuration.plain()
        cfg.title = submitted ? "レビューを編集" : "授業レビューを書く"
        cfg.image = UIImage(systemName: submitted ? "pencil.circle.fill" : "square.and.pencil")
        cfg.imagePlacement = .leading
        cfg.imagePadding = 6
        cfg.contentInsets = .init(top: 4, leading: 10, bottom: 4, trailing: 10)

        let btn = UIButton(configuration: cfg)
        btn.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        btn.backgroundColor = .secondarySystemBackground
        btn.layer.cornerRadius = 12
        btn.layer.masksToBounds = true
        btn.tintColor = UIColor(red: 0/255, green: 120/255, blue: 87/255, alpha: 1)
        btn.isEnabled = true
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.setContentCompressionResistancePriority(.required, for: .horizontal)
        btn.addAction(UIAction { [weak self] _ in self?.openWriteReview() }, for: .touchUpInside)
        reviewWriteButton = btn

        // セグメント直下の共有行(actionHeaderRow)の左端に挿入する。
        // 右側にはbuildNoteSection()が並び替え/資料ボタンを追加する。
        actionHeaderRow.insertArrangedSubview(btn, at: 0)

        // 初回のみレビュー促進アラートを表示
        showReviewPromptIfNeeded()
    }

    private static let reviewPromptShownKey = "reviewPromptShown"

    private func showReviewPromptIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.reviewPromptShownKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.reviewPromptShownKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let ac = UIAlertController(
                title: "📝 授業レビュー機能が追加されました",
                message: "3秒でできるので、後輩のためにぜひレビューをお願いします！",
                preferredStyle: .alert
            )
            ac.addAction(UIAlertAction(title: "あとで", style: .cancel))
            ac.addAction(UIAlertAction(title: "書いてみる", style: .default) { [weak self] _ in
                self?.openWriteReview()
            })
            self.present(ac, animated: true)
        }
    }

    private func openWriteReview() {
        let code = reviewCourseCode
        if WriteReviewViewController.hasSubmitted(courseCode: code) {
            ReviewService.shared.fetchMyReview(courseCode: code) { [weak self] existing in
                DispatchQueue.main.async {
                    self?.presentWriteReview(existing: existing)
                }
            }
        } else {
            presentWriteReview(existing: nil)
        }
    }

    private func presentWriteReview(existing: CourseReview?) {
        let vc = WriteReviewViewController(
            classDocID: reviewCourseCode,
            courseName: course.title,
            prefillTerm: term.displayTitle,
            existing: existing
        )
        vc.onSubmitted = { [weak self] in
            self?.refreshReviewWriteButton()
        }
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
    }

    private func refreshReviewWriteButton() {
        guard let btn = reviewWriteButton else { return }
        var cfg = btn.configuration
        cfg?.image = UIImage(systemName: "pencil.circle.fill")
        cfg?.title = "レビューを編集"
        btn.configuration = cfg
        btn.tintColor = UIColor(red: 0/255, green: 120/255, blue: 87/255, alpha: 1)
        btn.isEnabled = true
    }

    private func loadAndBuildReviewSummary() {
        ReviewService.shared.fetchPublicReviews(courseCode: reviewCourseCode) { [weak self] reviews in
            DispatchQueue.main.async {
                guard let self else { return }
                if !reviews.isEmpty {
                    self.buildReviewSummaryUI(reviews: reviews)
                }
            }
        }
    }

    private func buildReviewSummaryUI(reviews: [CourseReview]) {
        guard !reviews.isEmpty else { return }

        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 12

        let cardStack = UIStackView()
        cardStack.axis = .vertical
        cardStack.spacing = 12
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)
        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])

        let heading = UILabel()
        heading.text = "授業レビュー（\(reviews.count)件）"
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        cardStack.addArrangedSubview(heading)

        let avg: (KeyPath<CourseReview, Int>) -> Double = { kp in
            Double(reviews.map { $0[keyPath: kp] }.reduce(0, +)) / Double(reviews.count)
        }
        addRatingSummaryRow(to: cardStack, label: "先生の優しさ", value: avg(\.teacherKindness))
        addRatingSummaryRow(to: cardStack, label: "単位取得難易度", value: avg(\.creditDifficulty))

        let comments = reviews.filter { !$0.comment.isEmpty }.prefix(3)
        if !comments.isEmpty {
            let sep = UIView()
            sep.backgroundColor = .separator
            sep.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
            cardStack.addArrangedSubview(sep)

            for review in comments {
                let lbl = UILabel()
                lbl.text = "「\(review.comment)」"
                lbl.font = .systemFont(ofSize: 13)
                lbl.textColor = .secondaryLabel
                lbl.numberOfLines = 3
                cardStack.addArrangedSubview(lbl)
            }
        }

        stack.addArrangedSubview(card)
    }

    private func addRatingSummaryRow(to parent: UIStackView, label: String, value: Double) {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center

        let name = UILabel()
        name.text = label
        name.font = .systemFont(ofSize: 13)
        name.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let stars = UILabel()
        stars.text = starString(for: value)
        stars.font = .systemFont(ofSize: 14)

        let score = UILabel()
        score.text = String(format: "%.1f", value)
        score.font = .systemFont(ofSize: 13)
        score.textColor = .secondaryLabel
        score.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        row.addArrangedSubview(name)
        row.addArrangedSubview(stars)
        row.addArrangedSubview(score)
        parent.addArrangedSubview(row)
    }

    private func starString(for value: Double) -> String {
        let full = Int(value)
        let half = (value - Double(full)) >= 0.5
        var s = String(repeating: "★", count: full)
        if half { s += "☆" }
        return s
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


/// 送信済みの写真を横1列に並べるスクロール。内容が幅に収まるときは右寄せにする。
final class NotePhotoRowScrollView: UIScrollView {
    var photos: [CapturedPhoto] = []

    override func layoutSubviews() {
        super.layoutSubviews()
        let extra = max(0, bounds.width - contentSize.width)
        if contentInset.left != extra {
            contentInset.left = extra
            if extra > 0 { contentOffset.x = -extra }
        }
    }
}


// MARK: - スティッキーヘッダー用
extension CourseDetailViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === scroll else { return }
        updateStickyNoteChatHeader()
    }
}

/// ヘッダーの背後に敷く、下へ向かって透明になるフェード。
final class NoteHeaderFadeView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        updateColors()
    }

    private func updateColors() {
        guard let gradient = layer as? CAGradientLayer else { return }
        let base = UIColor.systemBackground.resolvedColor(with: traitCollection)
        gradient.colors = [base.cgColor, base.cgColor, base.withAlphaComponent(0).cgColor]
        gradient.locations = [0, 0.62, 1]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
    }
}


// MARK: - メッセージ長押しメニュー
extension CourseDetailViewController: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let bubble = interaction.view, let index = noteChatMessageIndex(for: bubble),
              let messages = noteChatMessagesBySession[noteChatCurrentSession], messages.indices.contains(index),
              case .text(let text) = messages[index] else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let copy = UIAction(title: "コピー", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = text
            }
            let edit = UIAction(title: "編集", image: UIImage(systemName: "pencil")) { _ in
                self?.beginEditingNoteMessage(at: index)
            }
            return UIMenu(children: [copy, edit])
        }
    }

    private func bubblePreview(for interaction: UIContextMenuInteraction) -> UITargetedPreview? {
        guard let bubble = interaction.view else { return nil }
        let params = UIPreviewParameters()
        params.backgroundColor = .clear
        params.visiblePath = UIBezierPath(roundedRect: bubble.bounds, cornerRadius: bubble.layer.cornerRadius > 0 ? bubble.layer.cornerRadius : 16)
        return UITargetedPreview(view: bubble, parameters: params)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        bubblePreview(for: interaction)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        bubblePreview(for: interaction)
    }
}

// MARK: - ヘッダーのタップを優先するスタック
/// スクロールで上端に貼り付いたヘッダーが、後ろのメッセージより先にタップを受け取れるようにする。
final class NoteChatStackView: UIStackView {
    weak var priorityHitView: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let header = priorityHitView, !header.isHidden, header.alpha > 0.01, header.isUserInteractionEnabled {
            let local = convert(point, to: header)
            if let hit = header.hitTest(local, with: event) { return hit }
        }
        return super.hitTest(point, with: event)
    }
}

// MARK: - 録音メッセージの吹き出し
final class NoteRecordingBubbleView: UIControl {
    let url: URL
    private let icon = UIImageView()

    init(url: URL, duration: TimeInterval, background: UIColor, tint: UIColor) {
        self.url = url
        super.init(frame: .zero)
        backgroundColor = background
        layer.cornerRadius = 16
        translatesAutoresizingMaskIntoConstraints = false

        icon.tintColor = tint
        icon.contentMode = .scaleAspectFit
        icon.isUserInteractionEnabled = false
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = "録音  \(CourseDetailViewController.timeText(duration))"
        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        label.textColor = tint
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
        accessibilityLabel = "録音を再生"
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        let name = NoteAudioPlayer.shared.isPlaying(url) ? "pause.circle.fill" : "play.circle.fill"
        icon.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold))
    }
}


// MARK: - 授業回カード(チャット一覧)
/// すりガラス風のカード。タップ中に少し縮む。
final class NoteSessionCardControl: UIControl {
    // ガラス風の面。UIVisualEffectView(ブラー)は、画面遷移で画像化すると黒っぽく写るため使わず、
    // 半透明の塗りと上からの光沢のグラデーションで質感を出す。
    private let blur = UIView()
    private let tintView = UIView()
    private let highlight = CAGradientLayer()

    init(cornerRadius: CGFloat, tint: UIColor?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        layer.cornerRadius = cornerRadius
        layer.borderWidth = 1
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.07
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 6)

        blur.isUserInteractionEnabled = false
        blur.layer.cornerRadius = cornerRadius
        blur.clipsToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        tintView.isUserInteractionEnabled = false
        tintView.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.08) : UIColor.white.withAlphaComponent(0.92)
        }
        tintView.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(tintView)
        blur.layer.addSublayer(highlight)
        highlight.startPoint = CGPoint(x: 0.5, y: 0)
        highlight.endPoint = CGPoint(x: 0.5, y: 1)

        if let tint {
            let color = UIView()
            color.isUserInteractionEnabled = false
            color.backgroundColor = tint
            color.translatesAutoresizingMaskIntoConstraints = false
            blur.addSubview(color)
            NSLayoutConstraint.activate([
                color.topAnchor.constraint(equalTo: blur.topAnchor), color.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
                color.leadingAnchor.constraint(equalTo: blur.leadingAnchor), color.trailingAnchor.constraint(equalTo: blur.trailingAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor), blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor), blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.topAnchor.constraint(equalTo: blur.topAnchor), tintView.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            tintView.leadingAnchor.constraint(equalTo: blur.leadingAnchor), tintView.trailingAnchor.constraint(equalTo: blur.trailingAnchor)
        ])
        updateBorder()
        updateHighlight()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateHighlight() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        let top = UIColor.white.withAlphaComponent(isDark ? 0.10 : 0.55).cgColor
        highlight.colors = [top, UIColor.white.withAlphaComponent(0).cgColor]
        highlight.locations = [0, 0.7]
    }

    private var dashed = false
    private let dashLayer = CAShapeLayer()

    /// 休講のカード用: 点線の枠・影なし。
    func setDashedStyle() {
        dashed = true
        layer.shadowOpacity = 0
        layer.borderWidth = 0
        dashLayer.fillColor = nil
        dashLayer.lineWidth = 1
        dashLayer.lineDashPattern = [5, 4]
        layer.addSublayer(dashLayer)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        highlight.frame = blur.bounds
        if dashed {
            dashLayer.frame = bounds
            dashLayer.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerRadius: layer.cornerRadius).cgPath
            dashLayer.strokeColor = UIColor.separator.cgColor
        }
    }

    private func updateBorder() {
        guard !dashed else { return }
        // ガラスの縁の光沢(ライトは白、ダークは薄い白)
        let isDark = traitCollection.userInterfaceStyle == .dark
        layer.borderColor = (isDark ? UIColor.white.withAlphaComponent(0.14) : UIColor.white.withAlphaComponent(0.9)).cgColor
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        updateBorder()
        updateHighlight()
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.975, y: 0.975) : .identity
            }
        }
    }
}

/// 回数を載せた丸いバッジ。solid=最新の回(濃い緑 + 淡い光の輪)、それ以外は淡い緑の円。
final class NoteSessionCircleBadge: UIView {
    init(number: Int, size: CGFloat, solid: Bool, deep: UIColor, fontSize: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        layer.cornerRadius = size / 2
        if solid {
            backgroundColor = deep
            // 外側に淡い光の輪
            layer.shadowColor = deep.cgColor
            layer.shadowOpacity = 0.28
            layer.shadowRadius = 6
            layer.shadowOffset = .zero
        } else {
            backgroundColor = deep.withAlphaComponent(0.12)
            layer.borderWidth = 1
            layer.borderColor = deep.withAlphaComponent(0.25).cgColor
        }
        let label = UILabel()
        label.text = "\(number)"
        label.font = .systemFont(ofSize: fontSize, weight: .medium)
        label.textColor = solid ? .white : deep
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    /// アイコン付き(休講のカード用)
    init(symbol: String, size: CGFloat, deep: UIColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        layer.cornerRadius = size / 2
        layer.borderWidth = 1
        layer.borderColor = UIColor.separator.cgColor
        let icon = UIImageView(image: UIImage(systemName: symbol,
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)))
        icon.tintColor = .secondaryLabel
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}


// MARK: - AIハック画面の背景
/// ごく薄い緑と青のにじみ。白い背景の上でも、ガラス風のカードが浮いて見えるようにする。
final class NoteBackdropView: UIView {
    private let green = CAGradientLayer()
    private let blue = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        for layer in [green, blue] {
            layer.type = .radial
            layer.locations = [0, 1]
            self.layer.addSublayer(layer)
        }
        green.startPoint = CGPoint(x: 0.1, y: 0.12)
        green.endPoint = CGPoint(x: 1.0, y: 0.85)
        blue.startPoint = CGPoint(x: 0.95, y: 0.95)
        blue.endPoint = CGPoint(x: 0.0, y: 0.2)
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        green.frame = bounds
        blue.frame = bounds
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        updateColors()
    }

    private func updateColors() {
        let dark = traitCollection.userInterfaceStyle == .dark
        let g = UIColor(red: 0/255, green: 150/255, blue: 100/255, alpha: dark ? 0.16 : 0.12)
        let b = UIColor(red: 70/255, green: 140/255, blue: 220/255, alpha: dark ? 0.12 : 0.09)
        green.colors = [g.cgColor, g.withAlphaComponent(0).cgColor]
        blue.colors = [b.cgColor, b.withAlphaComponent(0).cgColor]
    }
}


extension CourseDetailViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        do {
            let context = try aiContext(day: noteChatCurrentSession)
            let store = try SourceIngestionService.shared.store(uid: context.ownerUID)
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let source = try store.stage(context: context, kind: .pdf, title: url.lastPathComponent, mime: "application/pdf", fileURL: url)
                try store.submit(context: context, snapshots: [AIChatSnapshot(id: UUID().uuidString, context: context, kind: "pdf", text: nil, sourceIDs: [source.id], createdAt: Date())])
            }
            restoreAIInput(); SourceIngestionService.shared.resume(uid: context.ownerUID)
        } catch { showNoteAlert(title: "PDFを保存できませんでした", message: error.localizedDescription) }
    }
}


extension CourseDetailViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        let selectedDay = noteChatCurrentSession
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        Task { @MainActor in
            do {
                var photos: [CapturedPhoto] = []
                for result in results {
                    let bytes: Data = try await withCheckedThrowingContinuation { continuation in
                        result.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                            if let error { continuation.resume(throwing: error); return }
                            do {
                                guard let url else { throw AIInputError.message("写真を読み込めませんでした") }
                                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                                guard let image = PhotoCodec.downsample(data, maxPixel: 4096), let jpeg = image.jpegData(compressionQuality: 0.9) else {
                                    throw AIInputError.message("この写真の形式は読み込めませんでした")
                                }
                                continuation.resume(returning: jpeg)
                            } catch { continuation.resume(throwing: error) }
                        }
                    }
                    guard let thumb = PhotoCodec.downsample(bytes, maxPixel: 256) else { continue }
                    photos.append(CapturedPhoto(jpeg: bytes, thumb: thumb))
                }
                // Preserve the picker opening context even when loading an iCloud image takes time.
                let context = try aiContext(day: selectedDay)
                for photo in photos { _ = try stageAIPhoto(photo, context: context) }
                if selectedDay == noteChatCurrentSession { restoreAIInput() }
            } catch { showNoteAlert(title: "写真を追加できませんでした", message: error.localizedDescription) }
        }
    }
}
