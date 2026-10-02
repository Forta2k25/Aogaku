import UIKit

/// チャットで送った写真のライブラリ。授業回ごとにまとまって並ぶ。
/// 一覧画面からは全ての回、個別チャットからはその回だけを表示する。
final class NoteLibraryViewController: UIViewController {

    struct Section {
        let title: String
        let photos: [CapturedPhoto]
    }

    /// 設定すると選択モード: 複数選んで「追加」で返す。
    var onPick: (([CapturedPhoto]) -> Void)?
    private let pickButton = UIButton(type: .system)
    private let sections: [Section]
    private let headerTitle: String
    private let showsSectionHeaders: Bool

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 3
        layout.minimumLineSpacing = 3
        layout.sectionInset = UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .systemBackground
        cv.allowsMultipleSelection = true
        cv.dataSource = self
        cv.delegate = self
        cv.register(LibraryCell.self, forCellWithReuseIdentifier: LibraryCell.reuseID)
        cv.register(LibraryHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                    withReuseIdentifier: LibraryHeader.reuseID)
        cv.translatesAutoresizingMaskIntoConstraints = false
        return cv
    }()

    init(title: String, sections: [Section], showsSectionHeaders: Bool) {
        self.headerTitle = title
        self.sections = sections
        self.showsSectionHeaders = showsSectionHeaders
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let bar = UIView()
        bar.backgroundColor = .systemBackground
        bar.translatesAutoresizingMaskIntoConstraints = false

        var closeCfg = UIButton.Configuration.plain()
        closeCfg.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        closeCfg.baseForegroundColor = .label
        let closeButton = UIButton(configuration: closeCfg)
        closeButton.accessibilityLabel = "閉じる"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = headerTitle
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        if onPick != nil {
            var cfg = UIButton.Configuration.filled()
            cfg.title = "追加"
            cfg.cornerStyle = .capsule
            cfg.baseBackgroundColor = UIColor(red: 0xb4/255.0, green: 0xe8/255.0, blue: 0xff/255.0, alpha: 1)
            cfg.baseForegroundColor = .black
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 18, bottom: 8, trailing: 18)
            pickButton.configuration = cfg
            pickButton.isEnabled = false
            pickButton.addTarget(self, action: #selector(pickTapped), for: .touchUpInside)
            pickButton.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(pickButton)
            NSLayoutConstraint.activate([
                pickButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
                pickButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor)
            ])
        }
        view.addSubview(collectionView)
        view.addSubview(bar)
        bar.addSubview(closeButton)
        bar.addSubview(titleLabel)
        bar.addSubview(separator)

        let empty = UILabel()
        empty.text = "まだ写真がありません"
        empty.font = .systemFont(ofSize: 15)
        empty.textColor = .secondaryLabel
        empty.isHidden = !sections.allSatisfy { $0.photos.isEmpty }
        empty.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(empty)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: safe.topAnchor, constant: 52),
            closeButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            closeButton.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -4),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            collectionView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            empty.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private var selectedPhotos: [CapturedPhoto] {
        (collectionView.indexPathsForSelectedItems ?? [])
            .sorted { ($0.section, $0.item) < ($1.section, $1.item) }
            .map { sections[$0.section].photos[$0.item] }
    }

    private func refreshPickButton() {
        let count = selectedPhotos.count
        var cfg = pickButton.configuration
        cfg?.title = count == 0 ? "追加" : "追加 (\(count))"
        pickButton.configuration = cfg
        pickButton.isEnabled = count > 0
    }

    @objc private func pickTapped() {
        let photos = selectedPhotos
        dismiss(animated: true) { [onPick] in onPick?(photos) }
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }
}

extension NoteLibraryViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].photos.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: LibraryCell.reuseID, for: indexPath) as! LibraryCell
        cell.imageView.image = sections[indexPath.section].photos[indexPath.item].thumb
        cell.showsSelection = onPick != nil
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        if onPick != nil { refreshPickButton() }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if onPick != nil {
            refreshPickButton()   // 選択モードでは、タップで選択のオン/オフ
            return
        }
        collectionView.deselectItem(at: indexPath, animated: false)
        let set = CapturedPhotoSet(items: sections[indexPath.section].photos)
        let pager = SilentCameraPagerViewController(photoSet: set, startIndex: indexPath.item, allowsDelete: false)
        pager.modalPresentationStyle = .fullScreen
        present(pager, animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let columns: CGFloat = 3
        let side = floor((collectionView.bounds.width - 3 * (columns - 1)) / columns)
        return CGSize(width: side, height: side)
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        referenceSizeForHeaderInSection section: Int) -> CGSize {
        showsSectionHeaders ? CGSize(width: collectionView.bounds.width, height: 44) : .zero
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind, withReuseIdentifier: LibraryHeader.reuseID, for: indexPath) as! LibraryHeader
        header.titleLabel.text = sections[indexPath.section].title
        header.countLabel.text = "\(sections[indexPath.section].photos.count)枚"
        return header
    }
}

private final class LibraryCell: UICollectionViewCell {
    static let reuseID = "LibraryCell"
    let imageView = UIImageView()
    private let dimView = UIView()
    private let checkView = UIImageView()
    var showsSelection = false { didSet { updateSelection() } }

    override var isSelected: Bool { didSet { updateSelection() } }

    private func updateSelection() {
        let on = showsSelection && isSelected
        dimView.isHidden = !on
        checkView.isHidden = !on
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        dimView.backgroundColor = UIColor.white.withAlphaComponent(0.35)
        dimView.isHidden = true
        dimView.translatesAutoresizingMaskIntoConstraints = false
        checkView.image = UIImage(systemName: "checkmark.circle.fill")
        checkView.tintColor = UIColor(red: 0/255, green: 120/255, blue: 87/255, alpha: 1)
        checkView.backgroundColor = .white
        checkView.layer.cornerRadius = 12
        checkView.isHidden = true
        checkView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemBackground
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
        contentView.addSubview(dimView)
        contentView.addSubview(checkView)
        NSLayoutConstraint.activate([
            dimView.topAnchor.constraint(equalTo: contentView.topAnchor),
            dimView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dimView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            checkView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            checkView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            checkView.widthAnchor.constraint(equalToConstant: 24),
            checkView.heightAnchor.constraint(equalToConstant: 24)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class LibraryHeader: UICollectionReusableView {
    static let reuseID = "LibraryHeader"
    let titleLabel = UILabel()
    let countLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        countLabel.font = .systemFont(ofSize: 13)
        countLabel.textColor = .secondaryLabel
        let row = UIStackView(arrangedSubviews: [titleLabel, UIView(), countLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
