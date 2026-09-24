//
//  LectureNoteListViewController.swift
//  Aogaku
//
//  授業AI: この授業が覚えている講義内容の一覧
//

import UIKit

final class LectureNoteListViewController: UIViewController {

    private let course: Course
    private let term: TermKey
    private let dayPeriod: String
    private let weekday: Int

    private var notes: [LectureNote] = []
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyLabel = UILabel()

    init(course: Course, term: TermKey, dayPeriod: String, weekday: Int) {
        self.course = course
        self.term = term
        self.dayPeriod = dayPeriod
        self.weekday = weekday
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "\(dayPeriod)のAI"
        view.backgroundColor = .systemBackground
        let recordItem = UIBarButtonItem(
            image: UIImage(systemName: "waveform"),
            style: .plain,
            target: self,
            action: #selector(recordTapped)
        )
        recordItem.accessibilityLabel = "授業を聞かせる"
        let generateItem = UIBarButtonItem(
            image: UIImage(systemName: "sparkles"),
            style: .plain,
            target: self,
            action: #selector(generateTapped)
        )
        generateItem.accessibilityLabel = "リアペを作る"
        navigationItem.rightBarButtonItems = [recordItem, generateItem]

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.tableHeaderView = makeHeaderView()
        view.addSubview(tableView)

        emptyLabel.text = "このAIはまだ授業を知りません。\n右上の波形ボタンから、最初の授業を聞かせてください。"
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
    }

    private func makeHeaderView() -> UIView {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 104))
        let titleLabel = UILabel()
        titleLabel.text = course.title
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.numberOfLines = 2

        let detailLabel = UILabel()
        detailLabel.text = "このAIが覚えている授業"
        detailLabel.font = .systemFont(ofSize: 13, weight: .medium)
        detailLabel.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        stack.axis = .vertical
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        return header
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        Task {
            do {
                let key = LectureNote.courseKey(course: course, term: term)
                let fetched = try await LectureNoteStore.shared.fetchNotes(courseKey: key)
                await MainActor.run {
                    self.notes = fetched
                    self.tableView.reloadData()
                    self.emptyLabel.isHidden = !fetched.isEmpty
                }
            } catch {
                await MainActor.run {
                    self.emptyLabel.text = "読み込みに失敗しました: \(error.localizedDescription)"
                    self.emptyLabel.isHidden = false
                }
            }
        }
    }

    @objc private func recordTapped() {
        let vc = LectureRecordingViewController(course: course, term: term, dayPeriod: dayPeriod, weekday: weekday)
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
    }

    // MARK: - 日付ごとの生成
    // 同じ日に「録音」と「撮影」を別々に行うと別々のLectureNoteとして保存されるため、
    // 生成は個々の記録単位ではなく日付単位でまとめて行う。

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日(E)"
        f.locale = Locale(identifier: "ja_JP")
        return f
    }()

    private func notesGroupedByDate() -> [(date: Date, notes: [LectureNote])] {
        let cal = Calendar.current
        var groups: [Date: [LectureNote]] = [:]
        for note in notes where !note.transcriptText.isEmpty || !note.photoText.isEmpty {
            let day = cal.startOfDay(for: note.lectureDate)
            groups[day, default: []].append(note)
        }
        return groups.keys.sorted(by: >).map { (date: $0, notes: groups[$0] ?? []) }
    }

    @objc private func generateTapped() {
        let groups = notesGroupedByDate()
        guard !groups.isEmpty else {
            let alert = UIAlertController(title: "使える授業内容がありません", message: "先に授業を聞かせるか、資料を追加してください。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }

        let sheet = UIAlertController(title: "リアペを作る授業を選択", message: "その日の音声と資料をまとめて使います。", preferredStyle: .actionSheet)
        for group in groups {
            let dateStr = LectureNoteListViewController.dayFormatter.string(from: group.date)
            let hasAudio = group.notes.contains { !$0.transcriptText.isEmpty }
            let photoCount = group.notes.reduce(0) { $0 + ($1.photoText.isEmpty ? 0 : $1.photoText.components(separatedBy: "\n\n").count) }
            var detail: [String] = []
            if hasAudio { detail.append("録音あり") }
            if photoCount > 0 { detail.append("撮影\(photoCount)枚") }
            let title = detail.isEmpty ? dateStr : "\(dateStr)(\(detail.joined(separator: "・")))"
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.presentGeneration(for: group.notes)
            })
        }
        sheet.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItems?.last
        }
        present(sheet, animated: true)
    }

    private func presentGeneration(for notes: [LectureNote]) {
        let transcript = notes.map(\.transcriptText).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let photoText = notes.map(\.photoText).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let syllabusOverview = SyllabusOverviewProvider.overviewText(for: course)
        let vc = ReactionPaperViewController(transcript: transcript, photoText: photoText, syllabusOverview: syllabusOverview)
        navigationController?.pushViewController(vc, animated: true)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日(E) HH:mm"
        f.locale = Locale(identifier: "ja_JP")
        return f
    }()
}

extension LectureNoteListViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        notes.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let note = notes[indexPath.row]
        var config = cell.defaultContentConfiguration()
        // 学事暦と照合した回次が分かればそれを使い、判定できない古いデータは記録順の通し番号にフォールバックする
        let sessionNumber = note.sessionNumber ?? (notes.count - indexPath.row)
        let dateStr = LectureNoteListViewController.dateFormatter.string(from: note.lectureDate)
        config.text = "第\(sessionNumber)回 ・ \(dateStr)"
        let minutes = note.durationSec / 60
        let photoCount = note.photoText.isEmpty ? 0 : note.photoText.components(separatedBy: "\n\n").count
        var details: [String] = []
        if minutes > 0 { details.append("\(minutes)分") }
        if photoCount > 0 { details.append("資料 \(photoCount)枚") }
        if note.status == .failed { details.append("文字起こし未完了") }
        config.secondaryText = details.isEmpty ? "内容を確認" : details.joined(separator: " ・ ")
        if note.status == .failed {
            config.secondaryTextProperties.color = .systemOrange
        }
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let note = notes[indexPath.row]
        let vc = LectureNoteDetailViewController(note: note, course: course)
        navigationController?.pushViewController(vc, animated: true)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let note = notes[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "削除") { [weak self] _, _, done in
            Task {
                try? await LectureNoteStore.shared.delete(noteId: note.id)
                await MainActor.run { self?.reload() }
                done(true)
            }
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }
}

final class LectureNoteDetailViewController: UIViewController {
    private let note: LectureNote
    private let course: Course
    private let textView = UITextView()

    init(note: LectureNote, course: Course) {
        self.note = note
        self.course = course
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = note.courseTitle
        view.backgroundColor = .systemBackground

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.font = .systemFont(ofSize: 16)
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        var sections: [String] = []
        if !note.transcriptText.isEmpty { sections.append(note.transcriptText) }
        if !note.photoText.isEmpty { sections.append("[撮影した内容]\n\(note.photoText)") }
        textView.text = sections.isEmpty ? "(記録がありません)" : sections.joined(separator: "\n\n---\n\n")
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}
