import UIKit
import FirebaseFirestore

struct CircleFilters: Equatable {
    var categories: Set<String> = []
    var targets: Set<String> = []
    var weekdays: Set<String> = []
    var canDouble: Bool? = nil
    var hasSelection: Bool? = nil
    var moods: Set<String> = []
    var feeMin: Int? = nil
    var feeMax: Int? = nil
}

final class CirclesViewController: UIViewController,
                                   UICollectionViewDataSource,
                                   UICollectionViewDelegateFlowLayout,
                                   UISearchBarDelegate {

    // MARK: - Grid Columns（2列 / 3列）
    private enum GridColumns: Int {
        case two = 2
        case three = 3

        var iconName: String {
            switch self {
            case .two: return "square.grid.2x2"
            case .three: return "square.grid.3x3"
            }
        }
    }

    private let gridColumnsKey = "circles_grid_columns"
    private var gridBarButtonItem: UIBarButtonItem?

    private var gridColumns: GridColumns = .three {
        didSet {
            UserDefaults.standard.set(gridColumns.rawValue, forKey: gridColumnsKey)
            updateGridButtonIcon()

            if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
                layout.minimumInteritemSpacing = currentGridSpacing
                layout.minimumLineSpacing = currentGridSpacing
            }

            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.reloadData()
        }
    }

    private var currentGridSpacing: CGFloat {
        gridColumns == .three ? 4 : 16
    }

    private func loadGridColumns() {
        let saved = UserDefaults.standard.integer(forKey: gridColumnsKey)
        if let v = GridColumns(rawValue: saved) {
            gridColumns = v
        } else {
            gridColumns = .three
        }
    }

    // MARK: - Sort
    private enum SortOption: Equatable {
        case popularityDesc
        case membersDesc
        case membersAsc

        var title: String {
            switch self {
            case .popularityDesc: return "ビュー順"
            case .membersDesc:    return "人数順↓"
            case .membersAsc:     return "人数順↑"
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

    private let searchRow = UIView()

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

    private let sortButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        btn.tintColor = .label
        btn.setTitleColor(.label, for: .normal)
        btn.contentHorizontalAlignment = .center
        btn.setImage(UIImage(systemName: "arrow.up.arrow.down"), for: .normal)
        btn.semanticContentAttribute = .forceLeftToRight
        btn.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 4)
        btn.contentEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        btn.layer.cornerRadius = 10
        btn.backgroundColor = .secondarySystemGroupedBackground
        return btn
    }()

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = currentGridSpacing
        layout.minimumLineSpacing = currentGridSpacing

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

    private var bookmarkBarButtonItem: UIBarButtonItem?
    private var filters = CircleFilters()

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        setupNavigationHeader()
        setupRightBarButtons()
        setupUI()

        campusSegmentedControl.addTarget(self, action: #selector(campusChanged), for: .valueChanged)
        searchBar.delegate = self

        sortButton.addTarget(self, action: #selector(didTapSort), for: .touchUpInside)
        updateSortButtonTitle()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(bookmarkChanged),
                                               name: .bookmarkDidChange,
                                               object: nil)

        loadGridColumns()

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

    private func setupRightBarButtons() {
        let bookmark = UIBarButtonItem(image: UIImage(systemName: "bookmark"),
                                       style: .plain,
                                       target: self,
                                       action: #selector(didTapBookmarks))
        bookmark.tintColor = .label
        bookmarkBarButtonItem = bookmark

        let grid = UIBarButtonItem(image: UIImage(systemName: GridColumns.three.iconName),
                                   style: .plain,
                                   target: self,
                                   action: #selector(didTapGridButton))
        grid.tintColor = .label
        gridBarButtonItem = grid

        navigationItem.rightBarButtonItems = [bookmark, grid]
        updateGridButtonIcon()
    }

    private func updateGridButtonIcon() {
        gridBarButtonItem?.image = UIImage(systemName: gridColumns.iconName)
    }

    @objc private func didTapGridButton() {
        let ac = UIAlertController(title: "表示列数", message: nil, preferredStyle: .actionSheet)

        ac.addAction(UIAlertAction(title: "2列", style: .default) { [weak self] _ in
            self?.gridColumns = .two
        })
        ac.addAction(UIAlertAction(title: "3列", style: .default) { [weak self] _ in
            self?.gridColumns = .three
        })
        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))

        if let pop = ac.popoverPresentationController, let btn = gridBarButtonItem {
            pop.barButtonItem = btn
        }

        present(ac, animated: true)
    }

    // MARK: - UI Setup
    private func setupUI() {
        view.addSubview(campusSegmentedControl)
        view.addSubview(searchRow)
        view.addSubview(collectionView)

        searchRow.translatesAutoresizingMaskIntoConstraints = false
        searchRow.addSubview(searchBar)
        searchRow.addSubview(sortButton)

        NSLayoutConstraint.activate([
            campusSegmentedControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            campusSegmentedControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            campusSegmentedControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            searchRow.topAnchor.constraint(equalTo: campusSegmentedControl.bottomAnchor, constant: 10),
            searchRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            searchRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            searchRow.heightAnchor.constraint(equalToConstant: 44),

            sortButton.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor),
            sortButton.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
            sortButton.widthAnchor.constraint(equalToConstant: 96),
            sortButton.heightAnchor.constraint(equalToConstant: 36),

            searchBar.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor),
            searchBar.topAnchor.constraint(equalTo: searchRow.topAnchor),
            searchBar.bottomAnchor.constraint(equalTo: searchRow.bottomAnchor),
            searchBar.trailingAnchor.constraint(equalTo: sortButton.leadingAnchor, constant: -8),

            collectionView.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 10),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            collectionView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
    }

    // MARK: - Campus Matching
    private func normalizeCampusForFilter(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if s.isEmpty { return "both" }

        if s == "青山" || s == "相模原" || s == "両キャンパス" {
            return s
        }

        if s == "青山キャンパス" || s == "相模原キャンパス" {
            return "both"
        }

        if s.contains("両キャンパス") { return "両キャンパス" }

        let hasAoyama = s.contains("青山")
        let hasSagamihara = s.contains("相模原")

        if hasAoyama && hasSagamihara { return "両キャンパス" }

        return "both"
    }

    private func matchesSelectedCampus(_ item: CircleItem) -> Bool {
        let normalized = normalizeCampusForFilter(item.campus)

        switch normalized {
        case "青山":
            return selectedCampus == "青山"
        case "相模原":
            return selectedCampus == "相模原"
        case "両キャンパス", "both":
            return true
        default:
            return true
        }
    }

    // MARK: - Actions
    @objc private func campusChanged() {
        selectedCampus = campusSegmentedControl.selectedSegmentIndex == 0 ? "青山" : "相模原"

        queryText = ""
        searchBar.text = nil
        searchBar.resignFirstResponder()

        applyFilter()
    }

    @objc private func didTapBookmarks() {
        let vc = BookmarkedCirclesViewController()
        navigationController?.pushViewController(vc, animated: true)
    }

    @objc private func bookmarkChanged() {
        collectionView.reloadData()
    }

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
            .order(by: "popularity", descending: true)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }

                if let error = error {
                    print("Firestore error:", error.localizedDescription)
                    return
                }

                guard let snapshot else { return }
                let items = snapshot.documents.compactMap { CircleItem(document: $0) }
                self.setItems(items)

                if items.isEmpty {
                    print("Firestore returned 0 items")
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
                if ah != bh { return ah && !bh }
                let av = a.memberCount ?? -1
                let bv = b.memberCount ?? -1
                if av != bv { return av > bv }
                return a.popularity > b.popularity
            }

        case .membersAsc:
            visibleItems.sort { a, b in
                let ah = a.memberCount != nil
                let bh = b.memberCount != nil
                if ah != bh { return ah && !bh }
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
            guard matchesSelectedCampus(item) else { return false }

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

            if let v = filters.canDouble, item.canDouble != v {
                return false
            }

            if let v = filters.hasSelection, item.hasSelection != v {
                return false
            }

            if !filters.moods.isEmpty, !filters.moods.contains(item.intensity) {
                return false
            }

            if let minV = filters.feeMin {
                guard let fee = item.annualFeeYen, fee >= minV else { return false }
            }

            if let maxV = filters.feeMax {
                guard let fee = item.annualFeeYen, fee <= maxV else { return false }
            }

            return true
        }

        sortVisibleItems()
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
        visibleItems.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: CircleCollectionViewCell.reuseId,
            for: indexPath
        ) as! CircleCollectionViewCell

        let item = visibleItems[indexPath.item]
        cell.configure(with: item)

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

        let columns = CGFloat(gridColumns.rawValue)
        let interItemSpacing: CGFloat = currentGridSpacing
        let totalSpacing = interItemSpacing * (columns - 1)
        let width = floor((collectionView.bounds.width - totalSpacing) / columns)
        let height: CGFloat = (gridColumns == .two) ? 180 : 170

        return CGSize(width: width, height: height)
    }

    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        minimumInteritemSpacingForSectionAt section: Int) -> CGFloat {
        currentGridSpacing
    }

    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        minimumLineSpacingForSectionAt section: Int) -> CGFloat {
        currentGridSpacing
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
