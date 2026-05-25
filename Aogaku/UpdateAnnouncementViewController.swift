//
//  UpdateAnnouncementViewController.swift
//  Aogaku
//

import UIKit
import FirebaseAuth

// MARK: - Page Data

private struct AnnouncementPage {
    let imageName: String
    let title: String
    let body: String
    let actionTitle: String?
    let actionURL: URL?

    init(_ imageName: String, title: String, body: String,
         actionTitle: String? = nil, actionURL: URL? = nil) {
        self.imageName   = imageName
        self.title       = title
        self.body        = body
        self.actionTitle = actionTitle
        self.actionURL   = actionURL
    }
}

// ▼ 画像ページの内容（3枚の画像ページ）
private let imagePages: [AnnouncementPage] = [
    AnnouncementPage(
        "announce_action",
        title: "時間割と単位状況を20秒で更新",
        body: "ポータルをSafariで開き、右下の「・・・」→共有→「青山ハック」をタップするだけ。\n教室変更や単位状況も自動で最新情報に反映されます。"
    ),
    AnnouncementPage(
        "announce_action_loading",
        title: "取得中は閉じないで！",
        body: "「シラバスURLを取得中...」の画面が出たら完了まで待ってください。\n完了すると時間割・単位状況が自動で更新されます。",
        actionTitle: "ポータルを開く",
        actionURL: URL(string: "https://aguinfo.jm.aoyama.ac.jp/AGUInfo/message_list.aspx")
    ),
    AnnouncementPage(
        "announce_web",
        title: "PCでも時間割を確認（ベータ）",
        body: "Google連携後、パソコンのブラウザから aoyamahack.com にアクセスするとPCでも時間割を確認できます。"
    ),
]

// ページ順：[Action, ActionLoading, Google連携(専用VC), Web]
// インデックス 2 だけ GoogleLinkPageVC を使う
private let googlePageIndex = 2
private let totalPageCount  = imagePages.count + 1  // 4

// MARK: - Indexed VC protocol

private protocol IndexedVC: UIViewController {
    var pageIndex: Int { get }
}

// MARK: - Container VC

final class UpdateAnnouncementViewController: UIViewController {

    var onDismiss: (() -> Void)?

    private var currentIndex = 0
    private let pageVC      = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
    private let bottomBar   = UIView()
    private let pageControl = UIPageControl()
    private let nextButton  = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupBottomBar()
        setupPageVC()
        updateUI(animated: false)
    }

    // MARK: Setup

    private func setupBottomBar() {
        bottomBar.backgroundColor = .systemBackground
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBar)

        pageControl.numberOfPages = totalPageCount
        pageControl.currentPageIndicatorTintColor = HackColors.accent
        pageControl.pageIndicatorTintColor        = HackColors.accent.withAlphaComponent(0.25)
        pageControl.isUserInteractionEnabled      = false
        pageControl.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(pageControl)

        nextButton.backgroundColor = HackColors.accent
        nextButton.setTitleColor(.white, for: .normal)
        nextButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        nextButton.layer.cornerRadius = 14
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        bottomBar.addSubview(nextButton)

        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            pageControl.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 8),
            pageControl.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),

            nextButton.topAnchor.constraint(equalTo: pageControl.bottomAnchor, constant: 8),
            nextButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 32),
            nextButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -32),
            nextButton.heightAnchor.constraint(equalToConstant: 52),
            nextButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    private func setupPageVC() {
        addChild(pageVC)
        pageVC.view.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(pageVC.view, belowSubview: bottomBar)
        pageVC.didMove(toParent: self)
        pageVC.dataSource = self
        pageVC.delegate   = self

        NSLayoutConstraint.activate([
            pageVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            pageVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageVC.view.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
        ])

        if let first = makeChild(index: 0) {
            pageVC.setViewControllers([first], direction: .forward, animated: false)
        }
    }

    // MARK: Helpers

    private func makeChild(index: Int) -> (UIViewController & IndexedVC)? {
        guard (0..<totalPageCount).contains(index) else { return nil }

        if index == googlePageIndex {
            return GoogleLinkPageVC(pageIndex: index)
        }

        // imagePages のインデックスに変換（google ページを飛ばす）
        let imageIndex = index < googlePageIndex ? index : index - 1
        guard imagePages.indices.contains(imageIndex) else { return nil }
        return AnnouncementPageContentVC(page: imagePages[imageIndex], pageIndex: index)
    }

    private func updateUI(animated: Bool) {
        pageControl.currentPage = currentIndex
        let isLast = currentIndex == totalPageCount - 1
        let label  = isLast ? "はじめる！" : "次へ"
        if animated {
            UIView.transition(with: nextButton, duration: 0.2, options: .transitionCrossDissolve) {
                self.nextButton.setTitle(label, for: .normal)
            }
        } else {
            nextButton.setTitle(label, for: .normal)
        }
    }

    @objc private func nextTapped() {
        if currentIndex < totalPageCount - 1 {
            currentIndex += 1
            guard let next = makeChild(index: currentIndex) else { return }
            pageVC.setViewControllers([next], direction: .forward, animated: true)
            updateUI(animated: true)
        } else {
            onDismiss?()
            dismiss(animated: true)
        }
    }
}

// MARK: - UIPageViewController DataSource / Delegate

extension UpdateAnnouncementViewController: UIPageViewControllerDataSource, UIPageViewControllerDelegate {

    func pageViewController(_ pvc: UIPageViewController,
                            viewControllerBefore vc: UIViewController) -> UIViewController? {
        guard let child = vc as? IndexedVC else { return nil }
        return makeChild(index: child.pageIndex - 1)
    }

    func pageViewController(_ pvc: UIPageViewController,
                            viewControllerAfter vc: UIViewController) -> UIViewController? {
        guard let child = vc as? IndexedVC else { return nil }
        return makeChild(index: child.pageIndex + 1)
    }

    func pageViewController(_ pvc: UIPageViewController,
                            didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController],
                            transitionCompleted completed: Bool) {
        guard completed, let current = pvc.viewControllers?.first as? IndexedVC else { return }
        currentIndex = current.pageIndex
        updateUI(animated: true)
    }
}

// MARK: - Image Page VC

private final class AnnouncementPageContentVC: UIViewController, IndexedVC {

    let pageIndex: Int
    private let page: AnnouncementPage

    init(page: AnnouncementPage, pageIndex: Int) {
        self.page      = page
        self.pageIndex = pageIndex
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildLayout()
    }

    private func buildLayout() {
        let imageView = UIImageView(image: UIImage(named: page.imageName))
        imageView.contentMode    = .scaleAspectFill
        imageView.clipsToBounds  = true
        imageView.backgroundColor = .secondarySystemBackground
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let card = UIView()
        card.backgroundColor = .systemBackground
        card.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text          = page.title
        titleLabel.font          = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor     = .label
        titleLabel.numberOfLines = 0
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let bodyLabel = UILabel()
        bodyLabel.text          = page.body
        bodyLabel.font          = .systemFont(ofSize: 15)
        bodyLabel.textColor     = .secondaryLabel
        bodyLabel.numberOfLines = 0
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(imageView)
        view.addSubview(card)
        card.addSubview(titleLabel)
        card.addSubview(bodyLabel)

        var constraints: [NSLayoutConstraint] = [
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.58),

            card.topAnchor.constraint(equalTo: imageView.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            bodyLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
            bodyLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),
        ]

        if let actionTitle = page.actionTitle, let actionURL = page.actionURL {
            let btn = UIButton(type: .system)
            btn.setTitle(actionTitle, for: .normal)
            btn.setTitleColor(HackColors.accent, for: .normal)
            btn.titleLabel?.font   = .systemFont(ofSize: 14, weight: .medium)
            btn.layer.borderColor  = HackColors.accent.cgColor
            btn.layer.borderWidth  = 1.5
            btn.layer.cornerRadius = 10
            btn.contentEdgeInsets  = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
            btn.translatesAutoresizingMaskIntoConstraints = false
            let url = actionURL
            btn.addAction(UIAction { _ in UIApplication.shared.open(url) }, for: .touchUpInside)
            card.addSubview(btn)
            constraints += [
                btn.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 18),
                btn.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
                btn.heightAnchor.constraint(equalToConstant: 38),
            ]
        }

        NSLayoutConstraint.activate(constraints)
    }
}

// MARK: - Google Link Page VC

private final class GoogleLinkPageVC: UIViewController, IndexedVC {

    let pageIndex: Int
    private let googleButton = UIButton(type: .system)

    init(pageIndex: Int) {
        self.pageIndex = pageIndex
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildLayout()
        refreshGoogleButtonState()
    }

    // MARK: Layout

    private func buildLayout() {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(container)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            container.topAnchor.constraint(equalTo: scrollView.topAnchor),
            container.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            container.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        // Google icon
        let iconView = UIImageView(image: UIImage(named: "google_logo"))
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        // Title
        let titleLabel = UILabel()
        titleLabel.text          = "Googleでかんたんログイン"
        titleLabel.font          = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor     = .label
        titleLabel.numberOfLines = 0
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Body
        let bodyLabel = UILabel()
        bodyLabel.text          = "Googleアカウントでのサインインに対応しました。メールとパスワードなしでサクッとサインインできます。"
        bodyLabel.font          = .systemFont(ofSize: 15)
        bodyLabel.textColor     = .secondaryLabel
        bodyLabel.numberOfLines = 0
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        // Google button
        googleButton.backgroundColor    = .white
        googleButton.setTitleColor(UIColor(white: 0.2, alpha: 1), for: .normal)
        googleButton.titleLabel?.font   = .systemFont(ofSize: 16, weight: .medium)
        googleButton.layer.cornerRadius = 12
        googleButton.layer.borderWidth  = 1
        googleButton.layer.borderColor  = UIColor.separator.cgColor
        googleButton.layer.shadowColor  = UIColor.black.cgColor
        googleButton.layer.shadowOpacity = 0.06
        googleButton.layer.shadowOffset  = CGSize(width: 0, height: 1)
        googleButton.layer.shadowRadius  = 3
        if let gIcon = UIImage(named: "google_logo") {
            googleButton.setImage(gIcon, for: .normal)
            googleButton.imageView?.contentMode = .scaleAspectFit
        }
        googleButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        googleButton.imageEdgeInsets   = UIEdgeInsets(top: 0, left: -4, bottom: 0, right: 4)
        googleButton.translatesAutoresizingMaskIntoConstraints = false
        googleButton.addTarget(self, action: #selector(googleButtonTapped), for: .touchUpInside)

        // Divider
        let dividerStack = makeDivider(text: "あとから連携する場合")

        // Steps
        let stepsStack = makeSteps([
            ("友だち", "「友だち」タブを開く"),
            ("👤", "自分のプロフィールをタップ"),
            ("🔗", "「Google連携」からアカウントを連携"),
        ])

        container.addSubview(iconView)
        container.addSubview(titleLabel)
        container.addSubview(bodyLabel)
        container.addSubview(googleButton)
        container.addSubview(dividerStack)
        container.addSubview(stepsStack)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 48),
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            bodyLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            bodyLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),

            googleButton.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 24),
            googleButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            googleButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            googleButton.heightAnchor.constraint(equalToConstant: 52),

            dividerStack.topAnchor.constraint(equalTo: googleButton.bottomAnchor, constant: 32),
            dividerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            dividerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),

            stepsStack.topAnchor.constraint(equalTo: dividerStack.bottomAnchor, constant: 16),
            stepsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            stepsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            stepsStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -32),
        ])
    }

    private func makeDivider(text: String) -> UIView {
        let stack = UIStackView()
        stack.axis      = .horizontal
        stack.alignment = .center
        stack.spacing   = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let line1 = hairline()
        let line2 = hairline()
        let label = UILabel()
        label.text      = text
        label.font      = .systemFont(ofSize: 12)
        label.textColor = .tertiaryLabel
        label.setContentHuggingPriority(.required, for: .horizontal)

        stack.addArrangedSubview(line1)
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(line2)
        return stack
    }

    private func hairline() -> UIView {
        let v = UIView()
        v.backgroundColor = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return v
    }

    private func makeSteps(_ items: [(String, String)]) -> UIStackView {
        let stack = UIStackView()
        stack.axis    = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (i, (_, text)) in items.enumerated() {
            let row = UIStackView()
            row.axis      = .horizontal
            row.alignment = .top
            row.spacing   = 12

            let badge = UILabel()
            badge.text            = "\(i + 1)"
            badge.font            = .systemFont(ofSize: 13, weight: .semibold)
            badge.textColor       = HackColors.accent
            badge.textAlignment   = .center
            badge.backgroundColor = HackColors.accent.withAlphaComponent(0.1)
            badge.layer.cornerRadius = 11
            badge.clipsToBounds   = true
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.widthAnchor.constraint(equalToConstant: 22).isActive = true
            badge.heightAnchor.constraint(equalToConstant: 22).isActive = true

            let label = UILabel()
            label.text          = text
            label.font          = .systemFont(ofSize: 14)
            label.textColor     = .secondaryLabel
            label.numberOfLines = 0

            row.addArrangedSubview(badge)
            row.addArrangedSubview(label)
            stack.addArrangedSubview(row)
        }
        return stack
    }

    // MARK: Google Button State

    func refreshGoogleButtonState() {
        if AuthManager.shared.isGoogleLinked {
            googleButton.setTitle("  連携済み ✓", for: .normal)
            googleButton.isEnabled       = false
            googleButton.alpha           = 0.5
        } else {
            let isSignedIn = Auth.auth().currentUser != nil
            let title = isSignedIn ? "  Googleで連携する" : "  Googleでログイン"
            googleButton.setTitle(title, for: .normal)
            googleButton.isEnabled = true
            googleButton.alpha     = 1.0
        }
    }

    // MARK: Actions

    @objc private func googleButtonTapped() {
        googleButton.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            do {
                if Auth.auth().currentUser != nil {
                    try await AuthManager.shared.linkGoogle(presenting: self)
                } else {
                    _ = try await AuthManager.shared.signInWithGoogle(presenting: self)
                }
                await MainActor.run { self.showSuccess() }
            } catch AuthError.googleAlreadyLinked {
                await MainActor.run {
                    self.googleButton.isEnabled = true
                    self.showAlert("このGoogleアカウントは既に別のアカウントに連携されています。")
                }
            } catch {
                await MainActor.run {
                    self.googleButton.isEnabled = true
                    self.showAlert(error.localizedDescription)
                }
            }
        }
    }

    private func showSuccess() {
        UIView.transition(with: googleButton, duration: 0.25, options: .transitionCrossDissolve) {
            self.googleButton.setTitle("  連携済み ✓", for: .normal)
            self.googleButton.isEnabled = false
            self.googleButton.alpha     = 0.5
        }
    }

    private func showAlert(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
