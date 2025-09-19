import UIKit

/// 正方形トリミング専用の簡易クロッパー
/// - 最小ズームは「トリミング枠をちょうど満たす」までズームアウト可能
/// - ピンチでズーム、ドラッグで移動
/// - ダブルタップで「最小 <-> 1.5倍」をトグル
final class ImageCropViewController: UIViewController, UIScrollViewDelegate {

    // MARK: Public API
    var onCancel: (() -> Void)?
    var onDone: ((UIImage) -> Void)?

    // MARK: UI
    private let topBar = UIView()
    private let titleLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let overlayView = CropOverlayView()

    // 入力画像（向き正規化済みを保持）
    private let originalImage: UIImage
    private let titleText: String?

    // ズーム制御
    private var minZoom: CGFloat = 1.0
    private let maximumZoomMultiplier: CGFloat = 1 // ← ズーム上限を上げたい場合はここを調整
    private var didLayoutOnce = false

    // MARK: - Init
    init(image: UIImage, titleText: String? = nil) {
        self.originalImage = image.fixedOrientation()
        self.titleText = titleText
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Life cycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        setupTopBar()
        setupScrollView()
        setupOverlay()

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !didLayoutOnce else { return }
        didLayoutOnce = true

        layoutForCurrentBounds()
        configureZoomScalesAndCenter()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // レイアウト完了後にもう一度安全に中央へ（初期黒画面対策）
        centerUsingZoomRect(animated: false)
        clampContentOffset()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in
            self.didLayoutOnce = false
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        })
    }

    // MARK: - Setup
    private func setupTopBar() {
        topBar.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        titleLabel.text = titleText ?? "切り取り"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.setTitle("キャンセル", for: .normal)
        cancelButton.setTitleColor(.systemGray4, for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .regular)
        cancelButton.addTarget(self, action: #selector(didTapCancel), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        doneButton.setTitle("完了", for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        doneButton.setTitleColor(.white, for: .normal)
        doneButton.addTarget(self, action: #selector(didTapDone), for: .touchUpInside)
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        topBar.addSubview(titleLabel)
        topBar.addSubview(cancelButton)
        topBar.addSubview(doneButton)

        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 48),

            cancelButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            cancelButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            doneButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
            doneButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor)
        ])
    }

    private func setupScrollView() {
        scrollView.backgroundColor = .black
        scrollView.delegate = self
        scrollView.bounces = true
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.decelerationRate = .fast
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)

        imageView.image = originalImage
        imageView.contentMode = .center
        imageView.frame = CGRect(origin: .zero, size: originalImage.size)
        scrollView.addSubview(imageView)
    }

    private func setupOverlay() {
        overlayView.isUserInteractionEnabled = false
        overlayView.isOpaque = false
        overlayView.backgroundColor = .clear
        view.addSubview(overlayView)
    }

    private func layoutForCurrentBounds() {
        // トリミング枠は画面の短辺に合わせた正方形（上下/左右はマージン16）
        let sideMargin: CGFloat = 16
        let topToCropGap: CGFloat = 16

        let availableWidth = view.bounds.width - sideMargin * 2
        let availableHeight = view.bounds.height
            - view.safeAreaInsets.top - view.safeAreaInsets.bottom
            - 48 /*topBar*/ - topToCropGap - 24

        let cropSide = floor(min(availableWidth, availableHeight))

        // スクロールビュー自体を「トリミング枠の大きさ」にして中央配置
        scrollView.frame = CGRect(
            x: (view.bounds.width - cropSide) / 2.0,
            y: view.safeAreaInsets.top + 48 + topToCropGap + (availableHeight - cropSide) / 2.0,
            width: cropSide,
            height: cropSide
        )

        // オーバーレイは全画面に被せ、中心に同サイズのクリアな正方形を描画
        overlayView.frame = view.bounds
        overlayView.cropRect = scrollView.frame

        // imageView と contentSize を画像ピクセル等倍の座標系で保持
        imageView.frame = CGRect(origin: .zero, size: originalImage.size)
        scrollView.contentSize = originalImage.size
    }

    /// 最小/最大ズームを設定し、初期状態で中央に配置
    private func configureZoomScalesAndCenter() {
        guard scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }

        let cropW = scrollView.bounds.width
        let cropH = scrollView.bounds.height
        let imgW = originalImage.size.width
        let imgH = originalImage.size.height

        // 画像がトリミング枠を「完全に満たす」ための最小ズーム
        minZoom = max(cropW / imgW, cropH / imgH)
        scrollView.minimumZoomScale = minZoom
        scrollView.maximumZoomScale = max(minZoom * maximumZoomMultiplier, maximumZoomMultiplier)
        scrollView.zoomScale = minZoom

        // iOSに任せて安全に中央へ（ズーム矩形で指定）
        centerUsingZoomRect(animated: false)
        clampContentOffset()
    }

    /// 画像中央を表示するように、現在のズーム倍率の可視領域サイズで zoom(to:) を使ってセンタリング
    private func centerUsingZoomRect(animated: Bool) {
        let z = max(scrollView.minimumZoomScale, min(scrollView.maximumZoomScale, scrollView.zoomScale))
        let visibleW = scrollView.bounds.width / z
        let visibleH = scrollView.bounds.height / z
        let imgW = originalImage.size.width
        let imgH = originalImage.size.height

        let originX = max(0, (imgW - visibleW) / 2)
        let originY = max(0, (imgH - visibleH) / 2)
        let rect = CGRect(x: originX, y: originY, width: visibleW, height: visibleH)

        if abs(scrollView.zoomScale - z) > .ulpOfOne {
            scrollView.setZoomScale(z, animated: false)
        }
        scrollView.zoom(to: rect, animated: animated)
    }

    /// contentOffset をコンテンツ境界内にクランプ
    private func clampContentOffset() {
        let z = scrollView.zoomScale
        guard z > 0 else { return }

        let maxOffsetX = max(0, originalImage.size.width  - scrollView.bounds.width / z)
        let maxOffsetY = max(0, originalImage.size.height - scrollView.bounds.height / z)

        var x = min(max(0, scrollView.contentOffset.x), maxOffsetX)
        var y = min(max(0, scrollView.contentOffset.y), maxOffsetY)

        if !x.isFinite || !y.isFinite { x = 0; y = 0 }
        scrollView.contentOffset = CGPoint(x: x, y: y)
    }

    // MARK: - Actions
    @objc private func didTapCancel() { onCancel?() }

    @objc private func didTapDone() {
        guard let cropped = cropCurrentVisibleSquare() else { return }
        onDone?(cropped)
    }

    @objc private func handleDoubleTap(_ gr: UITapGestureRecognizer) {
        let next: CGFloat = abs(scrollView.zoomScale - minZoom) < 0.01
            ? min(minZoom * 1.5, scrollView.maximumZoomScale)
            : minZoom

        let location = gr.location(in: imageView)
        zoom(to: next, centeredAt: location, animated: true)
    }

    private func zoom(to scale: CGFloat, centeredAt point: CGPoint, animated: Bool) {
        let size = scrollView.bounds.size
        let w = size.width / scale
        let h = size.height / scale
        let x = point.x - (w / 2)
        let y = point.y - (h / 2)
        let rect = CGRect(x: x, y: y, width: w, height: h)
        scrollView.zoom(to: rect, animated: animated)
    }

    // MARK: - UIScrollViewDelegate
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        clampContentOffset()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        clampContentOffset()
    }

    // MARK: - Cropping
    // 既存の cropCurrentVisibleSquare() を丸ごと置換
    private func cropCurrentVisibleSquare() -> UIImage? {
        guard let cg = originalImage.cgImage else { return nil }

        // ① スクロールビューの可視範囲を imageView 座標系（ポイント）に変換
        //    → 内部のズーム/平行移動を含めて "いま見えている矩形" を正確に取得
        let visibleInImageViewPts = scrollView.convert(scrollView.bounds, to: imageView)
            .intersection(imageView.bounds)
            .integral
        guard !visibleInImageViewPts.isEmpty else { return nil }

        // ② imageView.bounds は元画像サイズ（pt）＝ originalImage.size と一致
        //    実ピクセル変換係数（端末スケールではなく cgImage の実サイズ基準）
        let scaleX = CGFloat(cg.width)  / imageView.bounds.width
        let scaleY = CGFloat(cg.height) / imageView.bounds.height

        // ③ ピクセル矩形に変換（整数化）
        var pixelRect = CGRect(
            x: visibleInImageViewPts.origin.x * scaleX,
            y: visibleInImageViewPts.origin.y * scaleY,
            width:  visibleInImageViewPts.size.width  * scaleX,
            height: visibleInImageViewPts.size.height * scaleY
        ).integral

        // ④ 境界クランプ
        pixelRect.origin.x = max(0, min(pixelRect.origin.x, CGFloat(cg.width)))
        pixelRect.origin.y = max(0, min(pixelRect.origin.y, CGFloat(cg.height)))
        pixelRect.size.width  = max(1, min(pixelRect.size.width,  CGFloat(cg.width)  - pixelRect.origin.x))
        pixelRect.size.height = max(1, min(pixelRect.size.height, CGFloat(cg.height) - pixelRect.origin.y))

        // ⑤ 実トリミング
        guard let croppedCG = cg.cropping(to: pixelRect) else { return nil }
        return UIImage(cgImage: croppedCG, scale: 1, orientation: .up)
    }

}

// MARK: - Overlay (外側を暗く・中央だけ四角く抜く & ガイド線)
private final class CropOverlayView: UIView {
    var cropRect: CGRect = .zero { didSet { setNeedsDisplay() } }

    override func draw(_ rect: CGRect) {
        guard !cropRect.isEmpty else { return }
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        // 背景を暗く
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fill(bounds)

        // クリア（中央の正方形を抜く）
        ctx.setBlendMode(.clear)
        let path = UIBezierPath(roundedRect: cropRect, cornerRadius: 12)
        path.fill()

        // 枠線
        ctx.setBlendMode(.normal)
        UIColor.white.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 2
        path.stroke()

        // 三分割ガイド（任意）
        ctx.setLineWidth(0.8)
        UIColor.white.withAlphaComponent(0.35).setStroke()

        let thirdW = cropRect.width / 3.0
        let thirdH = cropRect.height / 3.0
        for i in 1...2 {
            // 縦
            let x = cropRect.minX + CGFloat(i) * thirdW
            ctx.move(to: CGPoint(x: x, y: cropRect.minY))
            ctx.addLine(to: CGPoint(x: x, y: cropRect.maxY))
            // 横
            let y = cropRect.minY + CGFloat(i) * thirdH
            ctx.move(to: CGPoint(x: cropRect.minX, y: y))
            ctx.addLine(to: CGPoint(x: cropRect.maxX, y: y))
        }
        ctx.strokePath()
    }
}

// MARK: - Utils
private extension UIImage {
    /// 画像の向きを .up に正規化（CGImage ベースに）
    func fixedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(in: CGRect(origin: .zero, size: size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return normalized ?? self
    }
}
