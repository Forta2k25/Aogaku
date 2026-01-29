import UIKit
import FirebaseFirestore

// ✅ フィルター状態
struct CircleFilters: Equatable {
    var categories: Set<String> = []
    var targets: Set<String> = []
    var weekdays: Set<String> = []
    var canDouble: Bool? = nil          // nil=指定なし
    var hasSelection: Bool? = nil       // nil=指定なし
    var moods: Set<String> = []         // "ゆるめ","ふつう","ガチめ"（CircleItem.intensity）
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
}

final class CirclesViewController: UIViewController,
                                  UICollectionViewDataSource,
                                  UICollectionViewDelegateFlowLayout,
                                  UISearchBarDelegate {

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
    
    // ✅ 右上フィルターボタン（自前バッジ）
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


    // ✅ filters
    private var filters = CircleFilters()

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        setupNavigationHeader()
        setupFilterButton()
        setupUI()

        campusSegmentedControl.addTarget(self, action: #selector(campusChanged), for: .valueChanged)
        searchBar.delegate = self

        selectedCampus = "青山"
        setItems(CircleItem.mock(for: selectedCampus))
        startListening()
    }

    deinit { listener?.remove() }

    // MARK: - Navigation
    private func setupNavigationHeader() {
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = nil
        navigationItem.leftItemsSupplementBackButton = false

        let titleLabel = UILabel()
        titleLabel.text = "サークル・部活"
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = .label
        navigationItem.titleView = titleLabel
    }

    private func setupFilterButton() {
        filterButton.translatesAutoresizingMaskIntoConstraints = false
        filterButton.setImage(UIImage(systemName: "line.3.horizontal.decrease.circle"), for: .normal)
        filterButton.tintColor = .label
        filterButton.addTarget(self, action: #selector(didTapFilter), for: .touchUpInside)

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        container.addSubview(filterButton)
        container.addSubview(filterBadgeLabel)

        filterButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            filterButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            filterButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            filterButton.widthAnchor.constraint(equalToConstant: 28),
            filterButton.heightAnchor.constraint(equalToConstant: 28),

            filterBadgeLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: -2),
            filterBadgeLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 2),
            filterBadgeLabel.heightAnchor.constraint(equalToConstant: 18),
            filterBadgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
        ])

        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: container)
        refreshFilterButton()
    }


    private func refreshFilterButton() {
        let count = filters.activeCount
        if count <= 0 {
            filterBadgeLabel.isHidden = true
            filterBadgeLabel.text = nil
        } else {
            filterBadgeLabel.isHidden = false
            filterBadgeLabel.text = "\(min(count, 99))"
        }
    }


    // MARK: - UI Setup
    private func setupUI() {
        view.addSubview(campusSegmentedControl)
        view.addSubview(searchBar)
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            campusSegmentedControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            campusSegmentedControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            campusSegmentedControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            searchBar.topAnchor.constraint(equalTo: campusSegmentedControl.bottomAnchor, constant: 10),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            collectionView.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 12),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            collectionView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
    }

    // MARK: - Actions
    @objc private func campusChanged() {
        selectedCampus = campusSegmentedControl.selectedSegmentIndex == 0 ? "青山" : "相模原"

        queryText = ""
        searchBar.text = nil
        searchBar.resignFirstResponder()

        // ✅ キャンパス切替ではフィルター維持（消したければここで filters = .init()）
        setItems(CircleItem.mock(for: selectedCampus))
        startListening()
    }

    @objc private func didTapFilter() {
        let vc = CircleFilterViewController(current: filters)
        vc.onApply = { [weak self] newFilters in
            guard let self else { return }
            self.filters = newFilters
            self.refreshFilterButton()
            self.applyFilter()
        }
        vc.onReset = { [weak self] in
            guard let self else { return }
            self.filters = CircleFilters()
            self.refreshFilterButton()
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

    // MARK: - Firestore Listener
    private func startListening() {
        listener?.remove()

        listener = db.collection("circle")
            .whereField("campus", isEqualTo: selectedCampus)
            .order(by: "popularity", descending: true)
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

    // MARK: - Filtering
    private func setItems(_ items: [CircleItem]) {
        self.allItems = items
        applyFilter()
    }

    private func applyFilter() {
        let q = queryText.trimmingCharacters(in: .whitespacesAndNewlines)

        visibleItems = allItems.filter { item in
            // 1) 検索
            let matchesSearch: Bool = {
                if q.isEmpty { return true }
                return item.name.localizedCaseInsensitiveContains(q)
                || item.intensity.localizedCaseInsensitiveContains(q)
                || (item.category?.localizedCaseInsensitiveContains(q) ?? false)
            }()

            guard matchesSearch else { return false }

            // 2) カテゴリ
            if !filters.categories.isEmpty {
                guard let cat = item.category, filters.categories.contains(cat) else { return false }
            }

            // 3) 対象（複数持ち想定：どれか一致でOK）
            if !filters.targets.isEmpty {
                let s = Set(item.targets)
                if s.isDisjoint(with: filters.targets) { return false }
            }

            // 4) 曜日（どれか一致でOK）
            if !filters.weekdays.isEmpty {
                let s = Set(item.weekdays)
                if s.isDisjoint(with: filters.weekdays) { return false }
            }

            // 5) 兼サー
            if let v = filters.canDouble {
                if item.canDouble != v { return false }
            }

            // 6) 選考
            if let v = filters.hasSelection {
                if item.hasSelection != v { return false }
            }

            // 7) 雰囲気（= intensity）
            if !filters.moods.isEmpty {
                if !filters.moods.contains(item.intensity) { return false }
            }

            // 8) 費用（年額目安）
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

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: CircleCollectionViewCell.reuseId,
            for: indexPath
        ) as! CircleCollectionViewCell
        cell.configure(with: visibleItems[indexPath.item])
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
