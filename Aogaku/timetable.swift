//
//  timetable.swift
//  Aogaku
//
//  Created by shu m on 2025/08/09.
//

import UIKit

struct SlotLocation {
    let day: Int   // 0=月…4=金
    let period: Int   // 1..rows
    var dayName: String { ["月","火","水","木","金","土"][day] }
}



final class timetable: UIViewController, CourseListViewControllerDelegate, CourseDetailViewControllerDelegate {
    
    func courseDetail(_ vc: CourseDetailViewController, didChangeColor key: SlotColorKey, at location: SlotLocation) {
            // 1) 保存
            SlotColorStore.set(key, for: location)

            // 2) 対象のボタンだけ即時更新（見つからない時は全面リビルド）
            let idx = gridIndex(for: location)
            if (0..<slotButtons.count).contains(idx) {
                let btn = slotButtons[idx]
                configureButton(btn, at: idx)
            } else {
                rebuildGrid()
            }
        
    }
    
    func courseDetail(_ vc: CourseDetailViewController, requestEditFor course: Course, at location: SlotLocation) {
        
        // 編集＝このコマを選び直す（シラバスページは閉じる）
        vc.dismiss(animated: true) {
            let listVC = CourseListViewController(location: location)
            listVC.delegate = self
            
            if let nav = self.navigationController {
                    nav.pushViewController(listVC, animated: true)
            } else {
                    let nav = UINavigationController(rootViewController: listVC)
                    nav.modalPresentationStyle = .fullScreen
                    self.present(nav, animated: true)
                    }
                }
    }
    
    func courseDetail(_ vc: CourseDetailViewController, requestDelete course: Course, at location: SlotLocation) {
        let idx = (location.period - 1) * self.dayLabels.count + location.day
        self.assigned[idx] = nil
        if let btn = self.slotButtons.first(where: { $0.tag == idx }) {
            self.configureButton(btn, at: idx)
        } else {
            self.reloadAllButtons()
        }
        vc.dismiss(animated: true)
    }
    
    func courseDetail(_ vc: CourseDetailViewController, didUpdate counts: AttendanceCounts, for course: Course, at location: SlotLocation) {
        // 必要ならここでサーバ保存など。今は何もしない。
        // print("updated counts:", counts)
    }
    
    func courseDetail(_ vc: CourseDetailViewController, didDeleteAt location: SlotLocation) {
            assigned[index(for: location)] = nil
            reloadAllButtons()
            saveAssigned()     // 追加
        }
    func courseDetail(_ vc: CourseDetailViewController, didEdit course: Course, at location: SlotLocation) {
            assigned[index(for: location)] = course
            reloadAllButtons()
            saveAssigned()     // 追加
        }
    
    
    
    
    func courseDetailDidRequestEdit(_ vc: CourseDetailViewController, at location: SlotLocation, current: Course) {
        vc.dismiss(animated: true) { [weak self] in
                    guard let self = self else { return }
                    let listVC = CourseListViewController(location: location)
                    listVC.delegate = self
                    if let nav = self.navigationController {
                        nav.pushViewController(listVC, animated: true)
                    } else {
                        let nav = UINavigationController(rootViewController: listVC)
                        nav.modalPresentationStyle = .fullScreen
                        self.present(nav, animated: true)
                    }
                }
    }
    
    func courseDetailDidRequestDelete(_ vc: CourseDetailViewController, at location: SlotLocation) {
        let idx = (location.period - 1) * dayLabels.count + location.day
                assigned[idx] = nil

                if let btn = slotButtons.first(where: { $0.tag == idx }) {
                    configureButton(btn, at: idx)
                } else {
                    reloadAllButtons()
                }
                vc.dismiss(animated: true)
    }
    
    
    private let scrollView = UIScrollView()
    private let contentView = UIView()   // スクロールの「中身」用コンテナ
    
    private var registeredCourses: [Int: Course] = [:]
    
    private var bgObserver: NSObjectProtocol?

    // ===== Header =====
    private let headerBar = UIStackView()
    private let leftButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let rightStack = UIStackView()
    private let rightA = UIButton(type: .system)
    private let rightB = UIButton(type: .system)
    private let rightC = UIButton(type: .system)

    
    // 1限〜7限までの開始・終了（必要に応じて編集）
    private let timePairs: [(start: String, end: String)] = [
        ("9:00",  "10:30"),
        ("11:00", "12:30"),
        ("13:20", "14:50"),
        ("15:05", "16:35"),
        ("16:50", "18:20"),
        ("18:30", "20:00"),
        ("20:10", "21:40")
    ]
    // 5%用の「数値制約」に変更（ここを更新して確実に反映させる）
    private var headerTopConstraint: NSLayoutConstraint!

    // ===== Grid =====
    private let gridContainerView = UIView()
    private var colGuides: [UILayoutGuide] = []  // 0列目=時限列, 1..=曜日列
    private var rowGuides: [UILayoutGuide] = []  // 0行目=ヘッダ行, 1..=各時限
    private(set) var slotButtons: [UIButton] = []

    // Grid の上下制約（あとで定数を調整）
    private var gridTopConstraint: NSLayoutConstraint!
    //private var gridBottomConstraint: NSLayoutConstraint! スクロール形式にするため削除
    
    
    private var settings = TimetableSettings.load()
    // ▼ 追加：現在の表示ラベル（設定から算出）
    private var dayLabels: [String] {
        settings.includeSaturday ? ["月","火","水","木","金","土"] : ["月","火","水","木","金"]
    }
    private var periodLabels: [String] { (1...settings.periods).map { "\($0)" } }

    // ▼ 追加：直近の列数・行数（再構築のときに使う）
    private var lastDaysCount = 5
    private var lastPeriodsCount = 5
    
    
    // 25 マス分の“登録科目”（未登録は nil）
    private var assigned: [Course?] = Array(repeating: nil, count: 25)

    // location → 配列 index 変換
    private func index(for loc: SlotLocation) -> Int {
        // day:0..4, period:1..5
        return (loc.period - 1) * dayLabels.count + loc.day
    }
    
    private let spacing: CGFloat = 6
    private let cellPadding: CGFloat = 4
    private let headerRowHeight: CGFloat = 36
    private let timeColWidth: CGFloat = 48
    private let topRatio: CGFloat = 0.02   // ← 上端から SafeArea 高さの 5%
    
    // MARK: - Persistence (UserDefaults)
    private let saveKey = "assignedCourses.v1"

    private func saveAssigned() {
        do {
            let data = try JSONEncoder().encode(assigned) // [Course?]
            UserDefaults.standard.set(data, forKey: saveKey)
            // print("💾 saved \(assigned.compactMap{$0}.count) courses")
        } catch {
            print("Save error:", error)
        }
    }

    private func loadAssigned() {
        guard let data = UserDefaults.standard.data(forKey: saveKey) else { return }
        do {
            let loaded = try JSONDecoder().decode([Course?].self, from: data)
            // 想定25マスならサイズを確認してから反映
            if loaded.count == assigned.count {
                assigned = loaded
            } else {
                // 将来マス数が変わった時の簡易マージ
                for i in 0..<min(assigned.count, loaded.count) { assigned[i] = loaded[i] }
            }
        } catch {
            print("Load error:", error)
        }
    }

    

    override func viewDidLoad() {
        super.viewDidLoad()
        
        normalizeAssigned()

        loadAssigned()
        view.backgroundColor = .systemBackground
        buildHeader()
        layoutGridContainer()
        buildGridGuides()
        placeHeaders()
        placePlusButtons()
        
        NotificationCenter.default.addObserver(self,
                selector: #selector(onSettingsChanged),
                name: .timetableSettingsChanged, object: nil)
        
        bgObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.saveAssigned() }
        }
        deinit {
            if let bgObserver { NotificationCenter.default.removeObserver(bgObserver) }

    }
    
    @objc private func onSettingsChanged() {
        // 旧サイズを退避
        let oldDays = lastDaysCount
        let oldPeriods = lastPeriodsCount

        // 設定を再読込
        settings = TimetableSettings.load()

        // 既存の割当を温存しつつ、新サイズへリサイズ
        assigned = remapAssigned(old: assigned,
                                 oldDays: oldDays, oldPeriods: oldPeriods,
                                 newDays: dayLabels.count, newPeriods: periodLabels.count)

        // グリッドを作り直し
        rebuildGrid()

        // 新しいカウントを保存
        lastDaysCount = dayLabels.count
        lastPeriodsCount = periodLabels.count
    }

    // 既存コマを“入る範囲だけ”コピー
    private func remapAssigned(old: [Course?],
                               oldDays: Int, oldPeriods: Int,
                               newDays: Int, newPeriods: Int) -> [Course?] {
        var dst = Array(repeating: nil as Course?, count: newDays * newPeriods)
        let copyDays = min(oldDays, newDays)
        let copyPeriods = min(oldPeriods, newPeriods)
        for p in 0..<copyPeriods {
            for d in 0..<copyDays {
                dst[p * newDays + d] = old[p * oldDays + d]
            }
        }
        return dst
    }
    // timetable 内に追加
    private func normalizeAssigned() {
        let need = periodLabels.count * dayLabels.count
        if assigned.count < need {
            assigned.append(contentsOf: Array(repeating: nil, count: need - assigned.count))
        } else if assigned.count > need {
            assigned = Array(assigned.prefix(need))
        }
    }


    // すでにあるグリッドを壊して、今の設定で作り直す
    private func rebuildGrid() {
        
        // ★ これを追加：前回の見出しラベルやボタンをまとめて除去
        gridContainerView.subviews.forEach { $0.removeFromSuperview() }
        
        // 追加：配列サイズを現状の rows×cols に合わせる
        normalizeAssigned()

        // 既存ボタン/ガイド撤去
        slotButtons.forEach { $0.removeFromSuperview() }
        slotButtons.removeAll()
        colGuides.forEach { gridContainerView.removeLayoutGuide($0) }
        rowGuides.forEach { gridContainerView.removeLayoutGuide($0) }
        colGuides.removeAll()
        rowGuides.removeAll()

        // ガイド→見出し→セル(+/登録) の順で再構築
        buildGridGuides()
        placeHeaders()
        placePlusButtons()
        reloadAllButtons()
    }


    // SafeArea が確定したタイミングで 5% を反映（回転でも更新）
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safeHeight = view.safeAreaLayoutGuide.layoutFrame.height
        
        //削除
        print("✅ layout safeH=\(Int(safeHeight))  beforeTop=\(Int(headerTopConstraint.constant))")
        
        headerTopConstraint.constant = safeHeight * topRatio    // ← ここで 5% を確実に適用
        //gridTopConstraint.constant = 0                          // ヘッダー直下から開始
        //gridBottomConstraint.constant = -8                      // 下端にぴったり（余白8）
        
        // デバッグ
            print("header h=\(Int(headerBar.frame.height))  gridTop=\(Int(gridContainerView.frame.minY))")

        //削除
        view.layoutIfNeeded()
        print("✅ layout afterTop=\(Int(headerTopConstraint.constant))")
        
    }

    // MARK: Header
    private func buildHeader() {
        headerBar.axis = .horizontal
        headerBar.alignment = .center
        headerBar.distribution = .fill
        headerBar.spacing = 8
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerBar)
        
        // ← ここに入れる（見やすいよう一時的に色を付ける）
        //headerBar.backgroundColor = UIColor.systemPink.withAlphaComponent(0.15)

        leftButton.setTitle("2025年前期", for: .normal)
        leftButton.addTarget(self, action: #selector(tapLeft), for: .touchUpInside)

        titleLabel.text = "時間割"
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        rightStack.axis = .horizontal
        rightStack.alignment = .center
        rightStack.spacing = 8
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.setContentHuggingPriority(.required, for: .horizontal)

        func style(_ b: UIButton, _ t: String) {
            b.setTitle(t, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            b.backgroundColor = .secondarySystemBackground
            b.layer.cornerRadius = 8
            b.layer.borderWidth = 1
            b.layer.borderColor = UIColor.separator.cgColor
            b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
            
        }
        func styleIcon(_ b: UIButton, _ systemName: String) {
            var cfg = UIButton.Configuration.plain()
            cfg.image = UIImage(systemName: systemName)
            cfg.preferredSymbolConfigurationForImage =
                UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            cfg.baseForegroundColor = .label
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
            b.configuration = cfg

            // 既存ボタンと同じ“ pill ”風の見た目
            b.backgroundColor = .secondarySystemBackground
            b.layer.cornerRadius = 8
            b.layer.borderWidth = 1
            b.layer.borderColor = UIColor.separator.cgColor
        }

        style(rightA, "単") //;style(rightB, "複"); style(rightC, "設")
        // 「複」→ 三つの丸が繋がった風アイコン
        let multiIcon: String
        if #available(iOS 16.0, *) {
            multiIcon = "point.3.connected.trianglepath.dotted"   // 3点が線で繋がったSF Symbol
        } else {
            multiIcon = "ellipsis.circle"                         // 代替（iOS15以下など）
        }
        styleIcon(rightB, multiIcon)
        rightB.accessibilityLabel = "複数"

        // 「設」→ 歯車アイコン
        styleIcon(rightC, "gearshape.fill")
        rightC.accessibilityLabel = "設定"
        
        rightA.addTarget(self, action: #selector(tapRightA), for: .touchUpInside)
        rightB.addTarget(self, action: #selector(tapRightB), for: .touchUpInside)
        rightC.addTarget(self, action: #selector(tapRightC), for: .touchUpInside)
        rightStack.addArrangedSubview(rightA)
        rightStack.addArrangedSubview(rightB)
        rightStack.addArrangedSubview(rightC)

        let spacerL = UIView(); spacerL.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let spacerR = UIView(); spacerR.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerBar.addArrangedSubview(leftButton)
        headerBar.addArrangedSubview(spacerL)
        headerBar.addArrangedSubview(titleLabel)
        headerBar.addArrangedSubview(spacerR)
        headerBar.addArrangedSubview(rightStack)
        
        // ==== ここから追加（または置き換え） ====

        // arrangedSubView たちの AutoLayout を有効化
        [leftButton, titleLabel, rightStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        // StackView 自体が “中身＋上下8pt” で高さを決められるようにする
        headerBar.isLayoutMarginsRelativeArrangement = true
        headerBar.layoutMargins = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)

        // できるだけ小さく使う（縦のハギング／抵抗を強める）
        headerBar.setContentHuggingPriority(.required, for: .vertical)
        headerBar.setContentCompressionResistancePriority(.required, for: .vertical)
        titleLabel.setContentHuggingPriority(.required, for: .vertical)
        leftButton.setContentHuggingPriority(.required, for: .vertical)
        rightStack.setContentHuggingPriority(.required, for: .vertical)

        // タイトルの高さ + 16pt で headerBar をクランプ（確実に抑える最後の一手）
        let clamp = headerBar.heightAnchor.constraint(equalTo: titleLabel.heightAnchor, constant: 16)
        clamp.priority = .required
        clamp.isActive = true

        // 見た目を揃えるため、左右のスタックをタイトルの縦中心に合わせる
        NSLayoutConstraint.activate([
            leftButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            rightStack.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor)
        ])
        
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.centerXAnchor.constraint(equalTo: headerBar.centerXAnchor).isActive = true  // ← 追加

        
        let g = view.safeAreaLayoutGuide
        headerTopConstraint = headerBar.topAnchor.constraint(equalTo: g.topAnchor, constant: 0) // ← まず0、あとで5%を代入
        NSLayoutConstraint.activate([
            headerTopConstraint,
            headerBar.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            headerBar.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            headerBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        
        // ヘッダーを中身の高さ＋上下8ptに抑える
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        leftButton.translatesAutoresizingMaskIntoConstraints = false
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // あると見た目が安定：左右もタイトルと同じ高さに合わせておく
            leftButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            rightStack.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor)
        ])

        // ヘッダーは“できるだけ小さく”使う
        headerBar.setContentHuggingPriority(.required, for: .vertical)
        headerBar.setContentCompressionResistancePriority(.required, for: .vertical)

    }

    // 置き換え
    private func layoutGridContainer() {
        let g = view.safeAreaLayoutGuide

        // ① scrollView をヘッダーの下に敷く（画面いっぱい）
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: g.bottomAnchor)
        ])

        // ② contentView を scrollView の contentLayoutGuide に貼る
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),

            // 横方向は画面幅に合わせる（横スクロールを防ぐ）
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])

        // ③ gridContainerView を contentView 内に余白付きで配置
        gridContainerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(gridContainerView)
        
        gridTopConstraint = gridContainerView.topAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: 0)
        //gridBottomConstraint = gridContainerView.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -8)


        NSLayoutConstraint.activate([
            gridContainerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            gridContainerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            gridContainerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            gridContainerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        ])
    }


    // MARK: 比率ガイド
    private func buildGridGuides() {
        // 列（時限 + 曜日）
        let colCount = 1 + dayLabels.count
        for _ in 0..<colCount {
            let g = UILayoutGuide()
            gridContainerView.addLayoutGuide(g)
            colGuides.append(g)
            g.topAnchor.constraint(equalTo: gridContainerView.topAnchor).isActive = true
            g.bottomAnchor.constraint(equalTo: gridContainerView.bottomAnchor).isActive = true
        }
        colGuides[0].leadingAnchor.constraint(equalTo: gridContainerView.leadingAnchor).isActive = true
        colGuides[colCount-1].trailingAnchor.constraint(equalTo: gridContainerView.trailingAnchor).isActive = true
        colGuides[0].widthAnchor.constraint(equalToConstant: timeColWidth).isActive = true
        for i in 1..<colCount {
            colGuides[i].leadingAnchor.constraint(equalTo: colGuides[i-1].trailingAnchor, constant: spacing).isActive = true
            if i >= 2 { colGuides[i].widthAnchor.constraint(equalTo: colGuides[1].widthAnchor).isActive = true }
        }

        // 行（ヘッダ1 + 時限n）
        let rowCount = 1 + periodLabels.count
        for _ in 0..<rowCount {
            let g = UILayoutGuide()
            gridContainerView.addLayoutGuide(g)
            rowGuides.append(g)
            g.leadingAnchor.constraint(equalTo: gridContainerView.leadingAnchor).isActive = true
            g.trailingAnchor.constraint(equalTo: gridContainerView.trailingAnchor).isActive = true
        }
        rowGuides[0].topAnchor.constraint(equalTo: gridContainerView.topAnchor).isActive = true
        rowGuides[rowCount-1].bottomAnchor.constraint(equalTo: gridContainerView.bottomAnchor).isActive = true
        rowGuides[0].heightAnchor.constraint(equalToConstant: headerRowHeight).isActive = true
        for i in 1..<rowCount {
            rowGuides[i].topAnchor.constraint(equalTo: rowGuides[i-1].bottomAnchor, constant: spacing).isActive = true
            if i >= 2 { rowGuides[i].heightAnchor.constraint(equalTo: rowGuides[1].heightAnchor).isActive = true }
        }
    }
    
    
    // 「開始時刻」「番号」「終了時刻」を縦に並べたビューを作る
    private func makeTimeMarker(for period: Int) -> UIView {
        let v = UIStackView()
        v.axis = .vertical
        v.alignment = .center          // ← 中央揃え
        v.spacing = 2
        v.translatesAutoresizingMaskIntoConstraints = false

        let top = UILabel()
        top.font = .systemFont(ofSize: 11, weight: .regular)
        top.textColor = .secondaryLabel
        top.textAlignment = .center

        let mid = UILabel()
        mid.font = .systemFont(ofSize: 16, weight: .semibold)
        mid.textAlignment = .center
        mid.text = "\(period)"

        let bottom = UILabel()
        bottom.font = .systemFont(ofSize: 11, weight: .regular)
        bottom.textColor = .secondaryLabel
        bottom.textAlignment = .center

        if period-1 < timePairs.count {
            top.text    = timePairs[period-1].start
            bottom.text = timePairs[period-1].end
        } else {
            // 時刻未定義のコマは時限番号のみ
            top.text = nil; bottom.text = nil
        }

        [top, mid, bottom].forEach { v.addArrangedSubview($0) }
        return v
    }


    // MARK: 見出し
    private func placeHeaders() {
        for i in 0..<dayLabels.count {
            let l = headerLabel(dayLabels[i])
            gridContainerView.addSubview(l)
            NSLayoutConstraint.activate([
                l.centerXAnchor.constraint(equalTo: colGuides[i+1].centerXAnchor),
                l.centerYAnchor.constraint(equalTo: rowGuides[0].centerYAnchor)
            ])
        }
        for r in 0..<periodLabels.count {
            let marker = makeTimeMarker(for: r + 1)
            gridContainerView.addSubview(marker)
            NSLayoutConstraint.activate([
                // 列0の**中央**に幅固定で置く → 数字がど真ん中に来る
                marker.centerXAnchor.constraint(equalTo: colGuides[0].centerXAnchor),
                marker.widthAnchor.constraint(equalToConstant: timeColWidth),

                // 行の中央に
                marker.centerYAnchor.constraint(equalTo: rowGuides[r+1].centerYAnchor)
            ])
        }

    }
    private func headerLabel(_ text: String) -> UILabel {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.text = text
        l.font = .systemFont(ofSize: 16, weight: .regular)
        l.textAlignment = .center
        return l
    }
    
    private func configureButton(_ b: UIButton, at idx: Int) {
        // idx が配列外なら「＋」表示にして安全に抜ける
        guard assigned.indices.contains(idx) else {
            var cfg = UIButton.Configuration.gray()
            cfg.baseBackgroundColor = .secondarySystemBackground
            cfg.baseForegroundColor = .systemBlue
            cfg.title = "＋"
            cfg.titleAlignment = .center
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { inAttr in
                var out = inAttr
                out.font = .systemFont(ofSize: 22, weight: .semibold)
                let p = NSMutableParagraphStyle(); p.alignment = .center
                out.paragraphStyle = p
                return out
            }
            cfg.background.cornerRadius = 12
            cfg.contentInsets = .init(top: 6, leading: 6, bottom: 6, trailing: 6)
            b.configuration = cfg
            b.layer.borderWidth = 0.5
            b.layer.borderColor = UIColor.separator.cgColor
            return
        }
        let cols = dayLabels.count
        let row  = idx / cols
        let col  = idx % cols
        let loc  = SlotLocation(day: col, period: row + 1)
        // ここで保存済みの色（未設定なら既定色）を取る
        let colorKey = SlotColorStore.color(for: loc) ?? .teal

        let course = assigned[idx]   // ← ここで一度だけ読む
        if let c = course {
            // 登録済み表示
            var cfg = UIButton.Configuration.filled()

            let saved = SlotColorStore.color(for: loc)?.uiColor ?? .systemTeal
            cfg.baseBackgroundColor = colorKey.uiColor   // ← ここを保存色で
            cfg.baseForegroundColor = .white
            cfg.title = c.title
            cfg.subtitle = c.room
            cfg.titleAlignment = .center
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { inAttr in
                var out = inAttr
                out.font = .systemFont(ofSize: 10, weight: .semibold)
                let p = NSMutableParagraphStyle()
                p.alignment = .center
                p.lineBreakMode = .byWordWrapping
                out.paragraphStyle = p
                return out
            }
            cfg.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { inAttr in
                var out = inAttr
                out.font = .systemFont(ofSize: 11, weight: .medium)
                let p = NSMutableParagraphStyle(); p.alignment = .center
                out.paragraphStyle = p
                return out
            }
            cfg.background.cornerRadius = 12
            cfg.contentInsets = .init(top: 8, leading: 10, bottom: 8, trailing: 10)
            b.configuration = cfg
            b.layer.borderWidth = 0
        } else {
            // 未登録（＋）
            var cfg = UIButton.Configuration.gray()
            cfg.baseBackgroundColor = .secondarySystemBackground
            cfg.baseForegroundColor = .systemBlue
            cfg.title = "＋"
            cfg.titleAlignment = .center
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { inAttr in
                var out = inAttr
                out.font = .systemFont(ofSize: 22, weight: .semibold)
                let p = NSMutableParagraphStyle(); p.alignment = .center
                out.paragraphStyle = p
                return out
            }
            cfg.background.cornerRadius = 12
            cfg.contentInsets = .init(top: 6, leading: 6, bottom: 6, trailing: 6)
            b.configuration = cfg
            b.layer.borderWidth = 0.5
            b.layer.borderColor = UIColor.separator.cgColor
        }
    }

    
    

    
    private func reloadAllButtons() {
        for b in slotButtons { configureButton(b, at: b.tag) }
    }

    // 画面に戻って来た時の保険（pop 後でも確実に反映）
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadAllButtons()
    }


    // MARK: セル（＋）
    private func placePlusButtons() {
        let rows = periodLabels.count
        let cols = dayLabels.count
        for r in 0..<rows {
            for c in 0..<cols {
                let b = UIButton(type: .system)
                b.translatesAutoresizingMaskIntoConstraints = false
                //b.setTitle("+", for: .normal)
                //b.titleLabel?.font = .systemFont(ofSize: 24, weight: .medium)
                b.backgroundColor = .secondarySystemBackground
                //b.layer.cornerRadius = 14
                b.layer.borderWidth = 1
                b.layer.borderColor = UIColor.separator.cgColor
                gridContainerView.addSubview(b)

                let rowG = rowGuides[r+1], colG = colGuides[c+1]
                NSLayoutConstraint.activate([
                    b.topAnchor.constraint(equalTo: rowG.topAnchor, constant: cellPadding),
                    b.bottomAnchor.constraint(equalTo: rowG.bottomAnchor, constant: -cellPadding),
                    b.leadingAnchor.constraint(equalTo: colG.leadingAnchor, constant: cellPadding),
                    b.trailingAnchor.constraint(equalTo: colG.trailingAnchor, constant: -cellPadding)
                ])
                let idx = r * cols + c

                b.tag = idx
                b.addTarget(self, action: #selector(slotTapped(_:)), for: .touchUpInside)
                slotButtons.append(b)
                
                // ★ 状態に応じて見た目をセット（未登録なら「＋」が表示される）
                configureButton(b, at: idx)
            }
        }
    }
    
    // どこかに追加（今の dayLabels などに合わせて）
    private func gridIndex(for loc: SlotLocation) -> Int {
        let cols = dayLabels.count              // 表示中の列数（月〜金 or 月〜土）
        return loc.day + (loc.period - 1) * cols
    }
    
    private func presentCourseDetail(_ course: Course, at loc: SlotLocation) {
        let vc = CourseDetailViewController(course: course, location: loc)
        vc.delegate = self
        vc.modalPresentationStyle = .pageSheet

        if let sheet = vc.sheetPresentationController {
            if #available(iOS 16.0, *) {
                let id = UISheetPresentationController.Detent.Identifier("ninetyTwo")
                sheet.detents = [
                    .custom(identifier: id) { ctx in ctx.maximumDetentValue * 0.92 }, // ← 初期高さを99%
                    .large()                                                         // ← さらに引っぱれば全画面
                ]
                sheet.selectedDetentIdentifier = id
            } else {
                // iOS 15 は custom なし。高さを稼ぎたいなら large 一択
                sheet.detents = [.large()]
                sheet.selectedDetentIdentifier = .large
            }
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 16
            // “スクロールすると勝手に拡張”を抑えたい時は↓を有効化
            // sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        present(vc, animated: true)
    }


    // MARK: Actions
    @objc private func tapLeft()   { print("左ボタン") }
    @objc private func tapRightA() { print("右A") }
    @objc private func tapRightB() { print("右B") }
    @objc private func tapRightC() {
        let vc = TimetableSettingsViewController()
        if let nav = navigationController {
            nav.pushViewController(vc, animated: true)
        } else {
            let nav = UINavigationController(rootViewController: vc)
            present(nav, animated: true)
        } }
    @objc private func slotTapped(_ sender: UIButton) {
        let cols = dayLabels.count
        let idx  = sender.tag
        let row = sender.tag / cols       // 0..4
        let col = sender.tag % cols       // 0..4

        let loc = SlotLocation(day: col, period: row + 1)
        
        // ▼ 追加：そのコマが登録済みならハーフモーダルで詳細
        if let course = assigned[idx] {
            presentCourseDetail(course, at: loc)
            return
        }
        
        let listVC = CourseListViewController(location: loc)
        listVC.delegate = self

        if let nav = navigationController {
            nav.pushViewController(listVC, animated: true)
        } else {
            let nav = UINavigationController(rootViewController: listVC)
            nav.modalPresentationStyle = .fullScreen   // ← ドットの後に空白NG
            present(nav, animated: true)
        }
    }
    
    func courseList(_ vc: CourseListViewController, didSelect course: Course, at location: SlotLocation) {
        normalizeAssigned()
        let idx = (location.period - 1) * dayLabels.count + location.day

        // モデル更新
        assigned[idx] = course

        // UI更新（そのボタンだけ）
        if let btn = slotButtons.first(where: { $0.tag == idx }) {
            configureButton(btn, at: idx)
        }else {
            reloadAllButtons()
        }
        saveAssigned()     // ← 追加

        // 画面を戻す（push or modal）
        if let nav = vc.navigationController {
            if nav.viewControllers.first === vc { vc.dismiss(animated: true) }
            else { nav.popViewController(animated: true) }
        } else {
            vc.dismiss(animated: true)
        }
    }
    
    
    
}


    /*
    // MARK: - Navigation

    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        // Get the new view controller using segue.destination.
        // Pass the selected object to the new view controller.
    }
    */


