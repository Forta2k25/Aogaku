import UIKit
import FirebaseFirestore

/// 友だちの時間割（閲覧専用）
final class FriendTimetableViewController: UIViewController {

    // MARK: - Public
    init(friendUid: String, friendName: String?) {
        self.friendUid = friendUid
        self.friendName = friendName
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Props
    private let friendUid: String
    private let friendName: String?
    private var courses: [GridCell] = []          // 取得したコマ
    // 土曜は「ある時だけ出す」ため、既定は平日(= index 0...4)にしておく
    private var maxDay: Int = 4                   // 0:月 … 4:金（5=土があれば拡張）
    private var maxPeriod: Int = 5                // 1..N（6,7限はデータがある時だけ拡張）

    // MARK: - UI
    private let scroll = UIScrollView()
    private let content = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let header = UILabel()
    
    // MARK: - Layout tuning
    private enum Layout {
        static let afterWeekHeaderSpacing: CGFloat = 20   // 曜日→1限の間
        static let leftColumnWidth: CGFloat = 30      // ← 左の1〜5を極細に
        static let minBadgeHeight: CGFloat = 28
        static let interItemSpacing: CGFloat = 4      // ← マス間の横・縦の隙間を最小に
        static let rowSpacing: CGFloat = 4            // ← 行と行の間
        static let contentMargins = UIEdgeInsets(top: 4, left: 0, bottom: 16, right: 8)
        static let headerFontSize: CGFloat = 12
        static let periodTimeGap: CGFloat = 2   // 時限番号と時間ラベルの間隔

    }


    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = friendName.map { "\($0) の時間割" } ?? "友だちの時間割"

        setupUI()
        spinner.startAnimating()
        loadLatestTermAndBuild()
    }

    // MARK: - UI build
    private func setupUI() {
        header.text = ""
        header.font = .systemFont(ofSize: Layout.headerFontSize, weight: .medium)
        header.textColor = .secondaryLabel
        header.textAlignment = .center

        content.axis = .vertical
        content.spacing = Layout.rowSpacing
        content.layoutMargins = Layout.contentMargins
        content.isLayoutMarginsRelativeArrangement = true

        scroll.addSubview(content)
        view.addSubview(scroll)
        view.addSubview(spinner)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            content.topAnchor.constraint(equalTo: scroll.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.widthAnchor),

            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        content.addArrangedSubview(header)
        // ヘッダ直下の余白もキツめに
        content.setCustomSpacing(4, after: header)
    }

    private func buildGrid() {
        // 既存をクリア（header は残す）
        content.arrangedSubviews.dropFirst().forEach { $0.removeFromSuperview() }

        let weekTitles = ["月","火","水","木","金","土"]
        let columns = min(maxDay + 1, weekTitles.count)

        // 見出し行（曜日）
        let headerRow = makeWeekHeader(columns: columns, titles: weekTitles)
        content.addArrangedSubview(headerRow)

        // ★ 曜日ラベルの直後だけ少し大きめの余白を入れる
        content.setCustomSpacing(Layout.afterWeekHeaderSpacing, after: headerRow)

        // コマ行
        for p in 1...maxPeriod {
            content.addArrangedSubview(makeRow(period: p, columns: columns))
        }
    }


    // 左端（コマ番号）を固定幅に、右側を等幅で並べる二段スタック
    private func makeWeekHeader(columns: Int, titles: [String]) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .fill
        row.spacing = Layout.interItemSpacing

        // 左端は “幅だけあるダミー” で列位置を揃える
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: Layout.leftColumnWidth).isActive = true
        row.addArrangedSubview(spacer)

        let cols = UIStackView()
        cols.axis = .horizontal
        cols.alignment = .top         // ← 一番上に詰める
        cols.distribution = .fillEqually
        cols.spacing = Layout.interItemSpacing

        for d in 0..<columns {
            let lbl = UILabel()
            lbl.text = titles[d]
            lbl.font = .systemFont(ofSize: 13, weight: .semibold)
            lbl.textAlignment = .center
            lbl.textColor = .secondaryLabel
            // 上下の余白を極小化
            let wrapper = UIView()
            wrapper.addSubview(lbl)
            lbl.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                lbl.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 0),
                lbl.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor)
            ])
            cols.addArrangedSubview(wrapper)
        }

        row.addArrangedSubview(cols)
        return row
    }


    private func makeRow(period: Int, columns: Int) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .fill
        row.spacing = Layout.interItemSpacing

        // 左端：コマ番号（細く / 高さは“以上”）
        row.addArrangedSubview(makePeriodBadge(period: period))

        let cols = UIStackView()
        cols.axis = .horizontal
        cols.alignment = .fill
        cols.distribution = .fillEqually
        cols.spacing = Layout.interItemSpacing   // ← セル間を狭く
        for day in 0..<columns {
            let cellView = makeCourseCell()
            if let course = courses.first(where: { $0.day == day && $0.period == period }) {
                apply(course: course, to: cellView)
            }
            cols.addArrangedSubview(cellView)
        }
        row.addArrangedSubview(cols)
        return row
    }
    
    private func makeBadge(text: String, bg: UIColor,
                           width: CGFloat = Layout.leftColumnWidth,
                           minHeight: CGFloat = Layout.minBadgeHeight) -> UIView {
        let v = UIView()
        v.backgroundColor = bg
        v.layer.cornerRadius = 8

        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textAlignment = .center
        label.textColor = .secondaryLabel

        v.addSubview(label)
        v.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: width),
            v.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
            label.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: v.centerYAnchor)
        ])
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return v
    }
    
    private func makePeriodBadge(period: Int) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.translatesAutoresizingMaskIntoConstraints = false

        // 上時間
        let top = UILabel()
        top.text = periodTimes(period)?.start ?? ""
        top.font = .systemFont(ofSize: 11)
        top.textColor = .secondaryLabel
        top.textAlignment = .center
        top.translatesAutoresizingMaskIntoConstraints = false

        // 中央の時限番号
        let mid = UILabel()
        mid.text = "\(period)"
        mid.font = .systemFont(ofSize: 18, weight: .bold)
        mid.textColor = .label
        mid.textAlignment = .center
        mid.setContentCompressionResistancePriority(.required, for: .vertical)
        mid.translatesAutoresizingMaskIntoConstraints = false

        // 下時間
        let bottom = UILabel()
        bottom.text = periodTimes(period)?.end ?? ""
        bottom.font = .systemFont(ofSize: 11)
        bottom.textColor = .secondaryLabel
        bottom.textAlignment = .center
        bottom.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(top)
        v.addSubview(mid)
        v.addSubview(bottom)

        NSLayoutConstraint.activate([
            // 列幅はそのまま
            v.widthAnchor.constraint(equalToConstant: Layout.leftColumnWidth),
            v.heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.minBadgeHeight),

            // 中央に時限番号
            mid.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            mid.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            mid.trailingAnchor.constraint(equalTo: v.trailingAnchor),

            // 時間ラベルは「中央のすぐ上/下」に寄せる
            top.bottomAnchor.constraint(equalTo: mid.topAnchor, constant: -Layout.periodTimeGap),
            bottom.topAnchor.constraint(equalTo: mid.bottomAnchor, constant: Layout.periodTimeGap),

            // 左右いっぱい使って表示切れを防ぐ
            top.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            bottom.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: v.trailingAnchor),

            // 端との最小マージン（上下に貼り付きすぎないように弱め制約）
            top.topAnchor.constraint(greaterThanOrEqualTo: v.topAnchor, constant: 2),
            bottom.bottomAnchor.constraint(lessThanOrEqualTo: v.bottomAnchor, constant: -2),
        ])

        // つぶれ防止
        top.setContentCompressionResistancePriority(.required, for: .vertical)
        bottom.setContentCompressionResistancePriority(.required, for: .vertical)

        return v
    }



    private func makeCourseCell() -> UIView {
        let container = UIView()
        container.backgroundColor = .secondarySystemBackground
        container.layer.cornerRadius = 6
        container.layer.borderWidth = 0.5
        container.layer.borderColor = UIColor.separator.cgColor

        let title = UILabel()
        title.numberOfLines = 3
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .label
        title.textAlignment = .center
        title.tag = 11

        let sub = UILabel()
        sub.numberOfLines = 2
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabel
        sub.textAlignment = .center
        sub.tag = 12

        let stack = UIStackView(arrangedSubviews: [title, sub])
        stack.axis = .vertical
        stack.spacing = 2

        container.addSubview(stack)
        container.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // 最低高さをしっかり確保
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 116),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])
        return container
    }
    
    // MARK: - Period time table（必要に応じて調整可）
    private func periodTimes(_ p: Int) -> (start: String, end: String)? {
        let map: [Int: (String, String)] = [
            1: ("9:00",  "10:30"),
            2: ("11:00", "12:30"),
            3: ("13:20", "14:50"),
            4: ("15:05", "16:35"),
            5: ("16:50", "18:20"),
            6: ("18:30", "20:00"),
            7: ("20:10", "21:40")
        ]
        return map[p]
    }


    private func apply(course: GridCell, to view: UIView) {
        (view.viewWithTag(11) as? UILabel)?.text = course.title
        // 要望に合わせて「教室番号のみ」をサブに表示（無ければ空）
        (view.viewWithTag(12) as? UILabel)?.text = course.room ?? ""
    }


    // MARK: - Firestore load（最新学期 → ドキュメント名決定）
    private func loadLatestTermAndBuild() {
        let term = Term.latest()
        // CHANGE: Firestore の命名に合わせて "年_前期/後期" のピリオド区切りにする
        // 例: assignedCourses.2025_前期
        let docId = "assignedCourses.\(term.year)_\(term.semesterRaw)"

        Firestore.firestore()
            .collection("users")
            .document(friendUid)
            .collection("timetable")
            .document(docId)
            .getDocument { [weak self] snap, error in
                guard let self else { return }
                self.spinner.stopAnimating()

                guard error == nil, let data = snap?.data() else {
                    self.header.text = "時間割が見つかりません（\(docId)）"
                    self.buildGrid()
                    return
                }
                // ── データ取り出し ────────────────────────────────
                // 期待: cells = { "d0p1": {...}, "d4p4": {...}, ... }
                // ほか: ドキュメント直下に "cells.d0p1": {...} の形で平坦化されている可能性もある
                var parsed: [GridCell] = []

                // 1) まずは通常のネスト { cells: { d0p1: {...} } } を試す
                if let cells = data["cells"] as? [String: Any] {
                    for (k, v) in cells {
                        guard let dict = v as? [String: Any] else { continue }
                        if let gc = gridCell(fromKey: k, value: dict) {
                            parsed.append(gc)
                        } else if let day = k.firstMatch(#"d(\d+)"#).flatMap({ Int($0[1]) }) {
                            // ネスト: "d0": { "p1": {...} }
                            for (pk, pv) in dict {
                                if let pd = pk.firstMatch(#"p(\d+)"#).flatMap({ Int($0[1]) }),
                                   let inner = pv as? [String: Any],
                                   let title = (inner["title"] as? String), !title.isEmpty {
                                    parsed.append(GridCell(day: day, period: pd,
                                                           title: title,
                                                           teacher: inner["teacher"] as? String,
                                                           room: inner["room"] as? String))
                                }
                            }
                        }
                    }
                }

                // 2) フォールバック：トップレベルが "cells.d0p1" 形式の場合も拾う
                if parsed.isEmpty {
                    for (rawKey, value) in data {
                        guard rawKey.hasPrefix("cells."),
                              let dict = value as? [String: Any] else { continue }
                        // "cells.d0p1" -> "d0p1" を取り出して通常のキーとして解釈
                        let subkey = String(rawKey.dropFirst("cells.".count))
                        if let gc = gridCell(fromKey: subkey, value: dict) {
                            parsed.append(gc)
                        }
                    }
                }

                self.courses = parsed

                // 列・行の出し分け（データがある時だけ拡張）
                if let maxD = self.courses.map(\.day).max() { self.maxDay = max(4, maxD) } else { self.maxDay = 4 }
                if let maxP = self.courses.map(\.period).max() { self.maxPeriod = max(5, maxP) } else { self.maxPeriod = 5 }

                self.header.text = "\(term.year)年\(term.semesterJP) を表示中"
                self.buildGrid()

            }
    }

    /// key 文字列や値の day/period を見て GridCell を復元
    private func gridCell(fromKey key: String, value: [String: Any]) -> GridCell? {
        // ① key に dN / pN が両方ある（d..p / p..d の両方を許容）
        if let cap = key.firstMatch(#"d(\d+).*p(\d+)|p(\d+).*d(\d+)"#) {
            let d = Int(cap[1]) ?? Int(cap[4]) ?? 0
            let p = Int(cap[2]) ?? Int(cap[3]) ?? 1
            let title = (value["title"] as? String) ?? ""
            if title.isEmpty { return nil }
            return GridCell(day: d,
                            period: p,
                            title: title,
                            teacher: value["teacher"] as? String,
                            room: value["room"] as? String)
        }
        // ② 値の中に day / period がある
        let possibleDayKeys = ["day","weekday","d","w"]
        let possiblePeriodKeys = ["period","p"]
        let day = possibleDayKeys.compactMap { value[$0] as? Int }.first
        let per = possiblePeriodKeys.compactMap { value[$0] as? Int }.first
        if let d = day, let p = per {
            let title = (value["title"] as? String) ?? ""
            if title.isEmpty { return nil }
            return GridCell(day: d,
                            period: p,
                            title: title,
                            teacher: value["teacher"] as? String,
                            room: value["room"] as? String)
        }
        return nil
    }
}

// MARK: - Models / Helpers
private struct GridCell {
    let day: Int      // 0:月 …
    let period: Int   // 1..N
    let title: String
    let teacher: String?
    let room: String?
}

private struct Term {
    let year: Int
    /// "前期" or "後期"
    let semesterRaw: String
    var semesterJP: String { semesterRaw }

    /// 10月〜翌3月 = 後期 / それ以外 = 前期
    static func latest(date: Date = Date()) -> Term {
        let cal = Calendar(identifier: .gregorian)
        let y = cal.component(.year, from: date)
        let m = cal.component(.month, from: date)
        return (m >= 10) ? Term(year: y, semesterRaw: "後期")
                         : Term(year: y, semesterRaw: "前期")
    }
}

// 正規表現 1st マッチのキャプチャ配列を返す
private extension String {
    func firstMatch(_ pattern: String) -> [String]? {
        guard let r = try? NSRegularExpression(pattern: pattern) else { return nil }
        guard let m = r.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        var caps: [String] = []
        for i in 0..<m.numberOfRanges {
            let range = m.range(at: i)
            if let r = Range(range, in: self) { caps.append(String(self[r])) }
        }
        return caps.count > 1 ? caps : nil
    }
}
