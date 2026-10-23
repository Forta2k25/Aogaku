import UIKit

/// 授業時間の付近ではないときに、質問(と写真)が、どの授業のものかを、サーバーに予想してもらう。通信できないときは、授業名・先生の名前での簡単な予想にする。
@MainActor
enum QuickAskPredictor {
    struct Candidate: Equatable {
        let entry: QuickAskCourse
        let confidence: Double
        let reason: String
    }
    struct Prediction {
        /// 選んでもらうときの並び順(予想した授業が先頭)。すべての授業が入る。
        let ordered: [QuickAskCourse]
        /// サーバーが、自信をもって挙げた候補(自信の高い順、最大3つ)。通信できなかったときは、空。
        let candidates: [Candidate]
    }

    /// 授業の「ヒント」: シラバスの要約(端末に保存済みのもの)と、最近の質問。サーバーが、資料の話題から授業を当てるために使う。
    static func hint(for course: Course, recentQuestions: [String]) -> String {
        var parts: [String] = []
        let url = (course.syllabusURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let fields = SyllabusDataCache.shared.load(for: url.isEmpty ? course.id : url) {
            parts.append(String(AISyllabusSummary.make(fields: fields).replacingOccurrences(of: "\n", with: " ").prefix(300)))
        }
        let recent = recentQuestions.suffix(3).map { String($0.replacingOccurrences(of: "\n", with: " ").prefix(40)) }.filter { !$0.isEmpty }
        if !recent.isEmpty { parts.append("最近の質問: " + recent.joined(separator: " / ")) }
        return String(parts.joined(separator: " ").prefix(500))
    }

    /// サーバーに送る内容。授業は、同じ授業が複数のコマにあっても、1つにまとめる。
    static func payload(question: String, photo: CapturedPhoto?, entries: [QuickAskCourse], recentQuestions: (Course) -> [String]) -> [String: Any] {
        var seen = Set<String>()
        let courses: [[String: Any]] = entries.compactMap { entry in
            guard seen.insert(entry.course.id).inserted else { return nil }
            return ["id": entry.course.id, "name": entry.course.title, "teacher": entry.course.teacher,
                    "hint": hint(for: entry.course, recentQuestions: recentQuestions(entry.course))]
        }.prefix(12).map { $0 }
        var payload: [String: Any] = ["question": String(question.prefix(600)), "courses": courses]
        if let photo, let image = PhotoCodec.downsample(photo.jpeg, maxPixel: 768), let data = image.jpegData(compressionQuality: 0.7) {
            payload["image"] = ["mime": "image/jpeg", "data": data.base64EncodedString()]
        }
        return payload
    }

    static func rank(question: String, photo: CapturedPhoto?, entries: [QuickAskCourse], now: Date,
                     recentQuestions: (Course) -> [String],
                     transport: LiveRecordingTransport? = nil, uid: String? = AppBackend.currentUID) async -> Prediction {
        let transport = transport ?? SourceIngestionTransport()
        var predicted: [(id: String, confidence: Double)] = [], reasons: [String: String] = [:]
        if let uid, !entries.isEmpty {
            let payload = payload(question: question, photo: photo, entries: entries, recentQuestions: recentQuestions)
            if let result = try? await transport.call(task: "routeCourse", payload: payload, uid: uid),
               let ranked = result["ranked"] as? [[String: Any]] {
                for item in ranked {
                    guard let id = item["id"] as? String, let confidence = (item["confidence"] as? NSNumber)?.doubleValue else { continue }
                    predicted.append((id, confidence)); reasons[id] = item["reason"] as? String ?? ""
                }
            } else {
                // 通信できないとき: 授業名・先生の名前に、質問の言葉が含まれる授業を、先頭に。
                predicted = QuickAskRouting.localGuess(question: question, entries: entries).enumerated().map { ($1.course.id, 0.5 - Double($0) * 0.01) }
            }
        }
        let ordered = QuickAskRouting.orderedForChoice(entries, predicted: predicted, now: now)
        let candidates: [Candidate] = predicted.sorted { $0.confidence > $1.confidence }.prefix(3).compactMap { item in
            entries.first { $0.course.id == item.id }.map { Candidate(entry: $0, confidence: item.confidence, reason: reasons[item.id] ?? "") }
        }
        return Prediction(ordered: ordered, candidates: candidates)
    }
}
