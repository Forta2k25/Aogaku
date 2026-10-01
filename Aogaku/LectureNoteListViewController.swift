//
//  LectureNoteListViewController.swift
//  Aogaku
//
//  授業ノート: この授業に保存した写真・PDF・メモの一覧
//

import UIKit
import PhotosUI
import PDFKit
import UniformTypeIdentifiers

final class LectureNoteListViewController: UIViewController, UIDocumentPickerDelegate {

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
        title = "\(dayPeriod)のノート"
        view.backgroundColor = .systemBackground
        let addItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: self,
            action: #selector(addTapped)
        )
        addItem.accessibilityLabel = "授業ノートを追加"
        let generateItem = UIBarButtonItem(
            image: UIImage(systemName: "sparkles"),
            style: .plain,
            target: self,
            action: #selector(generateTapped)
        )
        generateItem.accessibilityLabel = "リアペを作る"
        navigationItem.rightBarButtonItems = [addItem, generateItem]

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.tableHeaderView = makeHeaderView()
        view.addSubview(tableView)

        emptyLabel.text = "まだ授業ノートがありません。\n右上の＋から写真・PDF・メモを追加できます。"
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
        detailLabel.text = "保存した写真・PDF・メモ"
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

    @objc private func addTapped() {
        let sheet = UIAlertController(title: "授業ノートを追加", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "カメラで撮る", style: .default) { [weak self] _ in
            self?.presentLectureCamera()
        })
        sheet.addAction(UIAlertAction(title: "写真から選ぶ", style: .default) { [weak self] _ in
            self?.presentLecturePhotoLibrary()
        })
        sheet.addAction(UIAlertAction(title: "PDF / ファイルを選ぶ", style: .default) { [weak self] _ in
            self?.presentDocumentPicker()
        })
        sheet.addAction(UIAlertAction(title: "メモを書く", style: .default) { [weak self] _ in
            self?.presentMemoInput()
        })
        sheet.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItems?.first
        }
        present(sheet, animated: true)
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
            let alert = UIAlertController(title: "使える授業ノートがありません", message: "先に写真・PDF・メモを追加してください。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }

        let sheet = UIAlertController(title: "リアペを作る授業を選択", message: "その日の資料とメモをまとめて使います。", preferredStyle: .actionSheet)
        for group in groups {
            let dateStr = LectureNoteListViewController.dayFormatter.string(from: group.date)
            let hasAudio = group.notes.contains { !$0.transcriptText.isEmpty }
            let photoCount = group.notes.reduce(0) { $0 + ($1.photoText.isEmpty ? 0 : $1.photoText.components(separatedBy: "\n\n").count) }
            var detail: [String] = []
            if hasAudio { detail.append("録音あり") }
            if photoCount > 0 { detail.append("資料\(photoCount)件") }
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

    private func presentLectureCamera() {
        let vc = LecturePhotoCaptureViewController()
        vc.onFinish = { [weak self] texts in
            guard let self, !texts.isEmpty else { return }
            self.saveLectureMaterialText(texts.joined(separator: "\n\n"), successMessage: "写真を\(texts.count)枚追加しました")
        }
        present(vc, animated: true)
    }

    private func presentLecturePhotoLibrary() {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 10
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentDocumentPicker() {
        var types: [UTType] = [.pdf]
        if #available(iOS 14.0, *) {
            types.append(.plainText)
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    private func presentMemoInput() {
        let alert = UIAlertController(title: "メモを書く", message: "この授業回のノートとして保存します。", preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "先生が強調していたこと、感想など"
            textField.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            guard let self,
                  let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            self.saveLectureMaterialText("[メモ]\n\(text)", successMessage: "メモを保存しました")
        })
        present(alert, animated: true)
    }

    private func saveLectureMaterialText(_ text: String, successMessage: String) {
        let lectureDate = Date()
        let sessionNumber = LectureSessionNumbering.sessionNumber(
            for: lectureDate,
            weekday: weekday,
            term: term,
            campus: LectureSessionNumbering.campus(for: course)
        )
        let note = LectureNote(
            courseKey: LectureNote.courseKey(course: course, term: term),
            courseTitle: course.title,
            term: term.displayTitle,
            dayPeriod: dayPeriod,
            lectureDate: lectureDate,
            durationSec: 0,
            transcriptText: "",
            photoText: text,
            sessionNumber: sessionNumber,
            status: .completed
        )
        Task {
            do {
                try await LectureNoteStore.shared.save(note)
                await MainActor.run {
                    self.reload()
                    let alert = UIAlertController(title: successMessage, message: nil, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self.present(alert, animated: true)
                }
            } catch {
                await MainActor.run {
                    let alert = UIAlertController(title: "授業ノートを保存できませんでした", message: error.localizedDescription, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self.present(alert, animated: true)
                }
            }
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { url.stopAccessingSecurityScopedResource() }
        }

        let text: String
        if url.pathExtension.lowercased() == "pdf" {
            text = extractPDFText(from: url)
        } else {
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let alert = UIAlertController(title: "文字を読み取れませんでした", message: "テキストを含むPDFまたはテキストファイルを選んでください。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        saveLectureMaterialText("[\(url.lastPathComponent)]\n\(trimmed)", successMessage: "\(url.lastPathComponent)を追加しました")
    }

    private func extractPDFText(from url: URL) -> String {
        guard let document = PDFDocument(url: url) else { return "" }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index),
                  let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !pageText.isEmpty else { continue }
            pages.append(pageText)
        }
        return pages.joined(separator: "\n\n")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日(E) HH:mm"
        f.locale = Locale(identifier: "ja_JP")
        return f
    }()
}

extension LectureNoteListViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true) { [weak self] in
            self?.importLecturePhotos(results)
        }
    }

    private func importLecturePhotos(_ results: [PHPickerResult]) {
        guard !results.isEmpty else { return }
        let group = DispatchGroup()
        let recognizedTexts = NSMutableArray(array: Array(repeating: "", count: results.count))
        for (index, result) in results.enumerated() {
            let provider = result.itemProvider
            guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
            group.enter()
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage else {
                    group.leave()
                    return
                }
                LecturePhotoOCR.recognizeText(in: image) { text in
                    objc_sync_enter(recognizedTexts)
                    recognizedTexts[index] = text
                    objc_sync_exit(recognizedTexts)
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let texts = recognizedTexts.compactMap { $0 as? String }.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard !texts.isEmpty else {
                let alert = UIAlertController(title: "文字を読み取れませんでした", message: "文字がはっきり写っている画像を選んでください。", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(alert, animated: true)
                return
            }
            self.saveLectureMaterialText(texts.joined(separator: "\n\n"), successMessage: "写真を\(results.count)枚追加しました")
        }
    }
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
