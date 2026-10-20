import UIKit
import AVFoundation
import ActivityKit

// MARK: - 週ごとの録音時間(上限180分)

enum NoteRecordingUsage {
    static let limitSeconds: TimeInterval = 180 * 60

    private static let weekKey = "note.recording.weekStart"
    private static let usedKey = "note.recording.usedSeconds"

    private static func currentWeekStart() -> TimeInterval {
        var calendar = Calendar(identifier: .iso8601)   // 月曜始まり
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return calendar.dateInterval(of: .weekOfYear, for: Date())?.start.timeIntervalSince1970 ?? 0
    }

    /// 今週すでに確定している録音時間。週が変わっていたらリセットする。
    static var committedSeconds: TimeInterval {
        get {
            let defaults = UserDefaults.standard
            if defaults.double(forKey: weekKey) != currentWeekStart() {
                defaults.set(currentWeekStart(), forKey: weekKey)
                defaults.set(0.0, forKey: usedKey)
            }
            return defaults.double(forKey: usedKey)
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(currentWeekStart(), forKey: weekKey)
            defaults.set(min(max(0, newValue), limitSeconds), forKey: usedKey)
        }
    }
}

// MARK: - 録音

struct NoteRecordingResult {
    let url: URL
    let duration: TimeInterval
    /// ライブ録音(1分ごとの文字起こし)の録音ID。無いときは、従来どおり、録音ファイルを送って文字にする。
    var recordingID: String? = nil
}

/// 授業の録音。週の上限(180分)に達したら自動で止まる。
@MainActor
final class NoteRecorder: NSObject {
    static let shared = NoteRecorder()

    enum StartError: Error {
        case limitReached
        case permissionDenied
        case failed
    }

    private var capture: LiveCapture?
    private var fullFileURL: URL?
    private var liveRecordingID: String?
    private var timer: Timer?
    private var committedAtStart: TimeInterval = 0
    private var tickCount = 0
    private var startGeneration = 0

    /// ロック画面に出す授業名と回(録音を始める前に設定する)
    var inputContext: AIInputContext?
    var activityCourseTitle = ""
    var activitySessionLabel = ""

    /// 録音している間の音量(0...1)。波形用。
    var onLevel: ((Float) -> Void)?
    /// 約0.5秒ごと。残り時間の表示更新用。
    var onTick: (() -> Void)?
    /// 上限や中断で自動的に止まったとき。
    var onAutoStopped: ((NoteRecordingResult?) -> Void)?

    var isRecording: Bool { capture?.isRunning ?? false }
    /// 録音中なら、その録音の経過時間
    var elapsed: TimeInterval { isRecording ? (capture?.elapsedSeconds ?? 0) : 0 }
    /// いま録音中の、ライブ録音のID。
    var currentRecordingID: String? { isRecording ? liveRecordingID : nil }
    /// 確定済み + 録音中の分
    var usedSeconds: TimeInterval { min(NoteRecordingUsage.limitSeconds, committedAtStartOrStored + elapsed) }
    var remainingSeconds: TimeInterval { max(0, NoteRecordingUsage.limitSeconds - usedSeconds) }

    private var committedAtStartOrStored: TimeInterval {
        isRecording ? committedAtStart : NoteRecordingUsage.committedSeconds
    }

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(audioInterrupted(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    func start(completion: @escaping (Result<Void, StartError>) -> Void) {
        let generation = startGeneration
        guard NoteRecordingUsage.committedSeconds < NoteRecordingUsage.limitSeconds else {
            completion(.failure(.limitReached))
            return
        }
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.startGeneration == generation else { completion(.failure(.failed)); return }
                guard granted else {
                    completion(.failure(.permissionDenied))
                    return
                }
                completion(self.beginRecording() ? .success(()) : .failure(.failed))
            }
        }
    }

    private func beginRecording() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

            // 録音は、授業の資料の置き場(アプリの中)に、1つの全体ファイルと、1分ごとの区間ファイルとして書く。
            let id = UUID().uuidString.lowercased()
            let directory: URL
            if let context = inputContext { directory = try LiveRecordingPaths.directory(uid: context.ownerUID, recordingID: id) }
            else {
                directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("NoteRecordings", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let url = directory.appendingPathComponent(inputContext == nil ? "\(UUID().uuidString).m4a" : "full.m4a")
            let writer = try AudioSegmentWriter(directory: directory, fullURL: url, segmentSeconds: 60) { segment in
                DispatchQueue.main.async { LiveRecordingService.shared.addSegment(recordingID: id, file: segment) }
            }
            let capture = LiveCapture(writer: writer)
            capture.onFailure = { [weak self] in
                // 取り込みを続けられなくなった(ディスクの空き・音声の取り合い)。そこまでの録音を保存して止める。
                guard let self, self.isRecording else { return }
                let result = self.stop()
                self.onAutoStopped?(result)
            }
            if let context = inputContext { LiveRecordingService.shared.begin(recordingID: id, context: context, fullFileName: url.lastPathComponent) }
            do { try capture.start() } catch {
                if inputContext != nil { LiveRecordingService.shared.abandon(recordingID: id, uid: inputContext?.ownerUID ?? "") }
                throw error
            }
            self.capture = capture; fullFileURL = url; liveRecordingID = inputContext == nil ? nil : id
            committedAtStart = NoteRecordingUsage.committedSeconds
            tickCount = 0
            startTimer()
            NoteRecordingActivityController.shared.start(
                courseTitle: activityCourseTitle, sessionLabel: activitySessionLabel,
                remainingSeconds: min(5399, NoteRecordingUsage.limitSeconds - committedAtStart))
            return true
        } catch {
            return false
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in Task { @MainActor in self?.timerFired() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func timerFired() {
        guard let capture, capture.isRunning else { return }
        onLevel?(capture.currentLevel)

        tickCount += 1
        if tickCount % 10 == 0 {
            onTick?()
            if tickCount % 100 == 0 {   // 5秒ごとに途中経過を保存(強制終了に備える)
                NoteRecordingUsage.committedSeconds = committedAtStart + capture.elapsedSeconds
            }
        }
        if remainingSeconds <= 0 || capture.elapsedSeconds >= 5399 {
            let result = stop()
            onAutoStopped?(result)
        }
    }

    /// 録音を止めて保存し、今週の使用時間に加算する。
    @discardableResult
    func stop() -> NoteRecordingResult? {
        guard let capture, let url = fullFileURL else { return nil }
        let (duration, segmentCount) = capture.stop()
        self.capture = nil
        timer?.invalidate()
        timer = nil
        let recordingID = liveRecordingID
        liveRecordingID = nil; fullFileURL = nil
        NoteRecordingUsage.committedSeconds = committedAtStart + duration
        NoteRecordingActivityController.shared.end()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onTick?()
        guard duration >= 1 else {   // 1秒未満は誤タップとして捨てる(時間は加算しない)
            try? FileManager.default.removeItem(at: url)
            if let recordingID, let uid = inputContext?.ownerUID { LiveRecordingService.shared.abandon(recordingID: recordingID, uid: uid) }
            NoteRecordingUsage.committedSeconds = committedAtStart
            return nil
        }
        if let recordingID {
            // 1分ごとの文字起こしを仕上げる(ノート作成・保存)。画面を閉じても続く。
            LiveRecordingService.shared.markStopped(recordingID: recordingID, expectedSegments: segmentCount, duration: duration)
            return NoteRecordingResult(url: url, duration: duration, recordingID: recordingID)
        }
        let savedURL = inputContext.flatMap { try? RecordingRecovery.finish(uid: $0.ownerUID) }
        return NoteRecordingResult(url: savedURL ?? url, duration: duration)
    }

    @objc private func audioInterrupted(_ note: Notification) {
        guard isRecording,
              let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        let result = stop()
        DispatchQueue.main.async { self.onAutoStopped?(result) }
    }
    /// Stop without staging a new recording or invoking a callback that could retain attachments.
    func discardForAccountDeletion(uid: String) {
        guard inputContext?.ownerUID == uid else { return }
        startGeneration += 1
        _ = capture?.stop(); capture = nil
        timer?.invalidate(); timer = nil
        onLevel = nil; onTick = nil; onAutoStopped = nil; inputContext = nil
        liveRecordingID = nil
        NoteRecordingActivityController.shared.end()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let url = fullFileURL { try? FileManager.default.removeItem(at: url) }
        fullFileURL = nil
        LiveRecordingService.shared.discard(uid: uid)
    }
}

// MARK: - 再生

@MainActor
final class NoteAudioPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = NoteAudioPlayer()
    private var player: AVAudioPlayer?
    private(set) var currentURL: URL?
    var onChange: (() -> Void)?

    func stop() {
        player?.stop()
        player = nil
        currentURL = nil
        onChange?()
    }

    func isPlaying(_ url: URL) -> Bool { currentURL == url && (player?.isPlaying ?? false) }

    func toggle(_ url: URL) {
        if isPlaying(url) {
            player?.stop()
            player = nil
            currentURL = nil
        } else {
            player?.stop()
            guard !NoteRecorder.shared.isRecording else { return }
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            guard let new = try? AVAudioPlayer(contentsOf: url) else { return }
            new.delegate = self
            new.play()
            player = new
            currentURL = url
        }
        onChange?()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        currentURL = nil
        onChange?()
    }
}

// MARK: - 見た目の部品

/// 利用済みの割合を示す細いバー。
final class UsageBarView: UIView {
    private let fill = UIView()
    var progress: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }
    var trackColor: UIColor = .clear { didSet { backgroundColor = trackColor } }
    var fillColor: UIColor = .clear { didSet { fill.backgroundColor = fillColor } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(fill)
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        // 使い始めでも少しだけ見える最小幅(丸い先端が出る程度)を確保する
        let width = max(min(bounds.height, bounds.width), bounds.width * min(max(progress, 0), 1))
        fill.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        fill.layer.cornerRadius = bounds.height / 2
    }
}

/// 録音中の音量を、右へ流れる棒グラフで見せる。
final class WaveformView: UIView {
    private var levels: [CGFloat] = []
    var barColor: UIColor = .white
    private let barWidth: CGFloat = 4
    private let gap: CGFloat = 4

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var capacity: Int { max(1, Int((bounds.width + gap) / (barWidth + gap))) }

    func push(_ level: Float) {
        levels.append(CGFloat(level))
        if levels.count > capacity { levels.removeFirst(levels.count - capacity) }
        setNeedsDisplay()
    }

    func reset() {
        levels.removeAll()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard !levels.isEmpty else { return }
        barColor.setFill()
        let total = CGFloat(capacity)
        let startX = bounds.width - (CGFloat(levels.count) * (barWidth + gap) - gap)
        _ = total
        for (index, level) in levels.enumerated() {
            let height = max(barWidth, level * bounds.height)
            let x = startX + CGFloat(index) * (barWidth + gap)
            let bar = CGRect(x: x, y: (bounds.height - height) / 2, width: barWidth, height: height)
            UIBezierPath(roundedRect: bar, cornerRadius: barWidth / 2).fill()
        }
    }
}


// MARK: - ライブアクティビティ(ロック画面・Dynamic Island)

/// 録音中、ロック画面とDynamic Islandに経過時間と今週の残り時間を出す。
final class NoteRecordingActivityController {
    static let shared = NoteRecordingActivityController()
    private var activity: Activity<NoteRecordingActivityAttributes>?

    func start(courseTitle: String, sessionLabel: String, remainingSeconds: TimeInterval) {
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let now = Date()
        let state = NoteRecordingActivityAttributes.ContentState(
            startDate: now, limitDate: now.addingTimeInterval(max(1, remainingSeconds)))
        let attributes = NoteRecordingActivityAttributes(courseTitle: courseTitle, sessionLabel: sessionLabel)
        activity = try? Activity.request(attributes: attributes,
                                         content: ActivityContent(state: state, staleDate: nil))
    }

    func end() {
        guard let current = activity else { return }
        activity = nil
        Task { await current.end(nil, dismissalPolicy: .immediate) }
    }
}
