import Foundation
import FirebaseAuth
import FirebaseFunctions
import FirebaseCore

extension Notification.Name {
    static let aiSourcesChanged = Notification.Name("aiSourcesChanged")
    static let aiAccountDeleted = Notification.Name("aiAccountDeleted")
}

@MainActor
final class SourceIngestionService {
    static let shared = SourceIngestionService()
    private var stores: [String: LocalSourceStore] = [:]
    private var running: Set<String> = []
    private var activeSourceIDs: [String: String] = [:]
    private var blockedUIDs: Set<String> = []
    private var runners: [String: Task<Void, Never>] = [:]
    private var uploadSessions: [String: URLSession] = [:]
    private lazy var functions = Functions.functions(region: "asia-northeast1")

    func store(uid: String) throws -> LocalSourceStore {
        guard !blockedUIDs.contains(uid) else { throw AIInputError.message("アカウント削除中は資料を保存できません") }
        if let store = stores[uid] { return store }
        let store = try LocalSourceStore(uid: uid); stores[uid] = store; return store
    }
    private func checkUser(_ uid: String) throws {
        try Task.checkCancellation()
        guard !blockedUIDs.contains(uid), AppBackend.currentUID == uid else { throw AIInputError.message("ログイン中のアカウントを確認してください") }
    }
    func pauseForAccountDeletion(uid: String) {
        blockedUIDs.insert(uid)
        runners[uid]?.cancel()
        uploadSessions.removeValue(forKey: uid)?.invalidateAndCancel()
    }
    func cancelAccountDeletion(uid: String) { blockedUIDs.remove(uid) }
    func eraseDeletedAccount(uid: String) throws {
        pauseForAccountDeletion(uid: uid)
        defer {
            stores.removeValue(forKey: uid)
            NotificationCenter.default.post(name: .aiAccountDeleted, object: uid)
            notify()
        }
        if let existing = stores[uid] { try existing.eraseAccount() }
        else { try LocalSourceStore.eraseAccount(uid: uid) }
    }
    func call(_ name: String, data: [String: Any], uid: String) async throws -> [String: Any] {
        try checkUser(uid)
        if AppBackend.isOffline { throw AIInputError.message("ローカル確認モードではクラウド通信を行いません") }
        let result: HTTPSCallableResult
        do { result = try await functions.httpsCallable(name).call(data) }
        catch {
            let details = (error as NSError).userInfo[FunctionsErrorDetailsKey] as? [String: Any]
            switch details?["code"] as? String {
            case "SHARING_DISABLED": throw AIInputError.message("授業内共有は現在利用できません。資料は自分のみで利用できます")
            case "LINKING_DISABLED": throw AIInputError.message("授業IDの確定は現在利用できません。保存済みの資料はそのまま利用できます")
            case "AI_INPUT_NOT_ENABLED": throw AIInputError.message("AIへの資料追加は現在準備中です")
            case "ACCOUNT_DELETED", "ACCOUNT_DISABLED": throw AIInputError.message("このアカウントで資料を利用できません。ログイン状態を確認してください")
            case "MEMBERSHIP_NOT_VERIFIED": throw AIInputError.message("この授業の参加確認が必要です。今は自分のみで利用できます")
            case "RATE_LIMITED": throw AIInputError.message("短時間の利用上限に達しました。少し待って再試行してください")
            case "APP_CHECK_REQUIRED": throw AIInputError.message("アプリの確認ができませんでした。最新版で再試行してください")
            case "QUOTA_EXCEEDED", "PROVIDER_QUOTA_EXCEEDED": throw AIInputError.message("資料の利用上限に達しました。時間を置いて再試行してください")
            case "RETRY_LIMIT", "RAW_EXPIRED": throw AIInputError.message("この資料の再試行期限または回数を超えました。資料を追加し直してください")
            case "SOURCE_DELETED": throw AIInputError.message("この資料は削除済みです")
            case "CLASS_NOT_FOUND": throw AIInputError.message("授業の情報を確認できませんでした。授業を開き直してください")
            case "INVALID_CLASS": throw AIInputError.message("授業IDは先頭の0を含む5桁の数字で指定してください")
            case "CLASS_YEAR_MISMATCH": throw AIInputError.message("資料の年度と現在の授業年度が異なります。過年度の紐付けは変更しません")
            case "OFFERING_UNRESOLVED", "LOCAL_COURSE_UUID_REQUIRED": throw AIInputError.message("授業IDと年度を確認してください。未解決の資料は自分のみで利用できます")
            case "OFFERING_ALREADY_LINKED": throw AIInputError.message("この資料は既に授業へ紐付けられています")
            case "SOURCE_BUSY": throw AIInputError.message("処理が終わってから授業IDを確定してください")
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
        guard !AppBackend.isOffline, !blockedUIDs.contains(uid), !running.contains(uid), AppBackend.currentUID == uid else { return }
        running.insert(uid)
        runners[uid] = Task {
            defer { running.remove(uid); runners[uid] = nil; notify() }
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
        let readyImage = source.kind == .image && ["ready", "partial_ready"].contains(source.remote?.status ?? "")
        if source.kind == .image && !readyImage {
            // Check BEFORE create/upload: old production APIs silently ignore new client fields.
            let capabilities = try await call("aiListSources", data: ["context": source.context.request, "onlyLecture": true], uid: source.context.ownerUID)
            try AIImagePipeline.requireCapability(capabilities)
        }
        let response = try await call("aiCreateSource", data: source.createRequest, uid: source.context.ownerUID)
        source.remote = try decode(response)
        if source.kind == .image && !readyImage { try AIImagePipeline.requireReceipt(source.remote!) }
        source.wantsDeletion = store.ledger.sources.first { $0.id == source.id }?.wantsDeletion ?? true
        try store.update(source)
        if source.wantsDeletion { try await finishDelete(source, store: store); return }
        var transferMs: Double?
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
            let session = uploadSessions[source.context.ownerUID] ?? URLSession(configuration: .default)
            uploadSessions[source.context.ownerUID] = session
            let transferStarted = Date()
            let (_, result) = try await session.upload(for: request, fromFile: file)
            try checkUser(source.context.ownerUID)
            guard let http = result as? HTTPURLResponse, (200..<300).contains(http.statusCode) || http.statusCode == 412 else { throw AIInputError.message("送信が中断されました。再試行できます") }
            if (200..<300).contains(http.statusCode) { transferMs = Date().timeIntervalSince(transferStarted) * 1000 }
        }
        try checkUser(source.context.ownerUID)
        if let latest = store.ledger.sources.first(where: { $0.id == source.id }), latest.wantsDeletion {
            try await finishDelete(latest, store: store); return
        }
        var completeData: [String: Any] = ["sourceId": source.remote!.sourceId]
        if let transferMs { completeData["uploadMs"] = transferMs }
        let complete = try await call("aiCompleteSource", data: completeData, uid: source.context.ownerUID)
        source.remote = try decode(complete); source.localState = "uploaded"
        source.wantsDeletion = store.ledger.sources.first { $0.id == source.id }?.wantsDeletion ?? true
        try store.update(source)
        if source.wantsDeletion { try await finishDelete(source, store: store) }
        notify()
    }
    func refreshSource(localID: String, uid: String) async {
        guard !AppBackend.isOffline, let store = try? store(uid: uid),
              let item = store.ledger.sources.first(where: { $0.id == localID }), !item.wantsDeletion, let remote = item.remote else { return }
        do {
            let response = try decode(await call("aiGetSource", data: ["sourceId": remote.sourceId], uid: uid))
            guard var latest = store.ledger.sources.first(where: { $0.id == localID }), !latest.wantsDeletion else { return }
            latest.remote = response; try store.update(latest); notify()
        } catch { /* Keep the durable previous status during network interruption. */ }
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
    func detectionResult(sourceId: String, uid: String, preview: Bool = false) async throws -> AIDetectionResult {
        let baseline = try decode(await call("aiGetSource", data: ["sourceId": sourceId], uid: uid))
        var chunks: [AIEvidenceChunk] = [], cursor: String?, page: AIEvidencePage?
        var routingPages: [AIVisualRouting.Page] = []
        var seen = Set<String>()
        repeat {
            var data: [String: Any] = ["sourceId": sourceId]
            if preview { data["preview"] = true }
            if let cursor { data["after"] = cursor }
            let value = try await call("aiGetEvidence", data: data, uid: uid)
            let current = try JSONDecoder().decode(AIEvidencePage.self, from: JSONSerialization.data(withJSONObject: value))
            if preview { guard current.preview == true, current.previewVersion == baseline.previewVersion else { throw AIInputError.message("途中結果が更新されました") } }
            routingPages += current.recognition?.routing?.pages ?? []
            if let page { guard current.activeVersion == page.activeVersion else { throw AIInputError.message("資料が更新されました。再読み込みします") } }
            if let version = current.activeVersion, version != baseline.activeVersion { throw AIInputError.message("資料が更新されました。再読み込みします") }
            page = current; chunks += current.items; cursor = current.nextCursor
            if let cursor { guard seen.insert(cursor).inserted, seen.count <= 40 else { throw AIInputError.message("資料の読み込みを完了できませんでした") } }
        } while cursor != nil
        let latest = try decode(await call("aiGetSource", data: ["sourceId": sourceId], uid: uid))
        if preview { guard latest.previewVersion == baseline.previewVersion, ["extracting", "indexing"].contains(latest.status) else { throw AIInputError.message("解析状態が更新されました") } }
        guard latest.activeVersion == baseline.activeVersion else { throw AIInputError.message("資料が更新されました。再読み込みします") }
        if preview, page?.recognition?.routing != nil { page?.recognition?.routing?.pages = routingPages }
        if latest.sourceType == "image" || latest.pipelineVersion == "pdf-auto-v1" {
            try AIImagePipeline.requireEvidence(pipelineVersion: page?.pipelineVersion ?? latest.pipelineVersion, recognition: page?.recognition ?? latest.recognition, chunks: chunks)
        }
        return AIDetectionResult(previewProgress: preview ? page?.progress : nil, latency: page?.latency ?? latest.latency, text: AIDetectionResult.cleanText(chunks, pageHeaders: latest.pipelineVersion == "pdf-auto-v1"), recognition: page?.recognition ?? latest.recognition,
            processingMs: page?.processingMs, method: page?.status == "partial_ready" && latest.sourceType == "audio" ? "partial_audio" : chunks.first?.method, pipelineVersion: page?.pipelineVersion ?? latest.pipelineVersion)
    }
    func retrieveContext(uid: String, courseOfferingId: String, lectureIds: [String], query: String, purpose: String = "question", after: String? = nil) async throws -> [String: Any] {
        var data: [String: Any] = ["courseOfferingId": courseOfferingId, "lectureIds": lectureIds, "query": query, "purpose": purpose, "maxCharacters": 12000]
        if let after { data["after"] = after }
        return try await call("aiRetrieveContext", data: data, uid: uid)
    }
    func linkOffering(_ item: AIStoredSource, classDocId: String, year: Int?) async throws {
        guard let remote = item.remote, let uuid = item.context.localCourseUUID else {
            throw AIInputError.message("送信を完了し、授業のUUIDを確認してください")
        }
        var data: [String: Any] = ["sourceId": remote.sourceId, "classDocId": classDocId,
                                   "localCourseUUID": uuid, "semester": item.context.semester]
        if let year { data["year"] = year }
        let response = try await call("aiLinkSourceOffering", data: data, uid: item.context.ownerUID)
        let store = try store(uid: item.context.ownerUID)
        guard var latest = store.ledger.sources.first(where: { $0.id == item.id }) else { return }
        latest.remote = try decode(response)
        try store.update(latest)
        if let snapshot = latest.remote?.canonicalSnapshot { try store.rememberBinding(context: item.context, snapshot: snapshot) }
        notify()
    }
    private func notify() { NotificationCenter.default.post(name: .aiSourcesChanged, object: nil) }
}
