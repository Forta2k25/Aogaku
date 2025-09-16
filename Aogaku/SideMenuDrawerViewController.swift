import UIKit

protocol SideMenuDrawerDelegate: AnyObject {
    func sideMenuDidSelectLogout()
    func sideMenuDidSelectDeleteAccount()
    func sideMenuDidSelectContact()
    func sideMenuDidSelectTerms()
    func sideMenuDidSelectPrivacy()
    func sideMenuDidSelectFAQ()
}

final class SideMenuDrawerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    weak var delegate: SideMenuDrawerDelegate?

    /// ← これでアカウント系セクションの表示/非表示を切り替え
    var showsAccountSection: Bool = true

    private let dimmingButton = UIButton(type: .custom)
    private let containerView = UIView()
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let versionLabel = UILabel()

    private enum Section: Int, CaseIterable { case account, others }

    private let accountTitles = ["ログアウト", "アカウント削除"]
    private let otherTitles   = ["お問い合わせ", "利用規約", "プライバシーポリシー", "よくある質問"]

    private var containerWidth: CGFloat { min(view.bounds.width * 0.82, 320) }
    private var containerTrailingConstraint: NSLayoutConstraint!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        setupUI()
        setupGestures()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        containerTrailingConstraint.constant = containerWidth
        updateDimming()
        view.layoutIfNeeded()
        open(animated: true)
    }

    // MARK: - UI
    private func setupUI() {
        dimmingButton.backgroundColor = UIColor.black.withAlphaComponent(0.0)
        dimmingButton.translatesAutoresizingMaskIntoConstraints = false
        dimmingButton.addTarget(self, action: #selector(didTapDimming), for: .touchUpInside)
        view.addSubview(dimmingButton)
        NSLayoutConstraint.activate([
            dimmingButton.topAnchor.constraint(equalTo: view.topAnchor),
            dimmingButton.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dimmingButton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimmingButton.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        containerView.backgroundColor = .systemBackground
        containerView.layer.cornerRadius = 12
        containerView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        containerView.layer.shadowColor = UIColor.black.cgColor
        containerView.layer.shadowOpacity = 0.15
        containerView.layer.shadowRadius = 10
        containerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(containerView)

        containerTrailingConstraint = containerView
            .trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: containerWidth)

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: view.topAnchor),
            containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            containerView.widthAnchor.constraint(equalToConstant: containerWidth),
            containerTrailingConstraint
        ])

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.showsVerticalScrollIndicator = false
        containerView.addSubview(tableView)

        let footer = UIView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(footer)

        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabel
        versionLabel.textAlignment = .right
        versionLabel.text = "バージョン 1.0\n© 2025 FORTA"
        versionLabel.numberOfLines = 2
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(versionLabel)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: containerView.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -12),

            versionLabel.topAnchor.constraint(equalTo: footer.topAnchor, constant: 8),
            versionLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            versionLabel.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -4)
        ])
    }

    private func setupGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        containerView.addGestureRecognizer(pan)
    }

    // MARK: - Actions
    @objc private func didTapDimming() { close(animated: true) }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: view)
        switch g.state {
        case .changed:
            let move = max(0, min(containerWidth, t.x))
            containerTrailingConstraint.constant = move
            updateDimming()
        case .ended, .cancelled:
            let v = g.velocity(in: view).x
            let shouldClose = (v > 400) || (containerTrailingConstraint.constant > containerWidth * 0.4)
            shouldClose ? close(animated: true) : open(animated: true)
        default: break
        }
    }

    // MARK: - Animations
    private func open(animated: Bool) {
        containerTrailingConstraint.constant = 0
        let animations = { self.updateDimming(); self.view.layoutIfNeeded() }
        if animated {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut], animations: animations)
        } else { animations() }
    }

    private func close(animated: Bool, completion: (() -> Void)? = nil) {
        containerTrailingConstraint.constant = containerWidth
        let animations = { self.updateDimming(); self.view.layoutIfNeeded() }
        let finish: (Bool) -> Void = { _ in
            self.dismiss(animated: false, completion: completion)
        }
        if animated {
            UIView.animate(withDuration: 0.20, delay: 0, options: [.curveEaseIn], animations: animations, completion: finish)
        } else { animations(); finish(true) }
    }

    private func updateDimming() {
        let progress = 1 - (containerTrailingConstraint.constant / containerWidth)
        dimmingButton.backgroundColor = UIColor.black.withAlphaComponent(0.25 * progress)
    }

    // MARK: - Helpers
    private func mappedSection(for index: Int) -> Section {
        // showsAccountSection=false のときは 0→others のみ
        return showsAccountSection ? Section(rawValue: index)! : .others
    }

    // MARK: - TableView
    func numberOfSections(in tableView: UITableView) -> Int {
        showsAccountSection ? Section.allCases.count : 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch mappedSection(for: section) {
        case .account: return accountTitles.count
        case .others:  return otherTitles.count
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch mappedSection(for: section) {
        case .account: return "アカウント"
        case .others:  return "その他"
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: "cell")
        switch mappedSection(for: indexPath.section) {
        case .account:
            cell.textLabel?.text = accountTitles[indexPath.row]
            cell.textLabel?.textColor = (indexPath.row == 1) ? .systemRed : .label
        case .others:
            cell.textLabel?.text = otherTitles[indexPath.row]
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let delegate = self.delegate
        close(animated: true) {
            switch self.mappedSection(for: indexPath.section) {
            case .account:
                if indexPath.row == 0 { delegate?.sideMenuDidSelectLogout() }
                else { delegate?.sideMenuDidSelectDeleteAccount() }
            case .others:
                switch indexPath.row {
                case 0: delegate?.sideMenuDidSelectContact()
                case 1: delegate?.sideMenuDidSelectTerms()
                case 2: delegate?.sideMenuDidSelectPrivacy()
                case 3: delegate?.sideMenuDidSelectFAQ()
                default: break
                }
            }
        }
    }
}
