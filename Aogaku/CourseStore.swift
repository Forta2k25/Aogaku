//
//  CourseStore.swift
//  Aogaku
//
//  Created by shu m on 2025/08/24.
//

import Foundation

enum CreditBucket { case aosuta, major, elective, other }

func normalizeCategory(_ s: String?) -> CreditBucket {
    // nil/空は other
    let raw = (s ?? "")
        .replacingOccurrences(of: " ", with: "")   // 半角スペース除去
        .replacingOccurrences(of: "　", with: "")  // 全角スペース除去
        .trimmingCharacters(in: .whitespacesAndNewlines)

    if raw.isEmpty { return .other }
    if raw.contains("青山スタンダード") || raw.contains("青スタ") { return .aosuta }
    if raw.contains("自由選択") { return .elective }               // ← 科目の有無に関係なく拾う
    if raw.contains("学科") || raw.contains("学部") { return .major }
    return .other
}


struct CourseStore {
    private static let key = "customCourses_v1"

    static func load() -> [Course] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Course].self, from: data)) ?? []
    }

    static func save(_ courses: [Course]) {
        let data = try? JSONEncoder().encode(courses)
        UserDefaults.standard.set(data, forKey: key)
    }

    static func add(_ c: Course) {
        var arr = load()
        arr.append(c)
        save(arr)
    }

    static func remove(id: String) {
        var arr = load()
        arr.removeAll { $0.id == id }
        save(arr)
    }

    static func isCustom(_ c: Course) -> Bool {
        load().contains { $0.id == c.id }
    }
}
