import XCTest
import FirebaseCore
import FirebaseAuth
@testable import Aogaku

/// Opt-in real Dev tests of the iOS ingestion service. No UI taps, production config, or real personal media.
final class AIInputDevIntegrationTests: XCTestCase {
    struct Fixture: Decodable {
        let projectId: String
        let email: String
        let password: String
        let uid: String
        let context: Context
        struct Context: Decodable { let classDocId: String; let localCourseId: String; let year: Int; let semester: String; let dayID: Int }
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
        let context = AIInputContext(ownerUID: fixture.uid, localCourseId: c.localCourseId, classDocId: c.classDocId, year: c.year, semester: c.semester, dayID: c.dayID)
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
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            await service.refresh(uid: fixture.uid)
            let current = store.ledger.sources.filter { receiptIds.contains($0.id) }
            if let failure = current.first(where: { $0.localState == "failed" || $0.remote?.status == "failed" }) {
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
        let result = try await service.call("aiRetrieveContext", data: ["courseOfferingId": remote.courseOfferingId, "purpose": "lecture_summary", "maxCharacters": 30000], uid: fixture.uid)
        let items = try XCTUnwrap(result["items"] as? [[String: Any]])
        let found = Set(items.compactMap { $0["sourceId"] as? String })
        XCTAssertTrue(Set(current.compactMap { $0.remote?.sourceId }).isSubset(of: found))
        print("PASS iOS Dev: four real ingestion uploads, durable receipts, evidence locators, retrieval")
    }
}
