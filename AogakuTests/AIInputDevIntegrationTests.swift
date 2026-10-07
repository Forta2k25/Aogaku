import XCTest
import UIKit
import FirebaseCore
import FirebaseAuth
@testable import Aogaku

/// Opt-in real Dev tests of the iOS ingestion service. No UI taps, production config, or real personal media.
final class AIInputDevIntegrationTests: XCTestCase {
    @MainActor func testDeletionPausesErasesAndRejectsDelayedStoreWrites() throws {
        let uid = "local-deletion-" + UUID().uuidString
        let otherUID = "local-survivor-" + UUID().uuidString
        let service = SourceIngestionService()
        let store = try service.store(uid: uid)
        let otherStore = try service.store(uid: otherUID)
        let context = AIInputContext(ownerUID: uid, localCourseId: "local", classDocId: nil, year: 2026, semester: "fall", dayID: 20730, localCourseUUID: UUID().uuidString)
        let source = try store.stage(context: context, kind: .image, title: "削除確認", mime: "image/jpeg", data: Data([1, 2, 3]))
        let file = try XCTUnwrap(store.fileURL(source))
        try store.submit(context: context, snapshots: [AIChatSnapshot(id: UUID().uuidString, context: context, kind: "image", text: "消去する会話", sourceIDs: [source.id], createdAt: Date())])
        service.pauseForAccountDeletion(uid: uid)
        XCTAssertThrowsError(try service.store(uid: uid))
        // A failed Auth deletion must keep the user's local documents recoverable.
        service.cancelAccountDeletion(uid: uid)
        XCTAssertEqual(try service.store(uid: uid).ledger.sources.count, 1)
        try service.eraseDeletedAccount(uid: uid)
        XCTAssertTrue(store.ledger.sources.isEmpty)
        XCTAssertTrue(store.ledger.messages.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertThrowsError(try store.update(source))
        XCTAssertThrowsError(try store.stage(context: context, kind: .note, title: "遅延", mime: "text/plain", text: "再保存不可"))
        XCTAssertThrowsError(try LocalSourceStore(uid: uid))
        XCTAssertTrue(try service.store(uid: otherUID) === otherStore)
        try service.eraseDeletedAccount(uid: otherUID)
    }
    struct Fixture: Decodable {
        let projectId: String
        let email: String
        let password: String
        let uid: String
        let context: Context
        struct Context: Decodable { let classDocId: String; let localCourseId: String; let year: Int; let semester: String; let dayID: Int; let localCourseUUID: String; let syllabusUrl: String; let courseName: String; let teacherName: String }
    }

    @MainActor func testCourseUUIDAndSavedYearSnapshot() throws {
        let a = Course(id: "#####", title: "授業A", room: "", teacher: "教員A", credits: nil, campus: nil, category: nil, syllabusURL: nil, term: nil)
        let b = Course(id: "#####", title: "授業B", room: "", teacher: "教員B", credits: nil, campus: nil, category: nil, syllabusURL: nil, term: nil)
        XCTAssertNotEqual(a.localCourseUUID, b.localCourseUUID)
        let restored = try JSONDecoder().decode(Course.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(restored.localCourseUUID, a.localCourseUUID)
        let term = TermKey(year: 2099, semester: .fall)
        defer { UserDefaults.standard.removeObject(forKey: term.storageKey) }
        let legacy = try JSONSerialization.data(withJSONObject: [
            ["id": "#####", "title": "旧形式A", "room": "", "teacher": "教員A"],
            ["id": "#####", "title": "旧形式B", "room": "", "teacher": "教員B"]
        ])
        UserDefaults.standard.set(legacy, forKey: term.storageKey)
        let migrated = TermStore.loadAssigned(for: term)
        XCTAssertEqual(migrated.count, 2)
        XCTAssertNotNil(migrated.first?.localCourseUUID)
        XCTAssertNotEqual(migrated[0].localCourseUUID, migrated[1].localCourseUUID)
        XCTAssertEqual(TermStore.loadAssigned(for: term).map(\.localCourseUUID), migrated.map(\.localCourseUUID))
    }

    @MainActor func testDevAuthDeletionUsesClientCleanupAndPreventsLocalResurrection() async throws {
        guard ProcessInfo.processInfo.environment["AOGAKU_RUN_DEV_E2E"] == "1" else { throw XCTSkip("Dev E2E is opt-in") }
        guard !AppBackend.isOffline, FirebaseApp.app()?.options.projectID == "forta-aogaku-dev" else { throw AIInputError.message("Dev project required") }
        let bundle = Bundle(for: Self.self)
        let credentialURL = try XCTUnwrap(bundle.url(forResource: "dev-e2e-credentials", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: credentialURL))
        guard fixture.projectId == "forta-aogaku-dev" else { throw AIInputError.message("Dev fixture required") }
        let user = try await Auth.auth().createUser(withEmail: "client-delete-\(UUID().uuidString)@example.test", password: UUID().uuidString).user
        XCTAssertNotEqual(user.uid, fixture.uid)
        let uid = user.uid
        do {
            let service = SourceIngestionService.shared
            let store = try service.store(uid: uid)
            let context = AIInputContext(ownerUID: uid, localCourseId: "client-deletion", classDocId: nil, year: 2026, semester: "fall", dayID: 20730, localCourseUUID: UUID().uuidString)
            let photoURL = try XCTUnwrap(bundle.url(forResource: "sample-photo", withExtension: "jpg"))
            let attachment = try store.stage(context: context, kind: .image, title: "削除対象", mime: "image/jpeg", fileURL: photoURL)
            let file = try XCTUnwrap(store.fileURL(attachment))
            try store.submit(context: context, snapshots: [AIChatSnapshot(id: UUID().uuidString, context: context, kind: "image", text: "消去する会話", sourceIDs: [attachment.id], createdAt: Date())])
            var course = Course(id: "local", title: "削除確認用授業", room: "", teacher: "架空教員", credits: nil, campus: nil, category: nil, syllabusURL: nil, term: "後期")
            course.localCourseUUID = context.localCourseUUID
            let courseView = CourseDetailViewController(course: course, location: SlotLocation(day: 1, period: 1), term: TermKey(year: 2026, semester: .fall), showsAttendanceControls: false, allowsCourseManagement: false, showsEnrolledFriends: false, showsMoodleAssignments: false, showsLectureNotes: true)
            courseView.loadViewIfNeeded()
            let library = SourceLibraryViewController(context: context, allDays: true, historyOnly: true)
            library.loadViewIfNeeded()
            XCTAssertTrue(courseView.hasRetainedAIInput)
            XCTAssertTrue(library.hasRetainedSourceData)
            try await AuthManager.shared.deleteAccount(presenting: UIViewController())
            XCTAssertNil(Auth.auth().currentUser)
            XCTAssertNil(AuthManager.shared.cachedUID)
            XCTAssertTrue(store.ledger.sources.isEmpty && store.ledger.messages.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertThrowsError(try service.store(uid: uid))
            XCTAssertThrowsError(try store.update(attachment))
            XCTAssertThrowsError(try LocalSourceStore(uid: uid))
            XCTAssertFalse(courseView.hasRetainedAIInput)
            XCTAssertFalse(library.hasRetainedSourceData)
            print("PASS iOS Dev: real client Auth deletion clears files/chat/cache, retained store and restart blocked")
        } catch {
            // Clean only this test's disposable account if the assertion path failed before deletion.
            if Auth.auth().currentUser?.uid == uid { try? await user.delete() }
            _ = try? await Auth.auth().signIn(withEmail: fixture.email, password: fixture.password)
            throw error
        }
        _ = try await Auth.auth().signIn(withEmail: fixture.email, password: fixture.password)
    }

    @MainActor func testFourInputsPersistUploadAndRetrieveInDevelopment() async throws {
        guard ProcessInfo.processInfo.environment["AOGAKU_RUN_DEV_E2E"] == "1" else { throw XCTSkip("Dev E2E is opt-in") }
        XCTAssertFalse(AppBackend.isOffline)
        guard !AppBackend.isOffline else { throw XCTSkip("Development scheme is required") }
        let bundle = Bundle(for: Self.self)
        guard let file = bundle.url(forResource: "dev-e2e-credentials", withExtension: "json") else { throw XCTSkip("Prepare ignored Dev fixtures first") }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
        XCTAssertEqual(fixture.projectId, "forta-aogaku-dev")
        guard fixture.projectId == "forta-aogaku-dev" else { throw AIInputError.message("Wrong fixture project") }
        if FirebaseApp.app() == nil { try AppBackend.configureFirebase() }
        XCTAssertEqual(FirebaseApp.app()?.options.projectID, fixture.projectId)
        guard FirebaseApp.app()?.options.projectID == fixture.projectId else { throw AIInputError.message("Wrong Firebase project") }
        let auth = try await Auth.auth().signIn(withEmail: fixture.email, password: fixture.password)
        XCTAssertEqual(auth.user.uid, fixture.uid)
        guard auth.user.uid == fixture.uid else { throw AIInputError.message("Wrong test account") }
        let c = fixture.context
        let context = AIInputContext(ownerUID: fixture.uid, localCourseId: c.localCourseId, classDocId: c.classDocId, year: c.year, semester: c.semester, dayID: c.dayID, localCourseUUID: c.localCourseUUID, syllabusUrl: c.syllabusUrl, courseName: c.courseName, teacherName: c.teacherName)
        let service = SourceIngestionService.shared
        let store = try service.store(uid: fixture.uid)
        var created: [AIStoredSource] = []
        for (kind, name, ext, mime) in [(AISourceKind.image, "sample-photo", "jpg", "image/jpeg"), (.pdf, "sample-document", "pdf", "application/pdf"), (.audio, "sample-audio", "m4a", "audio/mp4")] {
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: ext))
            let source = try store.stage(context: context, kind: kind, title: "iOS Dev E2E \(kind.rawValue)", mime: mime, fileURL: url, duration: kind == .audio ? 120 : nil)
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(store.fileURL(source)).path))
            created.append(source)
        }
        created.append(try store.stage(context: context, kind: .note, title: "iOS Dev E2E note", mime: "text/plain", text: "根拠資料を保存し、出典を確認する。iOS Dev E2E用の架空メモです。"))
        let receiptIds = created.map(\.id)
        try store.submit(context: context, snapshots: [AIChatSnapshot(id: UUID().uuidString, context: context, kind: "note", text: "iOS E2E", sourceIDs: receiptIds, createdAt: Date())])
        let recovered = try LocalSourceStore(uid: fixture.uid)
        XCTAssertTrue(Set(receiptIds).isSubset(of: Set(recovered.ledger.sources.map(\.id))))
        service.resume(uid: fixture.uid)
        var retryCounts: [String: Int] = [:]
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            service.resume(uid: fixture.uid)
            await service.refresh(uid: fixture.uid)
            let current = store.ledger.sources.filter { receiptIds.contains($0.id) }
            if let failure = current.first(where: { $0.localState == "failed" || $0.remote?.status == "failed" }) {
                // Real upload response loss must recover through the same UI retry path/receipt.
                if failure.localState == "failed", failure.remote?.status == "awaiting_upload",
                   retryCounts[failure.id, default: 0] < 2 {
                    retryCounts[failure.id, default: 0] += 1
                    let remoteID = failure.remote?.sourceId
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    try await service.retry(failure)
                    XCTAssertEqual(store.ledger.sources.first(where: { $0.id == failure.id })?.remote?.sourceId, remoteID)
                    print("RETRY iOS Dev upload: same durable receipt")
                    continue
                }
                XCTFail("\(failure.kind.rawValue): \(failure.lastError ?? failure.remote?.error?.code ?? "failed")")
                return
            }
            if current.count == 4 && current.allSatisfy({ $0.remote?.status == "ready" }) { break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let current = store.ledger.sources.filter { receiptIds.contains($0.id) }
        XCTAssertEqual(current.count, 4)
        XCTAssertTrue(current.allSatisfy { $0.remote?.status == "ready" }, "All four iOS uploads must finish")
        for source in current {
            let remote = try XCTUnwrap(source.remote)
            let evidence = try await service.call("aiGetEvidence", data: ["sourceId": remote.sourceId], uid: fixture.uid)
            let items = try XCTUnwrap(evidence["items"] as? [[String: Any]])
            XCTAssertFalse(items.isEmpty)
            XCTAssertTrue(items.allSatisfy { $0["locator"] != nil })
        }
        let remote = try XCTUnwrap(current.first?.remote)
        let expected = Set(current.compactMap { $0.remote?.sourceId })
        var request: [String: Any] = ["courseOfferingId": remote.courseOfferingId, "purpose": "lecture_summary", "maxCharacters": 30000]
        var found = Set<String>()
        var cursors = Set<String>()
        // Retained Dev fixtures can span several source pages; all four new sources must be found.
        while true {
            let result = try await service.call("aiRetrieveContext", data: request, uid: fixture.uid)
            let items = try XCTUnwrap(result["items"] as? [[String: Any]])
            found.formUnion(items.compactMap { $0["sourceId"] as? String })
            if expected.isSubset(of: found) { break }
            guard let cursor = result["nextCursor"] as? String else { break }
            XCTAssertTrue(cursors.insert(cursor).inserted, "Retrieval cursor must advance")
            guard cursors.count <= 100 else { XCTFail("Retrieval exceeded 100 pages"); break }
            request["after"] = cursor
        }
        XCTAssertTrue(expected.isSubset(of: found))
        print("PASS iOS Dev: four real ingestion uploads, durable receipts, evidence locators, retrieval")
    }
}
