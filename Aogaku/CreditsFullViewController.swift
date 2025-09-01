//  CreditsFullViewController.swift
//  Aogaku
//
//  全画面の「単位」ビュー。
//  ・渡された courses を3カテゴリ（青スタ/学科/自由選択）に集計
//  ・薄色＝必要枠、濃色＝取得分でドーナツ表示（DonutChartView.rings）
//  ・下にカテゴリ別の科目一覧（UITableView）

import UIKit

final class CreditsFullViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    // MARK: - Input
    private let courses: [Course]   // 事前に重複除去された配列を受け取る

    // 今は仮値（あとで学部ごとの必要単位テーブルに差し替えOK）
    private let required: [CreditCategory: Int] = [
        .aostandard: 24, .department: 62, .free: 38
    ]

    // MARK: - Aggregates
    private var grouped: [CreditCategory: [Course]] = [:]
    private var totals:  [CreditCategory: Int] = [.aostandard: 0, .department: 0, .free: 0]
    private var totalRequired = 0
    private var totalGot = 0

    // MARK: - UI
    private let scroll = UIScrollView()
    private let stack  = UIStackView()
    private let titleLabel = UILabel()
    private let donut = DonutChartView()
    private let legend = UIStackView()
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var tableHeightConstraint: NSLayoutConstraint?

    // 表示順を固定（enum の allCases に依存しない）
    private let displayOrder: [CreditCategory] = [.aostandard, .department, .free]

    // MARK: - Init
    init(courses: [Course]) {
        self.courses = courses
        super.init(nibName: nil, bundle: nil)
        self.title = "単位"
        modalPresentationStyle = .pageSheet
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - LifeCycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(close))

        aggregate()
        buildUI()
        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // テーブル高さを内容に合わせて更新
        table.layoutIfNeeded()
        tableHeightConstraint?.constant = table.contentSize.height
    }

    // MARK: - Data
    private func aggregate() {
        // 3カテゴリに振り分け（未分類は無視）
        grouped = [:]
        totals  = [.aostandard: 0, .department: 0, .free: 0]

        for c in courses {
            guard let cat = c.creditCategory else { continue }
            grouped[cat, default: []].append(c)
            totals[cat, default: 0] += max(0, c.creditValue)
        }

        totalRequired = required.values.reduce(0, +)
        totalGot = totals.values.reduce(0, +)
    }

    // MARK: - UI build
    private func buildUI() {
        // Scroll + Stack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scroll)
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16)
        ])

        // タイトル
        titleLabel.text = "取得済み（必要）"
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textAlignment = .center
        stack.addArrangedSubview(titleLabel)

        // ドーナツ（中央の数字ラベルは DonutChartView 側の centerBig/centerSmall を利用）
        donut.translatesAutoresizingMaskIntoConstraints = false
        donut.lineWidth = 28
        donut.setGap(degrees: 2)

        let donutContainer = UIView()
        donutContainer.translatesAutoresizingMaskIntoConstraints = false
        donutContainer.addSubview(donut)

        NSLayoutConstraint.activate([
            donut.centerXAnchor.constraint(equalTo: donutContainer.centerXAnchor),
            donut.centerYAnchor.constraint(equalTo: donutContainer.centerYAnchor),
            donut.widthAnchor.constraint(equalTo: donutContainer.widthAnchor, multiplier: 0.78),
            donut.heightAnchor.constraint(equalTo: donut.widthAnchor),
            donutContainer.heightAnchor.constraint(equalTo: donut.widthAnchor, multiplier: 1.05)
        ])
        stack.addArrangedSubview(donutContainer)

        // 凡例
        legend.axis = .vertical
        legend.spacing = 8
        legend.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(legend)

        // テーブル
        table.dataSource = self
        table.delegate = self
        table.isScrollEnabled = false
        table.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(table)

        // 高さ制約（内容に合わせて更新）
        tableHeightConstraint = table.heightAnchor.constraint(equalToConstant: 0)
        tableHeightConstraint?.isActive = true
    }

    // MARK: - Render
    private func render() {
        // 必要／取得
        let gotAo  = totals[.aostandard] ?? 0
        let gotDep = totals[.department] ?? 0
        let gotFree = totals[.free] ?? 0
        let totalGot = gotAo + gotDep + gotFree

        let reqAo  = required[.aostandard] ?? 0
        let reqDep = required[.department] ?? 0
        let reqFree = required[.free] ?? 0

        // ドーナツ
        donut.totalRequired = CGFloat(reqAo + reqDep + reqFree)
        donut.centerBig.text = "\(totalGot)(\(reqAo + reqDep + reqFree))"
        donut.centerSmall.text = "必要単位数"

        donut.rings = [
            .init(required: CGFloat(reqAo),   got: CGFloat(gotAo),
                  bgColor: UIColor.systemBlue.withAlphaComponent(0.25),
                  fgColor: .systemBlue,
                  name: "青山スタンダード"),
            .init(required: CGFloat(reqDep),  got: CGFloat(gotDep),
                  bgColor: UIColor.systemRed.withAlphaComponent(0.25),
                  fgColor: .systemRed,
                  name: "学科科目"),
            .init(required: CGFloat(reqFree), got: CGFloat(gotFree),
                  bgColor: UIColor.systemGreen.withAlphaComponent(0.25),
                  fgColor: .systemGreen,
                  name: "自由選択科目")
        ]

        // 凡例を作り直し
        legend.arrangedSubviews.forEach { $0.removeFromSuperview() }
        legend.addArrangedSubview(makeLegendRow(
            color: .systemBlue,  name: "青山スタンダード", got: gotAo,  req: reqAo))
        legend.addArrangedSubview(makeLegendRow(
            color: .systemRed,   name: "学科科目",         got: gotDep, req: reqDep))
        legend.addArrangedSubview(makeLegendRow(
            color: .systemGreen, name: "自由選択科目",     got: gotFree, req: reqFree))

        // テーブル
        table.reloadData()
        table.layoutIfNeeded()
        tableHeightConstraint?.constant = table.contentSize.height
    }

    private func makeLegendRow(color: UIColor, name: String, got: Int, req: Int) -> UIView {
        let dot = UIView()
        dot.backgroundColor = color
        dot.layer.cornerRadius = 6
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 12),
            dot.heightAnchor.constraint(equalToConstant: 12)
        ])

        let title = UILabel()
        title.text = name
        title.font = .systemFont(ofSize: 16, weight: .semibold)

        let numbers = UILabel()
        numbers.text = "\(got) / \(req)"
        numbers.font = .systemFont(ofSize: 16, weight: .regular)
        numbers.textColor = .secondaryLabel

        let h = UIStackView(arrangedSubviews: [dot, title, UIView(), numbers])
        h.axis = .horizontal
        h.alignment = .center
        h.spacing = 8
        return h
    }

    @objc private func close() { dismiss(animated: true) }

    // MARK: - UITableViewDataSource
    func numberOfSections(in tableView: UITableView) -> Int { displayOrder.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        displayOrder[section].rawValue   // 例: 「青山スタンダード科目」など
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let cat = displayOrder[section]
        return grouped[cat]?.count ?? 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let cat = displayOrder[indexPath.section]
        if let c = grouped[cat]?[indexPath.row] {
            var cfg = cell.defaultContentConfiguration()
            cfg.text = c.title
            cfg.secondaryText = "登録番号 \(c.id) ・ \(c.creditValue)単位"
            cell.contentConfiguration = cfg
        }
        return cell
    }

    // MARK: - UITableViewDelegate
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }
}
