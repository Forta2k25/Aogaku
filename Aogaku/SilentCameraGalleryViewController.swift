import UIKit

/// 撮影済みの写真の一覧。送信前に、全画面での確認と1枚ごとの取り消しができる。
final class SilentCameraGalleryViewController: UIViewController {

    var onSend: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let photoSet: CapturedPhotoSet
    private let accent = UIColor(red: 0xb4/255.0, green: 0xe8/255.0, blue: 0xff/255.0, alpha: 1)
    private let titleLabel = UILabel()
    private let sendButton = UIButton(type: .system)
    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 3
        layout.minimumLineSpacing = 3
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .black
        cv.dataSource = self
        cv.delegate = self
        cv.register(GalleryCell.self, forCellWithReuseIdentifier: GalleryCell.reuseID)
        cv.translatesAutoresizingMaskIntoConstraints = false
        return cv
    }()

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var prefersStatusBarHidden: Bool { true }

    init(photoSet: CapturedPhotoSet) {
        self.photoSet = photoSet
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        var backCfg = UIButton.Configuration.plain()
        backCfg.image = UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        backCfg.baseForegroundColor = .white
        let backButton = UIButton(configuration: backCfg)
        backButton.accessibilityLabel = "カメラに戻る"
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        var sendCfg = UIButton.Configuration.filled()
        sendCfg.title = "追加"
        sendCfg.baseBackgroundColor = accent
        sendCfg.baseForegroundColor = .black
        sendCfg.cornerStyle = .capsule
        sendCfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 18, bottom: 8, trailing: 18)
        sendButton.configuration = sendCfg
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(collectionView)
        view.addSubview(backButton)
        view.addSubview(titleLabel)
        view.addSubview(sendButton)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 8),
            backButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 4),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            sendButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            sendButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),

            collectionView.topAnchor.constraint(equalTo: backButton.bottomAnchor, constant: 4),
            collectionView.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        refreshHeader()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        collectionView.collectionViewLayout.invalidateLayout()
    }

    private func refreshHeader() {
        let count = photoSet.items.count
        titleLabel.text = "撮影した写真 (\(count))"
        var cfg = sendButton.configuration
        cfg?.title = "追加 (\(count))"
        sendButton.configuration = cfg
    }

    @objc private func backTapped() {
        dismiss(animated: true) { [onDismiss] in onDismiss?() }
    }

    @objc private func sendTapped() {
        onSend?()
    }

    fileprivate func delete(at index: Int) {
        guard photoSet.items.indices.contains(index) else { return }
        photoSet.items.remove(at: index)
        refreshHeader()
        if photoSet.items.isEmpty {
            backTapped()
            return
        }
        collectionView.performBatchUpdates {
            collectionView.deleteItems(at: [IndexPath(item: index, section: 0)])
        }
    }

    fileprivate func openPager(at index: Int) {
        let pager = SilentCameraPagerViewController(photoSet: photoSet, startIndex: index, allowsDelete: true)
        pager.modalPresentationStyle = .fullScreen
        pager.onDismiss = { [weak self] in
            guard let self else { return }
            self.refreshHeader()
            if self.photoSet.items.isEmpty {
                self.backTapped()
            } else {
                self.collectionView.reloadData()
            }
        }
        present(pager, animated: true)
    }
}

extension SilentCameraGalleryViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        photoSet.items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: GalleryCell.reuseID, for: indexPath) as! GalleryCell
        cell.imageView.image = photoSet.items[indexPath.item].thumb
        cell.onDelete = { [weak self, weak cell] in
            guard let self, let cell, let current = collectionView.indexPath(for: cell) else { return }
            self.delete(at: current.item)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        openPager(at: indexPath.item)
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let columns: CGFloat = collectionView.bounds.width > 600 ? 5 : 3
        let side = floor((collectionView.bounds.width - 3 * (columns - 1)) / columns)
        return CGSize(width: side, height: side)
    }
}

private final class GalleryCell: UICollectionViewCell {
    static let reuseID = "GalleryCell"
    let imageView = UIImageView()
    private let deleteButton = UIButton(type: .system)
    var onDelete: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)

        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        cfg.baseForegroundColor = .white
        deleteButton.configuration = cfg
        deleteButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        deleteButton.layer.cornerRadius = 13
        deleteButton.accessibilityLabel = "この写真を取り消す"
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        contentView.addSubview(deleteButton)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            deleteButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            deleteButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            deleteButton.widthAnchor.constraint(equalToConstant: 26),
            deleteButton.heightAnchor.constraint(equalToConstant: 26)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func deleteTapped() { onDelete?() }
}

// MARK: - 全画面ページャ

/// 1枚ずつ全画面で確認する。ピンチ/ダブルタップで拡大、ゴミ箱で取り消し。
final class SilentCameraPagerViewController: UIViewController {

    var onDismiss: (() -> Void)?

    private let photoSet: CapturedPhotoSet
    private let allowsDelete: Bool
    private var currentIndex: Int
    private let counterLabel = UILabel()
    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .black
        cv.isPagingEnabled = true
        cv.showsHorizontalScrollIndicator = false
        cv.dataSource = self
        cv.delegate = self
        cv.register(PagerCell.self, forCellWithReuseIdentifier: PagerCell.reuseID)
        cv.translatesAutoresizingMaskIntoConstraints = false
        return cv
    }()
    private var didScrollToStart = false

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var prefersStatusBarHidden: Bool { true }

    init(photoSet: CapturedPhotoSet, startIndex: Int, allowsDelete: Bool) {
        self.photoSet = photoSet
        self.allowsDelete = allowsDelete
        self.currentIndex = startIndex
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.addSubview(collectionView)

        func iconButton(_ symbol: String, label: String, action: Selector) -> UIButton {
            var cfg = UIButton.Configuration.plain()
            cfg.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
            cfg.baseForegroundColor = .white
            let b = UIButton(configuration: cfg)
            b.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            b.layer.cornerRadius = 22
            b.accessibilityLabel = label
            b.addTarget(self, action: action, for: .touchUpInside)
            b.translatesAutoresizingMaskIntoConstraints = false
            return b
        }
        let backButton = iconButton("chevron.left", label: "一覧に戻る", action: #selector(backTapped))
        let trashButton = iconButton("trash", label: "この写真を取り消す", action: #selector(trashTapped))
        view.addSubview(backButton)
        view.addSubview(trashButton)
        trashButton.isHidden = !allowsDelete

        counterLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        counterLabel.textColor = .white
        counterLabel.textAlignment = .center
        counterLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        counterLabel.layer.cornerRadius = 14
        counterLabel.clipsToBounds = true
        counterLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(counterLabel)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            backButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            backButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            trashButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            trashButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            trashButton.widthAnchor.constraint(equalToConstant: 44),
            trashButton.heightAnchor.constraint(equalToConstant: 44),
            counterLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            counterLabel.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            counterLabel.heightAnchor.constraint(equalToConstant: 28),
            counterLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 64)
        ])
        updateCounter()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !didScrollToStart, collectionView.bounds.width > 0 {
            didScrollToStart = true
            collectionView.layoutIfNeeded()
            collectionView.scrollToItem(at: IndexPath(item: currentIndex, section: 0), at: .centeredHorizontally, animated: false)
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        let index = currentIndex
        coordinator.animate(alongsideTransition: { _ in
            self.collectionView.collectionViewLayout.invalidateLayout()
        }, completion: { _ in
            self.collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredHorizontally, animated: false)
        })
    }

    private func updateCounter() {
        counterLabel.text = " \(currentIndex + 1) / \(photoSet.items.count) "
    }

    @objc private func backTapped() {
        dismiss(animated: true) { [onDismiss] in onDismiss?() }
    }

    @objc private func trashTapped() {
        guard photoSet.items.indices.contains(currentIndex) else { return }
        let removed = currentIndex
        photoSet.items.remove(at: removed)
        if photoSet.items.isEmpty {
            backTapped()
            return
        }
        currentIndex = min(removed, photoSet.items.count - 1)
        collectionView.performBatchUpdates {
            collectionView.deleteItems(at: [IndexPath(item: removed, section: 0)])
        } completion: { _ in
            self.updateCounter()
        }
    }
}

extension SilentCameraPagerViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        photoSet.items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PagerCell.reuseID, for: indexPath) as! PagerCell
        cell.configure(jpeg: photoSet.items[indexPath.item].jpeg, placeholder: photoSet.items[indexPath.item].thumb)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        collectionView.bounds.size
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        let width = max(scrollView.bounds.width, 1)
        let index = Int((scrollView.contentOffset.x / width).rounded())
        if index != currentIndex, photoSet.items.indices.contains(index) {
            currentIndex = index
            updateCounter()
        }
    }
}

private final class PagerCell: UICollectionViewCell, UIScrollViewDelegate {
    static let reuseID = "PagerCell"
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var token = UUID()

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)
        imageView.contentMode = .scaleToFill
        scrollView.addSubview(imageView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if scrollView.zoomScale == 1 { layoutImageToFit() }
    }

    /// 画像そのものの大きさ(アスペクトフィット後)にimageViewを合わせ、余白は contentInset で中央寄せにする。
    /// こうすると、拡大しても写真の枠の外までスクロールできない。
    private func layoutImageToFit() {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0,
              scrollView.bounds.width > 0 else { return }
        let bounds = scrollView.bounds.size
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        imageView.transform = .identity
        imageView.frame = CGRect(origin: .zero, size: fitted)
        scrollView.contentSize = fitted
        centerImage()
        scrollView.contentOffset = CGPoint(x: -scrollView.contentInset.left, y: -scrollView.contentInset.top)
    }

    private func centerImage() {
        let bounds = scrollView.bounds.size
        let content = imageView.frame.size
        scrollView.contentInset = UIEdgeInsets(
            top: max(0, (bounds.height - content.height) / 2),
            left: max(0, (bounds.width - content.width) / 2),
            bottom: 0, right: 0)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    func configure(jpeg: Data, placeholder: UIImage) {
        scrollView.setZoomScale(1, animated: false)
        imageView.image = placeholder   // まず小さい画像を出して、すぐに高精細版へ差し替える
        layoutImageToFit()
        let current = UUID()
        token = current
        DispatchQueue.global(qos: .userInitiated).async {
            let full = PhotoCodec.downsample(jpeg, maxPixel: 3000)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.token == current, let full else { return }
                self.imageView.image = full
            }
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1 {
            scrollView.setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let size = CGSize(width: scrollView.bounds.width / 2.5, height: scrollView.bounds.height / 2.5)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
        }
    }
}
