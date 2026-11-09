//
//  GakuchikaViewController.swift
//  Aogaku
//
//  ガクチカタブ。上でインターン・留学・バイト・サークル・部活を切り替え、
//  写真の大きいカードで掲載を並べる。PR 掲載（isSponsored）は「PR」を付けて先頭に出す。
//

import UIKit
import SafariServices
import FirebaseFirestore

/// 上段のカテゴリ
enum GakuchikaSection: Int, CaseIterable {
    case intern, studyAbroad, partTime, circle, club

    var title: String {
        switch self {
        case .intern: return "インターン"
        case .studyAbroad: return "留学"
        case .partTime: return "バイト"
        case .circle: return "サークル"
        case .club: return "部活"
        }
    }

    /// 掲載データ（careerListings）のどのカテゴリを出すか。nil はまだ掲載データがない
    var categories: Set<CareerCategory>? {
        switch self {
        case .intern: return [.longTermIntern, .shortTermIntern]
        case .studyAbroad: return [.studyAbroad]
        case .partTime: return [.partTime]
        case .circle, .club: return nil
        }
    }

    var filters: [GakuchikaFilter] {
        switch self {
        case .intern: return [.recommended, .longTerm, .shortTerm, .saved]
        default: return [.recommended, .saved]
        }
    }
}

/// 下段の絞り込み
enum GakuchikaFilter {
    case recommended, longTerm, shortTerm, saved

    var title: String {
        switch self {
        case .recommended: return "おすすめ"
        case .longTerm: return "長期"
        case .shortTerm: return "短期"
        case .saved: return "保存済み"
        }
    }
}

final class GakuchikaViewController: UIViewController,
                                     UITableViewDataSource,
                                     UITableViewDelegate,
                                     UISearchBarDelegate {

    // MARK: - UI
    private let headerStack = UIStackView()
    private let titleLabel = UILabel()
    private let searchButton = UIButton(type: .system)
    private let searchBar = UISearchBar()
    private let sectionControl = UISegmentedControl(items: GakuchikaSection.allCases.map(\.title))
    private let filterStack = UIStackView()
    private let filterUnderline = UIView()
    private var filterButtons: [UIButton] = []
    private var underlineLeading: NSLayoutConstraint?
    private var underlineWidth: NSLayoutConstraint?
    private var headerView: UIView { headerStack }

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()

    // MARK: - Data
    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var allItems: [CareerListing] = []
    private var items: [CareerListing] = []
    private var searchText = ""
    private var section: GakuchikaSection = .intern
    private var filter: GakuchikaFilter = .recommended

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        title = "ガクチカ"

        setupHeader()
        setupTableView()
        setupEmptyLabel()
        rebuildFilterButtons()
        startListening()

        NotificationCenter.default.addObserver(self, selector: #selector(bookmarksChanged),
                                               name: .careerBookmarkDidChange, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 見出しは自前で出すので、一覧ではナビゲーションバーを隠す（詳細へ進むと戻す）
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ScreenTracker.shared.appear("ガクチカ")
        AppAnalytics.logCareerListView()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        ScreenTracker.shared.disappear("ガクチカ")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        moveUnderline(animated: false)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        listener?.remove()
    }

    @objc private func bookmarksChanged() {
        if filter == .saved { applyFilter() }
    }

    // MARK: - Search
    private func toggleSearch() {
        let show = searchBar.isHidden
        UIView.animate(withDuration: 0.25) {
            self.searchBar.isHidden = !show
            self.searchBar.alpha = show ? 1 : 0
            self.view.layoutIfNeeded()
        }
        if show {
            searchBar.becomeFirstResponder()
        } else {
            searchBar.text = ""
            searchBar.resignFirstResponder()
            searchText = ""
            applyFilter()
        }
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange text: String) {
        searchText = text.trimmingCharacters(in: .whitespaces)
        applyFilter()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        toggleSearch()
    }

    // MARK: - Header（見出し + カテゴリ + 絞り込み）
    private func setupHeader() {
        headerStack.axis = .vertical
        headerStack.spacing = 8
        headerStack.backgroundColor = .systemGroupedBackground
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerStack)

        titleLabel.text = "ガクチカ"
        titleLabel.font = .systemFont(ofSize: 30, weight: .heavy)
        titleLabel.textColor = .label
        titleLabel.accessibilityTraits = .header

        searchButton.setImage(UIImage(systemName: "magnifyingglass",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)),
                              for: .normal)
        searchButton.tintColor = .label
        searchButton.accessibilityLabel = "検索"
        searchButton.addAction(UIAction { [weak self] _ in self?.toggleSearch() }, for: .touchUpInside)

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, UIView(), searchButton])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.isLayoutMarginsRelativeArrangement = true
        titleRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 8)

        searchBar.placeholder = "企業名・職種・キーワード"
        searchBar.searchBarStyle = .minimal
        searchBar.showsCancelButton = true
        searchBar.delegate = self
        searchBar.isHidden = true
        searchBar.alpha = 0

        sectionControl.selectedSegmentIndex = section.rawValue
        sectionControl.selectedSegmentTintColor = .systemBackground
        sectionControl.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                                               .foregroundColor: UIColor.secondaryLabel], for: .normal)
        sectionControl.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 13, weight: .bold),
                                               .foregroundColor: UIColor.label], for: .selected)
        sectionControl.addAction(UIAction { [weak self] _ in self?.didChangeSection() }, for: .valueChanged)
        let sectionWrap = UIView()
        sectionControl.translatesAutoresizingMaskIntoConstraints = false
        sectionWrap.addSubview(sectionControl)

        filterStack.axis = .horizontal
        filterStack.spacing = 20
        filterStack.alignment = .fill
        filterStack.translatesAutoresizingMaskIntoConstraints = false
        let filterWrap = UIView()
        filterWrap.addSubview(filterStack)

        headerStack.addArrangedSubview(titleRow)
        headerStack.addArrangedSubview(searchBar)
        headerStack.addArrangedSubview(sectionWrap)
        headerStack.addArrangedSubview(filterWrap)
        headerStack.setCustomSpacing(4, after: sectionWrap)
        self.filterWrap = filterWrap

        filterUnderline.backgroundColor = .label
        filterUnderline.layer.cornerRadius = 1
        filterUnderline.translatesAutoresizingMaskIntoConstraints = false
        filterWrap.addSubview(filterUnderline)

        let leading = filterUnderline.leadingAnchor.constraint(equalTo: filterWrap.leadingAnchor, constant: 16)
        let width = filterUnderline.widthAnchor.constraint(equalToConstant: 0)
        underlineLeading = leading
        underlineWidth = width

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            searchButton.widthAnchor.constraint(equalToConstant: 44),
            searchButton.heightAnchor.constraint(equalToConstant: 44),

            sectionControl.topAnchor.constraint(equalTo: sectionWrap.topAnchor),
            sectionControl.bottomAnchor.constraint(equalTo: sectionWrap.bottomAnchor),
            sectionControl.leadingAnchor.constraint(equalTo: sectionWrap.leadingAnchor, constant: 16),
            sectionControl.trailingAnchor.constraint(equalTo: sectionWrap.trailingAnchor, constant: -16),
            sectionControl.heightAnchor.constraint(equalToConstant: 34),

            filterStack.topAnchor.constraint(equalTo: filterWrap.topAnchor),
            filterStack.bottomAnchor.constraint(equalTo: filterWrap.bottomAnchor),
            filterStack.leadingAnchor.constraint(equalTo: filterWrap.leadingAnchor, constant: 16),
            filterStack.trailingAnchor.constraint(lessThanOrEqualTo: filterWrap.trailingAnchor, constant: -16),
            filterStack.heightAnchor.constraint(equalToConstant: 44),

            filterUnderline.bottomAnchor.constraint(equalTo: filterWrap.bottomAnchor, constant: -6),
            filterUnderline.heightAnchor.constraint(equalToConstant: 2),
            leading, width,
        ])
    }

    private var filterWrap: UIView?

    private func rebuildFilterButtons() {
        filterButtons.forEach { $0.removeFromSuperview() }
        filterButtons = section.filters.map { f in
            let b = UIButton(type: .system)
            b.setTitle(f.title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold)
            b.addAction(UIAction { [weak self] _ in self?.didSelectFilter(f) }, for: .touchUpInside)
            filterStack.addArrangedSubview(b)
            return b
        }
        // サークル・部活は掲載データがまだないので絞り込みを隠す
        let hasListings = section.categories != nil
        filterWrap?.isHidden = !hasListings
        updateFilterStyles()
        view.layoutIfNeeded()
        moveUnderline(animated: false)
    }

    private func updateFilterStyles() {
        for (i, b) in filterButtons.enumerated() {
            let selected = section.filters[i] == filter
            b.setTitleColor(selected ? .label : .secondaryLabel, for: .normal)
            b.accessibilityTraits = selected ? [.button, .selected] : .button
        }
    }

    private func moveUnderline(animated: Bool) {
        guard let idx = section.filters.firstIndex(of: filter), idx < filterButtons.count,
              let label = filterButtons[idx].titleLabel else { return }
        guard let wrap = filterWrap else { return }
        let frame = label.convert(label.bounds, to: wrap)
        guard frame.width > 0 else { return }
        underlineLeading?.constant = frame.minX
        underlineWidth?.constant = frame.width
        if animated {
            UIView.animate(withDuration: 0.2) { wrap.layoutIfNeeded() }
        }
    }

    // MARK: - Table
    private func setupTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(GakuchikaFeedCell.self, forCellReuseIdentifier: GakuchikaFeedCell.reuseId)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 340
        tableView.contentInset.top = 6
        tableView.keyboardDismissMode = .onDrag
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupEmptyLabel() {
        emptyLabel.font = .systemFont(ofSize: 14, weight: .medium)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            emptyLabel.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 80),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
    }

    // MARK: - Actions
    private func didChangeSection() {
        guard let s = GakuchikaSection(rawValue: sectionControl.selectedSegmentIndex) else { return }
        section = s
        filter = .recommended
        rebuildFilterButtons()
        applyFilter()
        if !items.isEmpty {
            tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
        }
    }

    private func didSelectFilter(_ f: GakuchikaFilter) {
        filter = f
        updateFilterStyles()
        moveUnderline(animated: true)
        applyFilter()
    }

    private func openApplication(for item: CareerListing) {
        AppAnalytics.logCareerApplyClick(jobID: item.id)
        guard let url = URL(string: item.applicationUrl) else { return }
        present(SFSafariViewController(url: url), animated: true)
    }

    // MARK: - Firestore
    private func startListening() {
        listener?.remove()
        #if DEBUG
        if GakuchikaSamples.isEnabled {
            allItems = GakuchikaSamples.items
            applyFilter()
            return
        }
        #endif
        listener = db.collection("careerListings")
            .order(by: "publishedAt", descending: true)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    print("Firestore error:", error.localizedDescription)
                    return
                }
                guard let snapshot else { return }
                let now = Date()
                self.allItems = snapshot.documents
                    .compactMap { CareerListing(document: $0) }
                    .filter { ($0.expiresAt ?? .distantFuture) > now }
                self.applyFilter()
            }
    }

    // MARK: - Filtering
    private func applyFilter() {
        guard let cats = section.categories else {
            items = []
            tableView.reloadData()
            emptyLabel.text = "\(section.title)の掲載は準備中です"
            emptyLabel.isHidden = false
            return
        }

        var list = allItems.filter { cats.contains($0.category) }
        switch filter {
        case .recommended: break
        case .longTerm: list = list.filter { $0.category == .longTermIntern }
        case .shortTerm: list = list.filter { $0.category == .shortTermIntern }
        case .saved:
            let ids = Set(CareerBookmarkStore.shared.allIDs())
            list = list.filter { ids.contains($0.id) }
        }

        if !searchText.isEmpty {
            list = list.filter { item in
                [item.companyName, item.title, item.description, item.location, item.sourceName ?? ""]
                    .contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
        }

        // おすすめ: PR → 締切間近 → 新着
        if filter == .recommended && searchText.isEmpty {
            let sponsored = list.filter(\.isSponsored)
            let soon = list.filter { !$0.isSponsored && $0.isDeadlineSoon }
                .sorted { ($0.applicationDeadline ?? .distantFuture) < ($1.applicationDeadline ?? .distantFuture) }
            let rest = list.filter { !$0.isSponsored && !$0.isDeadlineSoon }
            list = sponsored + soon + rest
        }

        items = list
        tableView.reloadData()

        if filter == .saved && searchText.isEmpty {
            emptyLabel.text = "保存した掲載はまだありません\n写真右上のしおりで保存できます"
        } else {
            emptyLabel.text = "該当する掲載はありません"
        }
        emptyLabel.isHidden = !items.isEmpty
    }

    // MARK: - UITableViewDataSource
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: GakuchikaFeedCell.reuseId, for: indexPath) as! GakuchikaFeedCell
        let item = items[indexPath.row]
        cell.configure(with: item)
        cell.onBookmarkToggled = { id in
            if CareerBookmarkStore.shared.toggle(id: id) {
                AppAnalytics.logCareerSave(jobID: id)
            }
        }
        cell.onApply = { [weak self] in self?.openApplication(for: item) }
        return cell
    }

    // MARK: - UITableViewDelegate
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let vc = CareerDetailViewController(listing: items[indexPath.row])
        navigationController?.pushViewController(vc, animated: true)
    }
}
