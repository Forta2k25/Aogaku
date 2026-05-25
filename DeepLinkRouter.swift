//
//  DeepLinkRouter.swift
//  Aogaku
//
//  Created by shu m on 2025/09/18.
//
import UIKit

enum DeepLinkRouter {
    static func handle(_ url: URL, window: UIWindow?) -> Bool {
        // スキーム確認
        guard url.scheme == "aogaku" else { return false }

        let path = (url.host ?? "") + url.path

        // ── ポータル取り込み ─────────────────────────────
        if path.contains("import") {
            guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let encoded = comps.queryItems?.first(where: { $0.name == "d" })?.value else {
                DispatchQueue.main.async {
                    processPendingPortalImport(window: window)
                }
                return true
            }

            // URL-safe Base64 → 標準 Base64 → JSON
            // ActionViewController が - → + / _ → / で変換しているので逆変換する
            // Legacy bookmarklets may have put standard Base64 directly in a query
            // string, where "+" is decoded as a space. Normalize both variants.
            let normalizedEncoded = encoded.replacingOccurrences(of: " ", with: "+")
            let rem      = normalizedEncoded.count % 4
            let padded   = normalizedEncoded + (rem > 0 ? String(repeating: "=", count: 4 - rem) : "")
            let base64   = padded
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            guard
                let jsonData = Data(base64Encoded: base64),
                let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else { return false }

            // URL open で直接来た場合は App Group の保留データを先に削除して重複取り込みを防ぐ
            UserDefaults(suiteName: "group.jp.forta.Aogaku")?.removeObject(forKey: "pendingPortalImport")

            DispatchQueue.main.async {
                importPortalData(json, window: window)
            }
            return true
        }

        // ── 成績取り込み ────────────────────────────────────────
        if path.contains("grades") {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let encoded = comps?.queryItems?.first(where: { $0.name == "d" })?.value {
                // 旧来の URL スキーム直接渡し（フォールバック）
                let normalizedEncoded = encoded.replacingOccurrences(of: " ", with: "+")
                let rem    = normalizedEncoded.count % 4
                let padded = normalizedEncoded + (rem > 0 ? String(repeating: "=", count: 4 - rem) : "")
                let base64 = padded
                    .replacingOccurrences(of: "-", with: "+")
                    .replacingOccurrences(of: "_", with: "/")
                guard let jsonData = Data(base64Encoded: base64),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
                else { return false }
                DispatchQueue.main.async { importGradesData(json, window: window) }
            } else {
                // App Group 経由（ActionViewController からの正規ルート）
                DispatchQueue.main.async { processPendingGradesImport(window: window) }
            }
            return true
        }

        // パス/ホストが timetable のときに反応
        guard path.contains("timetable") else { return false }

        // ?day=today / ?day=0..5 を解釈（0=月, ... 5=土 などアプリ側ルールに合わせて）
        var dayIndex: Int?
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let v = comps.queryItems?.first(where: { $0.name == "day" })?.value {
            if v == "today" {
                let w = Calendar.current.component(.weekday, from: Date()) // 1=Sun..7=Sat
                dayIndex = (w + 5) % 7   // 0=Mon..6=Sun に変換（必要に応じて調整）
                if dayIndex == 6 { dayIndex = nil } // 例：日曜は未使用なら nil
            } else {
                dayIndex = Int(v)
            }
        }

        DispatchQueue.main.async {
            openTimetable(in: window, dayIndex: dayIndex)
        }
        return true
    }

    private static func openTimetable(in window: UIWindow?, dayIndex: Int?) {
        guard let root = window?.rootViewController else { return }

        // タブ構成なら「時間割」タブに切替
        if let tab = root as? UITabBarController {
            // 適切な index に直してね（時間割が 0 番なら 0）
            tab.selectedIndex = 0
            // 探して呼び出し
            if let tt = findTimetable(from: tab.selectedViewController) {
                ttJump(tt, to: dayIndex)
            }
            return
        }

        // 直接 UINavigationController の場合など
        if let tt = findTimetable(from: root) { ttJump(tt, to: dayIndex) }
    }

    // MARK: - Portal Import

    private static func importPortalData(_ json: [String: Any], window: UIWindow?) {
        let subjectsRaw = json["subjects"] as? [[String: Any]] ?? []
        let days        = json["days"]     as? [String]         ?? []
        let term        = TermStore.loadSelected()

        print("[PortalImport] importPortalData: \(subjectsRaw.count) subjects, days=\(days), term=\(term.storageKey)")

        // 曜日文字列 → 0始まりのインデックス
        let dayIndexMap: [String: Int] = [
            "月": 0, "火": 1, "水": 2, "木": 3, "金": 4, "土": 5,
            "月曜": 0, "火曜": 1, "水曜": 2, "木曜": 3, "金曜": 4,
            "土曜": 5,
            "月曜日": 0, "火曜日": 1, "水曜日": 2, "木曜日": 3, "金曜日": 4,
            "土曜日": 5,
        ]
        // 時間割の現在の設定（曜日数・時限数）を取得
        let ttSettings  = TimetableSettings.load()
        let dayCount    = ttSettings.includeSaturday ? 6 : 5
        let periodCount = ttSettings.periods   // 5 / 6 / 7

        print("[PortalImport] ttSettings: dayCount=\(dayCount) periods=\(periodCount)")

        func intValue(_ value: Any?) -> Int? {
            if let int = value as? Int { return int }
            if let number = value as? NSNumber { return number.intValue }
            if let string = value as? String { return Int(string) }
            return nil
        }

        // 既存の位置配列を読み込む。
        // timetable.swift は (period-1)*dayCount + day のインデックスで管理している
        // サイズが一致しない場合でも既存データを捨てず、リサイズして保持する。
        var assigned: [Course?]
        let expectedCount = dayCount * periodCount
        if let loaded = loadExistingAssigned(term: term, dayCount: dayCount, periodCount: periodCount) {
            assigned = loaded
            print("[PortalImport] loaded existing assigned[\(loaded.count)]")
        } else {
            assigned = Array(repeating: nil, count: expectedCount)
            print("[PortalImport] fresh assigned[\(assigned.count)]")
        }

        var importCount = 0
        for s in subjectsRaw {
            guard
                let name    = s["name"]     as? String, !name.isEmpty,
                let period  = intValue(s["period"]),
                let jsDay   = intValue(s["dayIndex"])
            else {
                print("[PortalImport] skip subject (guard failed): \(s)")
                continue
            }

            if let courseSemester = s["semester"] as? String,
               !courseSemester.isEmpty,
               courseSemester != "通年",
               courseSemester != term.semester.rawValue {
                print("[PortalImport] skip '\(name)' semester='\(courseSemester)' current='\(term.semester.rawValue)'")
                continue
            }

            // JS の dayIndex → 曜日文字列 → 時間割内の列インデックス。
            // ポータルは週によって「土・月・火...」のように列順が変わるため、
            // dayIndex を月曜始まりとして扱わず、抽出済みの曜日ラベルを必ず優先する。
            let rawDay = (s["dayLabel"] as? String)
                ?? (jsDay < days.count ? days[jsDay] : nil)
            // "月曜日" → "月" など正規化
            let normalized = rawDay.map { $0.count > 1 ? String($0.prefix(1)) : $0 }
            guard let col = rawDay.flatMap({ dayIndexMap[$0] })
                    ?? normalized.flatMap({ dayIndexMap[$0] }),
                  col < dayCount,
                  period >= 1, period <= periodCount
            else {
                print("[PortalImport] skip '\(name)' rawDay='\(rawDay ?? "")' normalized='\(normalized ?? "")' dayIndex=\(jsDay) period=\(period)")
                continue
            }

            let displayName = normalizePortalDisplayText(name)
            let displayRoom = normalizePortalDisplayText(s["room"] as? String ?? "")
            let slotIdx   = (period - 1) * dayCount + col
            let safeTitle = displayName.components(separatedBy: .whitespaces).joined()
            let dayLabel  = ["月","火","水","木","金","土"][col]

            print("[PortalImport] placing '\(displayName)' at day=\(col)(\(dayLabel)) period=\(period) → slot[\(slotIdx)]")

            let importedID = (s["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let stableID = importedID.flatMap { id in
                id.rangeOfCharacter(from: CharacterSet.alphanumerics) == nil ? nil : id
            } ?? "portal_\(dayLabel)_\(period)_\(safeTitle)"

            var course = Course(
                id: stableID,
                title: displayName,
                room: displayRoom,
                teacher: s["teacher"] as? String ?? "",
                credits: intValue(s["credits"]),
                campus: s["campus"] as? String,
                category: (s["category"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 },
                syllabusURL: s["portalSyllabusURL"] as? String,
                term: "\(term.year)\(term.semester.rawValue)"
            )
            course.timeDay = dayLabel
            course.periods = [period]

            let existingCourse = assigned.indices.contains(slotIdx) ? assigned[slotIdx].map(normalizeCourseDisplayFields) : nil
            if let existing = existingCourse,
               existing.title == course.title {
                if course.room.isEmpty { course.room = existing.room }
                if course.syllabusURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    course.syllabusURL = existing.syllabusURL
                }
                course.category = course.category ?? existing.category
                course.campus = course.campus ?? existing.campus
                course.firestoreDocID = existing.firestoreDocID
            }

            if existingCourse == nil {
                SlotColorStore.set(SlotColorStore.defaultCourseColor, for: SlotLocation(day: col, period: period))
            }

            if let fields = s["syllabusFields"] as? [String: String], !fields.isEmpty {
                let cacheKey = course.syllabusURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? course.syllabusURL!
                    : course.id
                SyllabusDataCache.shared.save(fields, for: cacheKey)
            }

            assigned[slotIdx] = normalizeCourseDisplayFields(course)
            importCount += 1
        }

        print("[PortalImport] importCount=\(importCount)")
        guard importCount > 0 else {
            print("[PortalImport] ⚠️ importCount=0, aborting")
            return
        }

        // 位置インデックス付きの [Course?] として保存
        // （timetable.swift の loadAssigned が期待するフォーマット）
        if let data = try? JSONEncoder().encode(assigned) {
            UserDefaults.standard.set(data, forKey: term.storageKey)
        }

        // 時間割タブに切り替え
        if let tab = window?.rootViewController as? UITabBarController {
            tab.selectedIndex = 0
        }

        // ★ alert の OK を待たずに即時再描画する
        //   → AppGatekeeper 等が先に VC を表示していても確実に反映される
        NotificationCenter.default.post(name: .portalImportDidComplete, object: nil)

        // 成績データがペイロードに埋め込まれていれば同時取り込み（アラートは時間割側にまとめる）
        var gradesLine = ""
        if let gradesArr = json["grades"] as? [[String: Any]], !gradesArr.isEmpty {
            importGradesData(json, window: window, showAlert: false)
            let gpa = json["gpa"] as? String ?? ""
            if !gpa.isEmpty {
                gradesLine = "\nGPA: \(gpa)"
            }
        }

        // ユーザーへの完了アラート（表示できない場合は無視）
        let top = window?.rootViewController?.presentedViewController
               ?? window?.rootViewController
        let alert = UIAlertController(
            title: "取り込み完了 ✓",
            message: "\(importCount)件の授業を\(term.displayTitle)に追加しました\(gradesLine)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        top?.present(alert, animated: true)
    }

    // MARK: - App Group Pending Import

    /// AogakuAction Extension が App Group に書き込んだ保留データを処理する。
    /// SceneDelegate.sceneDidBecomeActive から呼ぶ。
    static func processPendingPortalImport(window: UIWindow?) {
        let defaults = UserDefaults(suiteName: "group.jp.forta.Aogaku")
        print("[PortalImport] processPending called. defaults=\(defaults != nil ? "OK" : "NIL")")

        guard let data = defaults?.data(forKey: "pendingPortalImport") else {
            print("[PortalImport] no pendingPortalImport data found")
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[PortalImport] JSON parse failed")
            return
        }
        print("[PortalImport] found pending data, subjects=\((json["subjects"] as? [[String:Any]])?.count ?? -1)")

        // 一度だけ処理するために即座に削除
        defaults?.removeObject(forKey: "pendingPortalImport")
        defaults?.synchronize()

        importPortalData(json, window: window)
    }

    private static func resizeAssignedPreservingSlots(
        _ loaded: [Course?],
        newDayCount: Int,
        newPeriodCount: Int
    ) -> [Course?] {
        let expectedCount = newDayCount * newPeriodCount
        var output = Array<Course?>(repeating: nil, count: expectedCount)

        guard let oldDayCount = inferDayCount(for: loaded.count) else {
            for i in 0..<min(loaded.count, expectedCount) {
                output[i] = loaded[i].map(normalizeCourseDisplayFields)
            }
            return output
        }

        let oldPeriodCount = max(1, loaded.count / oldDayCount)
        let copyPeriods = min(oldPeriodCount, newPeriodCount)
        let copyDays = min(oldDayCount, newDayCount)

        for period in 1...copyPeriods {
            for day in 0..<copyDays {
                let oldIndex = (period - 1) * oldDayCount + day
                let newIndex = (period - 1) * newDayCount + day
                if loaded.indices.contains(oldIndex), output.indices.contains(newIndex) {
                    output[newIndex] = loaded[oldIndex].map(normalizeCourseDisplayFields)
                }
            }
        }
        return output
    }

    private static func loadExistingAssigned(
        term: TermKey,
        dayCount: Int,
        periodCount: Int
    ) -> [Course?]? {
        let expectedCount = dayCount * periodCount
        guard let data = UserDefaults.standard.data(forKey: term.storageKey) else {
            return nil
        }

        if let loaded = try? JSONDecoder().decode([Course?].self, from: data) {
            let normalizedLoaded = loaded.map { $0.map(normalizeCourseDisplayFields) }
            if loaded.count == expectedCount {
                return normalizedLoaded
            }
            let remapped = resizeAssignedPreservingSlots(
                normalizedLoaded,
                newDayCount: dayCount,
                newPeriodCount: periodCount
            )
            print("[PortalImport] remapped existing assigned[\(loaded.count)] → [\(expectedCount)]")
            return remapped
        }

        if let flatCourses = try? JSONDecoder().decode([Course].self, from: data) {
            let restored = restoreAssignedSlots(
                from: flatCourses,
                dayCount: dayCount,
                periodCount: periodCount
            )
            print("[PortalImport] restored existing flat courses[\(flatCourses.count)] → [\(expectedCount)]")
            return restored
        }

        print("[PortalImport] existing assigned decode failed; keeping import scoped to parsed slots")
        return nil
    }

    private static func restoreAssignedSlots(
        from courses: [Course],
        dayCount: Int,
        periodCount: Int
    ) -> [Course?] {
        var output = Array<Course?>(repeating: nil, count: dayCount * periodCount)
        let dayIndexMap: [String: Int] = [
            "月": 0, "火": 1, "水": 2, "木": 3, "金": 4, "土": 5,
            "月曜": 0, "火曜": 1, "水曜": 2, "木曜": 3, "金曜": 4, "土曜": 5,
            "月曜日": 0, "火曜日": 1, "水曜日": 2, "木曜日": 3, "金曜日": 4, "土曜日": 5,
        ]

        for course in courses {
            guard
                let rawDay = course.timeDay,
                let day = dayIndexMap[rawDay] ?? dayIndexMap[String(rawDay.prefix(1))],
                day < dayCount,
                let period = course.periods?.first,
                period >= 1,
                period <= periodCount
            else {
                continue
            }
            output[(period - 1) * dayCount + day] = normalizeCourseDisplayFields(course)
        }
        return output
    }

    private static func normalizeCourseDisplayFields(_ course: Course) -> Course {
        let normalizedTitle = normalizePortalDisplayText(course.title)
        let normalizedRoom = normalizePortalDisplayText(course.room)
        guard normalizedTitle != course.title || normalizedRoom != course.room else {
            return course
        }

        var normalized = Course(
            id: course.id,
            title: normalizedTitle,
            room: normalizedRoom,
            teacher: course.teacher,
            credits: course.credits,
            campus: course.campus,
            category: course.category,
            syllabusURL: course.syllabusURL,
            term: course.term
        )
        normalized.timeDay = course.timeDay
        normalized.periods = course.periods
        normalized.firestoreDocID = course.firestoreDocID
        return normalized
    }

    /// ポータル由来の全角英数字・記号だけを半角化する。
    /// Foundation の fullwidthToHalfwidth は日本語カナまで半角になる可能性があるため、
    /// U+FF01...U+FF5E と全角スペースだけに限定する。
    private static func normalizePortalDisplayText(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { scalar in
            if scalar.value == 0x3000 {
                return UnicodeScalar(0x20)!
            }
            if (0xFF01...0xFF5E).contains(scalar.value),
               let converted = UnicodeScalar(scalar.value - 0xFEE0) {
                return converted
            }
            return scalar
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func inferDayCount(for count: Int) -> Int? {
        if count == 0 { return nil }
        if count % 6 == 0 { return 6 }
        if count % 5 == 0 { return 5 }
        return nil
    }

    // MARK: - Grades Import

    /// AogakuAction Extension が App Group に書き込んだ成績データを処理する。
    /// SceneDelegate.sceneDidBecomeActive から呼ぶ。
    static func processPendingGradesImport(window: UIWindow?) {
        let defaults = UserDefaults(suiteName: "group.jp.forta.Aogaku")
        guard let data = defaults?.data(forKey: "pendingGradesImport"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        // 一度だけ処理
        defaults?.removeObject(forKey: "pendingGradesImport")
        defaults?.synchronize()
        importGradesData(json, window: window)
    }

    private static func importGradesData(_ json: [String: Any], window: UIWindow?, showAlert: Bool = true) {
        let recordsRaw = json["grades"] as? [[String: Any]] ?? []

        func intValue(_ v: Any?) -> Int? {
            if let i = v as? Int    { return i }
            if let n = v as? NSNumber { return n.intValue }
            if let s = v as? String   { return Int(s) }
            return nil
        }
        func nullableInt(_ v: Any?) -> Int? {
            guard let i = intValue(v), i >= 0 else { return nil }
            return i
        }

        let records: [GradeRecord] = recordsRaw.compactMap { r in
            guard let name = r["name"] as? String, !name.isEmpty else { return nil }
            return GradeRecord(
                name:     name,
                teacher:  r["teacher"]  as? String ?? "",
                grade:    (r["grade"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                credits:  intValue(r["credits"]) ?? 0,
                year:     intValue(r["year"])    ?? 0,
                category: r["category"] as? String ?? ""
            )
        }

        let summaryRaw = json["creditSummary"] as? [[String: Any]] ?? []
        let summary: [CreditSummaryItem] = summaryRaw.compactMap { s in
            guard let label = s["label"] as? String, !label.isEmpty else { return nil }
            return CreditSummaryItem(
                label:    label,
                required: nullableInt(s["required"]),
                earned:   nullableInt(s["earned"])
            )
        }

        let data = GradesData(
            records:       records,
            creditSummary: summary,
            gpa:           json["gpa"]           as? String ?? "",
            onlineCredits: json["onlineCredits"] as? String ?? "",
            importedAt:    Date(),
            username:      json["username"]      as? String ?? "",
            department:    json["department"]    as? String ?? ""
        )

        GradeStore.save(data)
        print("[GradesImport] saved \(records.count) records, GPA=\(data.gpa)")

        NotificationCenter.default.post(name: .gradesImportDidComplete, object: nil)

        guard showAlert else { return }

        let passed  = records.filter { $0.isPassed }.count
        let message = "GPA: \(data.gpa)\n合格 \(passed) 件 / 全 \(records.count) 件"
        let top = window?.rootViewController?.presentedViewController
                ?? window?.rootViewController
        let alert = UIAlertController(
            title: "成績を取り込みました ✓",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        top?.present(alert, animated: true)
    }

    private static func findTimetable(from vc: UIViewController?) -> timetable? {
        if let tt = vc as? timetable { return tt }
        if let nav = vc as? UINavigationController { return nav.viewControllers.compactMap({ $0 as? timetable }).first }
        if let tab = vc as? UITabBarController {
            return tab.viewControllers?.compactMap { findTimetable(from: $0) }.first
        }
        return vc?.children.compactMap { findTimetable(from: $0) }.first
    }

    private static func ttJump(_ tt: timetable, to dayIndex: Int?) {
        // 今は「時間割を開く」だけで十分なら何もしないでOK。
        // 将来、曜日にスクロール等をしたい場合に備えて hook を用意
        // 例）tt.scrollTo(day: dayIndex) を用意して呼ぶ
    }
}
