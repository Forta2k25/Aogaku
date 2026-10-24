import Foundation
import FirebaseFirestore

/// 会話の履歴(文章だけ)を、サーバーを通して、Webなど別の端末と合わせる。
/// 写真・録音・PDFは、「送った」印(種類と枚数)だけを送る。失敗しても、会話は止めない(次の機会に、もう一度試す)。
@MainActor
final class ConversationSyncService {
    static let shared = ConversationSyncService()
    private var running: Set<String> = []
    private var lastRun: [String: Date] = [:]
    /// 授業ごとに、取り込みずみの、いちばん新しい発言の時刻(ms)。2回目からは、そこから少し戻った所以降だけを取る(通信と読み取りを減らす)。
    private var cursors: [String: Int] = [:]
    /// 授業ごとの、会話の保存先の授業ID(aiListMessages が返す)。リアルタイムの購読に使う。
    private var offerings: [String: String] = [:]
    /// 別の端末の、少し遅れて届いた発言(時計のずれ)も取りこぼさないための、戻す幅。
    private static let overlapMs = 120_000

    /// 戻り値: 別の端末の発言を、新しく取り込んだか(true なら、画面を読み直す)。
    @discardableResult
    func sync(context: AIInputContext, force: Bool = false) async -> Bool {
        let key = context.ownerUID + "|" + context.courseKey
        guard !running.contains(key), !AppBackend.isOffline, AppBackend.currentUID == context.ownerUID else { return false }
        if !force, let last = lastRun[key], Date().timeIntervalSince(last) < 2 { return false }
        running.insert(key); lastRun[key] = Date()
        defer { running.remove(key) }
        let service = SourceIngestionService.shared
        guard let store = try? service.store(uid: context.ownerUID) else { return false }
        let courseKey = context.courseKey
        do {
            // 1) サーバーの会話を取る(失敗したら、ここで終わり。何も変えない)
            var remote: [RemoteConversationRow] = []
            var cursor: Int? = cursors[key].map { max($0 - Self.overlapMs, 0) }
            var guardPages = 0
            repeat {
                var data: [String: Any] = ["context": context.request]
                if let cursor { data["after"] = cursor }
                let page = try await service.call("aiListMessages", data: data, uid: context.ownerUID)
                for item in (page["items"] as? [[String: Any]] ?? []) {
                    guard let id = item["id"] as? String, let role = item["role"] as? String, let created = (item["createdAt"] as? NSNumber)?.intValue,
                          let day = (item["dayID"] as? NSNumber)?.intValue else { continue }
                    remote.append(RemoteConversationRow(id: id, role: role, kind: item["kind"] as? String ?? "text", text: item["text"] as? String ?? "",
                                                        imageCount: (item["imageCount"] as? NSNumber)?.intValue ?? 0, dayID: day, createdAt: created))
                }
                if let offering = page["courseOfferingId"] as? String { offerings[key] = offering }
                cursor = (page["nextCursor"] as? NSNumber)?.intValue
                guardPages += 1
            } while cursor != nil && guardPages < 50
            // 2) 別の端末の発言を取り込む
            let added = try store.importConversation(context: context, remote: remote)
            // 3) こちらの未送信を送り、こちらで消したものを、サーバーからも消す
            let plan = store.conversationSyncPlan(courseKey: courseKey)
            let remoteIDs = Set(remote.map(\.id))
            let pending = plan.upload.filter { !remoteIDs.contains($0.id) }
            var uploadedIDs: [(id: String, context: AIInputContext)] = plan.upload.filter { remoteIDs.contains($0.id) }.map { ($0.id, $0.context) }
            let byDay = Dictionary(grouping: pending, by: { $0.context.dayID })
            for (_, items) in byDay {
                for start in stride(from: 0, to: items.count, by: 50) {
                    let chunk = Array(items[start..<min(start + 50, items.count)])
                    _ = try await service.call("aiSaveMessages", data: ["context": chunk[0].context.request, "messages": chunk.map(\.row)], uid: context.ownerUID)
                    uploadedIDs.append(contentsOf: chunk.map { ($0.id, $0.context) })
                }
            }
            var deletedIDs: [String] = []
            if let first = plan.deletions.first {
                for start in stride(from: 0, to: plan.deletions.count, by: 100) {
                    let ids = plan.deletions[start..<min(start + 100, plan.deletions.count)].map(\.id)
                    _ = try await service.call("aiDeleteMessages", data: ["context": first.context.request, "ids": ids], uid: context.ownerUID)
                    deletedIDs.append(contentsOf: ids)
                }
            }
            try store.markConversationSynced(uploaded: uploadedIDs, deleted: deletedIDs)
            let newest = max(remote.map(\.createdAt).max() ?? 0, plan.upload.compactMap { $0.row["createdAt"] as? Int }.max() ?? 0)
            if newest > 0 { cursors[key] = max(cursors[key] ?? 0, newest) }
            return added > 0
        } catch {
            return false   // 通信などに失敗しても、会話は続けられる
        }
    }

    /// 会話の「いちばん新しい保存」の変化だけを、リアルタイムで知る(読み取り専用。ルールで、本人だけが、自分の分を読める)。
    /// 知らせが来たら、onChange で、新しい分を取る。内容は、ここでは読まない。保存先が分かる前(最初の同期の前)は nil。
    func observe(context: AIInputContext, onChange: @escaping @MainActor () -> Void, onFailure: @escaping @MainActor () -> Void = {}) -> ListenerRegistration? {
        let key = context.ownerUID + "|" + context.courseKey
        guard !AppBackend.isOffline, AppBackend.currentUID == context.ownerUID, let offering = offerings[key] else { return nil }
        let latest = Firestore.firestore(database: "aogaku-ai").collection("aiChats").document(context.ownerUID)
            .collection("offerings").document(offering).collection("messages")
            .order(by: "updatedAt", descending: true).limit(to: 1)
        return latest.addSnapshotListener { snapshot, error in
            if error != nil { Task { @MainActor in onFailure() }; return }   // 権限などで購読できない間は、定期の確認が代わりをする
            guard let snapshot, !snapshot.metadata.hasPendingWrites else { return }
            Task { @MainActor in onChange() }
        }
    }
}
