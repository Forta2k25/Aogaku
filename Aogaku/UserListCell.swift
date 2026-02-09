import UIKit
import ImageIO

final class UserListCell: UITableViewCell {
    static let reuseID = "UserListCell"

    // UI
    private let avatarView = UIImageView()
    private let nameLabel = UILabel()
    private let idLabel = UILabel()
    let actionButton = UIButton(type: .system)

    // 画像ロード管理
    private var representedURL: String?
    private var task: URLSessionDataTask?

    // 共有キャッシュ（URL文字列 -> UIImage）
    private static let imageCache = NSCache<NSString, UIImage>()

    // URLSession（URLCache を有効にして高速化）
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(
            memoryCapacity: 50 * 1024 * 1024,
            diskCapacity: 200 * 1024 * 1024,
            diskPath: "UserListCell.AvatarCache"
        )
        return URLSession(configuration: config)
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setupUI() }

    private func setupUI() {
        // Avatar
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.backgroundColor = .secondarySystemFill
        avatarView.layer.cornerRadius = 24 // 48px / 2
        avatarView.translatesAutoresizingMaskIntoConstraints = false

        // Labels
        nameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        idLabel.font = .systemFont(ofSize: 13)
        idLabel.textColor = .secondaryLabel

        let textStack = UIStackView(arrangedSubviews: [nameLabel, idLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        // Button
        actionButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        actionButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        actionButton.layer.cornerRadius = 8
        actionButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(avatarView)
        contentView.addSubview(textStack)
        contentView.addSubview(actionButton)

        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 48),
            avatarView.heightAnchor.constraint(equalToConstant: 48),

            textStack.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -12),

            actionButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            actionButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()

        // 表示状態リセット
        nameLabel.text = nil
        idLabel.text = nil

        // 画像ロードをキャンセルして混線防止
        task?.cancel()
        task = nil
        representedURL = nil

        avatarView.image = nil

        actionButton.setTitle(nil, for: .normal)
        actionButton.isEnabled = true
        actionButton.layer.borderWidth = 0
        actionButton.layer.borderColor = nil
        actionButton.backgroundColor = .systemBlue
        actionButton.tintColor = .white
    }

    /// `extraText` には「経マ・2年」などを渡す（nil/空なら @id のみ表示）
    func configure(
        user: UserPublic,
        isFriend: Bool,
        isOutgoing: Bool,
        placeholder: UIImage?,
        extraText: String? = nil
    ) {
        nameLabel.text = user.name

        var sub = "@\(user.idString)"
        if let t = extraText, !t.isEmpty {
            sub += "    \(t)"
        }
        idLabel.text = sub

        // 画像
        loadAvatar(urlString: user.photoURL, placeholder: placeholder)

        // ボタン表示
        if isFriend {
            actionButton.setTitle("友だち", for: .normal)
            actionButton.isEnabled = false
            actionButton.tintColor = .secondaryLabel
            actionButton.backgroundColor = .clear
            actionButton.layer.borderWidth = 1
            actionButton.layer.borderColor = UIColor.tertiaryLabel.cgColor
        } else if isOutgoing {
            actionButton.setTitle("申請済", for: .normal)
            actionButton.isEnabled = false
            actionButton.tintColor = .secondaryLabel
            actionButton.backgroundColor = .clear
            actionButton.layer.borderWidth = 1
            actionButton.layer.borderColor = UIColor.tertiaryLabel.cgColor
        } else {
            actionButton.setTitle("追加", for: .normal)
            actionButton.isEnabled = true
            actionButton.tintColor = .white
            actionButton.backgroundColor = .systemBlue
            actionButton.layer.borderWidth = 0
            actionButton.layer.borderColor = nil
        }
    }

    private func loadAvatar(urlString: String?, placeholder: UIImage?) {
        // まずプレースホルダを即表示（残像防止）
        avatarView.image = placeholder

        // 空なら終了
        guard let urlString, !urlString.isEmpty, let url = URL(string: urlString) else {
            representedURL = nil
            return
        }

        // いまこのセルが表示すべきURLを記録
        representedURL = urlString

        // 既存タスクをキャンセル
        task?.cancel()
        task = nil

        // メモリキャッシュにあれば即表示
        if let cached = Self.imageCache.object(forKey: urlString as NSString) {
            avatarView.image = cached
            return
        }

        // 取得開始
        let req = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)

        task = Self.session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            if let _ = error { return }
            guard let data, !data.isEmpty else { return }

            // 48px表示なので、重いJPEG/PNGをそのままUIImage化せずダウンサンプリング
            let targetSize = CGSize(width: 48 * UIScreen.main.scale, height: 48 * UIScreen.main.scale)
            let image = Self.downsampleImage(data: data, to: targetSize) ?? UIImage(data: data)

            guard let image else { return }

            // キャッシュ
            Self.imageCache.setObject(image, forKey: urlString as NSString)

            DispatchQueue.main.async {
                // ここが超重要：セルがまだ同じURLを表示中か確認
                guard self.representedURL == urlString else { return }
                self.avatarView.image = image
            }
        }
        task?.resume()
    }

    private static func downsampleImage(data: Data, to pointSize: CGSize) -> UIImage? {
        let cfData = data as CFData
        guard let source = CGImageSourceCreateWithData(cfData, nil) else { return nil }

        let maxDimension = max(pointSize.width, pointSize.height)

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension)
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
