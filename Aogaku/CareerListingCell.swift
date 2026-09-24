//
//  CareerListingCell.swift
//  Aogaku
//
//  キャリア一覧のカードセル
//

import UIKit

final class CareerListingCell: UITableViewCell {
    static let reuseId = "CareerListingCell"

    private let cardView = UIView()

    private let companyLabel = UILabel()
    private let locationBadge = PaddingLabel(padding: UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10))

    private let postedIcon = UIImageView()
    private let postedLabel = UILabel()
    private let categoryChip = PaddingLabel(padding: UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8))

    private let titleLabel = UILabel()
    private let thumbnailImageView = UIImageView()
    private let divider = UIView()

    private let detailStack = UIStackView()
    private var photoTask: URLSessionDataTask?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        detailStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        photoTask?.cancel()
        photoTask = nil
        thumbnailImageView.image = nil
        thumbnailImageView.isHidden = true
    }

    private func setupUI() {
        contentView.addSubview(cardView)
        cardView.backgroundColor = .secondarySystemGroupedBackground
        cardView.layer.cornerRadius = 15
        cardView.translatesAutoresizingMaskIntoConstraints = false

        companyLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        companyLabel.textColor = .secondaryLabel
        companyLabel.translatesAutoresizingMaskIntoConstraints = false

        locationBadge.font = .systemFont(ofSize: 11, weight: .semibold)
        locationBadge.textColor = .secondaryLabel
        locationBadge.backgroundColor = .tertiarySystemFill
        locationBadge.layer.cornerRadius = 10
        locationBadge.layer.masksToBounds = true
        locationBadge.translatesAutoresizingMaskIntoConstraints = false

        postedIcon.image = UIImage(systemName: "clock.arrow.circlepath")
        postedIcon.tintColor = .tertiaryLabel
        postedIcon.contentMode = .scaleAspectFit
        postedIcon.translatesAutoresizingMaskIntoConstraints = false

        postedLabel.font = .systemFont(ofSize: 12, weight: .medium)
        postedLabel.textColor = .tertiaryLabel
        postedLabel.translatesAutoresizingMaskIntoConstraints = false

        categoryChip.font = .systemFont(ofSize: 11, weight: .bold)

        let metaStack = UIStackView(arrangedSubviews: [postedIcon, postedLabel, categoryChip])
        metaStack.axis = .horizontal
        metaStack.spacing = 4
        metaStack.alignment = .center
        metaStack.translatesAutoresizingMaskIntoConstraints = false
        metaStack.setCustomSpacing(10, after: postedLabel)

        titleLabel.font = .systemFont(ofSize: 17, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 0
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        divider.backgroundColor = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        detailStack.axis = .vertical
        detailStack.spacing = 10
        detailStack.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = UIStackView(arrangedSubviews: [companyLabel, UIView(), locationBadge])
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let topStack = UIStackView(arrangedSubviews: [headerRow, metaStack, titleLabel])
        topStack.axis = .vertical
        topStack.spacing = 6
        topStack.translatesAutoresizingMaskIntoConstraints = false

        thumbnailImageView.contentMode = .scaleAspectFill
        thumbnailImageView.clipsToBounds = true
        thumbnailImageView.layer.cornerRadius = 10
        thumbnailImageView.backgroundColor = .tertiarySystemFill
        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailImageView.isHidden = true
        thumbnailImageView.setContentHuggingPriority(.required, for: .horizontal)

        let heroRow = UIStackView(arrangedSubviews: [thumbnailImageView, topStack])
        heroRow.axis = .horizontal
        heroRow.alignment = .center
        heroRow.spacing = 12
        heroRow.translatesAutoresizingMaskIntoConstraints = false

        cardView.addSubview(heroRow)
        cardView.addSubview(divider)
        cardView.addSubview(detailStack)

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),

            heroRow.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 14),
            heroRow.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            heroRow.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),

            thumbnailImageView.widthAnchor.constraint(equalToConstant: 100),
            thumbnailImageView.heightAnchor.constraint(equalToConstant: 100),

            divider.topAnchor.constraint(equalTo: heroRow.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            divider.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            divider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            detailStack.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 12),
            detailStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            detailStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            detailStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -14),

            postedIcon.widthAnchor.constraint(equalToConstant: 13),
            postedIcon.heightAnchor.constraint(equalToConstant: 13),
        ])
    }

    func configure(with item: CareerListing) {
        companyLabel.text = item.companyName
        locationBadge.text = shortLocation(item.location)

        postedLabel.text = relativeTimeText(item.publishedAt)
        categoryChip.text = item.category.displayName
        categoryChip.textColor = item.category.tintColor
        categoryChip.backgroundColor = item.category.backgroundTintColor

        titleLabel.text = item.title
        loadThumbnail(for: item)

        detailStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        addRow(label: "職種", value: item.description, maxLines: 3)
        addRow(label: "特徴", value: item.eligibility, maxLines: 2)
        addRow(label: "アクセス", value: item.location, maxLines: 1)
        addRow(label: "カテゴリ", value: item.category.displayName, maxLines: 1)
        addRow(label: "勤務条件", value: workConditionText(for: item), maxLines: 0)
    }

    // MARK: - Thumbnail
    private func loadThumbnail(for item: CareerListing) {
        photoTask?.cancel()
        photoTask = nil
        thumbnailImageView.image = nil

        if let localImage = CareerLocalDemoPhotos.image(forListingID: item.id) {
            thumbnailImageView.image = localImage
            thumbnailImageView.isHidden = false
            return
        }

        guard let urlString = item.photoUrl, let url = URL(string: urlString) else {
            thumbnailImageView.isHidden = true
            return
        }
        thumbnailImageView.isHidden = false

        if let cached = DiskImageCache.shared.image(for: url) {
            thumbnailImageView.image = cached
            return
        }

        photoTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let img = UIImage(data: data) else { return }
            DiskImageCache.shared.set(img, for: url)
            DispatchQueue.main.async {
                self?.thumbnailImageView.image = img
            }
        }
        photoTask?.resume()
    }

    // MARK: - Row builder
    private func addRow(label: String, value: String, maxLines: Int) {
        guard !value.isEmpty else { return }

        let dt = UILabel()
        dt.text = label
        dt.font = .systemFont(ofSize: 11, weight: .semibold)
        dt.textColor = .tertiaryLabel
        dt.setContentHuggingPriority(.required, for: .horizontal)
        dt.translatesAutoresizingMaskIntoConstraints = false
        dt.widthAnchor.constraint(equalToConstant: 58).isActive = true

        let dd = UILabel()
        dd.attributedText = lineSpacedText(value, font: .systemFont(ofSize: 13, weight: .regular), color: .secondaryLabel, spacing: 3)
        dd.numberOfLines = maxLines
        dd.translatesAutoresizingMaskIntoConstraints = false

        let row = UIStackView(arrangedSubviews: [dt, dd])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        detailStack.addArrangedSubview(row)
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

    // MARK: - Formatting helpers
    private func shortLocation(_ raw: String) -> String {
        var s = raw
        if let idx = s.firstIndex(where: { $0 == "（" || $0 == "／" || $0 == "(" }) {
            s = String(s[s.startIndex..<idx])
        }
        s = s.replacingOccurrences(of: "東京都", with: "")
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? raw : s
    }

    private func relativeTimeText(_ date: Date?) -> String {
        guard let date else { return "" }
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days <= 0 { return "本日" }
        if days < 7 { return "\(days)日前" }
        if days < 30 { return "\(days / 7)週間前" }
        return "\(days / 30)ヶ月前"
    }

    private func workConditionText(for item: CareerListing) -> String {
        var lines: [String] = []
        if !item.compensation.isEmpty { lines.append("【報酬】\(item.compensation)") }
        if !item.schedule.isEmpty { lines.append("【期間】\(item.schedule)") }
        if let capacity = item.capacity, !capacity.isEmpty { lines.append("【人数】\(capacity)") }
        if let deadlineDate = item.deadlineDateText { lines.append("【締切】\(deadlineDate)") }
        return lines.joined(separator: "\n")
    }
}
