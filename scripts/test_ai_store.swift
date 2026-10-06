import Foundation

@main
struct AIStoreTests {
    @MainActor static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let context = AIInputContext(ownerUID: "alice", localCourseId: "course-1", classDocId: nil,
                                     year: 2026, semester: "fall", dayID: 20730)
        let store = try LocalSourceStore(uid: "alice", baseURL: base)
        let image = try store.stage(context: context, kind: .image, title: "写真", mime: "image/jpeg", data: Data([1, 2, 3]))
        let same = try store.stage(context: context, kind: .image, title: "写真", mime: "image/jpeg", data: Data([1, 2, 3]))
        precondition(image.id == same.id, "Draft recovery must preserve the request ID")
        let snapshot = AIChatSnapshot(id: "message-1", context: context, kind: "image", text: nil,
                                      sourceIDs: [image.id], createdAt: Date())
        try store.submit(context: context, snapshots: [snapshot])
        var uploading = store.ledger.sources[0]; uploading.localState = "uploading"; try store.update(uploading)
        let restarted = try LocalSourceStore(uid: "alice", baseURL: base)
        precondition(restarted.ledger.sources[0].localState == "queued")
        precondition(restarted.ledger.sources[0].id == image.id)
        let recoveredBytes = try Data(contentsOf: restarted.fileURL(image)!)
        precondition(recoveredBytes == Data([1, 2, 3]))
        let bob = try LocalSourceStore(uid: "bob", baseURL: base)
        precondition(bob.ledger.sources.isEmpty, "Accounts must have separate ledgers")
        do { _ = try bob.stage(context: context, kind: .note, title: "メモ", mime: "text/plain", text: "秘密"); fatalError("Cross-account staging was allowed") }
        catch is AIInputError { }
        let edit = AIChatSnapshot(id: "message-2", context: context, kind: "question", text: "質問の修正", sourceIDs: [], createdAt: Date())
        try restarted.submit(context: context, snapshots: [edit], replacingFrom: "message-1")
        precondition(restarted.messages(context: context).map(\.id) == ["message-2"])
        precondition(restarted.ledger.sources.count == 1, "Chat edits must retain saved sources")
        var deleting = restarted.ledger.sources[0]; deleting.wantsDeletion = true; try restarted.update(deleting)
        let recovered = try LocalSourceStore(uid: "alice", baseURL: base)
        precondition(recovered.ledger.sources[0].wantsDeletion, "Deletion intent must survive restart")
        try recovered.discard(image.id)
        precondition(!FileManager.default.fileExists(atPath: recovered.fileURL(image)!.path))
        let afterDelete = try LocalSourceStore(uid: "alice", baseURL: base)
        precondition(afterDelete.ledger.sources.isEmpty)
        print("PASS: stable receipts, restart recovery, account isolation, edit preservation, durable deletion")
    }
}
