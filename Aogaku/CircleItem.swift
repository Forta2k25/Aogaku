//
//  CircleItem.swift
//  AogakuHack
//
//  Firestore model + mock data
//

import Foundation
import FirebaseFirestore

struct CircleItem: Hashable {
    let id: String
    let name: String
    let campus: String
    let intensity: String
    let imageURL: String?
    let popularity: Int

    init(id: String,
         name: String,
         campus: String,
         intensity: String = "ふつう",
         imageURL: String? = nil,
         popularity: Int = 0) {
        self.id = id
        self.name = name
        self.campus = campus
        self.intensity = intensity
        self.imageURL = imageURL
        self.popularity = popularity
    }

    init?(document: QueryDocumentSnapshot) {
        let data = document.data()
        guard
            let name = data["name"] as? String,
            let campus = data["campus"] as? String
        else { return nil }

        self.id = document.documentID
        self.name = name
        self.campus = campus
        self.intensity = (data["intensity"] as? String) ?? "ふつう"
        self.imageURL = data["imageURL"] as? String
        self.popularity = (data["popularity"] as? Int) ?? 0
    }

    static func mock(for campus: String) -> [CircleItem] {
        if campus == "相模原" {
            return [
                CircleItem(id: "m1", name: "理工サイエンス部", campus: campus, intensity: "ガチめ", popularity: 90),
                CircleItem(id: "m2", name: "Sagamihara Music", campus: campus, intensity: "ゆるめ", popularity: 80),
                CircleItem(id: "m3", name: "フットサル同好会", campus: campus, intensity: "ふつう", popularity: 70),
                CircleItem(id: "m4", name: "写真サークル", campus: campus, intensity: "ゆるめ", popularity: 60),
            ]
        } else {
            return [
                CircleItem(id: "a1", name: "茶道部", campus: campus, intensity: "ふつう", popularity: 100),
                CircleItem(id: "a2", name: "ESS123daily", campus: campus, intensity: "ゆるめ", popularity: 95),
                CircleItem(id: "a3", name: "Sonickers", campus: campus, intensity: "ふつう", popularity: 90),
                CircleItem(id: "a4", name: "英字新聞編集委員会", campus: campus, intensity: "ガチめ", popularity: 85),
                CircleItem(id: "a5", name: "Rois", campus: campus, intensity: "ゆるめ", popularity: 80),
                CircleItem(id: "a6", name: "SHIBUYA English Guide", campus: campus, intensity: "ふつう", popularity: 75),
            ]
        }
    }
}
