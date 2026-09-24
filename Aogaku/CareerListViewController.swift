//
//  CareerListViewController.swift
//  Aogaku
//
//  キャリア（インターン・採用イベント・新卒求人）一覧画面
//

import UIKit
import FirebaseFirestore

final class CareerListViewController: UIViewController,
                                       UITableViewDataSource,
                                       UITableViewDelegate {

    // MARK: - UI
    private let filterScrollView = UIScrollView()
    private let filterStack = UIStackView()
    private var filterButtons: [CareerFilterTab: UIButton] = [:]

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()

    // MARK: - Firestore
    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?

    // MARK: - Data
    private var allItems: [CareerListing] = []
    private var visibleItems: [CareerListing] = []
    private var selectedTab: CareerFilterTab = .all

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        setupNavigationHeader()
        setupUI()
        startListening()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ScreenTracker.shared.appear("インターン一覧")
        AppAnalytics.logCareerListView()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        ScreenTracker.shared.disappear("インターン一覧")
    }

    deinit {
        listener?.remove()
    }

    // MARK: - Navigation
    private func setupNavigationHeader() {
        navigationItem.largeTitleDisplayMode = .never
        let titleLabel = UILabel()
        titleLabel.text = "インターン"
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = .label
        navigationItem.titleView = titleLabel
    }

    // MARK: - UI Setup
    private func setupUI() {
        setupFilterBar()
        setupTableView()
        setupEmptyLabel()
    }

    private func setupFilterBar() {
        filterScrollView.showsHorizontalScrollIndicator = false
        filterScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(filterScrollView)

        filterStack.axis = .horizontal
        filterStack.spacing = 8
        filterStack.translatesAutoresizingMaskIntoConstraints = false
        filterScrollView.addSubview(filterStack)

        for tab in CareerFilterTab.allCases {
            let button = UIButton(type: .system)
            button.setTitle(tab.title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            button.layer.cornerRadius = 17
            button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
            button.addAction(UIAction { [weak self] _ in
                self?.didSelectTab(tab)
            }, for: .touchUpInside)

            filterButtons[tab] = button
            filterStack.addArrangedSubview(button)
        }
        updateFilterButtonStyles()

        NSLayoutConstraint.activate([
            filterScrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            filterScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            filterScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            filterScrollView.heightAnchor.constraint(equalToConstant: 50),

            filterStack.topAnchor.constraint(equalTo: filterScrollView.topAnchor),
            filterStack.bottomAnchor.constraint(equalTo: filterScrollView.bottomAnchor),
            filterStack.leadingAnchor.constraint(equalTo: filterScrollView.leadingAnchor, constant: 16),
            filterStack.trailingAnchor.constraint(equalTo: filterScrollView.trailingAnchor, constant: -16),
            filterStack.heightAnchor.constraint(equalTo: filterScrollView.heightAnchor),
        ])
    }

    private func setupTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(CareerListingCell.self, forCellReuseIdentifier: CareerListingCell.reuseId)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 180
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: filterScrollView.bottomAnchor, constant: 4),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupEmptyLabel() {
        emptyLabel.text = "現在掲載中の求人・イベントはありません"
        emptyLabel.font = .systemFont(ofSize: 14, weight: .medium)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: tableView.topAnchor, constant: 60),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    // MARK: - Filter actions
    private func didSelectTab(_ tab: CareerFilterTab) {
        selectedTab = tab
        updateFilterButtonStyles()
        applyFilter()
    }

    private func updateFilterButtonStyles() {
        for (tab, button) in filterButtons {
            let selected = tab == selectedTab
            button.backgroundColor = selected ? .label : .secondarySystemGroupedBackground
            button.setTitleColor(selected ? .systemBackground : .label, for: .normal)
        }
    }

    // MARK: - Firestore
    private func startListening() {
        listener?.remove()

        listener = db.collection("careerListings")
            .order(by: "publishedAt", descending: true)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }

                if let error = error {
                    print("Firestore error:", error.localizedDescription)
                    return
                }

                guard let snapshot else { return }
                let now = Date()
                let items = snapshot.documents
                    .compactMap { CareerListing(document: $0) }
                    .filter { ($0.expiresAt ?? .distantFuture) > now }

                self.allItems = items
                self.applyFilter()
            }
    }

    // MARK: - Filtering
    private func applyFilter() {
        if let category = selectedTab.category {
            visibleItems = allItems.filter { $0.category == category }
        } else {
            visibleItems = allItems
        }
        tableView.reloadData()
        emptyLabel.isHidden = !visibleItems.isEmpty
    }

    // MARK: - UITableViewDataSource
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        visibleItems.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: CareerListingCell.reuseId, for: indexPath) as! CareerListingCell
        cell.configure(with: visibleItems[indexPath.row])
        return cell
    }

    // MARK: - UITableViewDelegate
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = visibleItems[indexPath.row]
        let vc = CareerDetailViewController(listing: item)
        navigationController?.pushViewController(vc, animated: true)
    }
}
