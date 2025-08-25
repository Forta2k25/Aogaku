//
//  CourseStore.swift
//  Aogaku
//
//  Created by shu m on 2025/08/24.
//

import Foundation

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
