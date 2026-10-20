import XCTest
@testable import Aogaku

@MainActor
private final class FakeTransport: LiveRecordingTransport {
    var calls: [(task: String, payload: [String: Any])] = []
    var handler: (String, [String: Any]) throws -> [String: Any]
    init(_ handler: @escaping (String, [String: Any]) throws -> [String: Any]) { self.handler = handler }
    func call(task: String, payload: [String: Any], uid: String) async throws -> [String: Any] {
        calls.append((task, payload)); return try handler(task, payload)
    }
    func count(_ task: String) -> Int { calls.filter { $0.task == task }.count }
}

@MainActor
final class LiveRecordingServiceTests: XCTestCase {
    private var base: URL!
    private var store: LocalSourceStore!
    private var service: LiveRecordingService!
    private let uid = "test-uid-live"
    private var context: AIInputContext { AIInputContext(ownerUID: uid, localCourseId: "course-live", classDocId: nil, year: 2026, semester: "fall", dayID: 20261020) }

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("live-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = try LocalSourceStore(uid: uid, baseURL: base)
        service = makeService()
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

    private func makeService() -> LiveRecordingService {
        let service = LiveRecordingService()
        service.baseURL = base
        service.storeProvider = { [store] _ in store! }
        service.retryDelay = { _ in 0 }
        service.onCommitted = { _ in }
        return service
    }
    private func segmentFile(_ id: String, _ index: Int, start: Double, duration: Double = 60) throws -> LiveSegmentFile {
        let dir = try LiveRecordingPaths.directory(uid: uid, recordingID: id, base: base)
        let url = dir.appendingPathComponent(String(format: "seg-%03d.m4a", index))
        try Data(repeating: 7, count: 64).write(to: url)
        return LiveSegmentFile(index: index, url: url, startSeconds: start, duration: duration)
    }
    private func waitUntil(_ what: String, timeout: Double = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), what)
    }
    private func standardTransport() -> FakeTransport {
        FakeTransport { task, payload in
            switch task {
            case "recordingSegment": return ["text": "区間\(payload["index"] as! Int)の話"]
            case "recordingSummary": return ["text": "要約 \(payload["startMinute"] as! Int)〜\(payload["endMinute"] as! Int)分"]
            default: return ["text": "## この回のまとめ\n偏微分の回"]
            }
        }
    }

    func testRecordingEndToEndProducesNoteSourcesMessageAndReply() async throws {
        let transport = standardTransport(); service.transport = transport
        let id = "rec-e2e-0001"
        service.begin(recordingID: id, context: context, fullFileName: "full.m4a")
        for i in 0..<3 { service.addSegment(recordingID: id, file: try segmentFile(id, i, start: Double(i) * 60)) }
        await waitUntil("3区間が文字になる") { self.service.session(id)?.segments.allSatisfy { $0.status == "done" } == true }
        XCTAssertEqual(service.session(id)?.state, "recording")
        XCTAssertEqual(transport.count("recordingSummary"), 0, "10分に満たない録音中は、要約しない")
        XCTAssertTrue(LiveTranscriptFormatter.liveText(service.session(id)!).contains("[1:00] 区間1の話"), "録音中の表示用の文字に、時刻がつく")

        service.markStopped(recordingID: id, expectedSegments: 3, duration: 180)
        await waitUntil("仕上がる") { self.service.session(id)?.state == "done" }
        let session = try XCTUnwrap(service.session(id))
        XCTAssertEqual(transport.count("recordingSummary"), 1)
        XCTAssertEqual(transport.count("recordingNote"), 1)
        XCTAssertEqual(session.blocks.map(\.text), ["要約 0〜3分"])
        let sources = store.ledger.sources.filter { $0.kind == .note }
        XCTAssertEqual(sources.map(\.title), ["録音ノート", "録音の文字起こし"])
        XCTAssertTrue(sources.allSatisfy(\.submitted))
        XCTAssertTrue(sources[0].text!.contains("【ノート】") && sources[0].text!.contains("【10分ごとの要約】"))
        XCTAssertTrue(sources[1].text!.contains("[0:00] 区間0の話") && sources[1].text!.contains("[2:00] 区間2の話"))
        let message = try XCTUnwrap(store.ledger.messages.first)
        XCTAssertEqual(message.kind, "recording"); XCTAssertEqual(message.text, id); XCTAssertEqual(message.sourceIDs.count, 2)
        let reply = try XCTUnwrap(store.reply(afterMessageID: message.id))
        XCTAssertTrue(reply.text.hasPrefix("この回の録音ノート(3分)"))
        XCTAssertEqual(reply.suggestions?.count, 3)
        XCTAssertEqual(session.messageID, message.id)
    }

    func testSummaryRunsEveryTenMinutesWhileStillRecording() async throws {
        let transport = standardTransport(); service.transport = transport
        let id = "rec-block-0001"
        service.begin(recordingID: id, context: context, fullFileName: "full.m4a")
        for i in 0..<11 { service.addSegment(recordingID: id, file: try segmentFile(id, i, start: Double(i) * 60)) }
        await waitUntil("最初の10分の要約ができる") { self.service.session(id)?.blocks.count == 1 }
        XCTAssertEqual(service.session(id)?.blocks.first?.text, "要約 0〜10分")
        XCTAssertEqual(service.session(id)?.state, "recording", "録音中は、ノートまで仕上げない")
        XCTAssertEqual(transport.count("recordingNote"), 0)
        service.markStopped(recordingID: id, expectedSegments: 11, duration: 660)
        await waitUntil("仕上がる") { self.service.session(id)?.state == "done" }
        let second = transport.calls.filter { $0.task == "recordingSummary" }.last!
        XCTAssertEqual(second.payload["startMinute"] as? Int, 10)
        XCTAssertEqual(second.payload["previousSummary"] as? String, "要約 0〜10分", "直前の要約が、前後関係として渡る")
        XCTAssertEqual(service.session(id)?.blocks.map(\.index), [0, 1])
    }

    func testRetriesOverloadButGivesUpOnPermanentFailureAndStillFinishes() async throws {
        var failures = 0
        let transport = FakeTransport { task, payload in
            switch task {
            case "recordingSegment":
                let index = payload["index"] as! Int
                if index == 0, failures < 2 { failures += 1; throw LiveTaskError(code: "ASR_UNAVAILABLE", retryable: true, message: "混み合っています") }
                if index == 1 { throw LiveTaskError(code: "QUOTA_EXCEEDED", retryable: false, message: "上限") }
                return ["text": "区間\(index)の話"]
            case "recordingSummary": return ["text": "要約"]
            default: return ["text": "## ノート"]
            }
        }
        service.transport = transport
        let id = "rec-fail-0001"
        service.begin(recordingID: id, context: context, fullFileName: "full.m4a")
        for i in 0..<3 { service.addSegment(recordingID: id, file: try segmentFile(id, i, start: Double(i) * 60)) }
        service.markStopped(recordingID: id, expectedSegments: 3, duration: 180)
        await waitUntil("仕上がる") { self.service.session(id)?.state == "done" }
        let session = try XCTUnwrap(service.session(id))
        XCTAssertEqual(session.segments.map(\.status), ["done", "failed", "done"])
        func attempts(_ index: Int) -> Int { transport.calls.filter { $0.task == "recordingSegment" && ($0.payload["index"] as? Int) == index }.count }
        XCTAssertEqual(attempts(0), 3, "混み合いは、2回やり直して3回目で成功")
        XCTAssertEqual(attempts(1), 1, "上限のような、やり直しても直らない失敗は、1回で諦める")
        let transcript = try XCTUnwrap(store.ledger.sources.first { $0.title == "録音の文字起こし" }?.text)
        XCTAssertTrue(transcript.contains("[1:00] (この区間は文字にできませんでした)"))
        let reply = try XCTUnwrap(store.reply(afterMessageID: try XCTUnwrap(session.messageID)))
        XCTAssertTrue(reply.text.contains("1か所の区間は、通信の都合で文字にできませんでした"))
    }

    func testSilentRecordingSaysSoInsteadOfInventingANote() async throws {
        let transport = FakeTransport { task, _ in
            if task == "recordingSegment" { return ["text": ""] }
            XCTFail("文字が無いのに、要約・ノートは作らない: \(task)"); return ["text": "x"]
        }
        service.transport = transport
        let id = "rec-silent-001"
        service.begin(recordingID: id, context: context, fullFileName: "full.m4a")
        service.addSegment(recordingID: id, file: try segmentFile(id, 0, start: 0))
        service.markStopped(recordingID: id, expectedSegments: 1, duration: 60)
        await waitUntil("仕上がる") { self.service.session(id)?.state == "done" }
        XCTAssertTrue(store.ledger.sources.isEmpty, "資料は作らない")
        let messageID = try XCTUnwrap(service.session(id)?.messageID)
        XCTAssertTrue(try XCTUnwrap(store.reply(afterMessageID: messageID)).text.contains("文字にできる音声が見つかりませんでした"))
        XCTAssertNil(store.reply(afterMessageID: messageID)?.suggestions)
    }

    func testDuplicateSegmentsAreIgnored() async throws {
        let transport = standardTransport(); service.transport = transport
        let id = "rec-dup-00001"
        service.begin(recordingID: id, context: context, fullFileName: "full.m4a")
        let file = try segmentFile(id, 0, start: 0)
        service.addSegment(recordingID: id, file: file); service.addSegment(recordingID: id, file: file)
        await waitUntil("文字になる") { self.service.session(id)?.segments.first?.status == "done" }
        XCTAssertEqual(service.session(id)?.segments.count, 1)
        XCTAssertEqual(transport.count("recordingSegment"), 1)
    }

    func testUnfinishedSessionResumesAfterRestartAndFinishes() async throws {
        service.transport = standardTransport()
        let id = "rec-resume-001"
        service.begin(recordingID: id, context: context, fullFileName: "full.m4a")
        service.addSegment(recordingID: id, file: try segmentFile(id, 0, start: 0))
        await waitUntil("文字になる") { self.service.session(id)?.segments.first?.status == "done" }
        let reborn = makeService()   // アプリが終了して、新しいサービスで開き直す(録音中のまま保存されている)
        reborn.transport = standardTransport()
        XCTAssertNil(reborn.session(id))
        reborn.resumePending(uid: uid, isRecording: false)
        await waitUntil("再開して仕上がる") { reborn.session(id)?.state == "done" }
        XCTAssertEqual(store.ledger.messages.filter { $0.kind == "recording" }.count, 1)
        XCTAssertEqual(reborn.session(id)?.expectedSegments, 1)
    }

    func testResumeLeavesARecordingThatIsStillBeingMade() async throws {
        service.transport = standardTransport()
        service.begin(recordingID: "rec-live-0001", context: context, fullFileName: "full.m4a")
        let other = makeService(); other.transport = standardTransport()
        other.resumePending(uid: uid, isRecording: true)
        XCTAssertNil(other.session("rec-live-0001"), "録音中のものは、勝手に仕上げない")
    }

    func testFormatterSplitsLongTranscriptsAtLineBoundaries() {
        var session = LiveRecordingSession(id: "x", context: context, startedAt: Date(), fullFileName: "f")
        for i in 0..<30 { session.segments.append(LiveSegment(index: i, startSeconds: Double(i) * 60, duration: 60, fileName: "s", status: "done", text: String(repeating: "あ", count: 1500))) }
        let parts = LiveTranscriptFormatter.transcriptParts(session, limit: 18000)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.utf16.count <= 18000 })
        XCTAssertEqual(parts.joined(separator: "\n"), LiveTranscriptFormatter.liveText(session), "分けても、文字は欠けない")
        XCTAssertEqual(LiveTranscriptFormatter.stamp(3725), "62:05")
    }
}
