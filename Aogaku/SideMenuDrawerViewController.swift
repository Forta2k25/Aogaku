import UIKit

protocol SideMenuDrawerDelegate: AnyObject {
    func sideMenuDidSelectLogout()
    func sideMenuDidSelectDeleteAccount()
    func sideMenuDidSelectContact()
    func sideMenuDidSelectTerms()
    func sideMenuDidSelectPrivacy()
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
    private let otherTitles   = ["お問い合わせ", "利用規約", "プライバシーポリシー"]

    private var containerWidth: CGFloat { min(view.bounds.width * 0.82, 320) }
    private var containerTrailingConstraint: NSLayoutConstraint!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        setupUI()
        setupGestures()
        prepareClosedState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        containerTrailingConstraint.constant = containerWidth
        updateDimming()
        view.layoutIfNeeded()
        open(animated: true)
    }
    
    
   /* override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        animateOpen()          // ← 画面表示と同時に“遅延ゼロ”で開始
    } */

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
        versionLabel.text = "バージョン 1.3\n© 2025 FORTA"
        versionLabel.numberOfLines = 2
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(versionLabel)
        
        // ▼ Instagramボタン（footerを作った“後”に追加）— 差し替え版
        let igButton = UIButton(type: .system)
        igButton.translatesAutoresizingMaskIntoConstraints = false

        // 画像セット（アセット "instagram" が無ければ SF Symbols にフォールバック）
        let baseImage = UIImage(named: "instagram")?.withRenderingMode(.alwaysOriginal)
            ?? UIImage(systemName: "camera.fill")
        igButton.setImage(baseImage, for: .normal)

        // ★ Configuration は使わず従来レイアウトに（制約が素直に効くように）
        igButton.configuration = nil
        igButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        // 画像をボタン枠内に確実にフィットさせる
        igButton.contentHorizontalAlignment = .fill
        igButton.contentVerticalAlignment   = .fill
        igButton.clipsToBounds = true
        igButton.tintColor = .label

        // imageView 自体に制約を張って “ボタン＝20pt、画像＝ボタンいっぱい” を保証
        if let iv = igButton.imageView {
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.contentMode = .scaleAspectFit
            NSLayoutConstraint.activate([
                iv.topAnchor.constraint(equalTo: igButton.topAnchor),
                iv.bottomAnchor.constraint(equalTo: igButton.bottomAnchor),
                iv.leadingAnchor.constraint(equalTo: igButton.leadingAnchor),
                iv.trailingAnchor.constraint(equalTo: igButton.trailingAnchor),
            ])
        }

        igButton.accessibilityLabel = "Open Instagram"
        igButton.addTarget(self, action: #selector(didTapInstagram), for: .touchUpInside)
        footer.addSubview(igButton)


        NSLayoutConstraint.activate([
            // tableView と footer の関係
            tableView.topAnchor.constraint(equalTo: containerView.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            // footer 自身の外枠
            footer.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -12),

            // ▼ Instagramボタン（右下固定）
            igButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            igButton.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -4),
            igButton.widthAnchor.constraint(equalToConstant: 30),
            igButton.heightAnchor.constraint(equalToConstant: 30),

            // バージョン表記は左→Instagramボタン手前まで
            versionLabel.topAnchor.constraint(equalTo: footer.topAnchor, constant: 8),
            versionLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            versionLabel.trailingAnchor.constraint(equalTo: igButton.leadingAnchor, constant: -8),
            versionLabel.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -4)
        ])

    }
    
    // 追加：一度だけ開くアニメを走らせるためのフラグ
    private var didAnimateOpenOnce = false

    // 閉じた初期状態を即セット（オフスクリーン＆暗幕ゼロ）
    private func prepareClosedState() {
        containerTrailingConstraint.constant = containerWidth    // 右外へ退避
        dimmingButton.alpha = 0
        view.layoutIfNeeded()                                    // ← ここで状態を確定
    }

    // 開くアニメ（delay: 0.0）
    private func animateOpenIfNeeded() {
        guard !didAnimateOpenOnce else { return }
        didAnimateOpenOnce = true

        // 初期状態を確実に反映
        prepareClosedState()

        // 目標：メニューin / 暗幕フェードin
        containerTrailingConstraint.constant = 0
        UIView.animate(withDuration: 0.22,
                       delay: 0.0,
                       options: [.curveEaseOut, .allowUserInteraction]) {
            self.dimmingButton.alpha = 1
            self.view.layoutIfNeeded()
        }
    }

    // 閉じるアニメ（参考・既存があればそのまま）
    private func animateClose(completion: (() -> Void)? = nil) {
        containerTrailingConstraint.constant = containerWidth
        UIView.animate(withDuration: 0.18,
                       delay: 0.0,
                       options: [.curveEaseIn, .allowUserInteraction]) {
            self.dimmingButton.alpha = 0
            self.view.layoutIfNeeded()
        } completion: { _ in
            completion?()
            self.dismiss(animated: false, completion: nil)
        }
    }

    private func setupGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        containerView.addGestureRecognizer(pan)
    }

    @objc private func didTapInstagram() {
        guard let url = URL(string: "https://www.instagram.com/aogaku.hack") else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
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
                default: break
                }
            }
        }
    }
}
