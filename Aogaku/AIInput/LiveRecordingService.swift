import Foundation

extension Notification.Name {
    /// ライブ録音の状態が変わった(文字が増えた・ノートができた)。object は録音のID。
    static let liveRecordingChanged = Notification.Name("liveRecordingChanged")
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

/// 10分ごとの要約。
struct LiveBlock: Codable, Equatable {
    var index: Int
    var startMinute: Int
    var endMinute: Int
    /// 空のときは、要約できなかった(または、音声が無かった)10分間。
    var text: String
}

struct LiveRecordingSession: Codable, Identifiable {
    let id: String
    let context: AIInputContext
    let startedAt: Date
    let fullFileName: String
    /// recording(録音中)/ finishing(止めた。文字・ノートを仕上げ中)/ done
    var state: String = "recording"
    var segments: [LiveSegment] = []
    var blocks: [LiveBlock] = []
    var expectedSegments: Int? = nil
    var durationSeconds: Double? = nil
    var note: String? = nil
    var messageID: String? = nil

    static let blockSeconds: Double = 600
    func blockIndex(_ segment: LiveSegment) -> Int { Int(segment.startSeconds / Self.blockSeconds) }
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

enum LiveTranscriptFormatter {
    static func stamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds)); return String(format: "%d:%02d", total / 60, total % 60)
    }
    /// 録音中の表示用: 文字になった区間を、時刻つきで並べる。
    static func liveText(_ session: LiveRecordingSession) -> String {
        session.segments.sorted { $0.index < $1.index }.compactMap { segment in
            switch segment.status {
            case "done": return segment.text.isEmpty ? nil : "[\(stamp(segment.startSeconds))] \(segment.text)"
            case "failed": return "[\(stamp(segment.startSeconds))] (この区間は文字にできませんでした)"
            default: return nil
            }
        }.joined(separator: "\n")
    }
    /// AIに渡す文字起こし。1つの資料は2万字までなので、行の切れ目で分ける。
    static func transcriptParts(_ session: LiveRecordingSession, limit: Int = 18000) -> [String] {
        let lines = liveText(session).components(separatedBy: "\n").filter { !$0.isEmpty }
        var parts: [String] = [], current = ""
        for line in lines {
            let piece = String(line.prefix(limit))
            if !current.isEmpty, current.utf16.count + piece.utf16.count + 1 > limit { parts.append(current); current = "" }
            current += (current.isEmpty ? "" : "\n") + piece
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
    /// AIの根拠になる「ノート」の資料。ノート本文と、10分ごとの要約。
    static func noteSourceText(note: String?, blocks: [LiveBlock]) -> String? {
        var sections: [String] = []
        if let note, !note.isEmpty { sections.append("【ノート】\n\(note)") }
        let summaries = blocks.filter { !$0.text.isEmpty }.map { "[\($0.startMinute)〜\($0.endMinute)分]\n\($0.text)" }
        if !summaries.isEmpty { sections.append("【10分ごとの要約】\n" + summaries.joined(separator: "\n\n")) }
        guard !sections.isEmpty else { return nil }
        return String(sections.joined(separator: "\n\n").prefix(19000))
    }
    /// 吹き出しに出す、この回のノート。
    static func replyText(note: String?, blocks: [LiveBlock], minutes: Int, hasTranscript: Bool, failedSegments: Int, audioKept: Bool = false) -> String {
        var text = ""
        if let note, !note.isEmpty { text = "この回の録音ノート(\(minutes)分)\n\n\(note)" }
        else if blocks.contains(where: { !$0.text.isEmpty }) {
            text = "この回の録音ノート(\(minutes)分)\n\n" + blocks.filter { !$0.text.isEmpty }.map { "## \($0.startMinute)〜\($0.endMinute)分\n\($0.text)" }.joined(separator: "\n\n")
        } else if hasTranscript { text = "録音(\(minutes)分)の文字起こしを保存しました。ノートは作れませんでしたが、質問すると、録音の内容から答えます。" }
        else if audioKept { text = "録音(\(minutes)分)を、リアルタイムでは文字にできませんでした。録音は、メッセージ欄の添付から送ると、あとで文字にして、AIが使えるようになります。" }
        else { text = "録音(\(minutes)分)から、文字にできる音声が見つかりませんでした。" }
        if failedSegments > 0, !audioKept { text += "\n\n※ \(failedSegments)か所の区間は、通信の都合で文字にできませんでした。" }
        return text
    }
}

// MARK: - サービス本体

/// 録音しながら、1分ごとの音声を文字にし、10分ごとに要約し、終わったらノートにして、授業の資料として保存する。
/// 画面とは独立して動く(画面を閉じても、録音と処理は続く)。状態は端末に保存するので、アプリが終了しても、続きから再開できる。
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
    var maxSummaryAttempts = 3
    /// ノートを保存したあとの後始末(資料のアップロードを始める)。テストでは差し替える。
    var onCommitted: (String) -> Void = { SourceIngestionService.shared.resume(uid: $0) }

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
    /// この授業回で、いま録音中・仕上げ中の録音。
    func activeSession(courseKey: String, dayID: Int) -> LiveRecordingSession? {
        sessions.values.filter { $0.state != "done" && $0.context.dayID == dayID && $0.context.courseKey == courseKey }
            .max { $0.startedAt < $1.startedAt }
    }
    /// 全体の録音ファイル(再生用)。
    func playbackURL(uid: String, recordingID: String) -> URL? {
        guard let directory = try? LiveRecordingPaths.directory(uid: uid, recordingID: recordingID, base: baseURL) else { return nil }
        let id = recordingID
        let name = (loadSession(uid: uid, id: id))?.fullFileName ?? "full.m4a"
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    func loadSession(uid: String, id: String) -> LiveRecordingSession? {
        if let existing = sessions[id] { return existing }
        guard let directory = try? LiveRecordingPaths.directory(uid: uid, recordingID: id, base: baseURL),
              let data = try? Data(contentsOf: directory.appendingPathComponent("session.json")),
              let session = try? JSONDecoder().decode(LiveRecordingSession.self, from: data) else { return nil }
        return session
    }

    // MARK: 録音側からの入口

    func begin(recordingID: String, context: AIInputContext, fullFileName: String) {
        save(LiveRecordingSession(id: recordingID, context: context, startedAt: Date(), fullFileName: fullFileName))
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
    /// アプリの再起動後に、途中だった録音の処理を続ける(落ちたときの、最後の区間は失われる)。
    func resumePending(uid: String, isRecording: Bool) {
        guard let root = try? LiveRecordingPaths.root(uid: uid, base: baseURL),
              let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            let id = folder.lastPathComponent
            guard sessions[id] == nil, var session = loadSession(uid: uid, id: id), session.state != "done" else { continue }
            if session.state == "recording" {
                if isRecording { continue }   // 今まさに録音中のもの(別の画面から戻ってきた)は触らない
                session.state = "finishing"; session.expectedSegments = session.segments.count
                session.durationSeconds = session.segments.map(\.endSeconds).max() ?? 0
            }
            for i in session.segments.indices where session.segments[i].status == "failed" && session.segments[i].attempts >= maxAttemptsAfterStop {
                session.segments[i].status = "pending"; session.segments[i].attempts = 0   // 通信が戻っていれば、もう一度試す
            }
            save(session); kick(id)
        }
    }
    /// 1秒未満など、捨てる録音の、保存した状態とファイルを消す。
    func abandon(recordingID: String, uid: String) {
        workers[recordingID]?.cancel(); workers[recordingID] = nil; sessions[recordingID] = nil
        if let directory = try? LiveRecordingPaths.directory(uid: uid, recordingID: recordingID, base: baseURL) { try? FileManager.default.removeItem(at: directory) }
    }
    func discard(uid: String) {
        for (id, session) in sessions where session.context.ownerUID == uid { workers[id]?.cancel(); workers[id] = nil; sessions[id] = nil }
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
        session.segments.contains { $0.status == "pending" } || nextDueBlock(session) != nil || (session.state == "finishing" && isComplete(session))
    }
    private func isComplete(_ session: LiveRecordingSession) -> Bool {
        guard session.state == "finishing", let expected = session.expectedSegments, session.segments.count >= expected, session.isResolved else { return false }
        return nextDueBlock(session) == nil
    }
    /// 10分ぶんの区間がそろって、まだ要約していないブロック。
    private func nextDueBlock(_ session: LiveRecordingSession) -> Int? {
        let indices = Set(session.segments.map(session.blockIndex)).sorted()
        let allKnown = session.state == "finishing" && (session.expectedSegments ?? .max) <= session.segments.count
        for b in indices where !session.blocks.contains(where: { $0.index == b }) {
            let members = session.segments.filter { session.blockIndex($0) == b }
            guard members.allSatisfy({ $0.status != "pending" }) else { continue }
            if b < (indices.last ?? b) || allKnown { return b }
        }
        return nil
    }

    private func run(_ id: String) async {
        while !Task.isCancelled, let session = sessions[id] {
            if let segment = session.segments.sorted(by: { $0.index < $1.index }).first(where: { $0.status == "pending" }) {
                await transcribe(id, segment.index); continue
            }
            if let block = nextDueBlock(session) { await summarize(id, block: block); continue }
            if isComplete(session) { await finalize(id) }
            return
        }
    }

    private func transcribe(_ id: String, _ index: Int) async {
        guard var session = sessions[id], let i = session.segments.firstIndex(where: { $0.index == index }) else { return }
        let segment = session.segments[i]
        func update(_ change: (inout LiveSegment) -> Void) {
            guard var s = sessions[id], let j = s.segments.firstIndex(where: { $0.index == index }) else { return }
            change(&s.segments[j]); save(s)
        }
        do {
            let directory = try directory(session)
            let data = try Data(contentsOf: directory.appendingPathComponent(segment.fileName))
            let payload: [String: Any] = ["recordingId": id, "index": segment.index, "durationSeconds": segment.duration, "audio": data.base64EncodedString()]
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

    private func summarize(_ id: String, block b: Int) async {
        guard let session = sessions[id] else { return }
        let members = session.segments.filter { session.blockIndex($0) == b }.sorted { $0.index < $1.index }
        let text = members.filter { $0.status == "done" && !$0.text.isEmpty }.map(\.text).joined(separator: "\n")
        let start = b * 10, end = max(start, Int(ceil((members.map(\.endSeconds).max() ?? Double(start * 60)) / 60)))
        func finish(_ summary: String) {
            guard var s = sessions[id] else { return }
            s.blocks.append(LiveBlock(index: b, startMinute: start, endMinute: end, text: summary)); save(s)
        }
        guard !text.isEmpty else { finish(""); return }
        let previous = session.blocks.filter { !$0.text.isEmpty }.max { $0.index < $1.index }?.text ?? ""
        var payload: [String: Any] = ["text": String(text.prefix(9000)), "startMinute": start, "endMinute": end]
        if !previous.isEmpty { payload["previousSummary"] = String(previous.suffix(1500)) }
        for attempt in 0..<maxSummaryAttempts {
            do {
                let result = try await transport.call(task: "recordingSummary", payload: payload, uid: session.context.ownerUID)
                finish((result["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)); return
            } catch let error as LiveTaskError where error.retryable && attempt + 1 < maxSummaryAttempts {
                try? await Task.sleep(nanoseconds: UInt64(retryDelay(attempt) * 1_000_000_000))
            } catch is CancellationError { return }
            catch { break }
        }
        finish("")   // 要約できなかった10分間は、文字起こしだけが残る
    }

    private func makeNote(_ session: LiveRecordingSession) async -> String? {
        let summaries = session.blocks.filter { !$0.text.isEmpty }.sorted { $0.index < $1.index }
        guard !summaries.isEmpty else { return nil }
        let payload: [String: Any] = ["summaries": summaries.map { ["startMinute": $0.startMinute, "endMinute": $0.endMinute, "text": $0.text] }]
        for attempt in 0..<maxSummaryAttempts {
            do {
                let result = try await transport.call(task: "recordingNote", payload: payload, uid: session.context.ownerUID)
                let text = (result["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            } catch let error as LiveTaskError where error.retryable && attempt + 1 < maxSummaryAttempts {
                try? await Task.sleep(nanoseconds: UInt64(retryDelay(attempt) * 1_000_000_000))
            } catch { break }
        }
        return nil
    }

    /// 文字・要約・ノートを、授業の資料とチャットのメッセージとして保存する。
    private func finalize(_ id: String) async {
        guard var session = sessions[id], session.state == "finishing" else { return }
        let note = await makeNote(session)
        guard !Task.isCancelled, let latest = sessions[id], latest.state == "finishing" else { return }
        session = latest
        do {
            let store = try storeProvider(session.context.ownerUID)
            session.messageID = try LiveRecordingFinalizer.commit(session: session, note: note, store: store, fullFileURL: try directory(session).appendingPathComponent(session.fullFileName))
            session.note = note; session.state = "done"
            save(session)
            if let directory = try? directory(session) {   // 区間のファイルを片付ける(全体の録音と、保存した状態は残す)
                for segment in session.segments { try? FileManager.default.removeItem(at: directory.appendingPathComponent(segment.fileName)) }
            }
            onCommitted(session.context.ownerUID)
        } catch {
            // 保存に失敗したときは、仕上げ中のまま残す(次に開いたときに、もう一度試す)。
            session.state = "finishing"; save(session)
        }
    }
}

// MARK: - 保存(資料・メッセージ・ノート)

@MainActor
enum LiveRecordingFinalizer {
    /// ノートと文字起こしを「授業の資料」にし、チャットに「録音」のメッセージとノートの返信を足す。メッセージのIDを返す。
    static func commit(session: LiveRecordingSession, note: String?, store: LocalSourceStore, fullFileURL: URL? = nil) throws -> String {
        let context = session.context
        var sourceIDs: [String] = []
        if let body = LiveTranscriptFormatter.noteSourceText(note: note, blocks: session.blocks) {
            sourceIDs.append(try store.stage(context: context, kind: .note, title: "録音ノート", mime: "text/plain", text: body).id)
        }
        let parts = LiveTranscriptFormatter.transcriptParts(session)
        for (i, part) in parts.enumerated() {
            let title = parts.count == 1 ? "録音の文字起こし" : "録音の文字起こし \(i + 1)/\(parts.count)"
            sourceIDs.append(try store.stage(context: context, kind: .note, title: title, mime: "text/plain", text: part).id)
        }
        let message = AIChatSnapshot(id: UUID().uuidString, context: context, kind: "recording", text: session.id, sourceIDs: sourceIDs, createdAt: Date())
        try store.submit(context: context, snapshots: [message])
        let failed = session.segments.filter { $0.status == "failed" }.count
        let duration = session.durationSeconds ?? session.segments.map(\.endSeconds).max() ?? 0
        let minutes = max(1, Int(ceil(duration / 60)))
        // 文字がまったく取れず、通信の失敗があったときは、録音ファイルを従来どおり送れるように、添付に残す。
        var audioKept = false
        if parts.isEmpty, failed > 0, let fullFileURL, FileManager.default.fileExists(atPath: fullFileURL.path), (1...5400).contains(duration) {
            audioKept = (try? store.stage(context: context, kind: .audio, title: "授業の録音", mime: "audio/mp4", fileURL: fullFileURL, duration: duration)) != nil
        }
        let text = LiveTranscriptFormatter.replyText(note: note, blocks: session.blocks, minutes: minutes, hasTranscript: !parts.isEmpty, failedSegments: failed, audioKept: audioKept)
        let suggestions = parts.isEmpty ? nil : ["重要語をくわしく教えて", "先生が強調したことは?", "課題や連絡はある?"]
        try store.addReply(AIStoredReply(id: UUID().uuidString, context: context, afterMessageID: message.id, text: text, createdAt: Date(), suggestions: suggestions))
        return message.id
    }
}
