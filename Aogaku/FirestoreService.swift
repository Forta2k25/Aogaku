//  FirestoreService.swift
//  Aogaku

import Foundation
import FirebaseFirestore

struct FirestorePage {
    let courses: [Course]
    let lastSnapshot: DocumentSnapshot?
}

final class FirestoreService {

    private let db = Firestore.firestore()
    private var baseQuery: Query {
        db.collection("classes")
    }

    /// 1ページ目：曜日と時限で10件取得（並びは documentID）
    func fetchFirstPageForDay(day: String,
                              period: Int,
                              limit: Int,
                              completion: @escaping (Result<FirestorePage, Error>) -> Void) {
        let q = baseQuery
            .whereField("time.day", isEqualTo: day)
            .whereField("time.periods", arrayContains: period)
            .order(by: FieldPath.documentID())
            .limit(to: max(1, limit))

        q.getDocuments { [weak self] snap, err in
            if let err = err { return completion(.failure(err)) }
            guard let self = self, let snap = snap else {
                return completion(.success(FirestorePage(courses: [], lastSnapshot: nil)))
            }
            let list = snap.documents.compactMap { self.map(doc: $0) }
            completion(.success(FirestorePage(courses: list, lastSnapshot: snap.documents.last)))
        }
    }

    
    // 次ページ取得（曜日と時限の条件を維持して 10 件など）
    func fetchNextPageForDay(day: String,
                             period: Int,
                             after cursor: DocumentSnapshot,
                             limit: Int,
                             completion: @escaping (Result<FirestorePage, Error>) -> Void) {
        let q = db.collection("classes")
            .whereField("time.day", isEqualTo: day)
            .whereField("time.periods", arrayContains: period)
            .order(by: FieldPath.documentID())
            .start(afterDocument: cursor)
            .limit(to: max(1, limit))

        q.getDocuments { [weak self] snap, err in
            if let err = err { return completion(.failure(err)) }
            guard let self = self, let snap = snap else {
                return completion(.success(FirestorePage(courses: [], lastSnapshot: nil)))
            }
            let list = snap.documents.compactMap { self.map(doc: $0) }
            completion(.success(FirestorePage(courses: list, lastSnapshot: snap.documents.last)))
        }
    }


    // MARK: - Mapper（Firestore → Course）
    private func map(doc: DocumentSnapshot) -> Course? {
        guard let d = doc.data() else { return nil }

        // 文字列 or 数値どちらでも受けるヘルパ
        func asString(_ any: Any?) -> String? {
            if let s = any as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let n = any as? NSNumber { return n.stringValue }
            if let i = any as? Int { return String(i) }
            if let d = any as? Double { return String(Int(d)) }
            return nil
        }
        // 文字列 or 文字列配列どちらでも受ける（最初の要素を採用）
        func asStringOrFirst(_ any: Any?) -> String? {
            if let s = asString(any) { return s }
            if let arr = any as? [String] { return arr.first }
            return nil
        }
        // Int or Double or String 数値 どれでも Int に
        func asInt(_ any: Any?) -> Int? {
            if let i = any as? Int { return i }
            if let d = any as? Double { return Int(d) }
            if let s = any as? String, let v = Int(s) { return v }
            return nil
        }

        // フィールド名は Firebase 側に合わせる（id→code, title→class_name, ...）
        let id      = asString(d["code"])        ?? "#####"
        let title   = asString(d["class_name"])  ?? "(タイトル未設定)"
        let room    = asStringOrFirst(d["room"]) ?? "-"          // 数字や配列でもOK
        let teacher = asStringOrFirst(d["teacher_name"]) ?? "-"

        let credits = asInt(d["credit"])                       // 1, 1.0, "1" すべて吸収
        let campus  = asStringOrFirst(d["campus"])             // "青山" or ["青山"]
        let category = asStringOrFirst(d["category"])          // "英米文学科" など
        let url     = asString(d["url"])

        return Course(
            id: id,
            title: title,
            room: room,
            teacher: teacher,
            credits: credits,
            campus: campus,
            category: category,
            syllabusURL: url
        )
    }

}
