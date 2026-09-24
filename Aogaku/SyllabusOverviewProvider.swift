//
//  SyllabusOverviewProvider.swift
//  Aogaku
//
//  授業ノート(AI)機能: 既に抽出済みのシラバスキャッシュから概要テキストを取り出す
//

import Foundation

enum SyllabusOverviewProvider {
    /// SyllabusDataCache(CourseDetailViewControllerのシラバス表示が保存したもの)から
    /// 概要テキストを組み立てる。キャッシュが無ければ空文字を返す。
    static func overviewText(for course: Course, maxLength: Int = 4000) -> String {
        let rawURL = course.syllabusURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = (rawURL?.isEmpty == false) ? rawURL! : course.id
        guard let fields = SyllabusDataCache.shared.load(for: cacheKey), !fields.isEmpty else { return "" }

        let joined = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        return String(joined.prefix(maxLength))
    }
}
