import XCTest
@testable import Aogaku

/// 会話の同期(文章だけ)のうち、端末の保存先(LocalSourceStore)の部分。通信はしない。
@MainActor
final class ConversationSyncStoreTests: XCTestCase {
    private var base: URL!
    private var store: LocalSourceStore!
    private let uid = "test-uid-sync"
    private let courseUUID = "5C0E2B7A-1D3F-4A6B-9C8D-0E1F2A3B4C5D"
    private func context(day: Int = 20_000) -> AIInputContext {
        AIInputContext(ownerUID: uid, localCourseId: courseUUID, classDocId: "17607", year: 2026, semester: "fall", dayID: day)
    }

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("sync-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = try LocalSourceStore(uid: uid, baseURL: base)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

    private func ask(_ text: String, day: Int = 20_000, at date: Date = Date()) throws -> AIChatSnapshot {
        let message = AIChatSnapshot(id: UUID().uuidString, context: context(day: day), kind: "question", text: text, sourceIDs: [], createdAt: date)
        try store.submit(context: context(day: day), snapshots: [message]); return message
    }

    func testPlanUploadsQuestionsRepliesAndAttachmentMarksButNotImportedOnes() throws {
        let q = try ask("こんにちは")
        try store.addReply(AIStoredReply(id: "reply-1", context: context(), afterMessageID: q.id, text: "こんにちは!", createdAt: Date()))
        let photo = AIChatSnapshot(id: "photo-1", context: context(), kind: "image", text: nil, sourceIDs: ["a", "b", "c"], createdAt: Date())
        // 画像は、資料の裏づけが必要なので、資料を作ってから送る。
        let sourceIDs = try (0..<3).map { _ in try store.stage(context: context(), kind: .image, title: "p", mime: "image/jpeg", data: Data([1, 2, 3])).id }
        let withSources = AIChatSnapshot(id: photo.id, context: photo.context, kind: "image", text: nil, sourceIDs: sourceIDs, createdAt: Date())
        try store.submit(context: context(), snapshots: [withSources])
        let plan = store.conversationSyncPlan(courseKey: context().courseKey)
        XCTAssertEqual(Set(plan.upload.map(\.id)), [q.id, "reply-1", "photo-1"])
        let imageRow = plan.upload.first { $0.id == "photo-1" }!.row
        XCTAssertEqual(imageRow["kind"] as? String, "image"); XCTAssertEqual(imageRow["imageCount"] as? Int, 3); XCTAssertEqual(imageRow["text"] as? String, "")
        XCTAssertEqual(plan.upload.first { $0.id == "reply-1" }!.row["role"] as? String, "assistant")
        XCTAssertTrue(plan.deletions.isEmpty)
        // 送ったあとは、もう計画に出ない。消すと、サーバーから消す計画に出る。
        try store.markConversationSynced(uploaded: plan.upload.map { ($0.id, $0.context) }, deleted: [])
        XCTAssertTrue(store.conversationSyncPlan(courseKey: context().courseKey).upload.isEmpty)
        try store.deleteMessages(ids: [q.id])
        let afterDelete = store.conversationSyncPlan(courseKey: context().courseKey)
        XCTAssertEqual(Set(afterDelete.deletions.map(\.id)), [q.id, "reply-1"])
        try store.markConversationSynced(uploaded: [], deleted: afterDelete.deletions.map(\.id))
        XCTAssertTrue(store.conversationSyncPlan(courseKey: context().courseKey).deletions.isEmpty)
    }

    func testImportBringsInWebConversationAndAttachmentMarksWithoutDuplicates() throws {
        let remote = [
            RemoteConversationRow(id: "web-q", role: "user", kind: "text", text: "Webからの質問", imageCount: 0, dayID: 20_000, createdAt: 1_790_000_000_000),
            RemoteConversationRow(id: "web-a", role: "assistant", kind: "text", text: "Webでの返信", imageCount: 0, dayID: 20_000, createdAt: 1_790_000_001_000),
            RemoteConversationRow(id: "web-img", role: "user", kind: "image", text: "", imageCount: 3, dayID: 20_000, createdAt: 1_790_000_002_000),
            RemoteConversationRow(id: "orphan-a", role: "assistant", kind: "text", text: "対応する発言のない返信", imageCount: 0, dayID: 20_001, createdAt: 1_790_000_003_000),
        ]
        XCTAssertEqual(try store.importConversation(context: context(), remote: remote), 3)
        let messages = store.messages(context: context())
        XCTAssertEqual(messages.map(\.id), ["web-q", "web-img"])
        XCTAssertTrue(messages.allSatisfy { $0.imported == true })
        XCTAssertEqual(messages[0].kind, "question"); XCTAssertEqual(messages[0].text, "Webからの質問")
        XCTAssertEqual(messages[1].kind, "image"); XCTAssertEqual(messages[1].text, "3"); XCTAssertTrue(messages[1].sourceIDs.isEmpty)
        XCTAssertEqual(store.reply(afterMessageID: "web-q")?.text, "Webでの返信")
        // 2回目は、何も増えない。取り込んだものは、サーバーへ送り返さない。
        XCTAssertEqual(try store.importConversation(context: context(), remote: remote), 0)
        XCTAssertTrue(store.conversationSyncPlan(courseKey: context().courseKey).upload.isEmpty)
    }

    func testReplyArrivingLaterAttachesToTheImportedQuestionOnly() throws {
        let question = RemoteConversationRow(id: "web-q", role: "user", kind: "text", text: "質問", imageCount: 0, dayID: 20_000, createdAt: 1_790_000_000_000)
        XCTAssertEqual(try store.importConversation(context: context(), remote: [question]), 1)
        XCTAssertNil(store.reply(afterMessageID: "web-q"))
        let answer = RemoteConversationRow(id: "web-a", role: "assistant", kind: "text", text: "遅れて届いた返信", imageCount: 0, dayID: 20_000, createdAt: 1_790_000_001_000)
        XCTAssertEqual(try store.importConversation(context: context(), remote: [question, answer]), 1)
        XCTAssertEqual(store.reply(afterMessageID: "web-q")?.text, "遅れて届いた返信")
    }

    func testLedgerWithoutSyncFieldsStillLoads() throws {
        // 同期の項目が無い、以前の保存データも、そのまま読める。
        XCTAssertNil(store.ledger.syncedMessages)
        let reopened = try LocalSourceStore(uid: uid, baseURL: base)
        XCTAssertEqual(reopened.ledger.messages.count, 0)
    }
}
