//
//  LectureRecordingViewController.swift
//  Aogaku
//
//  授業AI: 録音・撮影した内容を、その授業の文脈として保存する
//

import UIKit
import NaturalLanguage

final class LectureRecordingViewController: UIViewController {

    private let course: Course
    private let term: TermKey
    private let dayPeriod: String
    private let weekday: Int

    private let recorder = LectureRecorder()
    private let transcriber = LectureTranscriber()

    private enum State: Equatable {
        case idle
        case recording
        case paused
        case processing
    }
    private var state: State = .idle {
        didSet { render() }
    }
    private var recordedAudioURL: URL?
    private var recordedDuration: TimeInterval = 0
    private var pendingNoteId: String?
    private var photoTexts: [String] = []

    // MARK: - UI
    private let courseLabel = UILabel()
    private let statusLabel = UILabel()
    private let timeLabel = UILabel()
    private let primaryButton = UIButton(type: .system)   // 開始 / 停止 / 再開
    private let endButton = UIButton(type: .system)       // 終了
    private let photoButton = UIButton(type: .system)     // 撮影
    private let photoCountLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let disclaimerLabel = UILabel()

    init(course: Course, term: TermKey, dayPeriod: String, weekday: Int) {
        self.course = course
        self.term = term
        self.dayPeriod = dayPeriod
        self.weekday = weekday
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "\(dayPeriod)のAI"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            style: .plain,
            target: self,
            action: #selector(closeTapped)
        )
        buildLayout()
        bindRecorder()
        render()
    }

    private func buildLayout() {
        courseLabel.text = course.title
        courseLabel.font = .systemFont(ofSize: 22, weight: .bold)
        courseLabel.textColor = .label
        courseLabel.textAlignment = .center
        courseLabel.numberOfLines = 2

        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
        timeLabel.textAlignment = .center
        timeLabel.text = "00:00"

        var primaryConfig = UIButton.Configuration.filled()
        primaryConfig.baseBackgroundColor = HackColors.accent
        primaryConfig.baseForegroundColor = .white
        primaryConfig.cornerStyle = .medium
        primaryConfig.buttonSize = .large
        primaryConfig.imagePadding = 8
        primaryButton.configuration = primaryConfig
        primaryButton.addTarget(self, action: #selector(primaryButtonTapped), for: .touchUpInside)

        endButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        endButton.setTitle("録音を終了", for: .normal)
        endButton.setImage(UIImage(systemName: "stop.fill"), for: .normal)
        endButton.configuration?.imagePadding = 6
        endButton.setTitleColor(.systemRed, for: .normal)
        endButton.addTarget(self, action: #selector(endButtonTapped), for: .touchUpInside)

        photoButton.setTitle("資料を撮影", for: .normal)
        photoButton.setImage(UIImage(systemName: "camera.fill"), for: .normal)
        photoButton.configuration?.imagePadding = 6
        photoButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        photoButton.addTarget(self, action: #selector(photoButtonTapped), for: .touchUpInside)

        photoCountLabel.font = .systemFont(ofSize: 13)
        photoCountLabel.textColor = .secondaryLabel
        photoCountLabel.text = ""

        spinner.hidesWhenStopped = true

        progressView.progressTintColor = HackColors.accent
        progressView.trackTintColor = .quaternarySystemFill
        progressView.isHidden = true

        disclaimerLabel.font = .systemFont(ofSize: 12)
        disclaimerLabel.textColor = .tertiaryLabel
        disclaimerLabel.numberOfLines = 0
        disclaimerLabel.textAlignment = .center
        disclaimerLabel.text = "録音はAI文字起こしのため一時的にクラウドへ送信され、処理後に削除されます。録音・撮影の可否を担当教員に確認してご利用ください。"

        let buttonRow = UIStackView(arrangedSubviews: [photoButton, endButton])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 24
        buttonRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [
            courseLabel, statusLabel, timeLabel, primaryButton, buttonRow,
            photoCountLabel, spinner, progressView, disclaimerLabel
        ])
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        primaryButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 32),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            primaryButton.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            primaryButton.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            progressView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])
    }

    private func bindRecorder() {
        recorder.onTick = { [weak self] elapsed in
            guard let self else { return }
            self.timeLabel.text = Self.formatted(elapsed)
            LectureRecordingActivityManager.shared.update(
                elapsedSeconds: Int(elapsed),
                isPaused: false
            )
        }
        recorder.onMaximumDurationReached = { [weak self] in
            self?.finishRecording(reachedLimit: true)
        }
        transcriber.onStageChange = { [weak self] stage in
            self?.renderTranscriptionStage(stage)
        }
    }

    private func render() {
        switch state {
        case .idle:
            statusLabel.text = "授業を聞かせると、このAIが内容を覚えます\n1回90分まで"
            timeLabel.isHidden = false
            primaryButton.isHidden = false
            updatePrimaryButton(title: "録音を開始", image: "mic.fill", color: HackColors.accent)
            endButton.isHidden = true
            photoButton.isHidden = true
            photoCountLabel.isHidden = true
            spinner.stopAnimating()
            progressView.isHidden = true
        case .recording:
            statusLabel.text = "この授業を聞いています"
            timeLabel.isHidden = false
            primaryButton.isHidden = false
            updatePrimaryButton(title: "一時停止", image: "pause.fill", color: .systemGray)
            endButton.isHidden = false
            photoButton.isHidden = false
            photoCountLabel.isHidden = photoTexts.isEmpty
            spinner.stopAnimating()
            progressView.isHidden = true
        case .paused:
            statusLabel.text = "一時停止中"
            timeLabel.isHidden = false
            primaryButton.isHidden = false
            updatePrimaryButton(title: "録音を再開", image: "play.fill", color: HackColors.accent)
            endButton.isHidden = false
            photoButton.isHidden = false
            photoCountLabel.isHidden = photoTexts.isEmpty
            spinner.stopAnimating()
            progressView.isHidden = true
        case .processing:
            statusLabel.text = "録音を準備しています…"
            timeLabel.isHidden = true
            primaryButton.isHidden = true
            endButton.isHidden = true
            photoButton.isHidden = true
            photoCountLabel.isHidden = true
            spinner.startAnimating()
            progressView.isHidden = true
        }
        photoCountLabel.text = photoTexts.isEmpty ? "" : "撮影: \(photoTexts.count)枚"
    }

    private func updatePrimaryButton(title: String, image: String, color: UIColor) {
        primaryButton.configuration?.title = title
        primaryButton.configuration?.image = UIImage(systemName: image)
        primaryButton.configuration?.baseBackgroundColor = color
    }

    private func renderTranscriptionStage(_ stage: LectureTranscriber.Stage) {
        guard state == .processing else { return }
        switch stage {
        case .preparing:
            statusLabel.text = "録音を準備しています…"
            progressView.isHidden = true
        case .uploading(let progress):
            statusLabel.text = "この授業のAIに送っています  \(Int(progress * 100))%"
            progressView.isHidden = false
            progressView.setProgress(Float(progress), animated: true)
        case .transcribing:
            statusLabel.text = "AIが授業を文字起こししています…"
            progressView.isHidden = true
        case .onDeviceFallback:
            statusLabel.text = "通信が不安定なため、端末内で文字起こししています…"
            progressView.isHidden = true
        }
    }

    @objc private func closeTapped() {
        if state == .recording || state == .paused {
            let alert = UIAlertController(
                title: "録音を破棄しますか？",
                message: "ここまでの録音と撮影内容は保存されません。",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "続ける", style: .cancel))
            alert.addAction(UIAlertAction(title: "破棄", style: .destructive) { [weak self] _ in
                self?.discardAndClose()
            })
            present(alert, animated: true)
            return
        }
        discardAndClose()
    }

    private func discardAndClose() {
        recorder.stop()
        LectureRecordingActivityManager.shared.end()
        transcriber.cancel()
        dismiss(animated: true)
    }

    @objc private func primaryButtonTapped() {
        switch state {
        case .idle:
            recorder.start { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let noteId):
                    self.pendingNoteId = noteId
                    self.state = .recording
                    LectureRecordingActivityManager.shared.start(courseTitle: self.course.title)
                    AppAnalytics.log("lecture_recording_started")
                case .failure:
                    self.presentAlert(title: "録音を開始できません", message: "マイクへのアクセスを許可してください")
                }
            }
        case .recording:
            recorder.pause()
            state = .paused
            LectureRecordingActivityManager.shared.update(elapsedSeconds: Int(recorder.currentDuration), isPaused: true)
        case .paused:
            if recorder.resume() {
                state = .recording
                LectureRecordingActivityManager.shared.update(elapsedSeconds: Int(recorder.currentDuration), isPaused: false)
            } else {
                presentAlert(title: "録音を再開できません", message: "マイクの状態を確認して、もう一度お試しください")
            }
        case .processing:
            break
        }
    }

    @objc private func endButtonTapped() {
        finishRecording(reachedLimit: false)
    }

    private func finishRecording(reachedLimit: Bool) {
        guard state == .recording || state == .paused else { return }
        recordedDuration = reachedLimit
            ? LectureTranscriber.maximumDuration
            : recorder.currentDuration
        if reachedLimit, let noteId = pendingNoteId {
            recordedAudioURL = LectureNote.localAudioURL(noteId: noteId)
        } else {
            recordedAudioURL = recorder.stop()
        }
        LectureRecordingActivityManager.shared.end()
        state = .processing
        startTranscription()
    }

    @objc private func photoButtonTapped() {
        let vc = LecturePhotoCaptureViewController()
        vc.onTextRecognized = { [weak self] text in
            self?.photoTexts.append(text)
            self?.photoCountLabel.text = "撮影: \(self?.photoTexts.count ?? 0)枚"
            self?.photoCountLabel.isHidden = false
        }
        present(vc, animated: true)
    }

    private func startTranscription() {
        guard let url = recordedAudioURL else {
            saveNote(transcript: "")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let courseKey = LectureNote.courseKey(course: course, term: term)
            let previousNotes = (try? await LectureNoteStore.shared.fetchNotes(courseKey: courseKey)) ?? []
            let contextPrompt = Self.makeASRPrompt(
                course: course,
                syllabusOverview: SyllabusOverviewProvider.overviewText(for: course),
                photoTexts: photoTexts,
                previousNotes: previousNotes
            )
            await MainActor.run {
                self.beginTranscription(audioURL: url, contextPrompt: contextPrompt)
            }
        }
    }

    private func beginTranscription(audioURL: URL, contextPrompt: String) {
        transcriber.transcribe(
            audioURL: audioURL,
            durationSeconds: recordedDuration,
            contextPrompt: contextPrompt
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let transcription):
                AppAnalytics.log("lecture_transcription_completed", parameters: [
                    "duration_sec": Int(self.recordedDuration),
                    "transcript_length": transcription.rawTranscript.count,
                    "chunk_count": transcription.chunkCount,
                    "accurate_chunk_count": transcription.accurateChunkCount
                ])
                #if DEBUG
                DebugTextPreview.present(
                    on: self,
                    title: "文字起こし結果",
                    text: transcription.cleanedTranscript
                ) {
                    self.saveNote(transcription: transcription)
                }
                #else
                self.saveNote(transcription: transcription)
                #endif
            case .failure(let error):
                AppAnalytics.log("lecture_transcription_failed")
                self.presentTranscriptionFailure(error)
            }
        }
    }

    private static func makeASRPrompt(
        course: Course,
        syllabusOverview: String,
        photoTexts: [String],
        previousNotes: [LectureNote]
    ) -> String {
        let previousRawText = previousNotes
            .prefix(8)
            .map(\.rawTranscriptText)
            .joined(separator: " ")
        let source = String(
            ([syllabusOverview] + photoTexts + [previousRawText])
                .joined(separator: " ")
                .prefix(24_000)
        )
        var scores: [String: Int] = [:]
        let stopWords: Set<String> = [
            "授業", "講義", "内容", "学生", "今回", "前回", "先生", "資料", "大学", "青山学院大学",
            "こと", "もの", "ため", "よう", "これ", "それ", "ところ", "について"
        ]

        func addTerm(_ rawTerm: String, score: Int) {
            let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard term.count >= 2, term.count <= 40, !stopWords.contains(term) else { return }
            scores[term, default: 0] += score
        }

        if let regex = try? NSRegularExpression(
            pattern: #"[A-Za-z][A-Za-z0-9'’.-]*(?:\s+[A-Za-z][A-Za-z0-9'’.-]*){0,4}"#
        ) {
            let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
            regex.enumerateMatches(in: source, range: nsRange) { match, _, _ in
                guard let match, let range = Range(match.range, in: source) else { return }
                addTerm(String(source[range]), score: 4)
            }
        }

        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = source
        let fullRange = source.startIndex..<source.endIndex
        tagger.enumerateTags(
            in: fullRange,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            if tag == .noun { addTerm(String(source[range]), score: 1) }
            return true
        }
        tagger.enumerateTags(
            in: fullRange,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            if tag != nil { addTerm(String(source[range]), score: 5) }
            return true
        }

        let sortedTerms = scores.sorted {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value > $1.value
        }.map(\.key)

        var promptParts = ["青山学院大学", "授業名: \(course.title)"]
        if !course.teacher.isEmpty { promptParts.append("担当教員: \(course.teacher)") }
        var prompt = promptParts.joined(separator: " / ")
        var terms: [String] = []
        for term in sortedTerms {
            let candidateTerms = terms + [term]
            let candidate = "\(prompt) / 用語: \(candidateTerms.joined(separator: ", "))"
            guard candidate.count <= 240 else { break }
            terms = candidateTerms
        }
        if !terms.isEmpty { prompt += " / 用語: \(terms.joined(separator: ", "))" }
        return String(prompt.prefix(240))
    }

    private func presentTranscriptionFailure(_ error: Error) {
        let alert = UIAlertController(
            title: "文字起こしできませんでした",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "再試行", style: .default) { [weak self] _ in
            self?.startTranscription()
        })
        alert.addAction(UIAlertAction(title: "音声だけ保存", style: .cancel) { [weak self] _ in
            self?.saveNote(transcript: "", status: .failed)
        })
        present(alert, animated: true)
    }

    private func saveNote(transcript: String, status: LectureNoteStatus = .completed) {
        saveNote(
            transcript: transcript,
            rawTranscript: transcript,
            cleanedTranscript: transcript,
            metadata: nil,
            status: status
        )
    }

    private func saveNote(transcription: LectureTranscriber.ResultValue) {
        saveNote(
            transcript: transcription.cleanedTranscript,
            rawTranscript: transcription.rawTranscript,
            cleanedTranscript: transcription.cleanedTranscript,
            metadata: LectureTranscriptionMetadata(result: transcription),
            status: .completed
        )
    }

    private func saveNote(
        transcript: String,
        rawTranscript: String,
        cleanedTranscript: String,
        metadata: LectureTranscriptionMetadata?,
        status: LectureNoteStatus
    ) {
        guard let noteId = pendingNoteId else {
            dismiss(animated: true)
            return
        }

        let lectureDate = Date()
        let sessionNumber = LectureSessionNumbering.sessionNumber(
            for: lectureDate, weekday: weekday, term: term,
            campus: LectureSessionNumbering.campus(for: course)
        )

        let note = LectureNote(
            id: noteId,
            courseKey: LectureNote.courseKey(course: course, term: term),
            courseTitle: course.title,
            term: term.displayTitle,
            dayPeriod: dayPeriod,
            lectureDate: lectureDate,
            durationSec: Int(recordedDuration),
            transcriptText: transcript,
            rawTranscriptText: rawTranscript,
            cleanedTranscriptText: cleanedTranscript,
            photoText: photoTexts.joined(separator: "\n\n"),
            transcriptionMetadata: metadata,
            sessionNumber: sessionNumber,
            status: status
        )

        Task {
            do {
                try await LectureNoteStore.shared.save(note)
                await MainActor.run {
                    if status == .completed, !transcript.isEmpty, let audioURL = self.recordedAudioURL {
                        try? FileManager.default.removeItem(at: audioURL)
                        self.recordedAudioURL = nil
                    }
                    AppAnalytics.log("lecture_note_saved")
                    self.dismiss(animated: true)
                }
            } catch {
                await MainActor.run {
                    self.presentAlert(title: "保存に失敗しました", message: error.localizedDescription)
                    self.state = .idle
                }
            }
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private static func formatted(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
