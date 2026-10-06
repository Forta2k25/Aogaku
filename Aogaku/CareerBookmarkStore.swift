//
//  CareerBookmarkStore.swift
//  Aogaku
//
//  キャリア掲載の保存（ブックマーク）。UserDefaults に求人IDを保持する
//

import Foundation

extension Notification.Name {
    static let careerBookmarkDidChange = Notification.Name("careerBookmarkDidChange")
}

final class CareerBookmarkStore {
    static let shared = CareerBookmarkStore()

    private let key = "bookmarked_career_ids"
    private let ud = UserDefaults.standard

    private init() {}

    func allIDs() -> [String] { ud.stringArray(forKey: key) ?? [] }

    func isBookmarked(id: String) -> Bool { allIDs().contains(id) }

    /// 追加なら true、削除なら false
    @discardableResult
    func toggle(id: String) -> Bool {
        var ids = allIDs()
        let added: Bool
        if let idx = ids.firstIndex(of: id) {
            ids.remove(at: idx)
            added = false
        } else {
            ids.insert(id, at: 0)
            added = true
        }
        ud.set(ids, forKey: key)
        NotificationCenter.default.post(name: .careerBookmarkDidChange, object: nil)
        return added
    }
}
