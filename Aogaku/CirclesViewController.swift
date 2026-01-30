import UIKit
import FirebaseFirestore

// ✅ フィルター状態
struct CircleFilters: Equatable {
    var categories: Set<String> = []
    var targets: Set<String> = []
    var weekdays: Set<String> = []
    var canDouble: Bool? = nil
    var hasSelection: Bool? = nil
    var moods: Set<String> = []
    var feeMin: Int? = nil
    var feeMax: Int? = nil

    var isDefault: Bool {
        categories.isEmpty &&
        targets.isEmpty &&
        weekdays.isEmpty &&
        canDouble == nil &&
        hasSelection == nil &&
        moods.isEmpty &&
        feeMin == nil &&
        feeMax == nil
    }

    var activeCount: Int {
        var c = 0
        if !categories.isEmpty { c += 1 }
        if !targets.isEmpty { c += 1 }
        if !weekdays.isEmpty { c += 1 }
        if canDouble != nil { c += 1 }
        if hasSelection != nil { c += 1 }
        if !moods.isEmpty { c += 1 }
        if feeMin != nil || feeMax != nil { c += 1 }
        return c
    }

    /// 表示用のパーツ
    var summaryParts: [String] {
        var parts: [String] = []

        if !categories.isEmpty {
            parts.append("カテゴリ:" + categories.sorted().joined(separator: "・"))
        }
        if !targets.isEmpty {
            parts.append("対象:" + targets.sorted().joined(separator: "・"))
        }
        if !weekdays.isEmpty {
            parts.append("曜日:" + weekdays.sorted().joined(separator: "・"))
        }
        if let v = canDouble {
            parts.append(v ? "兼サー可" : "兼サー不可")
        }
        if let v = hasSelection {
            parts.append(v ? "選考あり" : "選考なし")
        }
        if !moods.isEmpty {
            parts.append("雰囲気:" + moods.sorted().joined(separator: "・"))
        }

        if feeMin != nil || feeMax != nil {
            let minText = feeMin != nil ? "\(feeMin!)円" : ""
            let maxText = feeMax != nil ? "\(feeMax!)円" : ""
            let feeText: String
            if feeMin != nil && feeMax != nil {
                feeText = "費用:\(minText)〜\(maxText)"
            } else if feeMin != nil {
                feeText = "費用:\(minText)〜"
            } else {
                feeText = "費用:〜\(maxText)"
            }
            parts.append(feeText)
        }

        return parts
    }

    /// 1行表示用（長ければ "..."）
    func summaryText(maxChars: Int = 18) -> String {
        let parts = summaryParts
        if parts.isEmpty { return "条件なし" }

        let joined = parts.joined(separator: " / ")
        if joined.count <= maxChars { return joined }

        let cut = max(0, maxChars - 3) // "..." の分
        let end = joined.index(joined.startIndex, offsetBy: min(cut, joined.count))
        return String(joined[..<end]) + "..."
    }
}

final class CirclesViewController: UIViewController,
                                  UICollectionViewDataSource,
                                  UICollectionViewDelegateFlowLayout,
                                  UISearchBarDelegate {

    // MARK: - Sort
    private enum SortOption: Equatable {
        case popularityDesc   // ビュー順（popularity）
        case membersDesc      // 人数の多い順
        case membersAsc       // 人数の少ない順

        var title: String {
            switch self {
            case .popularityDesc: return "ビュー順"
            case .membersDesc:    return "人数の多い順"
            case .membersAsc:     return "人数の少ない順"
            }
        }
    }
    private var sortOption: SortOption = .popularityDesc

    // MARK: - UI
    private let campusSegmentedControl: UISegmentedControl = {
        let sc = UISegmentedControl(items: ["青山", "相模原"])
        sc.selectedSegmentIndex = 0
        sc.translatesAutoresizingMaskIntoConstraints = false
        return sc
    }()

    private let searchBar: UISearchBar = {
        let sb = UISearchBar(frame: .zero)
        sb.translatesAutoresizingMaskIntoConstraints = false
        sb.placeholder = "キーワードで検索"
        sb.searchBarStyle = .minimal
        sb.autocapitalizationType = .none
        sb.autocorrectionType = .no
        sb.spellCheckingType = .no
        return sb
    }()

    // ✅ 検索バー下の行（左：条件要約、右：並び替え＋絞り込み）
    private let belowSearchRow = UIView()

    private let conditionLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = .systemFont(ofSize: 13, weight: .semibold)
        lb.textColor = .secondaryLabel
        lb.text = "条件なし"
        lb.numberOfLines = 1
        lb.lineBreakMode = .byClipping
        return lb
    }()

    private let sortButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        btn.tintColor = .label
        btn.setTitleColor(.label, for: .normal)
        btn.contentHorizontalAlignment = .right
        btn.setImage(UIImage(systemName: "arrow.up.arrow.down"), for: .normal)
        btn.semanticContentAttribute = .forceLeftToRight
        btn.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 6)
        return btn
    }()

    // ✅ 絞り込みボタン（右側に配置）
    private let filterButton = UIButton(type: .system)
    private let filterBadgeLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = .systemFont(ofSize: 11, weight: .bold)
        lb.textColor = .white
        lb.backgroundColor = .systemRed
        lb.textAlignment = .center
        lb.layer.cornerRadius = 9
        lb.clipsToBounds = true
        lb.isHidden = true
        return lb
    }()
    private let filterContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 16

        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .clear
        cv.alwaysBounceVertical = true
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.dataSource = self
        cv.delegate = self
        cv.register(CircleCollectionViewCell.self,
                    forCellWithReuseIdentifier: CircleCollectionViewCell.reuseId)
        return cv
    }()

    // MARK: - Firestore
    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?

    // MARK: - Data
    private var selectedCampus: String = "青山"
    private var allItems: [CircleItem] = []
    private var visibleItems: [CircleItem] = []
    private var queryText: String = ""

    // ✅ 右上ブックマーク（ナビバーはブクマだけ残す）
    private var bookmarkBarButtonItem: UIBarButtonItem?

    // ✅ filters
    private var filters = CircleFilters()

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        setupNavigationHeader()
        setupBookmarkButton()      // ✅ ナビバー右はブクマのみ
        setupFilterControl()       // ✅ row内の絞り込み
        setupUI()

        campusSegmentedControl.addTarget(self, action: #selector(campusChanged), for: .valueChanged)
        searchBar.delegate = self

        sortButton.addTarget(self, action: #selector(didTapSort), for: .touchUpInside)
        updateSortButtonTitle()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(bookmarkChanged),
                                               name: .bookmarkDidChange,
                                               object: nil)

        selectedCampus = "青山"
        setItems(CircleItem.mock(for: selectedCampus))
        startListening()
    }

    deinit {
        listener?.remove()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Navigation
    private func setupNavigationHeader() {
        navigationItem.largeTitleDisplayMode = .never

        let titleLabel = UILabel()
        titleLabel.text = "サークル・部活"
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = .label
        navigationItem.titleView = titleLabel
    }

    private func setupBookmarkButton() {
        let item = UIBarButtonItem(image: UIImage(systemName: "bookmark"),
                                   style: .plain,
                                   target: self,
                                   action: #selector(didTapBookmarks))
        item.tintColor = .label
        bookmarkBarButtonItem = item
        navigationItem.rightBarButtonItems = [item]
    }

    // ✅ 検索バー下の右側に置く絞り込み（バッジ付き）
    private func setupFilterControl() {
        filterButton.translatesAutoresizingMaskIntoConstraints = false
        filterButton.setImage(UIImage(systemName: "line.3.horizontal.decrease.circle"), for: .normal)

        // ✅ ここ追加（文字を右側に）
        filterButton.setTitle("絞り込み", for: .normal)
        filterButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        filterButton.setTitleColor(.label, for: .normal)
        filterButton.tintColor = .label
        filterButton.semanticContentAttribute = .forceLeftToRight
        filterButton.contentHorizontalAlignment = .right
        filterButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 6)

        filterButton.addTarget(self, action: #selector(didTapFilter), for: .touchUpInside)

        filterContainer.addSubview(filterButton)
        filterContainer.addSubview(filterBadgeLabel)

        NSLayoutConstraint.activate([
            // ✅ 右寄せ配置
            filterButton.trailingAnchor.constraint(equalTo: filterContainer.trailingAnchor),
            filterButton.centerYAnchor.constraint(equalTo: filterContainer.centerYAnchor),
            filterButton.heightAnchor.constraint(equalToConstant: 28),

            // ✅ バッジは右上（テキスト込みの右端に追従）
            filterBadgeLabel.topAnchor.constraint(equalTo: filterContainer.topAnchor, constant: -2),
            filterBadgeLabel.trailingAnchor.constraint(equalTo: filterContainer.trailingAnchor, constant: 2),
            filterBadgeLabel.heightAnchor.constraint(equalToConstant: 18),
            filterBadgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
        ])

        refreshFilterBadge()
    }


    private func refreshFilterBadge() {
        let count = filters.activeCount
        if count <= 0 {
            filterBadgeLabel.isHidden = true
            filterBadgeLabel.text = nil
        } else {
            filterBadgeLabel.isHidden = false
            filterBadgeLabel.text = "\(min(count, 99))"
        }
    }

    private func refreshConditionLabel() {
        conditionLabel.text = filters.summaryText(maxChars: 18)
    }

    // MARK: - UI Setup
    private func setupUI() {
        view.addSubview(campusSegmentedControl)
        view.addSubview(searchBar)
        view.addSubview(belowSearchRow)
        view.addSubview(collectionView)

        belowSearchRow.translatesAutoresizingMaskIntoConstraints = false
        belowSearchRow.addSubview(conditionLabel)
        belowSearchRow.addSubview(sortButton)
        belowSearchRow.addSubview(filterContainer)

        NSLayoutConstraint.activate([
            campusSegmentedControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            campusSegmentedControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            campusSegmentedControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            searchBar.topAnchor.constraint(equalTo: campusSegmentedControl.bottomAnchor, constant: 10),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            belowSearchRow.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 2),
            belowSearchRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            belowSearchRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            belowSearchRow.heightAnchor.constraint(equalToConstant: 28),

            // 左：条件
            conditionLabel.centerYAnchor.constraint(equalTo: belowSearchRow.centerYAnchor),
            conditionLabel.leadingAnchor.constraint(equalTo: belowSearchRow.leadingAnchor),

            // 右端：絞り込み（✅ 並び替えの右側）
            filterContainer.centerYAnchor.constraint(equalTo: belowSearchRow.centerYAnchor),
            filterContainer.trailingAnchor.constraint(equalTo: belowSearchRow.trailingAnchor),
            filterContainer.widthAnchor.constraint(equalToConstant: 80),
            filterContainer.heightAnchor.constraint(equalToConstant: 32),

            // 右：並び替え（絞り込みの左）
            sortButton.centerYAnchor.constraint(equalTo: belowSearchRow.centerYAnchor),
            sortButton.trailingAnchor.constraint(equalTo: filterContainer.leadingAnchor, constant: -10),

            // 条件は並び替えの左まで
            conditionLabel.trailingAnchor.constraint(lessThanOrEqualTo: sortButton.leadingAnchor, constant: -10),

            collectionView.topAnchor.constraint(equalTo: belowSearchRow.bottomAnchor, constant: 10),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            collectionView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])

        refreshConditionLabel()

        // ✅ タップ領域（絞り込み）
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTapFilter))
        filterContainer.isUserInteractionEnabled = true
        filterContainer.addGestureRecognizer(tap)
    }

    // MARK: - Actions
    @objc private func campusChanged() {
        selectedCampus = campusSegmentedControl.selectedSegmentIndex == 0 ? "青山" : "相模原"

        queryText = ""
        searchBar.text = nil
        searchBar.resignFirstResponder()

        setItems(CircleItem.mock(for: selectedCampus))
        startListening()
    }

    @objc private func didTapFilter() {
        let vc = CircleFilterViewController(current: filters)
        vc.onApply = { [weak self] newFilters in
            guard let self else { return }
            self.filters = newFilters
            self.refreshFilterBadge()
            self.refreshConditionLabel()
            self.applyFilter()
        }
        vc.onReset = { [weak self] in
            guard let self else { return }
            self.filters = CircleFilters()
            self.refreshFilterBadge()
            self.refreshConditionLabel()
            self.applyFilter()
        }

        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    @objc private func didTapBookmarks() {
        let vc = BookmarkedCirclesViewController()
        navigationController?.pushViewController(vc, animated: true)
    }

    @objc private func bookmarkChanged() {
        collectionView.reloadData()
    }

    // ✅ 並び替え
    private func updateSortButtonTitle() {
        sortButton.setTitle(sortOption.title, for: .normal)
    }

    @objc private func didTapSort() {
        let ac = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

        func optionTitle(_ option: SortOption) -> String {
            option == sortOption ? "✓ \(option.title)" : option.title
        }

        ac.addAction(UIAlertAction(title: optionTitle(.popularityDesc), style: .default) { [weak self] _ in
            guard let self else { return }
            self.sortOption = .popularityDesc
            self.updateSortButtonTitle()
            self.applyFilter()
        })

        ac.addAction(UIAlertAction(title: optionTitle(.membersDesc), style: .default) { [weak self] _ in
            guard let self else { return }
            self.sortOption = .membersDesc
            self.updateSortButtonTitle()
            self.applyFilter()
        })

        ac.addAction(UIAlertAction(title: optionTitle(.membersAsc), style: .default) { [weak self] _ in
            guard let self else { return }
            self.sortOption = .membersAsc
            self.updateSortButtonTitle()
            self.applyFilter()
        })

        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))

        if let pop = ac.popoverPresentationController {
            pop.sourceView = sortButton
            pop.sourceRect = sortButton.bounds
        }
        present(ac, animated: true)
    }

    // MARK: - Firestore Listener
    private func startListening() {
        listener?.remove()

        listener = db.collection("circle")
            .whereField("campus", isEqualTo: selectedCampus)
            .order(by: "popularity", descending: true) // Firestore側は一旦 popularity
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }

                if let error = error {
                    print("Firestore error:", error.localizedDescription)
                    return
                }

                guard let snapshot else { return }
                let items = snapshot.documents.compactMap { CircleItem(document: $0) }

                if !items.isEmpty {
                    self.setItems(items)
                } else {
                    print("Firestore returned 0 items for campus=\(self.selectedCampus)")
                }
            }
    }

    // MARK: - Filtering / Sorting
    private func setItems(_ items: [CircleItem]) {
        self.allItems = items
        applyFilter()
    }

    private func sortVisibleItems() {
        switch sortOption {
        case .popularityDesc:
            visibleItems.sort { a, b in
                if a.popularity != b.popularity { return a.popularity > b.popularity }
                return a.name < b.name
            }

        case .membersDesc:
            visibleItems.sort { a, b in
                let ah = a.memberCount != nil
                let bh = b.memberCount != nil
                if ah != bh { return ah && !bh } // 数字取れる方を先に
                let av = a.memberCount ?? -1
                let bv = b.memberCount ?? -1
                if av != bv { return av > bv }
                return a.popularity > b.popularity
            }

        case .membersAsc:
            visibleItems.sort { a, b in
                let ah = a.memberCount != nil
                let bh = b.memberCount != nil
                if ah != bh { return ah && !bh } // 数字取れる方を先に（nil は最後）
                let av = a.memberCount ?? Int.max
                let bv = b.memberCount ?? Int.max
                if av != bv { return av < bv }
                return a.popularity > b.popularity
            }
        }
    }

    private func applyFilter() {
        let q = queryText.trimmingCharacters(in: .whitespacesAndNewlines)

        visibleItems = allItems.filter { item in
            let matchesSearch: Bool = {
                if q.isEmpty { return true }
                return item.name.localizedCaseInsensitiveContains(q)
                || item.intensity.localizedCaseInsensitiveContains(q)
                || (item.category?.localizedCaseInsensitiveContains(q) ?? false)
            }()
            guard matchesSearch else { return false }

            if !filters.categories.isEmpty {
                guard let cat = item.category, filters.categories.contains(cat) else { return false }
            }

            if !filters.targets.isEmpty {
                let s = Set(item.targets)
                if s.isDisjoint(with: filters.targets) { return false }
            }

            if !filters.weekdays.isEmpty {
                let s = Set(item.weekdays)
                if s.isDisjoint(with: filters.weekdays) { return false }
            }

            if let v = filters.canDouble {
                if item.canDouble != v { return false }
            }

            if let v = filters.hasSelection {
                if item.hasSelection != v { return false }
            }

            if !filters.moods.isEmpty {
                if !filters.moods.contains(item.intensity) { return false }
            }

            if let minV = filters.feeMin {
                if let fee = item.annualFeeYen {
                    if fee < minV { return false }
                } else {
                    return false
                }
            }
            if let maxV = filters.feeMax {
                if let fee = item.annualFeeYen {
                    if fee > maxV { return false }
                } else {
                    return false
                }
            }

            return true
        }

        sortVisibleItems()
        refreshConditionLabel()
        refreshFilterBadge()

        collectionView.reloadData()
    }

    // MARK: - UISearchBarDelegate
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        queryText = searchText
        applyFilter()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        queryText = ""
        searchBar.text = nil
        searchBar.resignFirstResponder()
        applyFilter()
    }

    // MARK: - UICollectionViewDataSource
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return visibleItems.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: CircleCollectionViewCell.reuseId,
            for: indexPath
        ) as! CircleCollectionViewCell

        let item = visibleItems[indexPath.item]
        cell.configure(with: item)

        // ✅ 再利用事故を防ぐ：セル参照から indexPath を取り直す
        cell.onTapBookmark = { [weak self, weak cell] id in
            guard let self else { return }
            BookmarkStore.shared.toggle(id: id)

            guard let cell, let ip = self.collectionView.indexPath(for: cell) else {
                self.collectionView.reloadData()
                return
            }
            self.collectionView.reloadItems(at: [ip])
        }

        return cell
    }

    // MARK: - UICollectionViewDelegateFlowLayout
    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let interItemSpacing: CGFloat = 16
        let width = (collectionView.bounds.width - interItemSpacing) / 2
        return CGSize(width: width, height: 180)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let item = visibleItems[indexPath.item]
        let vc = CircleDetailViewController(circleId: item.id)

        if let nav = navigationController {
            nav.pushViewController(vc, animated: true)
        } else {
            present(UINavigationController(rootViewController: vc), animated: true)
        }
    }
}
