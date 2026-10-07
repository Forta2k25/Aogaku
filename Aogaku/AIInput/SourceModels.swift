import Foundation
import CryptoKit

struct AICourseSnapshot: Codable, Equatable {
    let courseOfferingId: String
    let classDocId: String?
    let year: Int?
    let semester: String
    let syllabusUrl: String?
    let courseName: String
    let teacherName: String
    let localCourseUUID: String
    let resolution: String
    let yearSource: String
}

/// Only YR or an explicit timetable year determines the academic year. Never Date().
struct AIInputContext: Codable, Equatable {
    let ownerUID: String
    let localCourseId: String // legacy receipts retain their original field exactly
    let classDocId: String?
    let year: Int?
    let semester: String
    let dayID: Int
    let localCourseUUID: String?
    let syllabusUrl: String?
    let courseName: String?
    let teacherName: String?

    init(ownerUID: String, localCourseId: String, classDocId: String?, year: Int?, semester: String, dayID: Int,
         localCourseUUID: String? = nil, syllabusUrl: String? = nil, courseName: String = "", teacherName: String = "") {
        self.ownerUID = ownerUID
        let uuid = localCourseUUID.flatMap(UUID.init(uuidString:)) ?? UUID(uuidString: localCourseId) ?? UUID()
        self.localCourseUUID = uuid.uuidString.lowercased()
        self.localCourseId = uuid.uuidString.lowercased()
        self.classDocId = classDocId
        self.year = year
        self.semester = semester
        self.dayID = dayID
        self.syllabusUrl = syllabusUrl
        self.courseName = courseName
        self.teacherName = teacherName
    }
    static func syllabusYear(_ value: String?) -> Int? {
        guard let value, let components = URLComponents(string: value),
              ["http", "https"].contains(components.scheme ?? "") else { return nil }
        let years = (components.queryItems ?? []).filter { $0.name == "YR" }
        guard years.count == 1, let raw = years[0].value, raw.range(of: #"^[0-9]{4}$"#, options: .regularExpression) != nil,
              let year = Int(raw), (2000...2100).contains(year) else { return nil }
        return year
    }
    var snapshot: AICourseSnapshot? {
        guard let localCourseUUID else { return nil } // legacy data is read, never guessed/migrated
        let urlYear = Self.syllabusYear(syllabusUrl)
        let resolvedYear = urlYear ?? year
        let validClass = classDocId?.range(of: #"^[0-9]{5}$"#, options: .regularExpression) != nil
        let canonical = validClass && resolvedYear != nil
        let offering = canonical ? "\(resolvedYear!):\(classDocId!)" : "local:" + Self.hash([ownerUID, localCourseUUID.lowercased(), resolvedYear as Any?])
        return AICourseSnapshot(courseOfferingId: offering, classDocId: classDocId, year: resolvedYear,
                                semester: semester, syllabusUrl: syllabusUrl, courseName: courseName ?? "",
                                teacherName: teacherName ?? "", localCourseUUID: localCourseUUID,
                                resolution: canonical ? "canonical" : resolvedYear == nil ? "unresolved" : "local",
                                yearSource: urlYear != nil ? "syllabus" : resolvedYear != nil ? "timetable" : "unresolved")
    }
    private static func hash(_ values: [Any?]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: values.map { $0 ?? NSNull() }, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    var courseKey: String {
        if let snapshot { return Self.hash([ownerUID, snapshot.courseOfferingId]) }
        let data = try! JSONEncoder().encode([ownerUID, classDocId ?? localCourseId, year.map(String.init) ?? "", semester])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    var request: [String: Any] {
        var result: [String: Any] = ["localCourseId": localCourseId, "semester": semester,
                                   "dayID": dayID, "occurrenceKey": "default"]
        if let year { result["year"] = year }
        if let classDocId, !classDocId.isEmpty { result["classDocId"] = classDocId }
        if let localCourseUUID {
            result["localCourseUUID"] = localCourseUUID
            result["syllabusUrl"] = syllabusUrl ?? ""
            result["courseName"] = courseName ?? ""
            result["teacherName"] = teacherName ?? ""
        }
        return result
    }
}

/// Bootstrap legacy records by their storage address, not a code, title or teacher name.
/// A remote legacy revision gets a separate UUID when available; replacement courses never inherit an identity.
enum PersistentCourseIdentity {
    static func uuid(record: String, defaults: UserDefaults = .standard) -> String {
        let digest = SHA256.hash(data: Data(record.utf8)).map { String(format: "%02x", $0) }.joined()
        let key = "ai.localCourseUUID.v1." + digest
        if let saved = defaults.string(forKey: key), let uuid = UUID(uuidString: saved) { return uuid.uuidString.lowercased() }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: key)
        return value
    }
}

enum AISourceKind: String, Codable { case image, pdf, audio, note }

struct AISourceCoverage: Codable {
    let totalUnits: Int
    let processedUnits: Int
    let failedUnits: [Int]
}
struct AISourceFailure: Codable {
    let code: String
    let retryable: Bool
}
struct AIRemoteSource: Codable {
    let sourceId: String
    let sourceType: String
    let title: String
    let courseOfferingId: String
    let lectureId: String
    let dayID: Int
    let status: String
    let coverage: AISourceCoverage?
    let error: AISourceFailure?
    let rawVisibility: String
    let knowledgeVisibility: String
    var courseSnapshot: AICourseSnapshot? = nil
    var canonicalSnapshot: AICourseSnapshot? = nil
    var sharingEnabled: Bool? = nil
    var linkingEnabled: Bool? = nil
}
struct AIStoredSource: Codable, Identifiable {
    let id: String
    let context: AIInputContext
    let kind: AISourceKind
    var title: String
    let mime: String
    let byteCount: Int
    let durationSeconds: Int?
    let text: String?
    let fileName: String?
    let checksum: String
    let createdAt: Date
    var submitted: Bool
    var localState: String
    var remote: AIRemoteSource?
    var lastError: String?
    var wantsDeletion: Bool = false
    let courseSnapshot: AICourseSnapshot?

    var statusText: String {
        if wantsDeletion { return "削除待ち" }
        switch localState {
        case "draft": return "未送信"
        case "queued": return "送信待ち"
        case "uploading": return "送信中"
        case "failed": return lastError ?? "送信失敗・再試行できます"
        default:
            switch remote?.status {
            case "ready": return "AIで利用可能"
            case "partial_ready": return "一部利用可能・未処理部分あり"
            case "failed": return remote?.error?.retryable == true ? "解析に失敗しました・再試行できます" : "解析できませんでした・別の資料を追加してください"
            case "deleted", "deleting": return "削除済み"
            case "extracting": return "内容を読み取り中"
            case "indexing": return "AI用に整理中"
            default: return "解析待ち"
            }
        }
    }
    var createRequest: [String: Any] {
        var value: [String: Any] = ["clientRequestId": id, "type": kind.rawValue, "title": title,
                                   "mime": mime, "size": byteCount, "context": context.request]
        if let text { value["text"] = text }
        if let durationSeconds { value["durationSeconds"] = durationSeconds }
        return value
    }
}

struct AIChatSnapshot: Codable, Identifiable {
    let id: String
    let context: AIInputContext
    let kind: String
    let text: String?
    let sourceIDs: [String]
    let createdAt: Date
    var hidden = false
}

enum AIInputError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
