//
//  CircleCollectionViewCell.swift
//  AogakuHack
//
//  Card cell for 2-column grid (image + intensity pill + title)
//

import UIKit

final class CircleCollectionViewCell: UICollectionViewCell {

    static let reuseId = "CircleCollectionViewCell"
    static let reuseIdentifier: String = reuseId   // ← 追加

    private let cardView = UIView()
    private let imageView = UIImageView()
    private let intensityLabel = PaddingLabel(padding: UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10))
    private let titleLabel = UILabel()

    private var imageTask: URLSessionDataTask?

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildUI()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
        imageView.image = nil
        intensityLabel.text = nil
        titleLabel.text = nil
    }

    func configure(with item: CircleItem) {
        titleLabel.text = item.name
        intensityLabel.text = item.intensity
        intensityLabel.backgroundColor = intensityColor(item.intensity)

        if let s = item.imageURL, let url = URL(string: s) {
            loadImage(url: url)
        } else {
            imageView.image = placeholderImage()
        }
    }

    // MARK: - UI
    private func buildUI() {
        contentView.backgroundColor = .clear

        cardView.backgroundColor = .systemBackground
        cardView.layer.cornerRadius = 16
        cardView.layer.masksToBounds = true
        cardView.layer.borderWidth = 1
        cardView.layer.borderColor = UIColor.black.withAlphaComponent(0.06).cgColor

        contentView.addSubview(cardView)
        cardView.translatesAutoresizingMaskIntoConstraints = false

        // shadow
        contentView.layer.shadowColor = UIColor.black.cgColor
        contentView.layer.shadowOpacity = 0.05
        contentView.layer.shadowRadius = 8
        contentView.layer.shadowOffset = CGSize(width: 0, height: 3)
        contentView.layer.masksToBounds = false

        // image
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemBackground

        // intensity pill
        intensityLabel.textColor = .white
        intensityLabel.font = .boldSystemFont(ofSize: 12)
        intensityLabel.layer.cornerRadius = 12
        intensityLabel.layer.masksToBounds = true

        // title
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 2

        cardView.addSubview(imageView)
        cardView.addSubview(intensityLabel)
        cardView.addSubview(titleLabel)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        intensityLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            imageView.topAnchor.constraint(equalTo: cardView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            imageView.heightAnchor.constraint(equalToConstant: 120),

            intensityLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 8),
            intensityLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 8),

            titleLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: cardView.bottomAnchor, constant: -10)
        ])
    }

    private func intensityColor(_ s: String) -> UIColor {
        switch s {
        case "ガチめ":
            return UIColor.systemGreen.withAlphaComponent(0.85)
        case "ゆるめ":
            return UIColor.systemMint.withAlphaComponent(0.85)
        default:
            return UIColor.systemTeal.withAlphaComponent(0.85)
        }
    }

    // MARK: - Image
    private func loadImage(url: URL) {
        imageTask?.cancel()

        if let cached = SimpleImageCache.shared.image(for: url) {
            imageView.image = cached
            return
        }

        imageView.image = placeholderImage()

        imageTask = URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let img = UIImage(data: data) else { return }
            SimpleImageCache.shared.set(img, for: url)
            DispatchQueue.main.async { [weak self] in
                self?.imageView.image = img
            }
        }
        imageTask?.resume()
    }

    private func placeholderImage() -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        return UIImage(systemName: "photo", withConfiguration: config)
    }
}

// MARK: - PaddingLabel
final class PaddingLabel: UILabel {
    private let padding: UIEdgeInsets

    init(padding: UIEdgeInsets) {
        self.padding = padding
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        self.padding = .zero
        super.init(coder: coder)
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: padding))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + padding.left + padding.right,
                      height: size.height + padding.top + padding.bottom)
    }
}

// MARK: - Tiny in-memory cache
final class SimpleImageCache {
    static let shared = SimpleImageCache()
    private let cache = NSCache<NSURL, UIImage>()
    private init() {}

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func set(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

