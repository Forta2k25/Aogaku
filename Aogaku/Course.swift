//
//  Course.swift
//  Aogaku
//
//  Created by shu m on 2025/09/02.
//
// Course.swift
import Foundation
import FirebaseFirestore

/// 時間割・検索リストで使う共通モデル
struct Course: Codable, Equatable {
    let id: String            // Firestore: code
    let title: String         // Firestore: class_name
    let room: String          // Firestore: room
    let teacher: String       // Firestore: teacher_name
    var credits: Int?         // Firestore: credit
    var campus: String?       // Firestore: campus
    var category: String?     // Firestore: category
    var syllabusURL: String?  // Firestore: url

    init(id: String,
         title: String,
         room: String,
         teacher: String,
         credits: Int?,
         campus: String?,
         category: String?,
         syllabusURL: String?) {
        self.id = id
        self.title = title
        self.room = room
        self.teacher = teacher
        self.credits = credits
        self.campus = campus
        self.category = category
        self.syllabusURL = syllabusURL
    }

    /// Firestore のドキュメントから生成するためのイニシャライザ
    init?(doc: DocumentSnapshot) {
        guard let d = doc.data() else { return nil }

        self.id = (d["code"] as? String) ?? ""
        self.title = (d["class_name"] as? String) ?? ""
        self.room = (d["room"] as? String) ?? ""
        self.teacher = (d["teacher_name"] as? String) ?? ""

        if let i = d["credit"] as? Int {
            self.credits = i
        } else if let s = d["credit"] as? String, let i = Int(s) {
            self.credits = i
        } else {
            self.credits = nil
        }

        self.campus = d["campus"] as? String
        self.category = d["category"] as? String
        self.syllabusURL = d["url"] as? String
    }
}

