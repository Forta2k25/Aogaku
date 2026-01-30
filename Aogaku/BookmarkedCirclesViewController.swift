//
//  BookmarkedCirclesViewController.swift
//  Aogaku
//
//  Created by shu m on 2026/01/31.
//

import UIKit
import FirebaseFirestore

final class BookmarkedCirclesViewController: UIViewController,
                                             UICollectionViewDataSource,
                                             UICollectionViewDelegateFlowLayout,
                                             UISearchBarDelegate {

    // MARK: UI
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

    private let kindSegment: UISegmentedControl = {
        let sc = UISegmentedControl(items: ["すべて", "サークル", "部活", "その他"])
        sc.selectedSegmentIndex = 0
        sc.translatesAutoresizingMaskIntoConstraints = false
        return sc
    }()

    private let countLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = .systemFont(ofSize: 13, weight: .semibold)
        lb.textColor = .secondaryLabel
        return lb
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

    // 空状態
    private let emptyStateView = UIView()
    private let emptyIcon = UIImageView()
    private let emptyTitle = UILabel()
    private let emptyBody = UILabel()
    private let emptyButton = UIButton(type: .system)

    // MARK: Data
    private let db = Firestore.firestore()
    private var allBookmarkedItems: [CircleItem] = []
    private var visibleItems: [CircleItem] = []
    private var queryText: String = ""
    private var selectedKind: String = "すべて"

    // MARK: Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        setupNav()
        setupUI()
        setupEmptyState()

        searchBar.delegate = self
        kindSegment.addTarget(self, action: #selector(kindChanged), for: .valueChanged)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(bookmarkChanged),
                                               name: .bookmarkDidChange,
                                               object: nil)

        reloadFromStore()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Nav
    private func setupNav() {
        navigationItem.largeTitleDisplayMode = .never
        let titleLabel = UILabel()
        titleLabel.text = "ブックマーク済み"
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = .label
        navigationItem.titleView = titleLabel
    }

    // MARK: UI
    private func setupUI() {
        view.addSubview(searchBar)
        view.addSubview(kindSegment)
        view.addSubview(countLabel)
        view.addSubview(collectionView)
        view.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            kindSegment.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 8),
            kindSegment.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            kindSegment.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            countLabel.topAnchor.constraint(equalTo: kindSegment.bottomAnchor, constant: 8),
            countLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            countLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            collectionView.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 12),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            collectionView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            emptyStateView.topAnchor.constraint(equalTo: collectionView.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: collectionView.bottomAnchor),
        ])
    }

    private func setupEmptyState() {
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true

        emptyIcon.translatesAutoresizingMaskIntoConstraints = false
        emptyIcon.image = UIImage(systemName: "bookmark")
        emptyIcon.tintColor = .tertiaryLabel
        emptyIcon.contentMode = .scaleAspectFit

        emptyTitle.translatesAutoresizingMaskIntoConstraints = false
        emptyTitle.text = "まだブックマークがありません"
        emptyTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        emptyTitle.textColor = .secondaryLabel
        emptyTitle.textAlignment = .center

        emptyBody.translatesAutoresizingMaskIntoConstraints = false
        emptyBody.text = "気になる団体を保存して、あとで見返そう"
        emptyBody.font = .systemFont(ofSize: 13, weight: .regular)
        emptyBody.textColor = .tertiaryLabel
        emptyBody.textAlignment = .center
        emptyBody.numberOfLines = 0

        emptyButton.translatesAutoresizingMaskIntoConstraints = false
        emptyButton.setTitle("団体を探しにいく", for: .normal)
        emptyButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        emptyButton.tintColor = .systemGreen
        emptyButton.addTarget(self, action: #selector(didTapGoExplore), for: .touchUpInside)

        emptyStateView.addSubview(emptyIcon)
        emptyStateView.addSubview(emptyTitle)
        emptyStateView.addSubview(emptyBody)
        emptyStateView.addSubview(emptyButton)

        NSLayoutConstraint.activate([
            emptyIcon.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            emptyIcon.centerYAnchor.constraint(equalTo: emptyStateView.centerYAnchor, constant: -40),
            emptyIcon.widthAnchor.constraint(equalToConstant: 44),
            emptyIcon.heightAnchor.constraint(equalToConstant: 44),

            emptyTitle.topAnchor.constraint(equalTo: emptyIcon.bottomAnchor, constant: 14),
            emptyTitle.leadingAnchor.constraint(equalTo: emptyStateView.leadingAnchor, constant: 24),
            emptyTitle.trailingAnchor.constraint(equalTo: emptyStateView.trailingAnchor, constant: -24),

            emptyBody.topAnchor.constraint(equalTo: emptyTitle.bottomAnchor, constant: 8),
            emptyBody.leadingAnchor.constraint(equalTo: emptyStateView.leadingAnchor, constant: 24),
            emptyBody.trailingAnchor.constraint(equalTo: emptyStateView.trailingAnchor, constant: -24),

            emptyButton.topAnchor.constraint(equalTo: emptyBody.bottomAnchor, constant: 14),
            emptyButton.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
        ])
    }

    // MARK: Actions
    @objc private func didTapGoExplore() {
        navigationController?.popViewController(animated: true)
    }

    @objc private func kindChanged() {
        selectedKind = kindSegment.titleForSegment(at: kindSegment.selectedSegmentIndex) ?? "すべて"
        applyFilter()
    }

    @objc private func bookmarkChanged() {
        reloadFromStore()
    }

    // MARK: Loading
    private func reloadFromStore() {
        let ids = BookmarkStore.shared.allIDs()
        if ids.isEmpty {
            allBookmarkedItems = []
            visibleItems = []
            updateEmptyState()
            collectionView.reloadData()
            return
        }

        fetchCirclesByIDs(ids) { [weak self] items in
            guard let self else { return }
            // store の順番に合わせる
            let map = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            self.allBookmarkedItems = ids.compactMap { map[$0] }
            self.applyFilter()
        }
    }

    private func fetchCirclesByIDs(_ ids: [String], completion: @escaping ([CircleItem]) -> Void) {
        // Firestore whereIn は10件制限があるので分割
        let chunks: [[String]] = stride(from: 0, to: ids.count, by: 10).map {
            Array(ids[$0..<min($0 + 10, ids.count)])
        }

        var results: [CircleItem] = []
        let group = DispatchGroup()

        for chunk in chunks {
            group.enter()
            db.collection("circle")
                .whereField(FieldPath.documentID(), in: chunk)
                .getDocuments { snap, err in
                    defer { group.leave() }
                    if let err = err {
                        print("bookmark fetch error:", err.localizedDescription)
                        return
                    }
                    let items = snap?.documents.compactMap { CircleItem(document: $0) } ?? []
                    results.append(contentsOf: items)
                }
        }

        group.notify(queue: .main) {
            completion(results)
        }
    }

    private func applyFilter() {
        let q = queryText.trimmingCharacters(in: .whitespacesAndNewlines)

        visibleItems = allBookmarkedItems.filter { item in
            // 種別
            if selectedKind != "すべて" {
                if item.kind != selectedKind { return false }
            }
            // 検索
            if q.isEmpty { return true }
            return item.name.localizedCaseInsensitiveContains(q)
            || item.intensity.localizedCaseInsensitiveContains(q)
            || (item.category?.localizedCaseInsensitiveContains(q) ?? false)
        }

        updateCountLabel()
        updateEmptyState()
        collectionView.reloadData()
    }

    private func updateCountLabel() {
        countLabel.text = "保存した団体 \(visibleItems.count)件"
    }

    private func updateEmptyState() {
        let hasAny = !BookmarkStore.shared.allIDs().isEmpty
        emptyStateView.isHidden = hasAny
        collectionView.isHidden = !hasAny
        kindSegment.isHidden = !hasAny
        countLabel.isHidden = !hasAny
    }

    // MARK: UISearchBarDelegate
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        queryText = searchText
        applyFilter()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    // MARK: Collection
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

        // ✅ 追加は「そのセルだけ」更新、削除はデータが減るので再取得
        cell.onTapBookmark = { [weak self, weak cell] id in
            guard let self else { return }
            let added = BookmarkStore.shared.toggle(id: id)

            if !added {
                self.reloadFromStore()
                return
            }

            if let cell, let ip = self.collectionView.indexPath(for: cell) {
                self.collectionView.reloadItems(at: [ip])
            } else {
                self.collectionView.reloadData()
            }
        }

        return cell
    }

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
        navigationController?.pushViewController(vc, animated: true)
    }
}
