//
//  BookmarkStore.swift
//  Aogaku
//
//  Created by shu m on 2026/01/31.
//
import Foundation

extension Notification.Name {
    static let bookmarkDidChange = Notification.Name("bookmarkDidChange")
}

/// UserDefaults に保存するブックマーク（団体IDセット）
final class BookmarkStore {
    static let shared = BookmarkStore()

    private let key = "bookmarked_circle_ids"
    private let ud = UserDefaults.standard

    private init() {}

    func allIDs() -> [String] {
        let arr = ud.stringArray(forKey: key) ?? []
        // 重複排除しつつ順番は維持
        var seen = Set<String>()
        return arr.filter { seen.insert($0).inserted }
    }

    func isBookmarked(id: String) -> Bool {
        return Set(allIDs()).contains(id)
    }

    /// 追加/削除をトグル。戻り値: 追加されたなら true、削除なら false
    @discardableResult
    func toggle(id: String) -> Bool {
        var ids = allIDs()
        if let idx = ids.firstIndex(of: id) {
            ids.remove(at: idx)
            ud.set(ids, forKey: key)
            NotificationCenter.default.post(name: .bookmarkDidChange, object: nil)
            return false
        } else {
            ids.insert(id, at: 0) // 最新を先頭に
            ud.set(ids, forKey: key)
            NotificationCenter.default.post(name: .bookmarkDidChange, object: nil)
            return true
        }
    }

    func remove(id: String) {
        var ids = allIDs()
        ids.removeAll { $0 == id }
        ud.set(ids, forKey: key)
        NotificationCenter.default.post(name: .bookmarkDidChange, object: nil)
    }

    func clear() {
        ud.removeObject(forKey: key)
        NotificationCenter.default.post(name: .bookmarkDidChange, object: nil)
    }
}
