// CourseReview.swift
// Aogaku

import Foundation
import FirebaseFirestore

struct CourseReview {
    let uid: String
    let teacherKindness: Int    // 1=厳しい 〜 5=優しい（右が優しい）
    let creditDifficulty: Int   // 1=鬼単   〜 5=楽単（右が楽単）
    let comment: String         // 最大150字
    let term: String            // 受講学期 e.g. "2025年前期"
    let isPublic: Bool          // 前期中は false、後期に一括 true
    let createdAt: Date

    var asDictionary: [String: Any] {
        [
            "uid": uid,
            "teacherKindness": teacherKindness,
            "creditDifficulty": creditDifficulty,
            "comment": comment,
            "term": term,
            "isPublic": isPublic,
            "createdAt": Timestamp(date: createdAt)
        ]
    }

    init?(documentData: [String: Any], uid: String) {
        guard
            let kindness   = documentData["teacherKindness"] as? Int,
            let difficulty = documentData["creditDifficulty"] as? Int
        else { return nil }
        self.uid = uid
        self.teacherKindness = kindness
        self.creditDifficulty = difficulty
        self.comment = documentData["comment"] as? String ?? ""
        self.term = documentData["term"] as? String ?? ""
        self.isPublic = documentData["isPublic"] as? Bool ?? false
        if let ts = documentData["createdAt"] as? Timestamp {
            self.createdAt = ts.dateValue()
        } else {
            self.createdAt = Date()
        }
    }

    init(uid: String,
         teacherKindness: Int,
         creditDifficulty: Int,
         comment: String,
         term: String) {
        self.uid = uid
        self.teacherKindness = teacherKindness
        self.creditDifficulty = creditDifficulty
        self.comment = comment
        self.term = term
        self.isPublic = false
        self.createdAt = Date()
    }
}
