
// CreditsClassifier.swift
import UIKit

/// 単位カテゴリ（表示名と色を一元管理）
enum CreditCategory: CaseIterable {
    case aoyamaStandard     // 青山スタンダード
    case department         // 学科科目
    case freeChoice         // 自由選択科目

    var title: String {
        switch self {
        case .aoyamaStandard: return "青山スタンダード"
        case .department:     return "学科科目"
        case .freeChoice:     return "自由選択科目"
        }
    }

    var color: UIColor {
        switch self {
        case .aoyamaStandard: return .systemBlue
        case .department:     return .systemRed
        case .freeChoice:     return .systemGreen
        }
    }
}

/// Course → カテゴリ判定（文言はデータに合わせて調整）
enum CreditsClassifier {
    static func classify(_ c: Course) -> CreditCategory {
        let cat = (c.category ?? "").lowercased()
        if cat.contains("スタンダード") || cat.contains("standard") { return .aoyamaStandard }
        if cat.contains("学科") || cat.contains("学部")           { return .department }
        return .freeChoice
    }
}
