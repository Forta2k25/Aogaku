import Foundation
import CryptoKit

/// All mutations are serialized on the main actor. Media is stored separately from the atomic ledger.
@MainActor
final class LocalSourceStore {
    struct Ledger: Codable {
        var schemaVersion = 1
        var sources: [AIStoredSource] = []
        var messages: [AIChatSnapshot] = []
        var offeringBindings: [String: AICourseSnapshot]? = nil
    }
    private let root: URL
    private let uid: String
    private let base: URL
    private var erased = false
    private(set) var ledger: Ledger

    init(uid: String, baseURL: URL? = nil) throws {
        self.uid = uid
        let userKey = SHA256.hash(data: Data(uid.utf8)).map { String(format: "%02x", $0) }.joined()
        let base = try baseURL ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        self.base = base
        guard !FileManager.default.fileExists(atPath: Self.deletionMarker(uid: uid, base: base).path) else {
            throw AIInputError.message("削除したアカウントの資料は復元できません")
        }
        root = base.appendingPathComponent("AIInput/\(userKey)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = root.appendingPathComponent("ledger.json")
        if FileManager.default.fileExists(atPath: index.path) {
            ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: index))
            guard ledger.schemaVersion == 1 else { throw AIInputError.message("保存データの形式を確認してください") }
        } else { ledger = Ledger() }
        // A killed upload is retried with the same receipt; never reattribute another user's data.
        for i in ledger.sources.indices where ledger.sources[i].localState == "uploading" { ledger.sources[i].localState = "queued" }
        let referenced = Set(ledger.sources.compactMap(\.fileName))
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        where ["jpg", "m4a", "pdf"].contains(file.pathExtension) && !referenced.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
    private func commit(_ value: Ledger) throws {
        try requireActive()
        let data = try JSONEncoder().encode(value)
        try data.write(to: root.appendingPathComponent("ledger.json"), options: .atomic)
        ledger = value
    }
    func fileURL(_ source: AIStoredSource) -> URL? {
        guard !erased else { return nil }
        guard let name = source.fileName else { return nil }
        return root.appendingPathComponent(name)
    }
    func stage(context: AIInputContext, kind: AISourceKind, title: String, mime: String,
               data: Data? = nil, fileURL: URL? = nil, text: String? = nil, duration: TimeInterval? = nil) throws -> AIStoredSource {
        try requireActive()
        guard context.ownerUID == uid else { throw AIInputError.message("アカウントが変わりました。画面を開き直してください") }
        let contents = try data ?? fileURL.map { try Data(contentsOf: $0, options: .mappedIfSafe) } ?? Data((text ?? "").utf8)
        let maximum = kind == .audio ? 100 * 1024 * 1024 : kind == .pdf ? 20 * 1024 * 1024 : kind == .image ? 10 * 1024 * 1024 : 80000
        guard !contents.isEmpty, contents.count <= maximum else { throw AIInputError.message("資料のサイズが上限を超えているか、内容が空です") }
        if kind == .note, (text ?? "").utf16.count > 20000 { throw AIInputError.message("メモは2万文字以内にしてください") }
        if kind == .audio, !(1...5400).contains(duration ?? 0) { throw AIInputError.message("録音は1秒以上90分以内にしてください") }
        let checksum = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        if let existing = ledger.sources.first(where: { !$0.submitted && !$0.wantsDeletion && $0.context == context && $0.checksum == checksum && $0.kind == kind }) { return existing }
        let identifier = UUID().uuidString
        let ext = kind == .image ? "jpg" : kind == .audio ? "m4a" : "pdf"
        let name = kind == .note ? nil : "\(identifier).\(ext)"
        if let name { try contents.write(to: root.appendingPathComponent(name), options: .atomic) }
        let source = AIStoredSource(id: identifier, context: context, kind: kind, title: String(title.prefix(200)), mime: mime,
                                    byteCount: contents.count, durationSeconds: duration.map { Int(ceil($0)) }, text: text,
                                    fileName: name, checksum: checksum, createdAt: Date(), submitted: false, localState: "draft", courseSnapshot: context.snapshot)
        var value = ledger; value.sources.append(source)
        do { try commit(value) } catch { if let name { try? FileManager.default.removeItem(at: root.appendingPathComponent(name)) }; throw error }
        return source
    }
    func update(_ source: AIStoredSource) throws {
        guard source.context.ownerUID == uid, let i = ledger.sources.firstIndex(where: { $0.id == source.id }) else { throw AIInputError.message("保存した資料が見つかりません") }
        guard source.context == ledger.sources[i].context, source.courseSnapshot == ledger.sources[i].courseSnapshot else {
            throw AIInputError.message("資料保存時の授業情報は変更できません")
        }
        var value = ledger; value.sources[i] = source; try commit(value)
    }
    func submit(context: AIInputContext, snapshots: [AIChatSnapshot], replacingFrom messageID: String? = nil) throws {
        guard context.ownerUID == uid, snapshots.allSatisfy({ sameSession($0.context, context) }) else { throw AIInputError.message("保存先が一致しません") }
        var value = ledger
        if let messageID, let start = value.messages.firstIndex(where: { $0.id == messageID && sameSession($0.context, context) }) {
            for i in start..<value.messages.count where sameSession(value.messages[i].context, context) { value.messages[i].hidden = true }
        }
        for sourceID in snapshots.flatMap(\.sourceIDs) {
            guard let i = value.sources.firstIndex(where: { $0.id == sourceID && sameSession($0.context, context) && !$0.wantsDeletion }) else { throw AIInputError.message("添付資料が見つかりません") }
            if !value.sources[i].submitted { value.sources[i].submitted = true; value.sources[i].localState = "queued" }
        }
        value.messages.append(contentsOf: snapshots); try commit(value)
    }
    func discard(_ sourceID: String) throws {
        guard let source = ledger.sources.first(where: { $0.id == sourceID }) else { return }
        var value = ledger; value.sources.removeAll { $0.id == sourceID }
        try commit(value)
        if let url = fileURL(source) { try? FileManager.default.removeItem(at: url) }
    }
    func retainDraftPhotos(context: AIInputContext, photos: [Data]) throws {
        let keep = Set(photos.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() })
        let removed = ledger.sources.filter { $0.context == context && $0.kind == .image && !$0.submitted && !keep.contains($0.checksum) }
        var value = ledger; let ids = Set(removed.map(\.id)); value.sources.removeAll { ids.contains($0.id) }
        try commit(value)
        for source in removed { if let url = fileURL(source) { try? FileManager.default.removeItem(at: url) } }
    }
    func sources(context: AIInputContext, includeOtherDays: Bool = false) -> [AIStoredSource] {
        ledger.sources.filter {
            let sameLocalCourse = context.localCourseUUID != nil && $0.context.localCourseUUID == context.localCourseUUID &&
                $0.context.snapshot?.year == context.snapshot?.year
            return (contextForInput($0.context).courseKey == contextForInput(context).courseKey || sameLocalCourse) &&
                (includeOtherDays || ($0.context.dayID == context.dayID && $0.context.semester == context.semester))
        }
    }
    private func bindingKey(_ context: AIInputContext) -> String? {
        context.localCourseUUID.map { $0 + ":" + (context.snapshot?.year.map(String.init) ?? "unresolved") }
    }
    func rememberBinding(context: AIInputContext, snapshot: AICourseSnapshot) throws {
        guard context.ownerUID == uid, let key = bindingKey(context) else { return }
        var value = ledger
        var bindings = value.offeringBindings ?? [:]
        if let existing = bindings[key], existing.courseOfferingId != snapshot.courseOfferingId {
            throw AIInputError.message("この授業は既に別の授業IDへ紐付けられています")
        }
        bindings[key] = snapshot; value.offeringBindings = bindings; try commit(value)
    }
    func contextForInput(_ original: AIInputContext) -> AIInputContext {
        guard original.ownerUID == uid, let key = bindingKey(original), let snapshot = ledger.offeringBindings?[key] else { return original }
        return AIInputContext(ownerUID: uid, localCourseId: snapshot.localCourseUUID, classDocId: snapshot.classDocId,
                              year: snapshot.year, semester: original.semester, dayID: original.dayID,
                              localCourseUUID: snapshot.localCourseUUID, syllabusUrl: snapshot.syllabusUrl,
                              courseName: snapshot.courseName, teacherName: snapshot.teacherName)
    }
    func messages(context: AIInputContext) -> [AIChatSnapshot] {
        ledger.messages.filter { sameSession($0.context, context) && !$0.hidden }
    }
    private func sameSession(_ a: AIInputContext, _ b: AIInputContext) -> Bool {
        a.ownerUID == b.ownerUID && contextForInput(a).courseKey == contextForInput(b).courseKey &&
            a.dayID == b.dayID && a.semester == b.semester
    }
    private static func deletionMarker(uid: String, base: URL) -> URL {
        let key = SHA256.hash(data: Data(uid.utf8)).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("AIInput/deleted-\(key)")
    }
    private func requireActive() throws {
        guard !erased, !FileManager.default.fileExists(atPath: Self.deletionMarker(uid: uid, base: base).path) else {
            throw AIInputError.message("削除したアカウントへ資料を保存できません")
        }
    }
    /// Retained store references and delayed upload callbacks cannot recreate the ledger.
    func eraseAccount() throws {
        erased = true
        ledger = Ledger()
        try Self.eraseAccount(uid: uid, baseURL: base)
    }
    static func eraseAccount(uid: String, baseURL: URL? = nil) throws {
        let base = try baseURL ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let marker = deletionMarker(uid: uid, base: base)
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("deleted".utf8).write(to: marker, options: .atomic)
        let key = SHA256.hash(data: Data(uid.utf8)).map { String(format: "%02x", $0) }.joined()
        let root = base.appendingPathComponent("AIInput/\(key)", isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
}
