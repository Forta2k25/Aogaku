//
//  LectureNote.swift
//  Aogaku
//
//  授業ノート機能: 授業ごとの録音・文字起こしメタデータ
//

import Foundation
import FirebaseFirestore

enum LectureNoteStatus: String, Codable {
    case recording
    case transcribing
    case completed
    case failed
}

struct LectureTranscriptionMetadata: Codable {
    var model: String
    var chunkCount: Int
    var accurateChunkCount: Int
    var openAIFallbackChunkCount: Int
    var retryImprovedChunkCount: Int
    var turboQuality: LectureTranscriber.QualitySummary?
    var finalQuality: LectureTranscriber.QualitySummary?

    init(result: LectureTranscriber.ResultValue) {
        model = result.model
        chunkCount = result.chunkCount
        accurateChunkCount = result.accurateChunkCount
        openAIFallbackChunkCount = result.openAIFallbackChunkCount
        retryImprovedChunkCount = result.retryImprovedChunkCount
        turboQuality = result.turboQuality
        finalQuality = result.finalQuality
    }

    init?(dictionary: [String: Any]?) {
        guard let dictionary else { return nil }
        model = dictionary["model"] as? String ?? ""
        chunkCount = dictionary["chunkCount"] as? Int ?? 0
        accurateChunkCount = dictionary["accurateChunkCount"] as? Int ?? 0
        openAIFallbackChunkCount = dictionary["openAIFallbackChunkCount"] as? Int ?? 0
        retryImprovedChunkCount = dictionary["retryImprovedChunkCount"] as? Int ?? 0
        turboQuality = LectureTranscriber.QualitySummary(
            dictionary: dictionary["turboQuality"] as? [String: Any]
        )
        finalQuality = LectureTranscriber.QualitySummary(
            dictionary: dictionary["finalQuality"] as? [String: Any]
        )
    }

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            "model": model,
            "chunkCount": chunkCount,
            "accurateChunkCount": accurateChunkCount,
            "openAIFallbackChunkCount": openAIFallbackChunkCount,
            "retryImprovedChunkCount": retryImprovedChunkCount
        ]
        if let turboQuality { result["turboQuality"] = turboQuality.dictionary }
        if let finalQuality { result["finalQuality"] = finalQuality.dictionary }
        return result
    }
}

struct LectureNote: Codable, Identifiable {
    var id: String
    var courseKey: String        // "\(courseFirestoreDocID ?? courseID)_\(year)_\(semester)" クエリ用
    var courseTitle: String
    var term: String             // "\(year)年\(semester.display)"
    var dayPeriod: String        // 例 "月3"
    var lectureDate: Date
    var durationSec: Int
    var transcriptText: String
    var rawTranscriptText: String
    var cleanedTranscriptText: String
    var photoText: String
    var transcriptionMetadata: LectureTranscriptionMetadata?
    var sessionNumber: Int?      // 学事暦と照合した「第N回」(判定できない場合はnil)
    var status: LectureNoteStatus
    var createdAt: Date

    static func courseKey(course: Course, term: TermKey) -> String {
        let base = course.firestoreDocID ?? course.id
        return "\(base)_\(term.year)_\(term.semester.rawValue)"
    }

    init(id: String = UUID().uuidString,
         courseKey: String,
         courseTitle: String,
         term: String,
         dayPeriod: String,
         lectureDate: Date,
         durationSec: Int,
         transcriptText: String,
         rawTranscriptText: String? = nil,
         cleanedTranscriptText: String? = nil,
         photoText: String = "",
         transcriptionMetadata: LectureTranscriptionMetadata? = nil,
         sessionNumber: Int? = nil,
         status: LectureNoteStatus,
         createdAt: Date = Date()) {
        self.id = id
        self.courseKey = courseKey
        self.courseTitle = courseTitle
        self.term = term
        self.dayPeriod = dayPeriod
        self.lectureDate = lectureDate
        self.durationSec = durationSec
        self.transcriptText = transcriptText
        self.rawTranscriptText = rawTranscriptText ?? transcriptText
        self.cleanedTranscriptText = cleanedTranscriptText ?? transcriptText
        self.photoText = photoText
        self.transcriptionMetadata = transcriptionMetadata
        self.sessionNumber = sessionNumber
        self.status = status
        self.createdAt = createdAt
    }

    init?(doc: DocumentSnapshot) {
        guard let d = doc.data() else { return nil }
        guard let courseKey = d["courseKey"] as? String,
              let courseTitle = d["courseTitle"] as? String,
              let term = d["term"] as? String,
              let dayPeriod = d["dayPeriod"] as? String,
              let lectureDateTS = d["lectureDate"] as? Timestamp,
              let statusRaw = d["status"] as? String,
              let status = LectureNoteStatus(rawValue: statusRaw)
        else { return nil }

        self.id = doc.documentID
        self.courseKey = courseKey
        self.courseTitle = courseTitle
        self.term = term
        self.dayPeriod = dayPeriod
        self.lectureDate = lectureDateTS.dateValue()
        self.durationSec = (d["durationSec"] as? Int) ?? 0
        let legacyTranscript = (d["transcriptText"] as? String) ?? ""
        self.rawTranscriptText = (d["rawTranscriptText"] as? String) ?? legacyTranscript
        self.cleanedTranscriptText = (d["cleanedTranscriptText"] as? String) ?? legacyTranscript
        self.transcriptText = cleanedTranscriptText.isEmpty ? rawTranscriptText : cleanedTranscriptText
        self.photoText = (d["photoText"] as? String) ?? ""
        self.transcriptionMetadata = LectureTranscriptionMetadata(
            dictionary: d["transcriptionMetadata"] as? [String: Any]
        )
        self.sessionNumber = d["sessionNumber"] as? Int
        self.status = status
        self.createdAt = (d["createdAt"] as? Timestamp)?.dateValue() ?? lectureDateTS.dateValue()
    }

    func asDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "courseKey": courseKey,
            "courseTitle": courseTitle,
            "term": term,
            "dayPeriod": dayPeriod,
            "lectureDate": Timestamp(date: lectureDate),
            "durationSec": durationSec,
            "transcriptText": transcriptText,
            "rawTranscriptText": rawTranscriptText,
            "cleanedTranscriptText": cleanedTranscriptText,
            "photoText": photoText,
            "status": status.rawValue,
            "createdAt": Timestamp(date: createdAt)
        ]
        if let transcriptionMetadata {
            dict["transcriptionMetadata"] = transcriptionMetadata.dictionary
        }
        if let sessionNumber { dict["sessionNumber"] = sessionNumber }
        return dict
    }

    /// 録音した端末上の音声ファイルパス(Firestoreには保存しない、端末保持のみ)
    static func localAudioURL(noteId: String) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LectureAudio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("\(noteId).m4a")
    }
}
