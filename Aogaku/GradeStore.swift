//
//  GradeStore.swift
//  Aogaku
//
//  成績通知書（tuutisho.aspx）から取り込んだ成績データの
//  モデル定義・永続化を担当する。

import Foundation

// MARK: - Models

/// 授業ごとの成績レコード（gvw_seiseki の1行）
struct GradeRecord: Codable {
    var name:     String   // 授業科目名
    var teacher:  String   // 教員氏名
    var grade:    String   // 成績 ("AA","A","B","C","++","**","FF","XX","X","W")
    var credits:  Int      // 単位数
    var year:     Int      // 取得年度
    var category: String   // 科目分野 ("青山ｽﾀﾝﾀﾞｰ", "学　科", "他学科" など)

    /// 合格済みかどうか（W=取消、X=欠席、XX=不合格、FF=未評価 は除く）
    var isPassed: Bool {
        let g = grade.trimmingCharacters(in: .whitespaces)
        return ["AA", "A", "B", "C", "++", "**"].contains(g)
    }

    /// 実際に修得した単位数
    var earnedCredits: Int { isPassed ? credits : 0 }
}

/// 修得済単位表の1行（gvw_tani）
struct CreditSummaryItem: Codable {
    var label:    String   // 単位分野・要件 ("スタンダード", "　教養コア　必修", …)
    var required: Int?     // 必要単位（空欄あり）
    var earned:   Int?     // 修得単位（空欄あり）
}

/// tuutisho.aspx から取り込んだデータ一式
struct GradesData: Codable {
    var records:       [GradeRecord]
    var creditSummary: [CreditSummaryItem]
    var gpa:           String
    var onlineCredits: String   // "オンライン単位：0" などのテキスト
    var importedAt:    Date
    var username:      String
    var department:    String

    /// 修得済み合計単位（合格科目のみ）
    var totalEarnedCredits: Int {
        records.reduce(0) { $0 + $1.earnedCredits }
    }

    /// 卒業要件単位数（修得済単位表の「卒業要件単位」行の必要単位列）
    var graduationRequiredCredits: Int? {
        creditSummary.first { $0.label.contains("卒業要件単位") }?.required
    }

    /// 卒業要件内の修得単位（修得済単位表の「卒業要件内」行）
    var graduationEarnedCredits: Int? {
        creditSummary.first { $0.label.contains("卒業要件内") }?.earned
    }
}

// MARK: - Store

enum GradeStore {
    static let storageKey = "portalGradesData"

    static func save(_ data: GradesData) {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        UserDefaults.standard.set(encoded, forKey: storageKey)
    }

    static func load() -> GradesData? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(GradesData.self, from: data)
        else { return nil }
        return decoded
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
