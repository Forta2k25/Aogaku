import UIKit
import FirebaseFirestore

// MARK: - モデル
private struct FavoriteItem {
    let docID: String
    let name: String
    let teacher: String?
    let regNumber: String?   // 登録番号（registration_number / code）
    let day: Int?            // 0=月…5=土（不明は nil）
    let period: Int?         // 1..7（不明は nil）
}

private struct SectionKey: Hashable {
    let day: Int?    // nil は「時間未設定」用
    let period: Int?
}

private struct Section {
    let key: SectionKey
    var items: [FavoriteItem]
}

final class FavoritesListViewController: UITableViewController {

    private let favoriteKey = "favoriteClassIDs"

    private var sections: [Section] = []
    private let daySymbols = ["月","火","水","木","金","土"]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "ブックマーク"
        tableView.rowHeight = 68
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        // .subtitle スタイルを使いたいので register はしない（都度生成）
        loadFavorites()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadFavorites()
    }

    // MARK: - データ読み込み & 整形

    private func loadFavorites() {
        // ★ 念のため保存側の重複をここで除去
        let ids = Array(Set(UserDefaults.standard.stringArray(forKey: favoriteKey) ?? []))
        if ids.isEmpty {
            sections = []
            tableView.reloadData()
            showEmptyIfNeeded()
            return
        }
        fetchByIDs(ids)
    }

    private func fetchByIDs(_ ids: [String]) {
        sections = []
        tableView.reloadData()

        let chunks: [[String]] = stride(from: 0, to: ids.count, by: 10).map { Array(ids[$0 ..< min($0 + 10, ids.count)]) }
        let col = Firestore.firestore().collection("classes")

        var remaining = chunks.count
        var pool: [FavoriteItem] = []
        var seen = Set<String>() // ★ 重複 docID を防止

        for group in chunks {
            col.whereField(FieldPath.documentID(), in: group).getDocuments { [weak self] snap, err in
                guard let self = self else { return }

                // ここで必ず呼ばれるので remaining 管理が崩れない
                defer {
                    remaining -= 1
                    if remaining == 0 { self.buildSections(from: pool) }
                }

                // ❌ continue は使えない → ✅ return に変更
                if let err = err {
                    print("❌ favorites fetch error:", err.localizedDescription)
                    return
                }
                guard let docs = snap?.documents else { return }

                for d in docs {
                    let id = d.documentID
                    if seen.contains(id) { continue }
                    seen.insert(id)

                    let data = d.data()
                    let name = (data["class_name"] as? String) ?? "（名称未設定）"
                    let teacher = data["teacher_name"] as? String
                    let reg = (data["registration_number"] as? String) ?? (data["code"] as? String)

                    var day: Int? = nil
                    var period: Int? = nil
                    if let t = data["time"] as? [String: Any] {
                        if let dayStr = t["day"] as? String,
                           let ch = dayStr.trimmingCharacters(in: .whitespaces).first {
                            day = ["月":0,"火":1,"水":2,"木":3,"金":4,"土":5][ch]
                        }
                        if let p = t["period"] as? Int { period = p }
                        else if let arr = t["periods"] as? [Int] { period = arr.first }
                    }

                    pool.append(FavoriteItem(docID: id,
                                             name: name,
                                             teacher: teacher,
                                             regNumber: reg,
                                             day: day,
                                             period: period))
                }
            }
        }
    }


    /// セクション（時限ごと）に分割し、月1 → … → 土7 → 時間未設定 の順で整列
    private func buildSections(from items: [FavoriteItem]) {
        // (day,period) => items
        var bucket: [SectionKey: [FavoriteItem]] = [:]
        for it in items {
            let key = SectionKey(day: it.day, period: it.period)
            bucket[key, default: []].append(it)
        }

        // section キーの並び順（nil は最後）
        func sectionOrder(_ k: SectionKey) -> (Int, Int) {
            let dayOrd = k.day ?? 99
            let periodOrd = k.period ?? 99
            return (dayOrd, periodOrd)
        }

        var built: [Section] = bucket
            .sorted { lhs, rhs in sectionOrder(lhs.key) < sectionOrder(rhs.key) }
            .map { (key, arr) in
                // 同一時限内は科目名昇順
                let sorted = arr.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return Section(key: key, items: sorted)
            }

        // 「時間未設定」セクションが無い時も問題ない
        self.sections = built
        self.tableView.reloadData()
        self.showEmptyIfNeeded()
    }

    private func showEmptyIfNeeded() {
        if sections.isEmpty {
            let label = UILabel()
            label.text = "ブックマークはまだありません"
            label.textAlignment = .center
            label.textColor = .secondaryLabel
            tableView.backgroundView = label
        } else {
            tableView.backgroundView = nil
        }
    }

    // MARK: - TableView DataSource

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let key = sections[section].key
        if let d = key.day, let p = key.period {
            return "\(daySymbols[d])\(p)"
        } else {
            return "時間未設定"
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].items.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // .subtitle スタイルで作成
        let cellID = "favCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: cellID) ??
                   UITableViewCell(style: .subtitle, reuseIdentifier: cellID)

        let item = sections[indexPath.section].items[indexPath.row]

        // ─ 表示：タイトルは Bold & 少し大きめ、サブは登録番号/教員名
        let titleFont = UIFont.systemFont(ofSize: 18, weight: .semibold) // ←「少しだけ大きく & Bold」
        cell.textLabel?.font = titleFont
        cell.textLabel?.text = item.name
        cell.textLabel?.numberOfLines = 2

        let reg = item.regNumber ?? "-"
        let teacherText = item.teacher ?? ""
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.text = "登録番号: \(reg)   \(teacherText)"

        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        let item = sections[indexPath.section].items[indexPath.row]
        let sb = UIStoryboard(name: "Main", bundle: nil)
        let anyVC = sb.instantiateViewController(withIdentifier: "SyllabusDetailViewController")

        // ① 直接 Detail VC の場合
        if let vc = anyVC as? SyllabusDetailViewController {
            vc.docID = item.docID
            vc.initialTitle = item.name
            vc.initialTeacher = item.teacher

            let nav = UINavigationController(rootViewController: vc)
            nav.setNavigationBarHidden(true, animated: false)          // ← ナビバーを隠す
            nav.modalPresentationStyle = .pageSheet
            if let sheet = nav.sheetPresentationController {
                sheet.detents = [.large()]
                sheet.selectedDetentIdentifier = .large
                sheet.prefersGrabberVisible = true    // つまみも消したい場合は false
                sheet.preferredCornerRadius = 16
            }
            present(nav, animated: true)
            return
        }

        // ② Storyboard 側で Nav に包まれている場合
        if let nav = anyVC as? UINavigationController,
           let vc = nav.viewControllers.first as? SyllabusDetailViewController {
            vc.docID = item.docID
            vc.initialTitle = item.name
            vc.initialTeacher = item.teacher

            nav.setNavigationBarHidden(true, animated: false)          // ← ナビバーを隠す
            nav.modalPresentationStyle = .pageSheet
            if let sheet = nav.sheetPresentationController {
                sheet.detents = [.large()]
                sheet.selectedDetentIdentifier = .large
                sheet.prefersGrabberVisible = true
                sheet.preferredCornerRadius = 16
            }
            present(nav, animated: true)
            return
        }

        assertionFailure("Storyboard ID \"SyllabusDetailViewController\" の型を確認してください。")
    }

    // 左スワイプでブックマーク解除
    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let remove = UIContextualAction(style: .destructive, title: "解除") { [weak self] _, _, done in
            guard let self = self else { return }
            let item = self.sections[indexPath.section].items[indexPath.row]
            var set = Set(UserDefaults.standard.stringArray(forKey: self.favoriteKey) ?? [])
            set.remove(item.docID)
            UserDefaults.standard.set(Array(set), forKey: self.favoriteKey)

            // セクション配列から削除
            self.sections[indexPath.section].items.remove(at: indexPath.row)
            if self.sections[indexPath.section].items.isEmpty {
                self.sections.remove(at: indexPath.section)
                tableView.deleteSections(IndexSet(integer: indexPath.section), with: .automatic)
            } else {
                tableView.deleteRows(at: [indexPath], with: .automatic)
            }
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }
}
