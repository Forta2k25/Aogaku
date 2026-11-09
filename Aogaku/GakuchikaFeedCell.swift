//
//  GakuchikaFeedCell.swift
//  Aogaku
//
//  ガクチカタブの写真フィード用カード（写真を大きく見せる）
//

import UIKit

final class GakuchikaFeedCell: UITableViewCell {
    static let reuseId = "GakuchikaFeedCell"

    /// しおりが押された（引数: 掲載ID）
    var onBookmarkToggled: ((String) -> Void)?
    /// PR 掲載の「公式サイトで申し込む」が押された
    var onApply: (() -> Void)?

    private let cardView = UIView()
    private let photoView = UIImageView()
    private let photoPlaceholder = UIImageView(image: UIImage(systemName: "photo"))
    private let prBadge = PaddingLabel(padding: UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6))
    private let bookmarkButton = UIButton(type: .system)
    private let pillStack = UIStackView()

    private let logoView = UIImageView()
    private let logoInitial = UILabel()
    private let companyLabel = UILabel()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    private let applyButton = UIButton(type: .system)

    private var listingID: String?
    private var photoTask: URLSessionDataTask?
    private var logoTask: URLSessionDataTask?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        photoTask?.cancel(); photoTask = nil
        logoTask?.cancel(); logoTask = nil
        photoView.image = nil
        logoView.image = nil
        onBookmarkToggled = nil
        onApply = nil
    }

    // MARK: - Layout
    private func setupUI() {
        cardView.backgroundColor = .secondarySystemGroupedBackground
        cardView.layer.cornerRadius = 18
        cardView.layer.cornerCurve = .continuous
        cardView.clipsToBounds = true
        cardView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardView)

        // 写真
        photoView.contentMode = .scaleAspectFill
        photoView.clipsToBounds = true
        photoView.backgroundColor = .tertiarySystemFill
        photoView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(photoView)

        photoPlaceholder.tintColor = .tertiaryLabel
        photoPlaceholder.contentMode = .scaleAspectFit
        photoPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        photoView.addSubview(photoPlaceholder)

        prBadge.text = "PR"
        prBadge.font = .systemFont(ofSize: 10, weight: .heavy)
        prBadge.textColor = UIColor(red: 122/255, green: 78/255, blue: 0, alpha: 1)
        prBadge.backgroundColor = UIColor(red: 1, green: 241/255, blue: 209/255, alpha: 1)
        prBadge.layer.cornerRadius = 4
        prBadge.layer.masksToBounds = true
        prBadge.accessibilityLabel = "広告"
        prBadge.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(prBadge)

        bookmarkButton.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        bookmarkButton.layer.cornerRadius = 20
        bookmarkButton.translatesAutoresizingMaskIntoConstraints = false
        bookmarkButton.addAction(UIAction { [weak self] _ in self?.toggleBookmark() }, for: .touchUpInside)
        cardView.addSubview(bookmarkButton)

        pillStack.axis = .horizontal
        pillStack.spacing = 6
        pillStack.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(pillStack)

        // 本文
        logoView.contentMode = .scaleAspectFill
        logoView.clipsToBounds = true
        logoView.layer.cornerRadius = 6
        logoView.translatesAutoresizingMaskIntoConstraints = false
        logoInitial.font = .systemFont(ofSize: 11, weight: .heavy)
        logoInitial.textColor = .white
        logoInitial.textAlignment = .center
        logoInitial.translatesAutoresizingMaskIntoConstraints = false
        logoView.addSubview(logoInitial)

        companyLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        companyLabel.textColor = .secondaryLabel

        let companyRow = UIStackView(arrangedSubviews: [logoView, companyLabel])
        companyRow.axis = .horizontal
        companyRow.alignment = .center
        companyRow.spacing = 8

        titleLabel.font = .systemFont(ofSize: 18, weight: .heavy)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 0

        metaLabel.font = .systemFont(ofSize: 12, weight: .regular)
        metaLabel.textColor = .secondaryLabel
        metaLabel.numberOfLines = 2

        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = .label
        config.baseForegroundColor = .systemBackground
        config.cornerStyle = .large
        config.image = UIImage(systemName: "arrow.up.right",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        config.imagePlacement = .trailing
        config.imagePadding = 6
        var title = AttributedString("公式サイトで申し込む")
        title.font = .systemFont(ofSize: 14, weight: .bold)
        config.attributedTitle = title
        applyButton.configuration = config
        applyButton.addAction(UIAction { [weak self] _ in self?.onApply?() }, for: .touchUpInside)

        let body = UIStackView(arrangedSubviews: [companyRow, titleLabel, metaLabel, applyButton])
        body.axis = .vertical
        body.spacing = 6
        body.setCustomSpacing(12, after: metaLabel)
        body.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(body)

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 7),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -7),

            photoView.topAnchor.constraint(equalTo: cardView.topAnchor),
            photoView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            photoView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            photoView.heightAnchor.constraint(equalTo: photoView.widthAnchor, multiplier: 9.0 / 16.0),

            photoPlaceholder.centerXAnchor.constraint(equalTo: photoView.centerXAnchor),
            photoPlaceholder.centerYAnchor.constraint(equalTo: photoView.centerYAnchor),
            photoPlaceholder.widthAnchor.constraint(equalToConstant: 36),
            photoPlaceholder.heightAnchor.constraint(equalToConstant: 36),

            prBadge.topAnchor.constraint(equalTo: photoView.topAnchor, constant: 12),
            prBadge.leadingAnchor.constraint(equalTo: photoView.leadingAnchor, constant: 12),

            bookmarkButton.topAnchor.constraint(equalTo: photoView.topAnchor, constant: 8),
            bookmarkButton.trailingAnchor.constraint(equalTo: photoView.trailingAnchor, constant: -8),
            bookmarkButton.widthAnchor.constraint(equalToConstant: 40),
            bookmarkButton.heightAnchor.constraint(equalToConstant: 40),

            pillStack.leadingAnchor.constraint(equalTo: photoView.leadingAnchor, constant: 12),
            pillStack.bottomAnchor.constraint(equalTo: photoView.bottomAnchor, constant: -12),
            pillStack.trailingAnchor.constraint(lessThanOrEqualTo: photoView.trailingAnchor, constant: -12),

            logoView.widthAnchor.constraint(equalToConstant: 24),
            logoView.heightAnchor.constraint(equalToConstant: 24),
            logoInitial.centerXAnchor.constraint(equalTo: logoView.centerXAnchor),
            logoInitial.centerYAnchor.constraint(equalTo: logoView.centerYAnchor),

            applyButton.heightAnchor.constraint(equalToConstant: 44),

            body.topAnchor.constraint(equalTo: photoView.bottomAnchor, constant: 12),
            body.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            body.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -16),
        ])
    }

    // MARK: - Configure
    func configure(with item: CareerListing) {
        listingID = item.id
        updateBookmarkIcon()

        prBadge.isHidden = !item.isSponsored
        applyButton.isHidden = !item.isSponsored
        cardView.layer.borderWidth = item.isSponsored ? 1 : 0
        cardView.layer.borderColor = UIColor(red: 240/255, green: 217/255, blue: 168/255, alpha: 1).cgColor

        pillStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        addPill(item.category.displayName)
        if let place = shortLocation(item.location) { addPill(place) }
        if item.isDeadlineSoon, let n = item.daysUntilDeadline {
            addPill(n == 0 ? "本日締切" : "あと\(n)日", color: .systemRed)
        } else if item.isNew {
            addPill("NEW", color: .systemGreen)
        }

        companyLabel.text = item.companyName
        titleLabel.text = item.title
        metaLabel.text = metaText(for: item)
        metaLabel.isHidden = metaLabel.text?.isEmpty ?? true

        logoInitial.text = item.companyName.first.map(String.init)
        logoInitial.isHidden = false
        logoView.backgroundColor = item.category.tintColor

        loadPhoto(for: item)
        loadLogo(for: item)
    }

    private func addPill(_ text: String, color: UIColor = .label) {
        let pill = PaddingLabel(padding: UIEdgeInsets(top: 4, left: 9, bottom: 4, right: 9))
        pill.text = text
        pill.font = .systemFont(ofSize: 11, weight: .bold)
        pill.textColor = color
        pill.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.94)
        pill.layer.cornerRadius = 10
        pill.layer.masksToBounds = true
        pill.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pillStack.addArrangedSubview(pill)
    }

    private func metaText(for item: CareerListing) -> String {
        var parts: [String] = []
        if !item.compensation.isEmpty { parts.append(firstLine(item.compensation)) }
        if !item.schedule.isEmpty { parts.append(firstLine(item.schedule)) }
        if let d = item.applicationDeadline {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ja_JP")
            f.dateFormat = "M/d"
            parts.append("締切 \(f.string(from: d))")
        }
        return parts.joined(separator: " ・ ")
    }

    private func firstLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
    }

    private func shortLocation(_ raw: String) -> String? {
        var s = raw
        if let idx = s.firstIndex(where: { $0 == "（" || $0 == "／" || $0 == "(" }) {
            s = String(s[s.startIndex..<idx])
        }
        s = s.replacingOccurrences(of: "東京都", with: "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    // MARK: - Bookmark
    private func toggleBookmark() {
        guard let id = listingID else { return }
        onBookmarkToggled?(id)
        updateBookmarkIcon()
    }

    private func updateBookmarkIcon() {
        let saved = listingID.map { CareerBookmarkStore.shared.isBookmarked(id: $0) } ?? false
        bookmarkButton.setImage(UIImage(systemName: saved ? "bookmark.fill" : "bookmark"), for: .normal)
        bookmarkButton.tintColor = saved ? .systemOrange : .white
        bookmarkButton.accessibilityLabel = saved ? "保存を解除" : "保存"
    }

    // MARK: - Images
    private func loadPhoto(for item: CareerListing) {
        photoTask?.cancel()
        photoView.image = nil
        photoPlaceholder.isHidden = false

        if let local = CareerLocalDemoPhotos.image(forListingID: item.id) {
            setPhoto(local)
            return
        }
        guard let s = item.photoUrl, let url = URL(string: s) else { return }
        if let cached = DiskImageCache.shared.image(for: url) {
            setPhoto(cached)
            return
        }
        let id = item.id
        photoTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let img = UIImage(data: data) else { return }
            DiskImageCache.shared.set(img, for: url)
            DispatchQueue.main.async {
                guard self?.listingID == id else { return }
                self?.setPhoto(img)
            }
        }
        photoTask?.resume()
    }

    private func setPhoto(_ image: UIImage) {
        photoView.image = image
        photoPlaceholder.isHidden = true
    }

    private func loadLogo(for item: CareerListing) {
        logoTask?.cancel()
        guard let s = item.logoUrl, let url = URL(string: s) else { return }
        if let cached = DiskImageCache.shared.image(for: url) {
            setLogo(cached)
            return
        }
        let id = item.id
        logoTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let img = UIImage(data: data) else { return }
            DiskImageCache.shared.set(img, for: url)
            DispatchQueue.main.async {
                guard self?.listingID == id else { return }
                self?.setLogo(img)
            }
        }
        logoTask?.resume()
    }

    private func setLogo(_ image: UIImage) {
        logoView.image = image
        logoView.backgroundColor = .clear
        logoInitial.isHidden = true
    }
}
