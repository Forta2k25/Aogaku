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
    // 授業のIDは、正しいUUIDにする(そうでないと、呼ぶたびに別の授業になる)。
    private let context = AIInputContext(ownerUID: "test-uid-live", localCourseId: "5A1E0B5C-2F4D-4C6A-9B7E-0D1C2B3A4F50", classDocId: nil, year: 2026, semester: "fall", dayID: 20261020)

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
        return service
    }
    private func recordingDirectory(_ id: String) throws -> URL { try LiveRecordingPaths.directory(uid: uid, recordingID: id, base: base) }
    /// フォルダを作らずに、あるかどうかだけを見る。
    private func recordingFolderExists(_ id: String) throws -> Bool {
        FileManager.default.fileExists(atPath: try LiveRecordingPaths.root(uid: uid, base: base).appendingPathComponent(id).path)
    }
    private func segmentFile(_ id: String, _ index: Int, start: Double, duration: Double = 60) throws -> LiveSegmentFile {
        let url = try recordingDirectory(id).appendingPathComponent(String(format: "seg-%03d.m4a", index))
        try Data(repeating: 7, count: 64).write(to: url)
        return LiveSegmentFile(index: index, url: url, startSeconds: start, duration: duration)
    }
    private func waitUntil(_ what: String, timeout: Double = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), what)
    }
    private func textTransport() -> FakeTransport {
        FakeTransport { _, payload in ["text": "区間\(payload["index"] as! Int)の話。"] }
    }

    func testRecordingBecomesOneTextReadyToDropIntoTheInputField() async throws {
        let transport = textTransport(); service.transport = transport
        let id = "rec-e2e-0001"
        service.begin(recordingID: id, context: context, fullFileName: "full.m4a")
        for i in 0..<3 { service.addSegment(recordingID: id, file: try segmentFile(id, i, start: Double(i) * 60)) }
        await waitUntil("3区間が文字になる") { self.service.session(id)?.segments.allSatisfy { $0.status == "done" } == true }
        XCTAssertEqual(service.session(id)?.state, "recording", "止めるまでは、入力欄に渡さない")
        XCTAssertTrue(service.readySessions(courseKey: context.courseKey, dayID: context.dayID).isEmpty)
        XCTAssertNotNil(service.activeSession(courseKey: context.courseKey, dayID: context.dayID))

        service.markStopped(recordingID: id, expectedSegments: 3, duration: 180)
        await waitUntil("文字ができる") { self.service.session(id)?.state == "ready" }
        let ready = try XCTUnwrap(service.readySessions(courseKey: context.courseKey, dayID: context.dayID).first)
        XCTAssertEqual(ready.text, "区間0の話。区間1の話。区間2の話。")
        XCTAssertEqual(ready.failedSegments, 0)
        XCTAssertEqual(transport.calls.map(\.task), Array(repeating: "recordingSegment", count: 3), "要約やノートは、頼まない(文字起こしだけ)")
        XCTAssertTrue(store.ledger.sources.isEmpty, "自動では、資料にもメッセージにもしない")
        XCTAssertTrue(store.ledger.messages.isEmpty)
        XCTAssertNil(service.activeSession(courseKey: context.courseKey, dayID: context.dayID))

        service.complete(id)   // 入力欄に渡した
        XCTAssertTrue(service.readySessions(courseKey: context.courseKey, dayID: context.dayID).isEmpty)
        XCTAssertFalse(try recordingFolderExists(id), "渡し終えたら、保存していた録音は消す")
    }

    func testRetriesOverloadButGivesUpOnPermanentFailureAndStillDeliversTheRest() async throws {
        var failures = 0
        let transport = FakeTransport { _, payload in
            let index = payload["index"] as! Int
            if index == 0, failures < 2 { failures += 1; throw LiveTaskError(code: "ASR_UNAVAILABLE", retryable: true, message: "混み合っています") }
            if index == 1 { throw LiveTaskError(code: "QUOTA_EXCEEDED", retryable: false, message: "上限") }
            return ["text": "区間\(index)の話。"]
        }
        service.transport = transport
        let id = "rec-fail-0001"
        service.begin(recordingID: id, context: context, fullFileName: "full.m4a")
        for i in 0..<3 { service.addSegment(recordingID: id, file: try segmentFile(id, i, start: Double(i) * 60)) }
        service.markStopped(recordingID: id, expectedSegments: 3, duration: 180)
        await waitUntil("文字ができる") { self.service.session(id)?.state == "ready" }
        let session = try XCTUnwrap(service.session(id))
        XCTAssertEqual(session.segments.map(\.status), ["done", "failed", "done"])
        func attempts(_ index: Int) -> Int { transport.calls.filter { ($0.payload["index"] as? Int) == index }.count }
        XCTAssertEqual(attempts(0), 3, "混み合いは、2回やり直して3回目で成功")
        XCTAssertEqual(attempts(1), 1, "上限のような、やり直しても直らない失敗は、1回で諦める")
        XCTAssertEqual(session.text, "区間0の話。区間2の話。", "読めた分だけを渡す")
        XCTAssertEqual(session.failedSegments, 1)
        XCTAssertFalse(session.audioKept)
    }

    func testWhenNothingCouldBeTranscribedBecauseOfFailuresTheRecordingIsKeptAsAnAttachment() async throws {
        service.transport = FakeTransport { _, _ in throw LiveTaskError(code: "ASR_UNAVAILABLE", retryable: false, message: "失敗") }
        let id = "rec-allfail-01"
        service.begin(recordingID: id, context: context, fullFileName: "full.m4a")
        try Data(repeating: 9, count: 2048).write(to: try recordingDirectory(id).appendingPathComponent("full.m4a"))
        service.addSegment(recordingID: id, file: try segmentFile(id, 0, start: 0))
        service.markStopped(recordingID: id, expectedSegments: 1, duration: 60)
        await waitUntil("仕上がる") { self.service.session(id)?.state == "ready" }
        let session = try XCTUnwrap(service.session(id))
        XCTAssertEqual(session.text, "")
        XCTAssertTrue(session.audioKept, "従来どおり、送れるように、録音を添付に残す")
        let audio = try XCTUnwrap(store.ledger.sources.first { $0.kind == .audio })
        XCTAssertFalse(audio.submitted, "自動では、送らない")
        service.complete(id)
        XCTAssertFalse(try recordingFolderExists(id), "資料にコピー済みなので、元の置き場は消す")
    }

    func testSilenceIsReadyWithEmptyTextAndNoAttachment() async throws {
        service.transport = FakeTransport { _, _ in ["text": ""] }
        let id = "rec-silent-001"
        service.begin(recordingID: id, context: context, fullFileName: "full.m4a")
        service.addSegment(recordingID: id, file: try segmentFile(id, 0, start: 0))
        service.markStopped(recordingID: id, expectedSegments: 1, duration: 60)
        await waitUntil("仕上がる") { self.service.session(id)?.state == "ready" }
        XCTAssertEqual(service.session(id)?.text, "")
        XCTAssertEqual(service.session(id)?.failedSegments, 0)
        XCTAssertFalse(service.session(id)?.audioKept ?? true)
        XCTAssertTrue(store.ledger.sources.isEmpty)
    }

    func testDuplicateSegmentsAreIgnored() async throws {
        let transport = textTransport(); service.transport = transport
        let id = "rec-dup-00001"
        service.begin(recordingID: id, context: context, fullFileName: "full.m4a")
        let file = try segmentFile(id, 0, start: 0)
        service.addSegment(recordingID: id, file: file); service.addSegment(recordingID: id, file: file)
        await waitUntil("文字になる") { self.service.session(id)?.segments.first?.status == "done" }
        XCTAssertEqual(service.session(id)?.segments.count, 1)
        XCTAssertEqual(transport.count("recordingSegment"), 1)
    }

    func testUnfinishedSessionResumesAfterRestartAndBecomesReady() async throws {
        service.transport = textTransport()
        let id = "rec-resume-001"
        service.begin(recordingID: id, context: context, fullFileName: "full.m4a")
        service.addSegment(recordingID: id, file: try segmentFile(id, 0, start: 0))
        await waitUntil("文字になる") { self.service.session(id)?.segments.first?.status == "done" }
        let reborn = makeService()   // アプリが終了して、新しいサービスで開き直す(録音中のまま保存されている)
        reborn.transport = textTransport()
        XCTAssertNil(reborn.session(id))
        reborn.resumePending(uid: uid, isRecording: false)
        await waitUntil("再開して仕上がる") { reborn.session(id)?.state == "ready" }
        XCTAssertEqual(reborn.session(id)?.text, "区間0の話。")
        XCTAssertEqual(reborn.session(id)?.expectedSegments, 1)
    }

    func testReadyTextSurvivesRestartUntilDelivered() async throws {
        service.transport = textTransport()
        let id = "rec-ready-0001"
        service.begin(recordingID: id, context: context, fullFileName: "full.m4a")
        service.addSegment(recordingID: id, file: try segmentFile(id, 0, start: 0))
        service.markStopped(recordingID: id, expectedSegments: 1, duration: 60)
        await waitUntil("文字ができる") { self.service.session(id)?.state == "ready" }
        let reborn = makeService()
        reborn.resumePending(uid: uid, isRecording: false)
        XCTAssertEqual(reborn.readySessions(courseKey: context.courseKey, dayID: context.dayID).first?.text, "区間0の話。", "入力欄に渡す前にアプリが終了しても、文字は残る")
    }

    func testResumeLeavesARecordingThatIsStillBeingMade() async throws {
        service.transport = textTransport()
        service.begin(recordingID: "rec-live-0001", context: context, fullFileName: "full.m4a")
        let other = makeService(); other.transport = textTransport()
        other.resumePending(uid: uid, isRecording: true)
        XCTAssertNil(other.session("rec-live-0001"), "録音中のものは、勝手に仕上げない")
    }

    func testReadySessionsAreOnlyForTheirOwnCourseAndDay() async throws {
        service.transport = textTransport()
        let id = "rec-scope-0001"
        service.begin(recordingID: id, context: context, fullFileName: "full.m4a")
        service.addSegment(recordingID: id, file: try segmentFile(id, 0, start: 0))
        service.markStopped(recordingID: id, expectedSegments: 1, duration: 60)
        await waitUntil("文字ができる") { self.service.session(id)?.state == "ready" }
        XCTAssertEqual(service.readySessions(courseKey: context.courseKey, dayID: context.dayID).count, 1)
        XCTAssertTrue(service.readySessions(courseKey: context.courseKey, dayID: context.dayID + 1).isEmpty, "別の回には渡さない")
        XCTAssertTrue(service.readySessions(courseKey: "other-course", dayID: context.dayID).isEmpty, "別の授業には渡さない")
    }

    func testJoinInsertsSpacesOnlyBetweenLatinWords() {
        var session = LiveRecordingSession(id: "x", context: context, startedAt: Date(), fullFileName: "f")
        let texts = ["今日は偏微分です。", "Partial derivative", "is the slope.", "つまり傾きです。"]
        for (i, text) in texts.enumerated() { session.segments.append(LiveSegment(index: i, startSeconds: Double(i) * 60, duration: 60, fileName: "s", status: "done", text: text)) }
        session.segments.append(LiveSegment(index: 4, startSeconds: 240, duration: 60, fileName: "s", status: "failed", text: "出ない"))
        session.segments.append(LiveSegment(index: 5, startSeconds: 300, duration: 60, fileName: "s", status: "done", text: "  "))
        XCTAssertEqual(LiveTranscript.join(session), "今日は偏微分です。Partial derivative is the slope.つまり傾きです。")
    }

    func testSplitCutsAtSentenceBoundariesWithoutLosingText() {
        let sentence = String(repeating: "あ", count: 99) + "。"
        let text = String(repeating: sentence, count: 400)   // 40,000字
        let parts = LiveTranscript.split(text, limit: 18000)
        XCTAssertGreaterThanOrEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { $0.utf16.count <= 18000 })
        XCTAssertTrue(parts.dropLast().allSatisfy { $0.hasSuffix("。") }, "文の切れ目で分ける")
        XCTAssertEqual(parts.joined(), text, "分けても、文字は欠けない")
        XCTAssertEqual(LiveTranscript.split("短い文章"), ["短い文章"])
        XCTAssertEqual(LiveTranscript.split("  \n "), [])
        let noBreak = String(repeating: "あ", count: 40000)   // 切れ目が無いときも、上限で分ける
        XCTAssertEqual(LiveTranscript.split(noBreak, limit: 18000).joined(), noBreak)
    }
}
