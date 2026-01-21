//
//  Course.swift
//  Aogaku
//
//  Created by shu m on 2025/09/02.
//
// Course.swift
import Foundation
// Course.swift

import FirebaseFirestore

struct Course: Codable, Equatable {
    let id: String
    let title: String
    var room: String
    let teacher: String
    var credits: Int?
    var campus: String?
    var category: String?
    var syllabusURL: String?
    var term: String?

    // 追加: Firestore の time 情報（オンライン一覧の曜日/時限フィルタで使用）
    var timeDay: String?         // time.day （例: "月" / "月曜" / "月曜日"）
    var periods: [Int]?          // time.periods（例: [1,2]）

    init(id: String,
         title: String,
         room: String,
         teacher: String,
         credits: Int?,
         campus: String?,
         category: String?,
         syllabusURL: String?,
         term: String?
    ) {
        self.id = id
        self.title = title
        self.room = room
        self.teacher = teacher
        self.credits = credits
        self.campus = campus
        self.category = category
        self.syllabusURL = syllabusURL
        self.term = term
        // 追加フィールドの初期値
        self.timeDay = nil
        self.periods = nil
    }

    /// Firestore のドキュメントから生成
    init?(doc: DocumentSnapshot) {
        guard let d = doc.data() else { return nil }

        let id        = (d["code"] as? String) ?? doc.documentID
        let title     = (d["class_name"] as? String) ?? (d["title"] as? String) ?? ""
        let room      = (d["room"] as? String) ?? ""
        let teacher   = (d["teacher_name"] as? String) ?? ""
        let credits   = d["credit"] as? Int
        let campus    = d["campus"] as? String
        let category  = d["category"] as? String
        let url       = d["url"] as? String
        let term      = d["term"] as? String

        self.init(id: id,
                  title: title,
                  room: room,
                  teacher: teacher,
                  credits: credits,
                  campus: campus,
                  category: category,
                  syllabusURL: url,
                  term: term)

        // ← 追加: time 情報を取り出して保持
        if let time = d["time"] as? [String: Any] {
            if let day = time["day"] as? String {
                self.timeDay = day
            }
            if let ps = time["periods"] as? [Int] {
                self.periods = ps
            } else if let psAny = time["periods"] as? [Any] {
                // "1","2" のような文字列が混在しても安全に Int に
                self.periods = psAny.compactMap { elem in
                    if let n = elem as? NSNumber { return n.intValue }
                    if let s = elem as? String { return Int(s) }
                    return nil
                }
            } else if let p = time["period"] as? Int {
                self.periods = [p]
            } else if let pStr = time["period"] as? String, let p = Int(pStr) {
                self.periods = [p]
            }
        }
    }
}

/*
import FirebaseFirestore

/// 時間割・検索リストで使う共通モデル
struct Course: Codable, Equatable {
    let id: String            // Firestore: code
    let title: String         // Firestore: class_name
    var room: String          // Firestore: room
    let teacher: String       // Firestore: teacher_name
    var credits: Int?         // Firestore: credit
    var campus: String?       // Firestore: campus
    var category: String?     // Firestore: category
    var syllabusURL: String?  // Firestore: url
    var term: String?            // [ADDED]

    init(id: String,
         title: String,
         room: String,
         teacher: String,
         credits: Int?,
         campus: String?,
         category: String?,
         syllabusURL: String?,
         term: String?) {
        self.id = id
        self.title = title
        self.room = room
        self.teacher = teacher
        self.credits = credits
        self.campus = campus
        self.category = category
        self.syllabusURL = syllabusURL
        self.term = term         // [ADDED]
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

*/
