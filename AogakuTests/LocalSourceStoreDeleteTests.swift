import XCTest
@testable import Aogaku

@MainActor
final class LocalSourceStoreDeleteTests: XCTestCase {
    private var base: URL!
    private var store: LocalSourceStore!
    private let uid = "test-uid-delete"
    private let context = AIInputContext(ownerUID: "test-uid-delete", localCourseId: "7B3C1D2E-4F5A-4B6C-8D7E-9F0A1B2C3D4E", classDocId: nil, year: 2026, semester: "fall", dayID: 20261021)

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("delete-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = try LocalSourceStore(uid: uid, baseURL: base)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

    private func question(_ text: String) throws -> AIChatSnapshot {
        let message = AIChatSnapshot(id: UUID().uuidString, context: context, kind: "question", text: text, sourceIDs: [], createdAt: Date())
        try store.submit(context: context, snapshots: [message]); return message
    }
    private func reply(to message: AIChatSnapshot) throws {
        try store.addReply(AIStoredReply(id: UUID().uuidString, context: context, afterMessageID: message.id, text: "返信", createdAt: Date()))
    }
    private func note(_ text: String) throws -> AIStoredSource {
        try store.stage(context: context, kind: .note, title: text, mime: "text/plain", text: text)
    }

    func testDeletingAMessageRemovesItsReplyAndLeavesTheOthers() throws {
        let a = try question("A"), b = try question("B")
        try reply(to: a); try reply(to: b)
        try store.deleteMessages(ids: [a.id])
        XCTAssertEqual(store.ledger.messages.map(\.text), ["B"])
        XCTAssertNil(store.reply(afterMessageID: a.id))
        XCTAssertNotNil(store.reply(afterMessageID: b.id))
    }

    func testSourcesOnlyThatMessageUsedAreRemovedLocallyWhenNotSentYet() throws {
        let source = try note("メモ本文")
        let message = AIChatSnapshot(id: UUID().uuidString, context: context, kind: "note", text: nil, sourceIDs: [source.id], createdAt: Date())
        try store.submit(context: context, snapshots: [message])
        // 送信の前に、状態を「下書き」に戻す(まだ、サーバーに何も送っていない)
        var draft = try XCTUnwrap(store.ledger.sources.first); draft.localState = "draft"; try store.update(draft)
        try store.deleteMessages(ids: [message.id])
        XCTAssertTrue(store.ledger.sources.isEmpty, "送っていない資料は、その場で消す")
    }

    func testSourcesAlreadySentAreMarkedForDeletionSoTheServerCopyIsRemovedToo() throws {
        let source = try note("送信済みのメモ")
        let message = AIChatSnapshot(id: UUID().uuidString, context: context, kind: "note", text: nil, sourceIDs: [source.id], createdAt: Date())
        try store.submit(context: context, snapshots: [message])   // 送信待ち(queued)になる
        try store.deleteMessages(ids: [message.id])
        XCTAssertEqual(store.ledger.sources.count, 1)
        XCTAssertTrue(store.ledger.sources[0].wantsDeletion, "サーバー側も消すため、削除予約にする")
        XCTAssertTrue(store.ledger.messages.isEmpty)
    }

    func testASourceStillUsedByAnotherMessageIsKept() throws {
        let source = try note("共有の資料")
        let first = AIChatSnapshot(id: UUID().uuidString, context: context, kind: "note", text: nil, sourceIDs: [source.id], createdAt: Date())
        let second = AIChatSnapshot(id: UUID().uuidString, context: context, kind: "note", text: nil, sourceIDs: [source.id], createdAt: Date())
        try store.submit(context: context, snapshots: [first, second])
        try store.deleteMessages(ids: [first.id])
        XCTAssertFalse(store.ledger.sources[0].wantsDeletion, "ほかのメッセージが使っている間は、残す")
        try store.deleteMessages(ids: [second.id])
        XCTAssertTrue(store.ledger.sources[0].wantsDeletion)
    }

    func testDeleteAllMessagesClearsOnlyThisSession() throws {
        let other = AIInputContext(ownerUID: uid, localCourseId: "7B3C1D2E-4F5A-4B6C-8D7E-9F0A1B2C3D4E", classDocId: nil, year: 2026, semester: "fall", dayID: 20261022)
        let a = try question("この回1"), b = try question("この回2")
        try reply(to: a)
        let otherMessage = AIChatSnapshot(id: UUID().uuidString, context: other, kind: "question", text: "別の回", sourceIDs: [], createdAt: Date())
        try store.submit(context: other, snapshots: [otherMessage])
        try store.deleteAllMessages(context: context)
        XCTAssertEqual(store.ledger.messages.map(\.text), ["別の回"], "別の回のチャットは、消さない")
        XCTAssertNil(store.reply(afterMessageID: a.id)); _ = b
    }

    func testDeletingUnknownOrEmptyIdsDoesNothing() throws {
        let a = try question("A")
        try store.deleteMessages(ids: [])
        try store.deleteMessages(ids: ["nope"])
        XCTAssertEqual(store.ledger.messages.map(\.id), [a.id])
    }
}
