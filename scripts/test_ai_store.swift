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
        let uuidA = "11111111-1111-4111-8111-111111111111"
        let uuidB = "22222222-2222-4222-8222-222222222222"
        let canonical = AIInputContext(ownerUID: "alice", localCourseId: "#####", classDocId: "00004", year: 2025,
                                       semester: "fall", dayID: 20730, localCourseUUID: uuidA,
                                       syllabusUrl: "https://syllabus.aoyama.ac.jp/shousai.ashx?YR=2026&FN=1611020-0004", courseName: "授業A", teacherName: "教員A")
        precondition(canonical.snapshot?.courseOfferingId == "2026:00004")
        precondition(canonical.snapshot?.yearSource == "syllabus")
        let future = AIInputContext(ownerUID: "alice", localCourseId: "#####", classDocId: "00004", year: 2027,
                                    semester: "fall", dayID: 21000, localCourseUUID: uuidA, syllabusUrl: "https://example.test/?YR=2027")
        precondition(future.courseKey != canonical.courseKey)
        let localA = AIInputContext(ownerUID: "alice", localCourseId: "#####", classDocId: nil, year: 2026,
                                    semester: "fall", dayID: 20730, localCourseUUID: uuidA)
        let localB = AIInputContext(ownerUID: "alice", localCourseId: "#####", classDocId: nil, year: 2026,
                                    semester: "fall", dayID: 20730, localCourseUUID: uuidB)
        precondition(localA.courseKey != localB.courseKey)
        precondition(localA.snapshot?.courseOfferingId == "local:4d899ca1468b8d0df3348717ea593fd7b73cc992db43487d94f6eca557b38f8b", "Swift and server UUID IDs must match")
        let unknown = AIInputContext(ownerUID: "alice", localCourseId: "", classDocId: "00004", year: nil,
                                     semester: "fall", dayID: 20730, localCourseUUID: uuidA)
        precondition(unknown.snapshot?.year == nil && unknown.snapshot?.resolution == "unresolved")
        precondition(unknown.snapshot?.courseOfferingId == "local:117c87855bf1cb1c878892e4e2f9055a5ea146a0630e29f77c6d398744b0430b")
        precondition(AIInputContext.syllabusYear("https://example.test/?YR=2026&YR=2027") == nil)
        let frozen = try recovered.stage(context: canonical, kind: .note, title: "過年度メモ", mime: "text/plain", text: "過年度の内容")
        let unchanged = try LocalSourceStore(uid: "alice", baseURL: base)
        precondition(unchanged.ledger.sources.first?.courseSnapshot == canonical.snapshot)
        precondition(unchanged.sources(context: future).isEmpty)
        precondition(unchanged.sources(context: canonical).first?.id == frozen.id)
        try unchanged.rememberBinding(context: localA, snapshot: canonical.snapshot!)
        let rebound = try LocalSourceStore(uid: "alice", baseURL: base)
        precondition(rebound.contextForInput(localA).snapshot?.courseOfferingId == "2026:00004")
        precondition(rebound.ledger.sources.first?.context.snapshot == canonical.snapshot)
        let unknownLocal = AIInputContext(ownerUID: "alice", localCourseId: uuidB, classDocId: nil, year: nil,
                                         semester: "fall", dayID: 20730, localCourseUUID: uuidB)
        let unknownSaved = try rebound.stage(context: unknownLocal, kind: .note, title: "年度未解決のメモ", mime: "text/plain", text: "未解決の内容")
        let resolvedUnknown = AIInputContext(ownerUID: "alice", localCourseId: uuidB, classDocId: "00008", year: 2026,
                                            semester: "fall", dayID: 20730, localCourseUUID: uuidB, syllabusUrl: "https://example.test/?YR=2026")
        try rebound.rememberBinding(context: unknownLocal, snapshot: resolvedUnknown.snapshot!)
        precondition(rebound.sources(context: unknownLocal).contains { $0.id == unknownSaved.id })
        precondition(rebound.contextForInput(unknownLocal).snapshot?.courseOfferingId == "2026:00008")
        let renamed = AIInputContext(ownerUID: "alice", localCourseId: uuidA, classDocId: "00004", year: 2026,
                                     semester: "fall", dayID: 20730, localCourseUUID: uuidA,
                                     syllabusUrl: canonical.syllabusUrl, courseName: "授業名の変更", teacherName: "教員名の変更")
        try rebound.submit(context: renamed, snapshots: [AIChatSnapshot(id: "snapshot-message", context: renamed, kind: "note", text: "送信", sourceIDs: [frozen.id], createdAt: Date())])
        precondition(rebound.messages(context: canonical).map(\.id) == ["snapshot-message"])
        precondition(rebound.ledger.sources.first?.courseSnapshot == canonical.snapshot, "Changing display metadata must not rewrite snapshots or detach attachments")
        let legacyJSON = try JSONSerialization.data(withJSONObject: ["ownerUID": "alice", "localCourseId": "#####", "classDocId": "old-id", "year": 2025, "semester": "fall", "dayID": 20730])
        let legacy = try JSONDecoder().decode(AIInputContext.self, from: legacyJSON)
        precondition(legacy.localCourseUUID == nil && legacy.localCourseId == "#####")
        precondition(legacy.request["localCourseUUID"] == nil)
        let defaults = UserDefaults(suiteName: "AIUUIDTest-" + UUID().uuidString)!
        let value = PersistentCourseIdentity.uuid(record: "alice|2026|slot1", defaults: defaults)
        precondition(PersistentCourseIdentity.uuid(record: "alice|2026|slot1", defaults: defaults) == value)
        precondition(PersistentCourseIdentity.uuid(record: "alice|2026|slot2", defaults: defaults) != value)
        print("PASS: annual IDs, URL priority, unresolved year, UUID separation, immutable snapshots, explicit binding persistence, legacy decoding")
        print("PASS: stable receipts, restart recovery, account isolation, edit preservation, durable deletion")
        let deletedUID = "deleted-store-test"
        let deletedContext = AIInputContext(ownerUID: deletedUID, localCourseId: "local", classDocId: nil, year: 2026, semester: "fall", dayID: 20730, localCourseUUID: "77777777-7777-4777-8777-777777777777")
        let deleted = try LocalSourceStore(uid: deletedUID, baseURL: base)
        let attachment = try deleted.stage(context: deletedContext, kind: .image, title: "消去対象", mime: "image/jpeg", data: Data([1,2,3]))
        let file = deleted.fileURL(attachment)!
        try deleted.submit(context: deletedContext, snapshots: [AIChatSnapshot(id: "erase-message", context: deletedContext, kind: "image", text: "消去対象の会話", sourceIDs: [attachment.id], createdAt: Date())])
        let retained = try LocalSourceStore(uid: deletedUID, baseURL: base)
        try deleted.eraseAccount()
        precondition(deleted.ledger.sources.isEmpty && deleted.ledger.messages.isEmpty)
        precondition(!FileManager.default.fileExists(atPath: file.path))
        do { try retained.update(attachment); fatalError("Delayed callback recreated a deleted account") } catch {}
        do { _ = try retained.stage(context: deletedContext, kind: .note, title: "遅延", mime: "text/plain", text: "復活不可"); fatalError("Deleted account staging allowed") } catch {}
        do { _ = try LocalSourceStore(uid: deletedUID, baseURL: base); fatalError("Deleted account restored") } catch {}
        let survivingAccount = try LocalSourceStore(uid: "alice", baseURL: base)
        precondition(!survivingAccount.ledger.sources.isEmpty)
        print("PASS: account erase removes media/chat/attachments, invalidates retained callbacks, blocks restart resurrection, preserves other UID")
    }
}
