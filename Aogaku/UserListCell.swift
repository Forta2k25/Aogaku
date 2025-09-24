
import UIKit

final class UserListCell: UITableViewCell {
    static let reuseID = "UserListCell"

    // UI
    private let avatarView = UIImageView()
    private let nameLabel = UILabel()
    private let idLabel = UILabel()
    let actionButton = UIButton(type: .system)

    // データ
    private var user: UserPublic?

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
        nameLabel.text = nil
        idLabel.text = nil
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
        self.user = user

        nameLabel.text = user.name

        var sub = "@\(user.idString)"
        if let t = extraText, !t.isEmpty {
            sub += "    \(t)" // スペースで離して右に表示
        }
        idLabel.text = sub

        // 画像（無ければプレースホルダー）
        if let urlStr = user.photoURL, !urlStr.isEmpty {
            ImageLoader.shared.load(urlString: urlStr, into: avatarView, placeholder: placeholder)
        } else {
            avatarView.image = placeholder
        }

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
}


/*import UIKit

final class UserListCell: UITableViewCell {
    static let reuseID = "UserListCell"

    // UI
    private let avatarView = UIImageView()
    private let nameLabel = UILabel()
    private let idLabel = UILabel()
    let actionButton = UIButton(type: .system)

    // データ
    private var user: UserPublic?

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
        nameLabel.text = nil
        idLabel.text = nil
        avatarView.image = nil
        actionButton.setTitle(nil, for: .normal)
        actionButton.isEnabled = true
    }

    func configure(user: UserPublic, isFriend: Bool, isOutgoing: Bool, placeholder: UIImage?) {
        self.user = user

        nameLabel.text = user.name
        idLabel.text = "@\(user.idString)"

        // 画像読み込み（無ければプレースホルダー）
        if let urlStr = user.photoURL, !urlStr.isEmpty {
            ImageLoader.shared.load(urlString: urlStr, into: avatarView, placeholder: placeholder)
        } else {
            avatarView.image = placeholder
        }

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
}
*/
