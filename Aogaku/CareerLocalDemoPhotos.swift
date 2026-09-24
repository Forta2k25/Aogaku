//
//  CareerLocalDemoPhotos.swift
//  Aogaku
//
//  営業デモ用にローカルバンドルした参考写真。
//  実在の人物・他社ロゴが写り込んでいるため、本番配信（App Store / TestFlight）には含めないこと。
//  Firestore の photoUrl が未設定のときのみ、ドキュメントIDに応じてこのローカル画像を表示する。
//

import UIKit

enum CareerLocalDemoPhotos {
    private static let mapping: [String: String] = [
        "seed-aoba-consulting": "intern_photo_1",
        "seed-greenleaf-sns": "intern_photo_2",
        "seed-nextgate-engineer": "intern_photo_3",
        "seed-hikari-media": "intern_photo_4",
        "seed-fortis-sales": "intern_photo_5",
    ]

    static func image(forListingID id: String) -> UIImage? {
        guard let name = mapping[id],
              let path = Bundle.main.path(forResource: name, ofType: "jpg")
        else { return nil }
        return UIImage(contentsOfFile: path)
    }
}
