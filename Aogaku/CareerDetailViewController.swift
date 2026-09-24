//
//  CareerDetailViewController.swift
//  Aogaku
//
//  キャリア（インターン・採用イベント・新卒求人）詳細画面
//

import UIKit
import SafariServices

final class CareerDetailViewController: UIViewController {

    private let listing: CareerListing

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let applyButton = UIButton(type: .system)
    private var photoTask: URLSessionDataTask?

    init(listing: CareerListing) {
        self.listing = listing
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never

        setupScrollView()
        setupHero()
        setupPhoto()
        setupSections()
        setupApplyButton()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ScreenTracker.shared.appear("インターン詳細")
        AppAnalytics.logCareerDetailView(jobID: listing.id)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        ScreenTracker.shared.disappear("インターン詳細")
    }

    // MARK: - Layout scaffolding
    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -96),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    // MARK: - Hero
    private func setupHero() {
        let hero = UIView()
        hero.backgroundColor = .systemBackground

        let badge = PaddingLabel(padding: UIEdgeInsets(top: 4, left: 9, bottom: 4, right: 9))
        badge.text = listing.category.displayName
        badge.font = .systemFont(ofSize: 11, weight: .bold)
        badge.textColor = listing.category.tintColor
        badge.backgroundColor = listing.category.backgroundTintColor
        badge.layer.cornerRadius = 9
        badge.layer.masksToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false

        let companyLabel = UILabel()
        companyLabel.text = listing.companyName
        companyLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        companyLabel.textColor = .secondaryLabel
        companyLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = listing.title
        titleLabel.font = .systemFont(ofSize: 24, weight: .heavy)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 0
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [badge, companyLabel, titleLabel])
        stack.axis = .vertical
        stack.spacing = 6
        stack.setCustomSpacing(10, after: badge)
        stack.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: hero.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: hero.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: hero.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: hero.bottomAnchor, constant: -16),
        ])

        contentStack.addArrangedSubview(hero)
    }

    // MARK: - Photo
    private func setupPhoto() {
        // 営業デモ用のローカル写真がある場合はそちらを優先表示（本番配信ビルドには含めないこと）
        let localDemoImage = CareerLocalDemoPhotos.image(forListingID: listing.id)

        guard localDemoImage != nil || listing.photoUrl != nil else { return }

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 16
        imageView.backgroundColor = .tertiarySystemFill
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            imageView.heightAnchor.constraint(equalToConstant: 190),
        ])

        contentStack.addArrangedSubview(container)

        if let localDemoImage {
            imageView.image = localDemoImage
            return
        }

        guard let urlString = listing.photoUrl, let url = URL(string: urlString) else { return }

        if let cached = DiskImageCache.shared.image(for: url) {
            imageView.image = cached
            return
        }

        photoTask = URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let img = UIImage(data: data) else { return }
            DiskImageCache.shared.set(img, for: url)
            DispatchQueue.main.async {
                imageView.image = img
            }
        }
        photoTask?.resume()
    }

    // MARK: - Sections
    private func setupSections() {
        addSection(title: "業務内容", body: listing.description)
        addSection(title: "応募条件・対象学年", body: listing.eligibility)
        addSection(title: "勤務地・開催場所", body: listing.location)
        addSection(title: "待遇", body: listing.compensation)
        addSection(title: "実施期間", body: listing.schedule)

        if let capacity = listing.capacity, !capacity.isEmpty {
            addSection(title: "募集人数", body: capacity)
        }

        if let deadlineText = listing.deadlineText {
            addSection(title: "応募締切", body: deadlineText)
        }

        if listing.isTrial {
            let note = UILabel()
            note.text = "この掲載は無償トライアル掲載です"
            note.font = .systemFont(ofSize: 11, weight: .medium)
            note.textColor = .tertiaryLabel
            note.textAlignment = .center
            note.translatesAutoresizingMaskIntoConstraints = false
            contentStack.addArrangedSubview(note)
        }
    }

    private func addSection(title: String, body: String) {
        guard !body.isEmpty else { return }

        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 14
        card.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let bodyLabel = UILabel()
        bodyLabel.attributedText = lineSpacedText(body, font: .systemFont(ofSize: 14, weight: .regular), color: .secondaryLabel, spacing: 4)
        bodyLabel.numberOfLines = 0
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])

        let wrapper = UIView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: wrapper.topAnchor),
            card.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -16),
        ])

        contentStack.addArrangedSubview(wrapper)
    }

    private func lineSpacedText(_ text: String, font: UIFont, color: UIColor, spacing: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = spacing
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }

    // MARK: - Apply button
    private func setupApplyButton() {
        let wrap = UIView()
        wrap.backgroundColor = .systemGroupedBackground.withAlphaComponent(0.96)
        wrap.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wrap)

        applyButton.setTitle("この求人に応募する", for: .normal)
        applyButton.setTitleColor(.white, for: .normal)
        applyButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .bold)
        applyButton.backgroundColor = listing.category.tintColor
        applyButton.layer.cornerRadius = 14
        applyButton.translatesAutoresizingMaskIntoConstraints = false
        applyButton.addAction(UIAction { [weak self] _ in
            self?.didTapApply()
        }, for: .touchUpInside)
        wrap.addSubview(applyButton)

        NSLayoutConstraint.activate([
            wrap.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            wrap.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            wrap.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            applyButton.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 12),
            applyButton.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16),
            applyButton.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -16),
            applyButton.heightAnchor.constraint(equalToConstant: 50),
            applyButton.bottomAnchor.constraint(equalTo: wrap.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
    }

    private func didTapApply() {
        AppAnalytics.logCareerApplyClick(jobID: listing.id)

        guard let url = URL(string: listing.applicationUrl) else { return }
        let safari = SFSafariViewController(url: url)
        present(safari, animated: true)
    }
}
