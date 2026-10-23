import UIKit
import PhotosUI

/// 「AI」タブ。開いた瞬間に、聞きたいことを入力できる。質問は、時間割をもとに、どの授業の、どの回に振るかを決めて、その回のチャットに送られる。
/// - 授業時間の付近(始まる15分前〜終わって60分後)なら、その授業に自動で振る(入力欄の上の札に出る。タップで変えられる)。
/// - それ以外は、送ると、内容(と写真)から予想して、候補を出すので、ユーザーが選ぶ。
@MainActor
final class AIHomeViewController: UIViewController, UITextViewDelegate, UITableViewDataSource, UITableViewDelegate, PHPickerViewControllerDelegate {
    struct RecentChat {
        let entry: QuickAskCourse
        let dayID: Int
        let title: String
        let subtitle: String
    }

    // MARK: 差し替えられる部品(テスト用)
    /// 授業の一覧。指定が無ければ、タブの中の時間割の画面から読む。
    var entriesProvider: (() -> (entries: [QuickAskCourse], term: TermKey))?
    var now: () -> Date = { Date() }
    /// 選ばれた授業の、その回のチャットを開く。(授業, 回, 質問, 写真)。既定は、時間割の画面を通して開く。
    var chatOpener: ((QuickAskCourse, Int, String, [CapturedPhoto]) -> Void)?
    var predictor: (String, CapturedPhoto?, [QuickAskCourse], Date) async -> QuickAskPredictor.Prediction = { question, photo, entries, now in
        await QuickAskPredictor.rank(question: question, photo: photo, entries: entries, now: now, recentQuestions: { AIHomeViewController.recentQuestions(for: $0) })
    }

    // MARK: 状態
    private(set) var entries: [QuickAskCourse] = []
    private var term = TermStore.loadSelected()
    private(set) var selected: QuickAskCourse?
    private var selectedIsManual = false
    private var manualSelectedAt = Date.distantPast
    private(set) var timeMatch: QuickAskRouting.TimeMatch?
    private(set) var photos: [CapturedPhoto] = []
    private(set) var recents: [RecentChat] = []
    private var busy = false
    private var clock: Timer?

    // MARK: 画面の部品
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    let chipButton = UIButton(type: .system)
    private let composer = UIView()
    let textView = ChatInputTextView()
    private let photoButton = UIButton(type: .system)
    let sendButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let photoScroll = UIScrollView()
    private let photoStack = UIStackView()
    private var photoHeight: NSLayoutConstraint!

    // MARK: 準備
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "AI"
        buildLayout()
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshRouting), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshRecents), name: .aiSourcesChanged, object: nil)
        refreshRouting(); refreshRecents(); updateSendState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        refreshRouting(); refreshRecents()
        SourceIngestionService.shared.warmUp()
        clock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshRouting() } }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        clock?.invalidate(); clock = nil
    }

    private func buildLayout() {
        titleLabel.text = "AI"
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textColor = .label
        subtitleLabel.text = "聞きたいことを、そのまま。授業は、時間割から選びます。"
        subtitleLabel.font = .systemFont(ofSize: 14)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0
        let header = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        header.axis = .vertical; header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false

        tableView.dataSource = self; tableView.delegate = self
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "recent")
        tableView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.text = "授業のことを、何でも聞いてください。\n写真を送ると、板書や配布プリントも読みます。"
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        var chipConfig = UIButton.Configuration.tinted()
        chipConfig.cornerStyle = .capsule
        chipConfig.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        chipConfig.imagePlacement = .trailing; chipConfig.imagePadding = 6
        chipConfig.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 12)
        chipButton.configuration = chipConfig
        chipButton.accessibilityIdentifier = "ai-home-course-chip"
        chipButton.addTarget(self, action: #selector(chipTapped), for: .touchUpInside)
        chipButton.translatesAutoresizingMaskIntoConstraints = false
        chipButton.setContentHuggingPriority(.required, for: .horizontal)

        composer.backgroundColor = .systemBackground
        composer.layer.cornerRadius = 24
        composer.layer.borderWidth = 1
        composer.layer.borderColor = UIColor.separator.cgColor
        composer.translatesAutoresizingMaskIntoConstraints = false

        photoScroll.showsHorizontalScrollIndicator = false
        photoScroll.translatesAutoresizingMaskIntoConstraints = false
        photoStack.axis = .horizontal; photoStack.spacing = 8
        photoStack.translatesAutoresizingMaskIntoConstraints = false
        photoScroll.addSubview(photoStack)

        textView.font = .systemFont(ofSize: 16)
        textView.placeholder = "授業のことを、聞いてみる"
        textView.delegate = self
        textView.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        textView.accessibilityIdentifier = "ai-home-input"
        textView.translatesAutoresizingMaskIntoConstraints = false

        photoButton.setImage(UIImage(systemName: "photo.badge.plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)), for: .normal)
        photoButton.tintColor = .secondaryLabel
        photoButton.accessibilityLabel = "写真を追加"
        photoButton.addTarget(self, action: #selector(pickPhotos), for: .touchUpInside)
        photoButton.translatesAutoresizingMaskIntoConstraints = false

        sendButton.setImage(UIImage(systemName: "arrow.up"), for: .normal)
        sendButton.tintColor = .white
        sendButton.layer.cornerRadius = 18
        sendButton.accessibilityLabel = "送信"
        sendButton.accessibilityIdentifier = "ai-home-send"
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        sendButton.addSubview(spinner)

        [header, tableView, emptyLabel, chipButton, composer].forEach { view.addSubview($0) }
        [photoScroll, textView, photoButton, sendButton].forEach { composer.addSubview($0) }
        photoHeight = photoScroll.heightAnchor.constraint(equalToConstant: 0)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),

            tableView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            tableView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: chipButton.topAnchor, constant: -10),
            emptyLabel.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 32),

            chipButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            chipButton.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -20),
            chipButton.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),

            composer.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            composer.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),

            photoScroll.topAnchor.constraint(equalTo: composer.topAnchor, constant: 10),
            photoScroll.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 14),
            photoScroll.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -14),
            photoHeight,
            photoStack.topAnchor.constraint(equalTo: photoScroll.contentLayoutGuide.topAnchor),
            photoStack.bottomAnchor.constraint(equalTo: photoScroll.contentLayoutGuide.bottomAnchor),
            photoStack.leadingAnchor.constraint(equalTo: photoScroll.contentLayoutGuide.leadingAnchor),
            photoStack.trailingAnchor.constraint(equalTo: photoScroll.contentLayoutGuide.trailingAnchor),
            photoStack.heightAnchor.constraint(equalTo: photoScroll.frameLayoutGuide.heightAnchor),

            photoButton.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 8),
            photoButton.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -3),
            photoButton.widthAnchor.constraint(equalToConstant: 40), photoButton.heightAnchor.constraint(equalToConstant: 40),
            sendButton.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -6),
            sendButton.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -5),
            sendButton.widthAnchor.constraint(equalToConstant: 36), sendButton.heightAnchor.constraint(equalToConstant: 36),
            spinner.centerXAnchor.constraint(equalTo: sendButton.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),

            textView.topAnchor.constraint(equalTo: photoScroll.bottomAnchor, constant: 6),
            textView.leadingAnchor.constraint(equalTo: photoButton.trailingAnchor, constant: 4),
            textView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -10),
            textView.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -6),
            composer.heightAnchor.constraint(greaterThanOrEqualToConstant: 52)
        ])
    }

    // MARK: 授業の札
    /// 時間割から、いまの授業を決める。手動で選んだ授業は、10分間(または、送るまで)そのまま。
    @objc func refreshRouting() {
        let loaded: (entries: [QuickAskCourse], term: TermKey) = entriesProvider?() ?? Self.timetable(in: tabBarController)?.quickAskEntries() ?? ([], TermStore.loadSelected())
        entries = loaded.entries; term = loaded.term
        timeMatch = QuickAskRouting.timeMatch(entries, now: now()) { entry, day in
            ((UserDefaults.standard.array(forKey: "note.cancelled.\(entry.course.id)") as? [Int]) ?? []).contains(day)
        }
        if selectedIsManual, now().timeIntervalSince(manualSelectedAt) > 600 { selectedIsManual = false }
        if !selectedIsManual { selected = timeMatch?.entry }
        updateChip()
    }

    func updateChip() {
        var configuration = chipButton.configuration ?? .tinted()
        let title: String
        if let selected {
            if selectedIsManual { title = "\(selected.course.title)" }
            else {
                switch timeMatch?.phase {
                case .inSession?: title = "\(selected.course.title) · 授業中"
                case .startingSoon?: title = "\(selected.course.title) · まもなく開始"
                case .justEnded?: title = "\(selected.course.title) · 授業の直後"
                case nil: title = selected.course.title
                }
            }
            configuration.baseBackgroundColor = UIColor(red: 0.04, green: 0.42, blue: 0.28, alpha: 1)
            configuration.baseForegroundColor = UIColor(red: 0.04, green: 0.31, blue: 0.21, alpha: 1)
        } else {
            title = "授業を選ぶ(送ると、内容から予想します)"
            configuration.baseBackgroundColor = .systemGray
            configuration.baseForegroundColor = .label
        }
        configuration.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 14, weight: .semibold)]))
        chipButton.configuration = configuration
        chipButton.accessibilityLabel = "聞く授業: " + title
    }

    @objc func chipTapped() {
        view.endEditing(true)
        presentCoursePicker(title: "どの授業に聞きますか?", message: nil, ordered: QuickAskRouting.orderedForChoice(entries, predicted: [], now: now()),
                            includeAutomatic: selectedIsManual) { [weak self] entry in
            guard let self else { return }
            if let entry { self.selected = entry; self.selectedIsManual = true; self.manualSelectedAt = self.now() }
            else { self.selectedIsManual = false }
            self.refreshRouting()
        }
    }

    /// 授業を選ぶ一覧。授業が、同じものは1つにまとめて、並べる。
    private func presentCoursePicker(title: String, message: String?, ordered: [QuickAskCourse], includeAutomatic: Bool, completion: @escaping (QuickAskCourse?) -> Void) {
        let sheet = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)
        if includeAutomatic { sheet.addAction(UIAlertAction(title: "自動(時間割から選ぶ)", style: .default) { _ in completion(nil) }) }
        var seen = Set<String>()
        for entry in ordered where seen.insert(entry.course.id).inserted {
            sheet.addAction(UIAlertAction(title: "\(entry.course.title)(\(entry.location.dayName)\(entry.location.period)限)", style: .default) { _ in completion(entry) })
        }
        sheet.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        sheet.popoverPresentationController?.sourceView = chipButton
        sheet.popoverPresentationController?.sourceRect = chipButton.bounds
        present(sheet, animated: true)
    }

    // MARK: 送信
    @objc func sendTapped() {
        let text = (textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !text.isEmpty || !photos.isEmpty else { return }
        view.endEditing(true)
        if let selected { openChat(selected, text: text, photos: photos); return }
        guard !entries.isEmpty else {
            let alert = UIAlertController(title: "授業が登録されていません", message: "時間割に授業を登録すると、その授業のことを聞けます。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true); return
        }
        // 授業時間の付近ではない: 内容(と写真)から予想して、候補を出す。
        setBusy(true)
        let first = photos.first
        Task { [weak self] in
            guard let self else { return }
            let prediction = await self.predictor(text, first, self.entries, self.now())
            self.setBusy(false)
            self.presentChooser(prediction, text: text)
        }
    }

    private func presentChooser(_ prediction: QuickAskPredictor.Prediction, text: String) {
        let photos = self.photos
        let top = prediction.candidates
        let message = top.first.map { "「\($0.entry.course.title)」が近そうです" + ($0.reason.isEmpty ? "" : "(\($0.reason))") }
        let sheet = UIAlertController(title: "どの授業の質問ですか?", message: message ?? "授業を選んでください", preferredStyle: .actionSheet)
        for (index, candidate) in top.enumerated() {
            let label = (index == 0 ? "おすすめ: " : "") + candidate.entry.course.title
            sheet.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in self?.openChat(candidate.entry, text: text, photos: photos) })
        }
        let others = prediction.ordered.filter { entry in !top.contains { $0.entry.course.id == entry.course.id } }
        if !others.isEmpty {
            sheet.addAction(UIAlertAction(title: "ほかの授業から選ぶ…", style: .default) { [weak self] _ in
                self?.presentCoursePicker(title: "どの授業に聞きますか?", message: nil, ordered: others, includeAutomatic: false) { entry in
                    if let entry { self?.openChat(entry, text: text, photos: photos) }
                }
            })
        }
        sheet.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        sheet.popoverPresentationController?.sourceView = sendButton
        sheet.popoverPresentationController?.sourceRect = sendButton.bounds
        present(sheet, animated: true)
    }

    /// 選ばれた授業の、その回のチャットを開いて、質問を送る。入力欄は、空に戻す。
    func openChat(_ entry: QuickAskCourse, text: String, photos: [CapturedPhoto]) {
        let dayID = QuickAskRouting.sessionDayID(for: entry, term: term, now: now())
        textView.text = ""; self.photos = []; selectedIsManual = false
        reloadPhotoStrip(); updateSendState(); refreshRouting()
        if let chatOpener { chatOpener(entry, dayID, text, photos); return }
        defaultOpen(entry, dayID: dayID, text: text, photos: photos)
    }

    private func defaultOpen(_ entry: QuickAskCourse, dayID: Int, text: String, photos: [CapturedPhoto]) {
        if let timetableVC = Self.timetable(in: tabBarController) {
            timetableVC.presentCourseChat(entry, dayID: dayID, text: text, photos: photos, from: self)
        } else {
            let vc = CourseDetailViewController(course: entry.course, location: entry.location, term: term, showsReview: true, showsLectureNotes: true)
            vc.modalPresentationStyle = .pageSheet
            present(vc, animated: true) { vc.startAIChat(dayID: dayID, text: text, photos: photos) }
        }
    }

    private func setBusy(_ value: Bool) {
        busy = value
        if value { spinner.startAnimating() } else { spinner.stopAnimating() }
        sendButton.setImage(value ? nil : UIImage(systemName: "arrow.up"), for: .normal)
        updateSendState()
    }

    func updateSendState() {
        let hasContent = !(textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty
        sendButton.isEnabled = hasContent && !busy
        sendButton.backgroundColor = sendButton.isEnabled || busy ? UIColor(red: 0.04, green: 0.42, blue: 0.28, alpha: 1) : .systemGray3
    }
    @objc private func textChanged() { updateSendState() }
    @objc private func dismissKeyboard() { view.endEditing(true) }

    // MARK: 写真
    @objc private func pickPhotos() {
        view.endEditing(true)
        guard photos.count < 3 else { return }
        var configuration = PHPickerConfiguration(); configuration.filter = .images; configuration.selectionLimit = 3 - photos.count
        let picker = PHPickerViewController(configuration: configuration); picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        for result in results {
            result.itemProvider.loadFileRepresentation(forTypeIdentifier: "public.image") { url, _ in
                guard let url, let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      let image = PhotoCodec.downsample(data, maxPixel: 2048), let jpeg = image.jpegData(compressionQuality: 0.8),
                      let thumb = PhotoCodec.downsample(jpeg, maxPixel: 256) else { return }
                let photo = CapturedPhoto(jpeg: jpeg, thumb: thumb)
                Task { @MainActor [weak self] in
                    guard let self, self.photos.count < 3 else { return }
                    self.photos.append(photo); self.reloadPhotoStrip(); self.updateSendState()
                }
            }
        }
    }

    func reloadPhotoStrip() {
        photoStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, photo) in photos.enumerated() {
            let imageView = UIImageView(image: photo.thumb)
            imageView.contentMode = .scaleAspectFill; imageView.clipsToBounds = true; imageView.layer.cornerRadius = 10
            imageView.translatesAutoresizingMaskIntoConstraints = false
            let remove = UIButton(type: .system)
            remove.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
            remove.tintColor = .white; remove.backgroundColor = UIColor.black.withAlphaComponent(0.5); remove.layer.cornerRadius = 10
            remove.accessibilityLabel = "写真を外す"; remove.tag = index
            remove.addTarget(self, action: #selector(removePhoto(_:)), for: .touchUpInside)
            remove.translatesAutoresizingMaskIntoConstraints = false
            let cell = UIView()
            cell.addSubview(imageView); cell.addSubview(remove)
            NSLayoutConstraint.activate([
                cell.widthAnchor.constraint(equalToConstant: 56), cell.heightAnchor.constraint(equalToConstant: 56),
                imageView.topAnchor.constraint(equalTo: cell.topAnchor), imageView.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor), imageView.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                remove.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2), remove.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                remove.widthAnchor.constraint(equalToConstant: 20), remove.heightAnchor.constraint(equalToConstant: 20)
            ])
            photoStack.addArrangedSubview(cell)
        }
        photoHeight.constant = photos.isEmpty ? 0 : 56
        view.layoutIfNeeded()
    }
    @objc private func removePhoto(_ sender: UIButton) {
        guard photos.indices.contains(sender.tag) else { return }
        photos.remove(at: sender.tag); reloadPhotoStrip(); updateSendState()
    }

    // MARK: 最近のチャット
    /// 授業・回ごとに、いちばん新しいやり取りを1行にして、新しい順に並べる。
    static func recentChats(store: LocalSourceStore, entries: [QuickAskCourse], term: TermKey, limit: Int = 20) -> [RecentChat] {
        let semester = term.semester == .spring ? "spring" : "fall"
        var latest: [String: AIChatSnapshot] = [:]
        for message in store.ledger.messages where !message.hidden && message.context.semester == semester && (message.context.year ?? term.year) == term.year {
            guard let uuid = message.context.localCourseUUID else { continue }
            let key = "\(uuid)|\(message.context.dayID)"
            if let existing = latest[key], existing.createdAt >= message.createdAt { continue }
            latest[key] = message
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ja_JP"); formatter.dateFormat = "M/d (E)"
        return latest.values.sorted { $0.createdAt > $1.createdAt }.compactMap { message -> RecentChat? in
            guard let entry = entries.first(where: { $0.course.localCourseUUID?.lowercased() == message.context.localCourseUUID?.lowercased() }) else { return nil }
            let date = Date(timeIntervalSince1970: TimeInterval(message.context.dayID) * 86400 - TimeInterval(QuickAskRouting.jst.timeZone.secondsFromGMT()))
            let last: String
            switch message.kind {
            case "question": last = (message.text ?? "").replacingOccurrences(of: "\n", with: " ")
            case "image": last = "写真を送りました"
            case "audio": last = "録音を送りました"
            case "pdf": last = "PDFを送りました"
            default: last = "メモを保存しました"
            }
            return RecentChat(entry: entry, dayID: message.context.dayID, title: "\(entry.course.title) · \(formatter.string(from: date))", subtitle: last)
        }.prefix(limit).map { $0 }
    }

    @objc func refreshRecents() {
        guard let uid = AppBackend.currentUID, let store = try? SourceIngestionService.shared.store(uid: uid) else { recents = []; reloadRecents(); return }
        recents = Self.recentChats(store: store, entries: entries, term: term)
        reloadRecents()
    }
    private func reloadRecents() {
        tableView.reloadData()
        emptyLabel.isHidden = !recents.isEmpty
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { recents.count }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { recents.isEmpty ? nil : "最近のチャット" }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "recent", for: indexPath)
        let chat = recents[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = chat.title; content.secondaryText = chat.subtitle
        content.textProperties.font = .systemFont(ofSize: 16, weight: .semibold)
        content.secondaryTextProperties.font = .systemFont(ofSize: 14)
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "ai-home-recent"
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let chat = recents[indexPath.row]
        if let chatOpener { chatOpener(chat.entry, chat.dayID, "", []); return }
        defaultOpen(chat.entry, dayID: chat.dayID, text: "", photos: [])
    }

    // MARK: 時間割・最近の質問を読む
    static func timetable(in tab: UITabBarController?) -> timetable? {
        tab?.viewControllers?.lazy.compactMap { ($0 as? timetable) ?? (($0 as? UINavigationController)?.viewControllers.first as? timetable) }.first
    }
    static func recentQuestions(for course: Course) -> [String] {
        guard let uid = AppBackend.currentUID, let store = try? SourceIngestionService.shared.store(uid: uid),
              let uuid = course.localCourseUUID?.lowercased() else { return [] }
        return store.ledger.messages.filter { !$0.hidden && $0.kind == "question" && $0.context.localCourseUUID?.lowercased() == uuid }
            .sorted { $0.createdAt < $1.createdAt }.compactMap(\.text)
    }
}
