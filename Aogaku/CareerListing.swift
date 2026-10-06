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
    case newGrad            // 本選考・新卒採用
    case jobHunting         // 就活イベント・説明会・選考対策
    case studyAbroad
    case partTime
    case recruitingEvent    // その他イベント
    case other

    var displayName: String {
        switch self {
        case .longTermIntern: return "長期インターン"
        case .shortTermIntern: return "短期インターン"
        case .newGrad: return "本選考"
        case .jobHunting: return "就活"
        case .studyAbroad: return "留学"
        case .partTime: return "バイト"
        case .recruitingEvent: return "イベント"
        case .other: return "その他"
        }
    }

    var tintColor: UIColor {
        switch self {
        case .longTermIntern: return UIColor(red: 0/255, green: 90/255, blue: 200/255, alpha: 1)
        case .shortTermIntern: return UIColor(red: 0/255, green: 122/255, blue: 90/255, alpha: 1)
        case .newGrad, .jobHunting: return UIColor(red: 110/255, green: 70/255, blue: 190/255, alpha: 1)
        case .studyAbroad: return UIColor(red: 0/255, green: 130/255, blue: 160/255, alpha: 1)
        case .partTime: return UIColor(red: 200/255, green: 80/255, blue: 40/255, alpha: 1)
        case .recruitingEvent: return UIColor(red: 176/255, green: 128/255, blue: 0/255, alpha: 1)
        case .other: return .systemGray
        }
    }

    var backgroundTintColor: UIColor {
        tintColor.withAlphaComponent(0.12)
    }
}

/// 一覧の絞り込みタブ。複数カテゴリをまとめて 1 タブにできる
enum CareerFilterTab: CaseIterable, Hashable {
    case all
    case saved
    case intern
    case jobHunting
    case studyAbroad
    case partTime
    case event

    var title: String {
        switch self {
        case .all: return "すべて"
        case .saved: return "保存済み"
        case .intern: return "インターン"
        case .jobHunting: return "就活"
        case .studyAbroad: return "留学"
        case .partTime: return "バイト"
        case .event: return "イベント"
        }
    }

    /// `all` / `saved` は nil（カテゴリでは絞らない）
    var categories: Set<CareerCategory>? {
        switch self {
        case .all, .saved: return nil
        case .intern: return [.longTermIntern, .shortTermIntern]
        case .jobHunting: return [.newGrad, .jobHunting]
        case .studyAbroad: return [.studyAbroad]
        case .partTime: return [.partTime]
        case .event: return [.recruitingEvent]
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
    /// 掲載元サイト名（例: "Wantedly"）。応募ボタンに表示し、将来のアフィリエイト集計にも使う
    let sourceName: String?

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
        self.sourceName = data["sourceName"] as? String
    }

    /// 締切の日付のみ（例: 11月1日(日)）
    var deadlineDateText: String? {
        guard let d = applicationDeadline else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日(E)"
        return f.string(from: d)
    }

    /// 締切までの日数（今日=0、期限切れは負）
    var daysUntilDeadline: Int? {
        guard let d = applicationDeadline else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day
    }

    /// 締切が7日以内
    var isDeadlineSoon: Bool {
        guard let n = daysUntilDeadline else { return false }
        return (0...7).contains(n)
    }

    /// 公開から7日以内
    var isNew: Bool {
        guard let p = publishedAt else { return false }
        return Date().timeIntervalSince(p) < 7 * 86400
    }

    /// カード・詳細画面共通の締切テキスト
    var deadlineText: String? {
        guard let dateText = deadlineDateText else { return nil }
        return "\(dateText)締切"
    }
}
