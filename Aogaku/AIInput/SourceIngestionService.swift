import Foundation
import FirebaseAuth
import FirebaseFunctions
import FirebaseCore

extension Notification.Name { static let aiSourcesChanged = Notification.Name("aiSourcesChanged") }

@MainActor
final class SourceIngestionService {
    static let shared = SourceIngestionService()
    private var stores: [String: LocalSourceStore] = [:]
    private var running: Set<String> = []
    private var activeSourceIDs: [String: String] = [:]
    private lazy var functions = Functions.functions(region: "asia-northeast1")

    func store(uid: String) throws -> LocalSourceStore {
        if let store = stores[uid] { return store }
        let store = try LocalSourceStore(uid: uid); stores[uid] = store; return store
    }
    private func checkUser(_ uid: String) throws {
        guard AppBackend.currentUID == uid else { throw AIInputError.message("ログイン中のアカウントを確認してください") }
    }
    func call(_ name: String, data: [String: Any], uid: String) async throws -> [String: Any] {
        try checkUser(uid)
        if AppBackend.isOffline { throw AIInputError.message("ローカル確認モードではクラウド通信を行いません") }
        let result: HTTPSCallableResult
        do { result = try await functions.httpsCallable(name).call(data) }
        catch {
            let details = (error as NSError).userInfo[FunctionsErrorDetailsKey] as? [String: Any]
            switch details?["code"] as? String {
            case "MEMBERSHIP_NOT_VERIFIED": throw AIInputError.message("この授業の参加確認が必要です。今は自分のみで利用できます")
            case "QUOTA_EXCEEDED": throw AIInputError.message("資料の利用上限に達しました。時間を置いて再試行してください")
            case "RETRY_LIMIT", "RAW_EXPIRED": throw AIInputError.message("この資料の再試行期限または回数を超えました。資料を追加し直してください")
            case "SOURCE_DELETED": throw AIInputError.message("この資料は削除済みです")
            case "CLASS_NOT_FOUND": throw AIInputError.message("授業の情報を確認できませんでした。授業を開き直してください")
            default: throw error
            }
        }
        try checkUser(uid)
        guard let object = result.data as? [String: Any] else { throw AIInputError.message("サーバーの応答を読み取れませんでした") }
        return object
    }
    private func decode(_ value: [String: Any]) throws -> AIRemoteSource {
        try JSONDecoder().decode(AIRemoteSource.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func resume(uid: String) {
        guard !AppBackend.isOffline, !running.contains(uid), AppBackend.currentUID == uid else { return }
        running.insert(uid)
        Task {
            defer { running.remove(uid); notify() }
            do {
                let store = try store(uid: uid)
                // Take one item at a time; foreground returns/retries can safely call resume again.
                var processed: Set<String> = []
                while let item = store.ledger.sources.first(where: { !processed.contains($0.id) && ($0.wantsDeletion || ($0.submitted && $0.localState == "queued")) }) {
                    processed.insert(item.id)
                    activeSourceIDs[uid] = item.id
                    defer { activeSourceIDs[uid] = nil }
                    do {
                        try checkUser(uid)
                        if item.wantsDeletion { try await finishDelete(item, store: store); continue }
                        try await upload(item, store: store)
                    } catch {
                        if var latest = store.ledger.sources.first(where: { $0.id == item.id }) {
                            latest.localState = "failed"; latest.lastError = error.localizedDescription
                            try store.update(latest); notify()
                        }
                    }
                }
            } catch { notify() }
        }
    }
    private func upload(_ item: AIStoredSource, store: LocalSourceStore) async throws {
        var source = item
        source.localState = "uploading"; source.lastError = nil; try store.update(source); notify()
        let response = try await call("aiCreateSource", data: source.createRequest, uid: source.context.ownerUID)
        source.remote = try decode(response)
        source.wantsDeletion = store.ledger.sources.first { $0.id == source.id }?.wantsDeletion ?? true
        try store.update(source)
        if source.wantsDeletion { try await finishDelete(source, store: store); return }
        if let upload = response["upload"] as? [String: Any], let address = upload["url"] as? String, let url = URL(string: address) {
            guard let bucket = FirebaseApp.app()?.options.storageBucket,
                  url.scheme == "https",
                  (url.host == "storage.googleapis.com" && url.path.hasPrefix("/\(bucket)/")) || url.host == "\(bucket).storage.googleapis.com" else {
                throw AIInputError.message("アップロード先が現在のFirebase環境と一致しません")
            }
            guard let file = store.fileURL(source) else { throw AIInputError.message("送信するファイルが見つかりません") }
            var request = URLRequest(url: url); request.httpMethod = "PUT"; request.timeoutInterval = 180
            for (name, value) in upload["headers"] as? [String: String] ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
            try checkUser(source.context.ownerUID)
            let (_, result) = try await URLSession.shared.upload(for: request, fromFile: file)
            guard let http = result as? HTTPURLResponse, (200..<300).contains(http.statusCode) || http.statusCode == 412 else { throw AIInputError.message("送信が中断されました。再試行できます") }
        }
        try checkUser(source.context.ownerUID)
        if let latest = store.ledger.sources.first(where: { $0.id == source.id }), latest.wantsDeletion {
            try await finishDelete(latest, store: store); return
        }
        let complete = try await call("aiCompleteSource", data: ["sourceId": source.remote!.sourceId], uid: source.context.ownerUID)
        source.remote = try decode(complete); source.localState = "uploaded"
        source.wantsDeletion = store.ledger.sources.first { $0.id == source.id }?.wantsDeletion ?? true
        try store.update(source)
        if source.wantsDeletion { try await finishDelete(source, store: store) }
        notify()
    }
    func refresh(uid: String) async {
        guard !AppBackend.isOffline else { return }
        guard let store = try? store(uid: uid) else { return }
        for item in store.ledger.sources where item.submitted && !item.wantsDeletion && item.localState == "uploaded" {
            guard let remote = item.remote, !["ready", "deleted"].contains(remote.status) else { continue }
            do {
                let status = try decode(await call("aiGetSource", data: ["sourceId": remote.sourceId], uid: uid))
                guard var latest = store.ledger.sources.first(where: { $0.id == item.id }), !latest.wantsDeletion else { continue }
                latest.remote = status; try store.update(latest)
            } catch { /* The last known state remains visible during an outage. */ }
        }
        notify()
    }
    func retry(_ item: AIStoredSource) async throws {
        let store = try store(uid: item.context.ownerUID)
        guard var source = store.ledger.sources.first(where: { $0.id == item.id }), !source.wantsDeletion else { return }
        try checkUser(item.context.ownerUID)
        if AppBackend.isOffline {
            source.localState = "queued"; source.lastError = nil; source.remote = nil
            try store.update(source); notify(); return
        }
        if let remote = source.remote, ["failed", "partial_ready"].contains(remote.status) {
            source.remote = try decode(await call("aiRetrySource", data: ["sourceId": remote.sourceId], uid: item.context.ownerUID))
            source.localState = "uploaded"
        } else { source.localState = "queued" }
        source.lastError = nil; try store.update(source); notify(); resume(uid: item.context.ownerUID)
    }
    func delete(_ item: AIStoredSource) async throws {
        try checkUser(item.context.ownerUID)
        let store = try store(uid: item.context.ownerUID)
        var source = store.ledger.sources.first { $0.id == item.id } ?? item
        source.wantsDeletion = true; try store.update(source); notify()
        // Never discard the receipt while upload/creation may still be in flight.
        if activeSourceIDs[item.context.ownerUID] == item.id { return }
        try await finishDelete(source, store: store)
    }
    private func finishDelete(_ source: AIStoredSource, store: LocalSourceStore) async throws {
        if AppBackend.isOffline { try store.discard(source.id); notify(); return }
        if let remote = source.remote { _ = try await call("aiDeleteSource", data: ["sourceId": remote.sourceId], uid: source.context.ownerUID) }
        else if source.submitted {
            // Resolve the idempotent receipt when a create response was lost.
            let response = try await call("aiCreateSource", data: source.createRequest, uid: source.context.ownerUID)
            let remote = try decode(response)
            _ = try await call("aiDeleteSource", data: ["sourceId": remote.sourceId], uid: source.context.ownerUID)
        }
        try store.discard(source.id); notify()
    }
    func setShared(_ item: AIStoredSource, shared: Bool) async throws {
        try checkUser(item.context.ownerUID)
        if AppBackend.isOffline {
            let store = try store(uid: item.context.ownerUID)
            guard var latest = store.ledger.sources.first(where: { $0.id == item.id }), let remote = latest.remote else { return }
            latest.remote = AIRemoteSource(sourceId: remote.sourceId, sourceType: remote.sourceType, title: remote.title,
                courseOfferingId: remote.courseOfferingId, lectureId: remote.lectureId, dayID: remote.dayID, status: remote.status,
                coverage: remote.coverage, error: remote.error, rawVisibility: "private", knowledgeVisibility: shared ? "course" : "private")
            try store.update(latest); notify(); return
        }
        guard let remote = item.remote else { throw AIInputError.message("送信完了後に変更してください") }
        let result = try await call("aiUpdateSource", data: ["sourceId": remote.sourceId, "knowledgeVisibility": shared ? "course" : "private"], uid: item.context.ownerUID)
        let store = try store(uid: item.context.ownerUID)
        guard var latest = store.ledger.sources.first(where: { $0.id == item.id }) else { return }
        latest.remote = try decode(result); try store.update(latest); notify()
    }
    func retrieveContext(uid: String, courseOfferingId: String, lectureIds: [String], query: String, purpose: String = "question", after: String? = nil) async throws -> [String: Any] {
        var data: [String: Any] = ["courseOfferingId": courseOfferingId, "lectureIds": lectureIds, "query": query, "purpose": purpose, "maxCharacters": 12000]
        if let after { data["after"] = after }
        return try await call("aiRetrieveContext", data: data, uid: uid)
    }
    private func notify() { NotificationCenter.default.post(name: .aiSourcesChanged, object: nil) }
}
