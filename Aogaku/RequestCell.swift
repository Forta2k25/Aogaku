import UIKit

final class RequestCell: UITableViewCell {
    static let reuseID = "RequestCell"

    // 外から設定するアクション
    var onApprove: (() -> Void)?
    var onDelete: (() -> Void)?

    // UI
    private let avatarView = UIImageView()
    private let nameLabel = UILabel()
    private let idLabel = UILabel()
    private let approveButton = UIButton(type: .system)
    private let deleteButton  = UIButton(type: .system)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setupUI() }

    private func setupUI() {
        selectionStyle = .none

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = 24
        avatarView.backgroundColor = .secondarySystemFill

        nameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        idLabel.font = .systemFont(ofSize: 13)
        idLabel.textColor = .secondaryLabel

        let textStack = UIStackView(arrangedSubviews: [nameLabel, idLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        approveButton.setTitle("承認", for: .normal)
        approveButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        approveButton.backgroundColor = .systemBlue
        approveButton.tintColor = .white
        approveButton.layer.cornerRadius = 10
        approveButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        approveButton.translatesAutoresizingMaskIntoConstraints = false
        approveButton.addTarget(self, action: #selector(tapApprove), for: .touchUpInside)

        deleteButton.setTitle("削除", for: .normal)
        deleteButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        deleteButton.layer.cornerRadius = 10
        deleteButton.layer.borderWidth = 1
        deleteButton.layer.borderColor = UIColor.tertiaryLabel.cgColor
        deleteButton.tintColor = .label
        deleteButton.backgroundColor = .clear
        deleteButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.addTarget(self, action: #selector(tapDelete), for: .touchUpInside)

        contentView.addSubview(avatarView)
        contentView.addSubview(textStack)
        contentView.addSubview(approveButton)
        contentView.addSubview(deleteButton)

        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 48),
            avatarView.heightAnchor.constraint(equalToConstant: 48),

            textStack.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: approveButton.leadingAnchor, constant: -12),

            deleteButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            deleteButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            approveButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -12),
            approveButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarView.image = nil
        nameLabel.text = nil
        idLabel.text = nil
        onApprove = nil
        onDelete = nil
    }

    func configure(name: String, id: String, photoURL: String?, placeholder: UIImage?) {
        nameLabel.text = name
        idLabel.text = "@\(id)"
        if let url = photoURL, !url.isEmpty {
            ImageLoader.shared.load(urlString: url, into: avatarView, placeholder: placeholder)
        } else {
            avatarView.image = placeholder
        }
    }

    @objc private func tapApprove() { onApprove?() }
    @objc private func tapDelete()  { onDelete?() }
}
