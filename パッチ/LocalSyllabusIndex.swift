// LocalSyllabusIndex.swift
import Foundation
import FirebaseRemoteConfig

// 検索に使う最小項目（サーバ生成JSONの1行）
struct SyllabusRaw: Codable {
    let id: String
    let class_name: String
    let teacher_name: String
    let category: String
    let grade: String
    let campus: [String]    // 文字列 or 配列でも良いが、配列に寄せる
    let time: Time?
    let term: String
    let credit: Int?
    let eval_method: String?
    struct Time: Codable {
        let day: String?
        let periods: [Int]?
    }
}

// メモリ常駐エントリ（正規化＋インデックス済み）
private struct SyllabusEntry {
    let raw: SyllabusRaw
    let aggNorm: String          // 授業名+教員名（既存 normalize に合わせる）
    let nameNorm: String         // 授業名の正規化（1文字prefix用）
    let teacherNorm: String      // 教員名の正規化（1文字prefix用）
    let termNorm: String         // 学期の代表表記
    let grams2: [String]         // n-gram(2)（候補抽出用）
}

final class LocalSyllabusIndex {

    static let shared = LocalSyllabusIndex()
    private init() {}

    // RCキー（必要なら命名変更OK）
    private let rcKeyURL = "syllabusIndexURL"
    private let rcKeyVersion = "syllabusIndexVersion"

    // 永続キャッシュ
    private var diskURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("syllabus_index.json", conformingTo: .json)
    }
    private let versionKey = "syllabus_index_version"

    // メモリ常駐
    private var entries: [SyllabusEntry] = []
    private var gram2Posting: [String: [Int]] = [:]  // 2gram -> entry indices
    private(set) var isReady = false

    // 外からワンコールで用意
    func prepare() {
        // 1) 手元にあるならまず読む
        if loadFromDiskAndBuild() {
            isReady = true
        }
        // 2) RCを見て必要なら更新
        fetchRemoteConfigAndUpdate()
    }

    // ==== Remote Config & ダウンロード ====
    private func fetchRemoteConfigAndUpdate() {
        let rc = RemoteConfig.remoteConfig()
        rc.fetchAndActivate { [weak self] _, _ in
            guard let self = self else { return }
            let urlStr = rc[self.rcKeyURL].stringValue ?? ""
            let version = rc[self.rcKeyVersion].stringValue ?? ""
            guard let url = URL(string: urlStr), !version.isEmpty else { return }

            let current = UserDefaults.standard.string(forKey: self.versionKey) ?? ""
            guard current != version || !FileManager.default.fileExists(atPath: self.diskURL.path) else {
                return // 既に最新
            }
            self.downloadIndex(from: url) { ok in
                if ok, self.loadFromDiskAndBuild() {
                    UserDefaults.standard.set(version, forKey: self.versionKey)
                    self.isReady = true
                }
            }
        }
    }

    private func downloadIndex(from url: URL, completion: @escaping (Bool) -> Void) {
        let task = URLSession.shared.dataTask(with: url) { data, resp, err in
            guard let data = data, err == nil else { completion(false); return }
            do {
                try data.write(to: self.diskURL, options: .atomic)
                completion(true)
            } catch {
                completion(false)
            }
        }
        task.resume()
    }

    private func loadFromDiskAndBuild() -> Bool {
        guard let data = try? Data(contentsOf: diskURL) else { return false }
        guard let raws = try? JSONDecoder().decode([SyllabusRaw].self, from: data) else { return false }

        // ビルド
        var built: [SyllabusEntry] = []
        built.reserveCapacity(raws.count)
        for r in raws {
            let nameNorm = normalizeForSearch(r.class_name)
            let teacherNorm = normalizeForSearch(r.teacher_name)
            let agg = normalizeForSearch(r.class_name + r.teacher_name)  // 既存と同じ指標で最終判定
            let termN = normalizeTerm(r.term)
            // n-gramは、ひらがな長音削除と、カタカナ長音保持をインターリーブ（既存ロジック踏襲）
            let hira = ngrams2Raw(normalizeForSearch(r.class_name + r.teacher_name))
            let kata = ngrams2Raw(squashForTokensKeepingLong(r.class_name + r.teacher_name))
            var grams: [String] = []
            grams.reserveCapacity(max(hira.count, kata.count))
            var seen = Set<String>()
            for i in 0..<max(hira.count, kata.count) {
                if i < hira.count, seen.insert(hira[i]).inserted { grams.append(hira[i]) }
                if i < kata.count, seen.insert(kata[i]).inserted { grams.append(kata[i]) }
            }
            built.append(SyllabusEntry(
                raw: r, aggNorm: agg, nameNorm: nameNorm, teacherNorm: teacherNorm, termNorm: termN, grams2: grams
            ))
        }
        // postings
        var posting: [String: [Int]] = [:]
        for (idx, e) in built.enumerated() {
            for g in e.grams2.prefix(50) { // エントリあたり上限でメモリ抑制
                posting[g, default: []].append(idx)
            }
        }
        // 確定
        self.entries = built
        self.gram2Posting = posting
        return true
    }

    // ==== 公開検索API ====
    func search(text rawText: String, criteria: SyllabusSearchCriteria) -> [syllabus.SyllabusData] {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        // 候補抽出
        var candidates: [Int] = []
        if text.count == 1 {
            // 軽量 prefix（授業名 / 教員名）
            let key = normalizeForSearch(text)
            for (i, e) in entries.enumerated() where
                (e.nameNorm.hasPrefix(key) || e.teacherNorm.hasPrefix(key)) {
                candidates.append(i)
            }
        } else {
            let tokens = tokensForArrayContainsAny(text)
            if tokens.isEmpty {
                candidates = Array(entries.indices)
            } else {
                var seen = Set<Int>()
                for t in tokens {
                    if let list = gram2Posting[t] {
                        for id in list { if seen.insert(id).inserted { candidates.append(id) } }
                    }
                }
                if candidates.isEmpty {
                    candidates = Array(entries.indices) // 念のため
                }
            }
        }

        // 最終判定（substring contains, 既存と同じ）＋ すべての条件フィルタ
        let q = normalizeForSearch(text)
        var out: [syllabus.SyllabusData] = []
        out.reserveCapacity(min(200, candidates.count))
        for i in candidates {
            let e = entries[i]
            guard e.aggNorm.contains(q) else { continue }
            if !matchesFilters(entry: e, criteria: criteria) { continue }
            out.append(toModel(e))
        }
        // 並びは既存に寄せる
        if text.count == 1 {
            return out
        } else {
            return out.sorted { $0.class_name.localizedStandardCompare($1.class_name) == .orderedAscending }
        }
    }

    // ===== 既存ロジック互換のフィルタ =====

    private func matchesFilters(entry e: SyllabusEntry, criteria c: SyllabusSearchCriteria) -> Bool {
        // 学部 → 学科展開（既存UIと同じ挙動）
        if let dept = c.department, !dept.isEmpty {
            if e.raw.category != dept { return false }
        } else if let list = expandedCategories(c.category) {
            if !list.contains(e.raw.category) { return false }
        }

        // campus
        if let wantCampus = c.campus, !wantCampus.isEmpty {
            let want = canonicalizeCampusString(wantCampus) ?? wantCampus
            let set = Set(e.raw.campus.compactMap { canonicalizeCampusString($0) })
            if !set.contains(want) { return false }
        }

        // place（授業名末尾の [オンライン] で判定）
        if let place = c.place, !place.isEmpty {
            let name = e.raw.class_name
            if place == "オンライン" {
                if !isOnlineClassName(name) { return false }
            } else if place == "対面" {
                if isOnlineClassName(name) { return false }
            }
        }

        // 学年
        if let g = c.grade, !g.isEmpty {
            let s = e.raw.grade
            if !(s == g || s.contains(g)) { return false }
        }

        // 不定（授業名に「不定」）
        if c.undecided == true {
            if !e.raw.class_name.contains("不定") { return false }
            // 不定時は曜日・時限スキップ
        } else {
            // 曜日 / 時限
            let docDay = e.raw.time?.day ?? ""
            let docPeriods = e.raw.time?.periods ?? []

            if let slots = c.timeSlots, !slots.isEmpty {
                let ok = slots.contains { $0.0 == docDay && docPeriods.contains($0.1) }
                if !ok { return false }
            } else {
                if let d = c.day, !d.isEmpty, docDay != d { return false }
                if let ps = c.periods {
                    if ps.count == 1 {
                        if !docPeriods.contains(ps[0]) { return false }
                    } else if ps.count > 1 {
                        if !Set(ps).isSubset(of: Set(docPeriods)) { return false }
                    }
                }
            }
        }

        // 学期（代表表記で比較・集中などは包含）
        if let wantTerm = c.term, !wantTerm.isEmpty {
            let doc = e.termNorm
            let want = normalizeTerm(wantTerm)
            switch want {
            case "集中":
                if !doc.contains("集中") { return false }
            case "通年":
                if !doc.hasPrefix("通年") { return false }
            case "前期":
                if !doc.hasPrefix("前期") { return false }
            case "後期":
                if !doc.hasPrefix("後期") { return false }
            default:
                if doc != want { return false }
            }
        }
        return true
    }

    // ===== 既存ユーティリティの“互換実装” =====
    private func normalizeTerm(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "[()（）\\s]", with: "", options: .regularExpression)
        if let x = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) { s = x }
        s = s.replacingOccurrences(of: "隔週第1週", with: "隔1")
             .replacingOccurrences(of: "隔週第2週", with: "隔2")
        switch s.lowercased() {
        case "前期","春学期","spring": return "前期"
        case "後期","秋学期","autumn","fall": return "後期"
        case "通年","年間","fullyear","yearlong": return "通年"
        default:
            s = s.replacingOccurrences(of: "通年隔週第1週", with: "通年隔1")
                 .replacingOccurrences(of: "通年隔週第2週", with: "通年隔2")
                 .replacingOccurrences(of: "前期隔週第1週", with: "前期隔1")
                 .replacingOccurrences(of: "前期隔週第2週", with: "前期隔2")
                 .replacingOccurrences(of: "後期隔週第1週", with: "後期隔1")
                 .replacingOccurrences(of: "後期隔週第2週", with: "後期隔2")
            return s
        }
    }

    private func toHiragana(_ s: String) -> String {
        let ms = NSMutableString(string: s) as CFMutableString
        CFStringTransform(ms, nil, kCFStringTransformHiraganaKatakana, true)
        return ms as String
    }
    private func toKatakana(_ s: String) -> String {
        let ms = NSMutableString(string: s) as CFMutableString
        CFStringTransform(ms, nil, kCFStringTransformHiraganaKatakana, false)
        return ms as String
    }
    private func normalizeForSearch(_ raw: String) -> String {
        var s = raw
        if let x = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) { s = x }
        s = toHiragana(s).lowercased()
        s = s.replacingOccurrences(of: "[\\s\\p{Punct}ー‐-–—・／/,.、．\\[\\]［］()（）{}【】]+",
                                   with: "", options: .regularExpression)
        return s
    }
    private func squashForTokensKeepingLong(_ raw: String) -> String {
        var s = raw
        if let x = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) { s = x }
        s = toKatakana(s).lowercased()
        s = s.replacingOccurrences(of: "[\\s‐-–—・／/,.、．\\[\\]［］()（）{}【】]+",
                                   with: "", options: .regularExpression)
        return s
    }
    private func ngrams2Raw(_ prepared: String) -> [String] {
        let cs = Array(prepared)
        guard !cs.isEmpty else { return [] }
        if cs.count == 1 { return [String(cs[0])] }
        var out: [String] = []
        out.reserveCapacity(cs.count - 1)
        for i in 0..<(cs.count - 1) { out.append(String(cs[i]) + String(cs[i+1])) }
        return out
    }
    private func tokensForArrayContainsAny(_ text: String) -> [String] {
        let hira = ngrams2Raw(normalizeForSearch(text))
        let kata = ngrams2Raw(squashForTokensKeepingLong(text))
        var seen = Set<String>(), res: [String] = []
        var i = 0, n = max(hira.count, kata.count)
        while res.count < 10 && i < n {
            if i < hira.count { let t = hira[i]; if seen.insert(t).inserted { res.append(t) } }
            if res.count >= 10 { break }
            if i < kata.count { let t = kata[i]; if seen.insert(t).inserted { res.append(t) } }
            i += 1
        }
        return res
    }

    private func canonicalizeCampusString(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.contains("相模") || t.contains("sagamihara") || t == "s" { return "相模原" }
        if t.contains("青山") || t.contains("aoyama")     || t == "a" { return "青山" }
        return nil
    }
    private func isOnlineClassName(_ name: String) -> Bool {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "[\\[［\\(（【]\\s*オンライン\\s*[\\]］\\)）】]\\s*$"
        return t.range(of: pattern, options: .regularExpression) != nil
    }
    private func expandedCategories(_ category: String?) -> [String]? {
        guard let cat = category, !cat.isEmpty else { return nil }
        // syllabus.swift の展開表に揃える（主要学部だけで十分）
        let expansion: [String: [String]] = [
            "文学部": ["文学部","文学部共通","文学部外国語科目","英米文学科","フランス文学科","日本文学科","史学科","比較芸術学科"],
            "教育人間科学部": ["教育人間科学部","教育人間 外国語科目","教育人間 教育学科","教育人間 心理学科","教育人間　外国語科目","教育人間　教育学科","教育人間　心理学科"],
            "経済学部": ["経済学部"],
            "法学部": ["法学部"],
            "経営学部": ["経営学部"],
            "国際政治経済学部": ["国際政治経済学部","国際政治学科","国際経済学科","国際コミュニケーション学科"],
            "総合文化政策学部": ["総合文化政策学部"],
            "理工学部": ["理工学部共通","物理・数理","化学・生命","機械創造","経営システム","情報テクノロジ－","物理科学","数理サイエンス"],
            "コミュニティ人間科学部": ["ｺﾐｭﾆﾃｨ人間科学部"],
            "社会情報学部": ["社会情報学部"],
            "地球社会共生学部": ["地球社会共生学部"],
            "青山スタンダード科目": ["青山スタンダード科目"],
            "教職課程科目": ["教職課程科目"]
        ]
        return expansion[cat] ?? [cat]
    }
    
    // 追加: 条件にマッチするローカル一覧を offset/limit で返す
    func page(criteria c: SyllabusSearchCriteria, offset: Int, limit: Int) -> [syllabus.SyllabusData] {
        var out: [syllabus.SyllabusData] = []
        var skipped = 0
        var taken = 0
        for e in entries {
            if !matchesFilters(entry: e, criteria: c) { continue }
            if skipped < offset { skipped += 1; continue }
            out.append(toModel(e))
            taken += 1
            if taken >= limit { break }
        }
        // 必要なら並びを軽めに整える
        out.sort { $0.class_name.localizedStandardCompare($1.class_name) == .orderedAscending }
        return out
    }

    // 追加：条件に合う全件を返す（limit指定可）
    func all(criteria c: SyllabusSearchCriteria, limit: Int? = nil) -> [syllabus.SyllabusData] {
        var out: [syllabus.SyllabusData] = []
        out.reserveCapacity( min(limit ?? entries.count, entries.count) )
        for e in entries {
            if !matchesFilters(entry: e, criteria: c) { continue }
            out.append(toModel(e))
            if let lim = limit, out.count >= lim { break }
        }
        return out.sorted { $0.class_name.localizedStandardCompare($1.class_name) == .orderedAscending }
    }

    // UI表示用へ変換（syllabus.swift の toModel と同等）
    private func toModel(_ e: SyllabusEntry) -> syllabus.SyllabusData {
        let day = e.raw.time?.day ?? ""
        let ps  = (e.raw.time?.periods ?? []).sorted()
        let timeStr: String = {
            if ps.isEmpty { return day }
            if ps.count == 1 { return "\(day)\(ps[0])" }
            return "\(day)\(ps.first!)-\(ps.last!)"
        }()
        let campusStr: String = {
    let normalized = e.raw.campus
        .map { canonicalizeCampusString($0) ?? $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    let uniqSorted = Array(Set(normalized)).sorted()
    return uniqSorted.joined(separator: ",")
}()// 追加：syllabus.swift の安定キー規則と同じにする
        let stableKey = [
            normalizeForSearch(e.raw.class_name),
            normalizeForSearch(e.raw.teacher_name),
            timeStr.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression),
            campusStr.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression).lowercased(),
            e.raw.grade.lowercased(),
            normalizeForSearch(e.raw.category),
            normalizeTerm(e.raw.term)
        ].joined(separator: "|")

        return syllabus.SyllabusData(
            docID: e.raw.id,
            stableKey: stableKey,
            class_name: e.raw.class_name,
            teacher_name: e.raw.teacher_name,
            time: timeStr,
            campus: campusStr,
            grade: e.raw.grade,
            category: e.raw.category,
            credit: String(e.raw.credit ?? 0),
            term: e.termNorm,
            eval_method: e.raw.eval_method ?? ""    // ★ 追加
        )
    }

}

