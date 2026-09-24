//
//  CareerListing.swift
//  Aogaku
//
//  キャリア（インターン・採用イベント・新卒求人）掲載の Firestore モデル
//

import Foundation
import FirebaseFirestore
import UIKit

enum CareerCategory: String, CaseIterable, Hashable {
    case longTermIntern
    case shortTermIntern
    case recruitingEvent
    case newGrad
    case other

    var displayName: String {
        switch self {
        case .longTermIntern: return "長期インターン"
        case .shortTermIntern: return "短期インターン"
        case .recruitingEvent: return "イベント"
        case .newGrad: return "新卒採用"
        case .other: return "その他"
        }
    }

    var tintColor: UIColor {
        switch self {
        case .longTermIntern: return UIColor(red: 0/255, green: 90/255, blue: 200/255, alpha: 1)
        case .shortTermIntern: return UIColor(red: 0/255, green: 122/255, blue: 90/255, alpha: 1)
        case .recruitingEvent: return UIColor(red: 176/255, green: 128/255, blue: 0/255, alpha: 1)
        case .newGrad, .other: return .systemGray
        }
    }

    var backgroundTintColor: UIColor {
        tintColor.withAlphaComponent(0.12)
    }
}

/// 一覧タブに表示するカテゴリフィルター（新卒・その他は「すべて」からのみ閲覧可能）
enum CareerFilterTab: CaseIterable, Hashable {
    case all
    case longTermIntern
    case shortTermIntern
    case recruitingEvent

    var title: String {
        switch self {
        case .all: return "すべて"
        case .longTermIntern: return CareerCategory.longTermIntern.displayName
        case .shortTermIntern: return CareerCategory.shortTermIntern.displayName
        case .recruitingEvent: return CareerCategory.recruitingEvent.displayName
        }
    }

    var category: CareerCategory? {
        switch self {
        case .all: return nil
        case .longTermIntern: return .longTermIntern
        case .shortTermIntern: return .shortTermIntern
        case .recruitingEvent: return .recruitingEvent
        }
    }
}

struct CareerListing: Hashable {
    let id: String
    let companyName: String
    let logoUrl: String?
    let photoUrl: String?
    let category: CareerCategory
    let title: String
    let description: String
    let eligibility: String
    let location: String
    let compensation: String
    let schedule: String
    let capacity: String?
    let applicationDeadline: Date?
    let applicationUrl: String
    let publishedAt: Date?
    let expiresAt: Date?
    let isTrial: Bool

    init?(document: QueryDocumentSnapshot) {
        let data = document.data()
        guard
            let companyName = data["companyName"] as? String,
            let title = data["title"] as? String,
            let applicationUrl = data["applicationUrl"] as? String
        else { return nil }

        self.id = document.documentID
        self.companyName = companyName
        self.logoUrl = data["logoUrl"] as? String
        self.photoUrl = data["photoUrl"] as? String
        self.category = CareerCategory(rawValue: data["category"] as? String ?? "") ?? .other
        self.title = title
        self.description = data["description"] as? String ?? ""
        self.eligibility = data["eligibility"] as? String ?? ""
        self.location = data["location"] as? String ?? ""
        self.compensation = data["compensation"] as? String ?? ""
        self.schedule = data["schedule"] as? String ?? ""
        self.capacity = data["capacity"] as? String
        self.applicationDeadline = (data["applicationDeadline"] as? Timestamp)?.dateValue()
        self.applicationUrl = applicationUrl
        self.publishedAt = (data["publishedAt"] as? Timestamp)?.dateValue()
        self.expiresAt = (data["expiresAt"] as? Timestamp)?.dateValue()
        self.isTrial = data["isTrial"] as? Bool ?? false
    }

    /// 締切の日付のみ（例: 11月1日(日)）
    var deadlineDateText: String? {
        guard let d = applicationDeadline else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日(E)"
        return f.string(from: d)
    }

    /// カード・詳細画面共通の締切テキスト
    var deadlineText: String? {
        guard let dateText = deadlineDateText else { return nil }
        return "\(dateText)締切"
    }
}
