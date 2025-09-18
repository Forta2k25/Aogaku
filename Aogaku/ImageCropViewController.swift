import UIKit

final class ImageCropViewController: UIViewController, UIScrollViewDelegate {

    // MARK: - Public callbacks
    var onCancel: (() -> Void)?
    var onDone: ((UIImage) -> Void)?

    // MARK: - UI
    private let scrollView = UIScrollView()
    private let imageView  = UIImageView()
    private let maskLayer  = CAShapeLayer()
    private let gridLayer  = CAShapeLayer()
    private let titleText: String
    // 位置ズレ防止：必ず .up に正規化して扱う
    private let image: UIImage

    private var didConfigureOnce = false

    // MARK: - Crop config
    /// 画面レイアウトからの希望サイズ（最大値）
    private var cropBaseSide: CGFloat {
        let w = max(0, view.bounds.width  - 32)
        let h = max(0, view.bounds.height - 200)
        return max(80, min(w, h))
    }
    /// 実際に使う円の直径（フィット後の画像短辺を超えないように設定）
    private var cropSide: CGFloat = 120

    /// 画面上の“円”の外接正方形（見た目は円、処理は正方形）
    private var cropRectInView: CGRect {
        let side = cropSide
        return CGRect(
            x: (view.bounds.width  - side)/2,
            y: (view.bounds.height - side)/2,
            width: side, height: side
        )
    }

    // MARK: - Init
    init(image: UIImage, titleText: String = "アイコンを切り取る") {
        self.image = image.normalizedUp()
        self.titleText = titleText
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // Top bar
        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        let titleLabel = UILabel()
        titleLabel.text = titleText
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let cancelBtn = UIButton(type: .system)
        cancelBtn.setTitle("キャンセル", for: .normal)
        cancelBtn.tintColor = .white
        cancelBtn.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false

        let doneBtn = UIButton(type: .system)
        doneBtn.setTitle("決定", for: .normal)
        doneBtn.tintColor = .white
        doneBtn.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        doneBtn.translatesAutoresizingMaskIntoConstraints = false

        topBar.addSubview(titleLabel)
        topBar.addSubview(cancelBtn)
        topBar.addSubview(doneBtn)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),

            cancelBtn.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            cancelBtn.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            doneBtn.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
            doneBtn.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
        ])

        // ScrollView + Image（下限はレイアウト後に算出）
        scrollView.delegate = self
        scrollView.bounces = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .black
        scrollView.decelerationRate = .fast
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -32),
        ])

        // 上限だけ先に。下限は画像サイズから後で設定。
        scrollView.maximumZoomScale = 20.0
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !didConfigureOnce {
            didConfigureOnce = true
            configureGeometryOnce()   // ← 初回レイアウト後に一度だけ安全に計算
        }
        updateMaskAndGrid()           // マスクは毎回更新（回転対応）
        updateContentInsetForCentering() // frameを動かさず見た目中央寄せ
        constrainOffset()             // 円が画像外に出ないようオフセットをクランプ（content座標）
    }

    // MARK: - First-time geometry
    private func configureGeometryOnce() {
        guard image.size.width > 0, image.size.height > 0 else { return }

        // 画像をscrollViewにフィット配置（アスペクト保持）
        let sv = scrollView.bounds.size
        let img = image.size
        let fitScale = min(sv.width / img.width, sv.height / img.height)
        let fittedSize = CGSize(width: img.width * fitScale, height: img.height * fitScale)

        // imageView.frame は (0,0) 起点のまま固定（以降動かさない）
        imageView.frame = CGRect(origin: .zero, size: fittedSize)
        scrollView.contentSize = fittedSize

        // ✅ 円直径を “フィット後の画像短辺” までに自動クランプ
        //    これで最小倍率が過剰にならない（ズームアウト可能に）
        let maxSideAllowed = max(80, min(fittedSize.width, fittedSize.height))
        cropSide = min(cropBaseSide, maxSideAllowed)

        // === 下限ズーム：円が画像に完全に収まる倍率（＝画像外に被らない） ===
        let minScale = max(cropSide / fittedSize.width, cropSide / fittedSize.height)
        let safeMin  = max(0.001, minScale)
        scrollView.minimumZoomScale = safeMin
        scrollView.maximumZoomScale = max(safeMin * 8, 8)

        // 初期表示は最小倍率（できるだけズームアウト）
        scrollView.setZoomScale(safeMin, animated: false)

        // 画像中心と円中心を合わせる（contentOffset で／insetは式に入れない）
        centerCropOverImage()

        // 念のため次のRunLoopでも一度適用（端末差のタイミング対策）
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollView.setZoomScale(safeMin, animated: false)
            self.centerCropOverImage()
            self.updateContentInsetForCentering()
            self.constrainOffset()
        }
    }

    // MARK: - Overlay (mask + grid)
    private func updateMaskAndGrid() {
        // 円形マスク（見た目）。保存は正方形で切り抜く想定。
        let path = UIBezierPath(rect: view.bounds)
        let circle = UIBezierPath(ovalIn: cropRectInView)
        path.append(circle)
        maskLayer.fillRule = .evenOdd
        maskLayer.path = path.cgPath
        maskLayer.fillColor = UIColor.black.withAlphaComponent(0.5).cgColor
        if maskLayer.superlayer == nil { view.layer.addSublayer(maskLayer) }

        // 3分割グリッド（円の内側）
        let rect = cropRectInView
        let gridPath = UIBezierPath()
        for i in 1...2 {
            let x = rect.minX + rect.width  * CGFloat(i) / 3
            let y = rect.minY + rect.height * CGFloat(i) / 3
            gridPath.move(to: CGPoint(x: x, y: rect.minY))
            gridPath.addLine(to: CGPoint(x: x, y: rect.maxY))
            gridPath.move(to: CGPoint(x: rect.minX, y: y))
            gridPath.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        gridLayer.path = gridPath.cgPath
        gridLayer.strokeColor = UIColor.white.withAlphaComponent(0.6).cgColor
        gridLayer.fillColor = UIColor.clear.cgColor
        gridLayer.lineWidth = 0.5
        if gridLayer.superlayer == nil { view.layer.addSublayer(gridLayer) }
    }

    // MARK: - Centering（frameは固定／中央寄せはinsetで）
    /// コンテンツがboundsより小さい場合、contentInsetで見た目中央寄せ（frameは触らない）
    private func updateContentInsetForCentering() {
        let bounds = scrollView.bounds.size
        let content = scrollView.contentSize
        let insetX = max(0, (bounds.width  - content.width)  / 2)
        let insetY = max(0, (bounds.height - content.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    /// 初期：画像中心と切り取り円の中心を合わせる（insetは式に入れない）
    private func centerCropOverImage() {
        let cropSV = scrollView.convert(cropRectInView, from: view) // SV座標（bounds基準）
        let imgF   = imageView.frame                                // コンテンツ座標
        var off = scrollView.contentOffset
        // contentOffset + cropSV.center = imgF.center
        off.x = imgF.midX - cropSV.midX
        off.y = imgF.midY - cropSV.midY
        scrollView.setContentOffset(off, animated: false)
    }

    /// 円が常に画像内に完全に入るよう、contentOffset をクランプ（純粋なコンテンツ座標で計算）
    private func constrainOffset() {
        let cropSV = scrollView.convert(cropRectInView, from: view) // SV座標
        let imgF   = imageView.frame                                // コンテンツ座標

        // 制約：cropRect（コンテンツ座標）= contentOffset + cropSV
        // これが imgF 内に完全に収まるようにする
        let minOffsetX = imgF.minX - cropSV.origin.x
        let maxOffsetX = imgF.maxX - cropSV.maxX
        let minOffsetY = imgF.minY - cropSV.origin.y
        let maxOffsetY = imgF.maxY - cropSV.maxY

        var off = scrollView.contentOffset
        off.x = min(max(off.x, minOffsetX), maxOffsetX)
        off.y = min(max(off.y, minOffsetY), maxOffsetY)

        if abs(off.x - scrollView.contentOffset.x) > 0.5 || abs(off.y - scrollView.contentOffset.y) > 0.5 {
            scrollView.setContentOffset(off, animated: false)
        }
    }

    // MARK: - UIScrollViewDelegate
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // frame は動かさない。中央寄せは inset で。
        updateContentInsetForCentering()
        constrainOffset() // 右端・下端まで動けるよう、純粋なcontent座標でクランプ
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        constrainOffset()
    }

    // MARK: - Actions
    @objc private func cancelTapped() { onCancel?() }

    @objc private func doneTapped() {
        guard var cropped = cropImage() else { onCancel?(); return }
        // 通信量削減：切り取った“後”だけ最大辺512pxへ縮小（UIの円やズームには無関係）
        cropped = cropped.resized(maxEdge: 512)
        onDone?(cropped)
    }

    // MARK: - Cropping（ズレ無し：imageView座標→実ピクセル）
    private func cropImage() -> UIImage? {
        // 1) 円の外接正方形を imageView のローカル座標へ変換
        let rectInIV = view.convert(cropRectInView, to: imageView)
        // 2) imageView.bounds と交差（見えてない部分や黒帯は除外）
        let ivBounds = imageView.bounds
        let ivCrop   = rectInIV.intersection(ivBounds)
        guard !ivCrop.isNull, ivCrop.width > 1, ivCrop.height > 1 else { return nil }

        // 3) imageView座標 → 画像ピクセル座標へスケーリング
        let scaleX = image.size.width  / ivBounds.width
        let scaleY = image.size.height / ivBounds.height
        let pxRect = CGRect(
            x: max(0, ivCrop.minX) * scaleX,
            y: max(0, ivCrop.minY) * scaleY,
            width: min(ivCrop.width,  ivBounds.width)  * scaleX,
            height: min(ivCrop.height, ivBounds.height) * scaleY
        ).integral

        // 4) 実画像の範囲で安全にトリミング
        let safeRect = pxRect.intersection(CGRect(origin: .zero, size: image.size)).integral
        guard safeRect.width > 1, safeRect.height > 1,
              let cg = image.cgImage?.cropping(to: safeRect) else { return nil }
        return UIImage(cgImage: cg, scale: image.scale, orientation: .up)
    }
}

// MARK: - Utils
private extension UIImage {
    /// 向きを .up に正規化（表示と切り取りのズレ防止）
    func normalizedUp() -> UIImage {
        if imageOrientation == .up { return self }
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(in: CGRect(origin: .zero, size: size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return normalized ?? self
    }

    /// 最大辺だけ 512px に縮小（UIのズームや円サイズには影響しない）
    func resized(maxEdge: CGFloat) -> UIImage {
        let w = size.width, h = size.height
        let s = min(1.0, maxEdge / max(w, h))
        if s >= 0.999 { return self }
        let newSize = CGSize(width: w * s, height: h * s)
        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
        draw(in: CGRect(origin: .zero, size: newSize))
        let img = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return img ?? self
    }
}
