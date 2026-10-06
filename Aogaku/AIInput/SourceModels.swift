import Foundation
import CryptoKit

struct AIInputContext: Codable, Equatable {
    let ownerUID: String
    let localCourseId: String
    let classDocId: String?
    let year: Int
    let semester: String
    let dayID: Int

    var courseKey: String {
        let data = try! JSONEncoder().encode([ownerUID, classDocId ?? localCourseId, String(year), semester])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    var request: [String: Any] {
        var result: [String: Any] = ["localCourseId": localCourseId, "year": year, "semester": semester,
                                   "dayID": dayID, "occurrenceKey": "default"]
        if let classDocId, !classDocId.isEmpty { result["classDocId"] = classDocId }
        return result
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
