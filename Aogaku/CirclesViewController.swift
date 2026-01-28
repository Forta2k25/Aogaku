

//
//  CirclesViewController.swift
//  AogakuHack
//
//  UIKit / Storyboard minimal (scene only) compatible:
//   - Put a plain UIViewController in storyboard and set Custom Class = CirclesViewController
//   - Do NOT place UI components on storyboard
//
//  This controller builds UI entirely in code:
//   - UISegmentedControl (青山 / 相模原)
//   - 2-column UICollectionView grid (scrollable)
//   - Firestore listener for collection "circle"
//   - Falls back to mock data if Firestore is empty or not ready
//
//


import UIKit
import FirebaseFirestore

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

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        setupNavigationHeader()   // ← 自動の「＜」の右にタイトルを置く
        setupUI()

        campusSegmentedControl.addTarget(self, action: #selector(campusChanged), for: .valueChanged)
        searchBar.delegate = self

        // 初期表示：まずmockを出す → Firestoreが取れたら上書き
        selectedCampus = "青山"
        setItems(CircleItem.mock(for: selectedCampus))
        startListening()
    }

    deinit {
        listener?.remove()
    }

    // MARK: - Navigation (title next to back button)
    private func setupNavigationHeader() {
        navigationItem.largeTitleDisplayMode = .never

        // 左の customView をやめる（これが“ボタンっぽさ”の原因）
        navigationItem.leftBarButtonItem = nil
        navigationItem.leftItemsSupplementBackButton = false

        // 真ん中に普通のタイトルとして表示
        navigationItem.title = "サークル・部活"

        // もしフォントを太字/サイズ指定したいなら titleView を使う
        let titleLabel = UILabel()
        titleLabel.text = "サークル・部活"
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = .label
        navigationItem.titleView = titleLabel
    }


    // MARK: - UI Setup
    private func setupUI() {
        view.addSubview(campusSegmentedControl)
        view.addSubview(searchBar)
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            // ここを詰めると「全体を上に」持っていける
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

        // キャンパス切り替えたら検索もリセット（好みで外してOK）
        queryText = ""
        searchBar.text = nil
        searchBar.resignFirstResponder()

        // まずmockで即表示
        setItems(CircleItem.mock(for: selectedCampus))

        // Firestoreを張り直し
        startListening()
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
        if q.isEmpty {
            visibleItems = allItems
        } else {
            visibleItems = allItems.filter {
                $0.name.localizedCaseInsensitiveContains(q)
                || $0.intensity.localizedCaseInsensitiveContains(q)
            }
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
        // 2列想定（interitemSpacing = 16）
        let interItemSpacing: CGFloat = 16
        let width = (collectionView.bounds.width - interItemSpacing) / 2

        // 縦を縮めて「元の感じ」に寄せる（Cell内部の image=120 に対して余白が出にくい）
        return CGSize(width: width, height: 180)
    }
    // 末尾に追加（クラス内）
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let item = visibleItems[indexPath.item]
        let vc = CircleDetailViewController(circleId: item.id)

        if let nav = navigationController {
            nav.pushViewController(vc, animated: true)
        } else {
            // navが無い場合でも開けるように保険
            present(UINavigationController(rootViewController: vc), animated: true)
        }
    }

}
