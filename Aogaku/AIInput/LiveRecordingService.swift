import Foundation

extension Notification.Name {
    /// 録音の文字起こしの状態が変わった(文字が増えた・仕上がった)。object は録音のID。
    static let liveRecordingChanged = Notification.Name("liveRecordingChanged")
}

// MARK: - 録音の言語

/// 録音を文字にするときの言語。自動のときは、区間(1分)ごとに、言語を判定する(英語の授業・日英まじりの授業向け)。
enum RecordingLanguage: String, CaseIterable {
    case auto, ja, en
    private static let key = "ai.recording.language"
    static var current: RecordingLanguage {
        get { UserDefaults.standard.string(forKey: key).flatMap(RecordingLanguage.init(rawValue:)) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
    var title: String {
        switch self { case .auto: return "自動(日本語・English)"; case .ja: return "日本語"; case .en: return "English" }
    }
}

// MARK: - 保存する状態

struct LiveSegment: Codable, Equatable {
    var index: Int
    var startSeconds: Double
    var duration: Double
    var fileName: String
    /// pending(まだ)/ done(文字になった)/ failed(文字にできなかった)
    var status: String = "pending"
    var text: String = ""
    var attempts: Int = 0
    var error: String? = nil
    var endSeconds: Double { startSeconds + duration }
}

struct LiveRecordingSession: Codable, Identifiable {
    let id: String
    let context: AIInputContext
    let startedAt: Date
    let fullFileName: String
    /// recording(録音中)/ finishing(止めた。残りの区間を文字にしている)/ ready(文字ができた。入力欄への受け渡し待ち)/ done
    var state: String = "recording"
    var segments: [LiveSegment] = []
    var expectedSegments: Int? = nil
    var durationSeconds: Double? = nil
    /// ready のとき: 文字になった全文。
    var text: String? = nil
    /// ready のとき: 文字にできなかった区間の数。
    var failedSegments: Int = 0
    /// 文字がまったく取れず、通信の失敗があったので、録音を従来どおり送れる形で添付に残した。
    var audioKept: Bool = false
    /// 文字にする言語(auto / ja / en)。録音を始めたときの設定。古い保存データには無い。
    var language: String? = nil
    var isResolved: Bool { !segments.contains { $0.status == "pending" } }
}

// MARK: - サーバーとのやり取り

struct LiveTaskError: Error {
    let code: String
    let retryable: Bool
    let message: String
}

@MainActor
protocol LiveRecordingTransport {
    func call(task: String, payload: [String: Any], uid: String) async throws -> [String: Any]
}

@MainActor
struct SourceIngestionTransport: LiveRecordingTransport {
    func call(task: String, payload: [String: Any], uid: String) async throws -> [String: Any] {
        try await SourceIngestionService.shared.callTask(task, payload: payload, uid: uid)
    }
}

// MARK: - 文章の組み立て

enum LiveTranscript {
    /// 区間の文字を、順に1つの文章につなぐ。日本語は、そのまま。英数字どうしが隣り合うときだけ、空白を入れる。
    static func join(_ session: LiveRecordingSession) -> String {
        var result = ""
        for segment in session.segments.sorted(by: { $0.index < $1.index }) where segment.status == "done" {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = result.last, let first = text.first, isWordCharacter(last), isWordCharacter(first) { result += " " }
            result += text
        }
        return result
    }
    private static func isWordCharacter(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }

    /// 長い文章を、授業のメモとして保存するために、文の切れ目で分ける(1つの資料は2万字までなので、既定は18,000字)。
    static func split(_ text: String, limit: Int = 18000) -> [String] {
        var parts: [String] = [], rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while rest.utf16.count > limit {
            let window = rest.prefix(limit)
            // 末尾の近く(最後の500字)に、文の切れ目があれば、そこで切る。
            let cut = window.suffix(500).lastIndex(where: { "。\n!?!?".contains($0) }).map { window.index(after: $0) } ?? window.endIndex
            parts.append(String(rest[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines))
            rest = rest[cut...]
        }
        let last = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { parts.append(last) }
        return parts
    }
}

// MARK: - サービス本体

/// 録音しながら、1分ごとの音声を文字にして貯め、止めたら全文を、入力欄へ渡せる形(ready)にする。
/// 画面とは独立して動く(画面を閉じても、録音と文字起こしは続く)。状態は端末に保存するので、アプリが終了しても、続きから再開できる。
@MainActor
final class LiveRecordingService {
    static let shared = LiveRecordingService()

    var transport: LiveRecordingTransport = SourceIngestionTransport()
    var storeProvider: (String) throws -> LocalSourceStore = { try SourceIngestionService.shared.store(uid: $0) }
    var baseURL: URL? = nil
    /// 通信に失敗したときの待ち時間(秒)。テストでは0にする。
    var retryDelay: (Int) -> Double = { min(30, 3 * Double($0 + 1)) }
    /// 録音が終わったあと、この回数までは再試行する(録音中は、通信が戻るまで粘る)。
    var maxAttemptsAfterStop = 4
    var maxAttemptsWhileRecording = 30

    private var sessions: [String: LiveRecordingSession] = [:]
    private var workers: [String: Task<Void, Never>] = [:]

    // MARK: 保存

    private func directory(_ session: LiveRecordingSession) throws -> URL {
        try LiveRecordingPaths.directory(uid: session.context.ownerUID, recordingID: session.id, base: baseURL)
    }
    private func save(_ session: LiveRecordingSession) {
        sessions[session.id] = session
        if let directory = try? directory(session), let data = try? JSONEncoder().encode(session) {
            try? data.write(to: directory.appendingPathComponent("session.json"), options: .atomic)
        }
        NotificationCenter.default.post(name: .liveRecordingChanged, object: session.id)
    }
    func session(_ id: String) -> LiveRecordingSession? { sessions[id] }
    /// この授業回で、いま録音中・文字を仕上げ中の録音。
    func activeSession(courseKey: String, dayID: Int) -> LiveRecordingSession? {
        sessions.values.filter { ["recording", "finishing"].contains($0.state) && $0.context.dayID == dayID && $0.context.courseKey == courseKey }
            .max { $0.startedAt < $1.startedAt }
    }
    /// この授業回で、文字ができていて、まだ入力欄へ渡していない録音(古い順)。
    func readySessions(courseKey: String, dayID: Int) -> [LiveRecordingSession] {
        sessions.values.filter { $0.state == "ready" && $0.context.dayID == dayID && $0.context.courseKey == courseKey }.sorted { $0.startedAt < $1.startedAt }
    }
    /// 入力欄へ渡し終えた。保存していた録音と状態を消す。
    func complete(_ id: String) {
        guard let session = sessions[id], session.state == "ready" else { return }
        let directory = try? directory(session)
        sessions[id] = nil
        workers[id]?.cancel(); workers[id] = nil
        // 全体の録音も区間も、もう要らない(文字は入力欄に渡した。添付に残した録音は、資料として別に保存してある)。
        if let directory { try? FileManager.default.removeItem(at: directory) }
        NotificationCenter.default.post(name: .liveRecordingChanged, object: id)
    }

    // MARK: 録音側からの入口

    func begin(recordingID: String, context: AIInputContext, fullFileName: String, language: RecordingLanguage = .current) {
        var session = LiveRecordingSession(id: recordingID, context: context, startedAt: Date(), fullFileName: fullFileName)
        session.language = language.rawValue
        save(session)
    }
    func addSegment(recordingID: String, file: LiveSegmentFile) {
        guard var session = sessions[recordingID], !session.segments.contains(where: { $0.index == file.index }) else { return }
        session.segments.append(LiveSegment(index: file.index, startSeconds: file.startSeconds, duration: file.duration, fileName: file.url.lastPathComponent))
        save(session); kick(recordingID)
    }
    func markStopped(recordingID: String, expectedSegments: Int, duration: Double) {
        guard var session = sessions[recordingID] else { return }
        session.state = "finishing"; session.expectedSegments = expectedSegments; session.durationSeconds = duration
        save(session); kick(recordingID)
    }
    /// 1秒未満など、捨てる録音の、保存した状態とファイルを消す。
    func abandon(recordingID: String, uid: String) {
        workers[recordingID]?.cancel(); workers[recordingID] = nil; sessions[recordingID] = nil
        if let directory = try? LiveRecordingPaths.directory(uid: uid, recordingID: recordingID, base: baseURL) { try? FileManager.default.removeItem(at: directory) }
    }
    /// アプリの再起動後に、途中だった録音の処理を続ける(落ちたときの、最後の区間は失われる)。
    func resumePending(uid: String, isRecording: Bool) {
        guard let root = try? LiveRecordingPaths.root(uid: uid, base: baseURL),
              let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            let id = folder.lastPathComponent
            guard sessions[id] == nil, var session = loadSession(uid: uid, id: id), session.state != "done" else { continue }
            if session.state == "ready" { sessions[id] = session; NotificationCenter.default.post(name: .liveRecordingChanged, object: id); continue }
            if session.state == "recording" {
                if isRecording { continue }   // 今まさに録音中のものは触らない
                session.state = "finishing"; session.expectedSegments = session.segments.count
                session.durationSeconds = session.segments.map(\.endSeconds).max() ?? 0
            }
            for i in session.segments.indices where session.segments[i].status == "failed" && session.segments[i].attempts >= maxAttemptsAfterStop {
                session.segments[i].status = "pending"; session.segments[i].attempts = 0   // 通信が戻っていれば、もう一度試す
            }
            save(session); kick(id)
        }
    }
    func discard(uid: String) {
        for (id, session) in sessions where session.context.ownerUID == uid { workers[id]?.cancel(); workers[id] = nil; sessions[id] = nil }
    }
    private func loadSession(uid: String, id: String) -> LiveRecordingSession? {
        guard let directory = try? LiveRecordingPaths.directory(uid: uid, recordingID: id, base: baseURL),
              let data = try? Data(contentsOf: directory.appendingPathComponent("session.json")) else { return nil }
        return try? JSONDecoder().decode(LiveRecordingSession.self, from: data)
    }

    // MARK: 処理

    private func kick(_ id: String) {
        guard workers[id] == nil else { return }
        workers[id] = Task { [weak self] in
            await self?.run(id)
            self?.workers[id] = nil
            // 実行中に追加された仕事を取りこぼさない。
            if let self, let session = self.sessions[id], self.hasWork(session) { self.kick(id) }
        }
    }
    private func hasWork(_ session: LiveRecordingSession) -> Bool {
        session.segments.contains { $0.status == "pending" } || isComplete(session)
    }
    private func isComplete(_ session: LiveRecordingSession) -> Bool {
        session.state == "finishing" && (session.expectedSegments ?? .max) <= session.segments.count && session.isResolved
    }

    private func run(_ id: String) async {
        while !Task.isCancelled, let session = sessions[id] {
            if let segment = session.segments.sorted(by: { $0.index < $1.index }).first(where: { $0.status == "pending" }) {
                await transcribe(id, segment.index); continue
            }
            if isComplete(session) { makeReady(id) }
            return
        }
    }

    private func transcribe(_ id: String, _ index: Int) async {
        guard let session = sessions[id], let i = session.segments.firstIndex(where: { $0.index == index }) else { return }
        let segment = session.segments[i]
        func update(_ change: (inout LiveSegment) -> Void) {
            guard var s = sessions[id], let j = s.segments.firstIndex(where: { $0.index == index }) else { return }
            change(&s.segments[j]); save(s)
        }
        do {
            let directory = try directory(session)
            let data = try Data(contentsOf: directory.appendingPathComponent(segment.fileName))
            let payload: [String: Any] = ["recordingId": id, "index": segment.index, "durationSeconds": segment.duration, "audio": data.base64EncodedString(), "language": session.language ?? "ja"]
            let result = try await transport.call(task: "recordingSegment", payload: payload, uid: session.context.ownerUID)
            let text = (result["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            update { $0.status = "done"; $0.text = text; $0.error = nil }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(segment.fileName))   // 文字になったら、区間のファイルは要らない
        } catch let error as LiveTaskError {
            let limit = session.state == "recording" ? maxAttemptsWhileRecording : maxAttemptsAfterStop
            let attempts = segment.attempts + 1
            if error.retryable && attempts < limit {
                update { $0.attempts = attempts; $0.error = error.message }
                try? await Task.sleep(nanoseconds: UInt64(retryDelay(min(attempts - 1, 9)) * 1_000_000_000))
            } else {
                update { $0.status = "failed"; $0.attempts = attempts; $0.error = error.message }
            }
        } catch is CancellationError { return }
        catch {
            // ファイルが読めない、などの、やり直しても直らないもの。
            update { $0.status = "failed"; $0.error = error.localizedDescription }
        }
    }

    /// すべての区間が文字になった(または諦めた)。全文を作って、入力欄へ渡せる状態にする。
    private func makeReady(_ id: String) {
        guard var session = sessions[id], session.state == "finishing" else { return }
        session.text = LiveTranscript.join(session)
        session.failedSegments = session.segments.filter { $0.status == "failed" }.count
        // 文字がまったく取れず、通信の失敗があったときは、録音ファイルを従来どおり送れるように、添付に残す。
        if (session.text ?? "").isEmpty, session.failedSegments > 0, let duration = session.durationSeconds, (1...5400).contains(duration),
           let directory = try? directory(session) {
            let url = directory.appendingPathComponent(session.fullFileName)
            if FileManager.default.fileExists(atPath: url.path), let store = try? storeProvider(session.context.ownerUID),
               (try? store.stage(context: session.context, kind: .audio, title: "授業の録音", mime: "audio/mp4", fileURL: url, duration: duration)) != nil {
                session.audioKept = true
            }
        }
        session.state = "ready"
        save(session)
    }
}
