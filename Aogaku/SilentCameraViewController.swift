import UIKit
import AVFoundation
import CoreImage

/// シャッター音の出ない資料撮影カメラ。
///
/// 日本向けのiPhoneは AVCapturePhotoOutput で撮るとシャッター音を消せないため、
/// 動画フレーム(AVCaptureVideoDataOutput)から静止画を切り出す。
/// 動画フォーマットのうち最も解像度の高い4:3のものを選び、連続AF・タップAF・
/// 撮影直前のピント合わせ待ち・ピンチ/ボタンズームで画質と使いやすさを確保する。
final class SilentCameraViewController: UIViewController {

    /// 「送信」で閉じたときに、撮影した全ての写真(撮影順)を渡す。
    var onFinish: (([CapturedPhoto]) -> Void)?

    // MARK: - Capture
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "aogaku.silentcamera.session")
    private let videoQueue = DispatchQueue(label: "aogaku.silentcamera.video")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var isConfigured = false

    private let frameLock = NSLock()
    private var latestFrame: CVPixelBuffer?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Zoom
    /// 「1倍」に当たる videoZoomFactor。超広角を持つ仮想カメラでは広角に切り替わる値(通常2.0)。
    private var baseZoom: CGFloat = 1
    private var minZoomFactor: CGFloat = 1
    private var maxZoomFactor: CGFloat = 1
    private var pinchStartZoom: CGFloat = 1
    private var zoomObservation: NSKeyValueObservation?
    private var zoomPresets: [CGFloat] = []   // 表示倍率(0.5, 1, 2, 5)

    // MARK: - State
    private let photoSet = CapturedPhotoSet()
    private var isCapturing = false

    // MARK: - UI
    private let previewView = PreviewView()
    private let flashView = UIView()
    private let focusBox = UIView()
    private let closeButton = UIButton(type: .system)
    private let torchButton = UIButton(type: .system)
    private let zoomLabel = UILabel()
    private let zoomStack = UIStackView()
    private var zoomButtons: [UIButton] = []
    private let shutterButton = UIButton(type: .custom)
    private let shutterInner = UIView()
    private let thumbView = UIImageView()
    private let countBadge = UILabel()
    private let sendButton = UIButton(type: .system)
    private let hintLabel = UILabel()
    private let zoomDial = ZoomDialView()
    private var dialPanStartLog: CGFloat = 0
    private var dialHideWork: DispatchWorkItem?

    private let accent = UIColor(red: 0xb4/255.0, green: 0xe8/255.0, blue: 0xff/255.0, alpha: 1)

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    /// カメラ表示中だけ横向きを許可する(AppDelegateが参照)。他の画面は縦固定のまま。
    static var isActive = false

    private var portraitConstraints: [NSLayoutConstraint] = []
    private var landscapeConstraints: [NSLayoutConstraint] = []
    private var isLandscapeLayout: Bool?

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        isModalInPresentation = true
        buildUI()
        requestAccessAndConfigure()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Self.isActive = true
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed { Self.isActive = false }   // 一覧を重ねただけの間は横向きを許可したままにする
        setTorch(false)
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Permission / session setup
    private func requestAccessAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.configureSession() : self?.showPermissionDenied()
                }
            }
        default:
            showPermissionDenied()
        }
    }

    private func showPermissionDenied() {
        let alert = UIAlertController(
            title: "カメラを使えません",
            message: "設定アプリで「青山ハック」のカメラを許可してください。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "設定を開く", style: .default) { [weak self] _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            self?.dismiss(animated: true)
        })
        alert.addAction(UIAlertAction(title: "閉じる", style: .cancel) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let device = Self.bestBackCamera(),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                DispatchQueue.main.async { self.showPermissionDenied() }
                return
            }
            self.device = device

            self.session.beginConfiguration()
            if self.session.canAddInput(input) { self.session.addInput(input) }
            self.session.sessionPreset = .inputPriority   // フォーマットは下で自分で選ぶ

            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
            if self.session.canAddOutput(self.videoOutput) { self.session.addOutput(self.videoOutput) }
            if let connection = self.videoOutput.connection(with: .video) {
                Self.applyPortrait(to: connection)
            }
            self.session.commitConfiguration()

            self.configureDevice(device)
            self.isConfigured = true
            self.session.startRunning()

            DispatchQueue.main.async {
                self.previewView.previewLayer.session = self.session
                self.previewView.previewLayer.videoGravity = .resizeAspect
                if let connection = self.previewView.previewLayer.connection {
                    Self.applyPortrait(to: connection)
                }
                self.setUpZoomUI()
                self.observeDevice(device)
            }
        }
    }

    /// 超広角を含む仮想カメラを優先(0.5倍〜ズームを連続で扱える)。
    private static func bestBackCamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back)
        for type in types {
            if let found = discovery.devices.first(where: { $0.deviceType == type }) { return found }
        }
        return AVCaptureDevice.default(for: .video)
    }

    private static func applyPortrait(to connection: AVCaptureConnection) {
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }

    private func configureDevice(_ device: AVCaptureDevice) {
        do { try device.lockForConfiguration() } catch { return }
        defer { device.unlockForConfiguration() }

        // 解像度が最大の4:3フォーマット(30fps以上)を選ぶ。無ければ4:3以外も含めて最大。
        func area(_ f: AVCaptureDevice.Format) -> Int32 {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width * d.height
        }
        func supports30fps(_ f: AVCaptureDevice.Format) -> Bool {
            f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
        }
        func isYUV(_ f: AVCaptureDevice.Format) -> Bool {
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            return sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        let usable = device.formats.filter { supports30fps($0) && isYUV($0) }
        let fourThree = usable.filter {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return d.width * 3 == d.height * 4
        }
        if let best = (fourThree.isEmpty ? usable : fourThree).max(by: { area($0) < area($1) }) {
            device.activeFormat = best
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        }

        // ピント・露出は常に自動で追従
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = false }   // 滑らか動作より合焦の速さを優先
        if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .none }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = true }
        device.isSubjectAreaChangeMonitoringEnabled = true

        // ズーム範囲と「1倍」の基準
        var base: CGFloat = 1
        let hasUltraWide = device.deviceType == .builtInTripleCamera || device.deviceType == .builtInDualWideCamera
        if hasUltraWide, let first = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            base = CGFloat(truncating: first)
        }
        baseZoom = base
        minZoomFactor = device.minAvailableVideoZoomFactor
        maxZoomFactor = min(device.maxAvailableVideoZoomFactor, base * 10)
        device.videoZoomFactor = min(max(base, minZoomFactor), maxZoomFactor)
    }

    private func observeDevice(_ device: AVCaptureDevice) {
        zoomObservation = device.observe(\.videoZoomFactor, options: [.new]) { [weak self] dev, _ in
            DispatchQueue.main.async { self?.updateZoomUI(factor: dev.videoZoomFactor) }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(subjectAreaDidChange),
            name: .AVCaptureDeviceSubjectAreaDidChange, object: device)
        torchButton.isHidden = !device.hasTorch
    }

    // MARK: - UI construction
    private func buildUI() {
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.backgroundColor = .black
        view.addSubview(previewView)

        flashView.backgroundColor = .white
        flashView.alpha = 0
        flashView.isUserInteractionEnabled = false
        flashView.translatesAutoresizingMaskIntoConstraints = false
        previewView.addSubview(flashView)

        focusBox.layer.borderColor = UIColor.systemYellow.cgColor
        focusBox.layer.borderWidth = 1.5
        focusBox.frame = CGRect(x: 0, y: 0, width: 76, height: 76)
        focusBox.alpha = 0
        focusBox.isUserInteractionEnabled = false
        previewView.addSubview(focusBox)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTapToFocus(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        previewView.addGestureRecognizer(tap)
        previewView.addGestureRecognizer(pinch)

        func configureIcon(_ button: UIButton, symbol: String) {
            var cfg = UIButton.Configuration.plain()
            cfg.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
            cfg.baseForegroundColor = .white
            button.configuration = cfg
            button.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            button.layer.cornerRadius = 22
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        configureIcon(closeButton, symbol: "xmark")
        closeButton.accessibilityLabel = "閉じる"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        configureIcon(torchButton, symbol: "bolt.slash.fill")
        torchButton.accessibilityLabel = "ライト"
        torchButton.isHidden = true
        torchButton.addTarget(self, action: #selector(torchTapped), for: .touchUpInside)
        view.addSubview(closeButton)
        view.addSubview(torchButton)

        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        zoomLabel.textColor = .systemYellow
        zoomLabel.textAlignment = .center
        zoomLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        zoomLabel.layer.cornerRadius = 12
        zoomLabel.clipsToBounds = true
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.alpha = 0

        zoomStack.axis = .horizontal
        zoomStack.spacing = 10
        zoomStack.alignment = .center
        zoomStack.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.text = "資料全体が入るようにして撮影"
        hintLabel.font = .systemFont(ofSize: 12, weight: .medium)
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        hintLabel.textAlignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        let controls = UIView()
        controls.backgroundColor = .black
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        view.addSubview(zoomLabel)
        view.addSubview(zoomStack)

        zoomDial.alpha = 0
        zoomDial.isUserInteractionEnabled = false
        zoomDial.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(zoomDial)
        for target in [zoomStack, zoomDial] as [UIView] {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDialPan(_:)))
            target.addGestureRecognizer(pan)
        }
        zoomStack.isUserInteractionEnabled = true
        view.addSubview(hintLabel)

        // シャッター(白いリング+内側の円)
        shutterButton.translatesAutoresizingMaskIntoConstraints = false
        shutterButton.layer.cornerRadius = 36
        shutterButton.layer.borderWidth = 4
        shutterButton.layer.borderColor = UIColor.white.cgColor
        shutterButton.accessibilityLabel = "撮影"
        shutterInner.backgroundColor = .white
        shutterInner.layer.cornerRadius = 29
        shutterInner.isUserInteractionEnabled = false
        shutterInner.translatesAutoresizingMaskIntoConstraints = false
        shutterButton.addSubview(shutterInner)
        shutterButton.addTarget(self, action: #selector(shutterTapped), for: .touchUpInside)
        shutterButton.addTarget(self, action: #selector(shutterDown), for: [.touchDown, .touchDragEnter])
        shutterButton.addTarget(self, action: #selector(shutterUp), for: [.touchUpOutside, .touchCancel, .touchDragExit, .touchUpInside])
        controls.addSubview(shutterButton)

        // 直近の1枚のサムネイルと枚数
        thumbView.contentMode = .scaleAspectFill
        thumbView.clipsToBounds = true
        thumbView.layer.cornerRadius = 10
        thumbView.layer.borderWidth = 1.5
        thumbView.layer.borderColor = UIColor.white.withAlphaComponent(0.8).cgColor
        thumbView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        thumbView.isUserInteractionEnabled = true
        thumbView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(thumbTapped)))
        thumbView.accessibilityLabel = "撮影した写真の一覧"
        thumbView.translatesAutoresizingMaskIntoConstraints = false
        countBadge.font = .systemFont(ofSize: 12, weight: .bold)
        countBadge.textColor = .black
        countBadge.backgroundColor = accent
        countBadge.textAlignment = .center
        countBadge.layer.cornerRadius = 10
        countBadge.clipsToBounds = true
        countBadge.isHidden = true
        countBadge.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(thumbView)
        controls.addSubview(countBadge)

        var sendCfg = UIButton.Configuration.filled()
        sendCfg.title = "追加"
        sendCfg.baseBackgroundColor = accent
        sendCfg.baseForegroundColor = .black
        sendCfg.cornerStyle = .capsule
        sendCfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 22, bottom: 10, trailing: 22)
        sendButton.configuration = sendCfg
        sendButton.isEnabled = false
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        controls.addSubview(sendButton)

        let safe = view.safeAreaLayoutGuide
        // 縦横どちらでも共通の制約
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            closeButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            torchButton.trailingAnchor.constraint(equalTo: previewView.trailingAnchor, constant: -16),
            torchButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            torchButton.widthAnchor.constraint(equalToConstant: 44),
            torchButton.heightAnchor.constraint(equalToConstant: 44),

            flashView.topAnchor.constraint(equalTo: previewView.topAnchor),
            flashView.bottomAnchor.constraint(equalTo: previewView.bottomAnchor),
            flashView.leadingAnchor.constraint(equalTo: previewView.leadingAnchor),
            flashView.trailingAnchor.constraint(equalTo: previewView.trailingAnchor),

            shutterButton.widthAnchor.constraint(equalToConstant: 72),
            shutterButton.heightAnchor.constraint(equalToConstant: 72),
            shutterInner.centerXAnchor.constraint(equalTo: shutterButton.centerXAnchor),
            shutterInner.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),
            shutterInner.widthAnchor.constraint(equalToConstant: 58),
            shutterInner.heightAnchor.constraint(equalToConstant: 58),

            thumbView.widthAnchor.constraint(equalToConstant: 52),
            thumbView.heightAnchor.constraint(equalToConstant: 52),
            countBadge.centerXAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: -2),
            countBadge.centerYAnchor.constraint(equalTo: thumbView.topAnchor, constant: 2),
            countBadge.heightAnchor.constraint(equalToConstant: 20),
            countBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),

            zoomStack.centerXAnchor.constraint(equalTo: previewView.centerXAnchor),
            zoomStack.bottomAnchor.constraint(equalTo: previewView.bottomAnchor, constant: -14),
            zoomLabel.centerXAnchor.constraint(equalTo: previewView.centerXAnchor),
            zoomLabel.bottomAnchor.constraint(equalTo: zoomStack.topAnchor, constant: -8),
            zoomLabel.heightAnchor.constraint(equalToConstant: 24),
            zoomLabel.widthAnchor.constraint(equalToConstant: 56),

            zoomDial.leadingAnchor.constraint(equalTo: previewView.leadingAnchor),
            zoomDial.trailingAnchor.constraint(equalTo: previewView.trailingAnchor),
            zoomDial.bottomAnchor.constraint(equalTo: previewView.bottomAnchor),
            zoomDial.heightAnchor.constraint(equalToConstant: 120),

            hintLabel.centerXAnchor.constraint(equalTo: previewView.centerXAnchor),
            hintLabel.topAnchor.constraint(equalTo: previewView.topAnchor, constant: 8)
        ])

        // 縦: プレビューの下に操作バー
        portraitConstraints = [
            previewView.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 8),
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: controls.topAnchor),

            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controls.topAnchor.constraint(equalTo: safe.bottomAnchor, constant: -112),

            shutterButton.centerXAnchor.constraint(equalTo: controls.centerXAnchor),
            shutterButton.topAnchor.constraint(equalTo: controls.topAnchor, constant: 22),
            thumbView.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 28),
            thumbView.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),
            sendButton.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -24),
            sendButton.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor)
        ]

        // 横: プレビューの右に縦長の操作バー(シャッターは中央、送信は上、サムネイルは下)
        landscapeConstraints = [
            previewView.topAnchor.constraint(equalTo: view.topAnchor),
            previewView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: controls.leadingAnchor),

            controls.topAnchor.constraint(equalTo: view.topAnchor),
            controls.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controls.leadingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -112),

            shutterButton.centerXAnchor.constraint(equalTo: controls.centerXAnchor, constant: -(0)),
            shutterButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            sendButton.centerXAnchor.constraint(equalTo: shutterButton.centerXAnchor),
            sendButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 16),
            thumbView.centerXAnchor.constraint(equalTo: shutterButton.centerXAnchor),
            thumbView.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -16)
        ]
        applyLayout(landscape: view.bounds.width > view.bounds.height)
    }

    private func applyLayout(landscape: Bool) {
        guard isLandscapeLayout != landscape else { return }
        isLandscapeLayout = landscape
        NSLayoutConstraint.deactivate(landscape ? portraitConstraints : landscapeConstraints)
        NSLayoutConstraint.activate(landscape ? landscapeConstraints : portraitConstraints)
        hintLabel.isHidden = landscape
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        applyLayout(landscape: size.width > size.height)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.updateCaptureOrientation()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyLayout(landscape: view.bounds.width > view.bounds.height)
        updateCaptureOrientation()
    }

    /// 画面の向きに合わせて、プレビューと切り出す静止画の向きを揃える。
    private func updateCaptureOrientation() {
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        let connections = [videoOutput.connection(with: .video), previewView.previewLayer.connection].compactMap { $0 }
        for connection in connections { Self.apply(orientation: orientation, to: connection) }
    }

    private static func apply(orientation: UIInterfaceOrientation, to connection: AVCaptureConnection) {
        if #available(iOS 17.0, *) {
            let angle: CGFloat
            switch orientation {
            case .landscapeRight: angle = 0
            case .landscapeLeft: angle = 180
            case .portraitUpsideDown: angle = 270
            default: angle = 90
            }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        } else if connection.isVideoOrientationSupported {
            switch orientation {
            case .landscapeRight: connection.videoOrientation = .landscapeRight
            case .landscapeLeft: connection.videoOrientation = .landscapeLeft
            case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
            default: connection.videoOrientation = .portrait
            }
        }
    }

    // MARK: - Zoom UI
    private func setUpZoomUI() {
        zoomButtons.forEach { $0.removeFromSuperview() }
        zoomButtons.removeAll()
        zoomPresets.removeAll()

        let minDisplay = minZoomFactor / baseZoom
        let maxDisplay = maxZoomFactor / baseZoom
        for candidate: CGFloat in [0.5, 1, 2, 5] where candidate >= minDisplay - 0.01 && candidate <= maxDisplay + 0.01 {
            zoomPresets.append(candidate)
        }
        for preset in zoomPresets {
            let button = UIButton(type: .system)
            button.tag = zoomPresets.firstIndex(of: preset) ?? 0
            button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            button.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            button.layer.cornerRadius = 19
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 38).isActive = true
            button.heightAnchor.constraint(equalToConstant: 38).isActive = true
            button.addTarget(self, action: #selector(zoomPresetTapped(_:)), for: .touchUpInside)
            zoomButtons.append(button)
            zoomStack.addArrangedSubview(button)
        }
        updateZoomUI(factor: device?.videoZoomFactor ?? baseZoom)
    }

    private func zoomText(_ value: CGFloat) -> String {
        value < 10 && abs(value - value.rounded()) > 0.05 ? String(format: "%.1f", value) : String(format: "%.0f", value)
    }

    private func updateZoomUI(factor: CGFloat) {
        let display = factor / baseZoom
        zoomDial.update(current: display, minZoom: minZoomFactor / baseZoom, maxZoom: maxZoomFactor / baseZoom)
        zoomLabel.text = "\(zoomText(display))×"
        // 一番近いプリセットを強調(現在値が±5%以内ならそのボタンに現在値を表示)
        let nearest = zoomPresets.enumerated().min(by: { abs($0.element - display) < abs($1.element - display) })?.offset
        for (index, button) in zoomButtons.enumerated() {
            let preset = zoomPresets[index]
            let selected = index == nearest
            let isExact = abs(preset - display) / preset < 0.05
            let title = selected ? "\(zoomText(isExact ? preset : display))×" : zoomText(preset)
            button.setTitle(title, for: .normal)
            button.setTitleColor(selected ? .systemYellow : .white, for: .normal)
            button.transform = selected ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity
        }
    }

    private func showZoomLabelTemporarily() {
        zoomLabel.layer.removeAllAnimations()
        UIView.animate(withDuration: 0.1) { self.zoomLabel.alpha = 1 }
        UIView.animate(withDuration: 0.3, delay: 1.0, options: [.allowUserInteraction]) { self.zoomLabel.alpha = 0 }
    }

    private func setZoom(display: CGFloat, ramp: Bool) {
        guard let device else { return }
        let target = min(max(display * baseZoom, minZoomFactor), maxZoomFactor)
        do {
            try device.lockForConfiguration()
            if ramp {
                device.ramp(toVideoZoomFactor: target, withRate: 6)
            } else {
                device.cancelVideoZoomRamp()
                device.videoZoomFactor = target
            }
            device.unlockForConfiguration()
        } catch {}
    }

    @objc private func zoomPresetTapped(_ sender: UIButton) {
        guard zoomPresets.indices.contains(sender.tag) else { return }
        setZoom(display: zoomPresets[sender.tag], ramp: true)
        showZoomLabelTemporarily()
    }

    /// iPhone純正カメラのように、左右にスライドして連続的にズームする(ダイヤルが現れる)。
    @objc private func handleDialPan(_ gesture: UIPanGestureRecognizer) {
        guard let device else { return }
        switch gesture.state {
        case .began:
            device.cancelVideoZoomRamp()
            dialPanStartLog = log2(device.videoZoomFactor / baseZoom)
            showDial(true)
        case .changed:
            // 左へスライド=ズームイン。1オクターブ(2倍)あたり約140pt。
            let dx = gesture.translation(in: view).x
            var display = pow(2, dialPanStartLog - dx / 140)
            // 主要な倍率の近くでは吸い付かせる
            if let snap = zoomPresets.first(where: { abs($0 - display) / $0 < 0.025 }) { display = snap }
            setZoom(display: display, ramp: false)
        case .ended, .cancelled, .failed:
            scheduleDialHide()
        default:
            break
        }
    }

    private func showDial(_ show: Bool) {
        dialHideWork?.cancel()
        zoomDial.isUserInteractionEnabled = show
        UIView.animate(withDuration: 0.2) {
            self.zoomDial.alpha = show ? 1 : 0
            self.zoomStack.alpha = show ? 0 : 1
            self.zoomLabel.alpha = 0
        }
    }

    private func scheduleDialHide() {
        dialHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showDial(false) }
        dialHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let device else { return }
        switch gesture.state {
        case .began:
            device.cancelVideoZoomRamp()
            pinchStartZoom = device.videoZoomFactor
            showZoomLabelTemporarily()
        case .changed:
            let target = min(max(pinchStartZoom * gesture.scale, minZoomFactor), maxZoomFactor)
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = target
                device.unlockForConfiguration()
            } catch {}
            zoomLabel.layer.removeAllAnimations()
            zoomLabel.alpha = 1
        case .ended, .cancelled:
            showZoomLabelTemporarily()
        default:
            break
        }
    }

    // MARK: - Focus
    @objc private func handleTapToFocus(_ gesture: UITapGestureRecognizer) {
        guard device != nil else { return }
        let point = gesture.location(in: previewView)
        let devicePoint = previewView.previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        focus(at: devicePoint, mode: .autoFocus)
        showFocusBox(at: point)
    }

    @objc private func subjectAreaDidChange() {
        // 被写体が大きく変わったら、画面中央への連続AFに戻す
        focus(at: CGPoint(x: 0.5, y: 0.5), mode: .continuousAutoFocus)
    }

    private func focus(at devicePoint: CGPoint, mode: AVCaptureDevice.FocusMode) {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = devicePoint
                if device.isFocusModeSupported(mode) { device.focusMode = mode }
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = devicePoint
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            }
            device.unlockForConfiguration()
        } catch {}
    }

    private func showFocusBox(at point: CGPoint) {
        focusBox.layer.removeAllAnimations()
        focusBox.center = point
        focusBox.alpha = 1
        focusBox.transform = CGAffineTransform(scaleX: 1.4, y: 1.4)
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
            self.focusBox.transform = .identity
        }
        UIView.animate(withDuration: 0.3, delay: 0.9, options: [.allowUserInteraction]) {
            self.focusBox.alpha = 0
        }
    }

    // MARK: - Torch
    private func setTorch(_ on: Bool) {
        guard let device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        } catch {}
        let name = on ? "bolt.fill" : "bolt.slash.fill"
        var cfg = torchButton.configuration
        cfg?.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        cfg?.baseForegroundColor = on ? .systemYellow : .white
        torchButton.configuration = cfg
    }

    @objc private func torchTapped() {
        setTorch(device?.torchMode != .on)
    }

    // MARK: - Capture
    @objc private func shutterDown() {
        UIView.animate(withDuration: 0.08) { self.shutterInner.transform = CGAffineTransform(scaleX: 0.88, y: 0.88) }
    }

    @objc private func shutterUp() {
        UIView.animate(withDuration: 0.12) { self.shutterInner.transform = .identity }
    }

    @objc private func shutterTapped() {
        guard !isCapturing, isConfigured else { return }
        isCapturing = true
        captureWhenFocused(attempt: 0)
    }

    /// ピント合わせの最中なら、合うまで(最長0.7秒)待ってからフレームを確定する。
    private func captureWhenFocused(attempt: Int) {
        if let device, device.isAdjustingFocus, attempt < 14 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.captureWhenFocused(attempt: attempt + 1)
            }
            return
        }
        // 合焦直後のフレームが安定するまで、ごく短く待つ
        videoQueue.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self else { return }
            self.frameLock.lock()
            let buffer = self.latestFrame
            self.frameLock.unlock()
            guard let buffer else {
                DispatchQueue.main.async { self.isCapturing = false }
                return
            }
            // 高画質のままJPEG化(縮小しない)。メモリを食う生のビットマップは保持しない。
            let ci = CIImage(cvPixelBuffer: buffer)
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let jpeg = self.ciContext.jpegRepresentation(
                of: ci, colorSpace: space,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92])
            let longEdge = max(ci.extent.width, ci.extent.height)
            let scale = min(1, 480 / longEdge)
            let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let thumbCG = self.ciContext.createCGImage(small, from: small.extent)
            DispatchQueue.main.async {
                self.isCapturing = false
                guard let jpeg, let thumbCG else { return }
                self.didCapture(CapturedPhoto(jpeg: jpeg, thumb: UIImage(cgImage: thumbCG)))
            }
        }
    }

    private func didCapture(_ photo: CapturedPhoto) {
        photoSet.items.append(photo)
        // 音の代わりに画面を一瞬白くして撮れたことを示す(触覚フィードバックも使わない)
        flashView.alpha = 0.7
        UIView.animate(withDuration: 0.18) { self.flashView.alpha = 0 }

        thumbView.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0.5) {
            self.thumbView.transform = .identity
        }
        refreshPhotoSummary()
    }

    /// サムネイル・枚数バッジ・送信ボタンを、現在の写真リストに合わせる。
    private func refreshPhotoSummary() {
        let items = photoSet.items
        thumbView.image = items.last?.thumb
        countBadge.text = "\(items.count)"
        countBadge.isHidden = items.isEmpty
        sendButton.isEnabled = !items.isEmpty
        var cfg = sendButton.configuration
        cfg?.title = items.isEmpty ? "追加" : "追加 (\(items.count))"
        sendButton.configuration = cfg
    }

    @objc private func thumbTapped() {
        guard !photoSet.items.isEmpty else { return }
        let gallery = SilentCameraGalleryViewController(photoSet: photoSet)
        gallery.modalPresentationStyle = .fullScreen
        gallery.onSend = { [weak self] in
            self?.dismiss(animated: false) { self?.sendTapped() }
        }
        gallery.onDismiss = { [weak self] in self?.refreshPhotoSummary() }
        present(gallery, animated: true)
    }

    // MARK: - Actions
    @objc private func sendTapped() {
        guard !photoSet.items.isEmpty else { return }
        let result = photoSet.items
        dismiss(animated: true) { [onFinish] in onFinish?(result) }
    }

    @objc private func closeTapped() {
        guard !photoSet.items.isEmpty else {
            dismiss(animated: true)
            return
        }
        let alert = UIAlertController(
            title: "撮影した写真を破棄しますか？",
            message: "\(photoSet.items.count)枚の写真は追加されません。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "破棄して閉じる", style: .destructive) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        alert.addAction(UIAlertAction(title: "撮影を続ける", style: .cancel))
        present(alert, animated: true)
    }
}

// MARK: - Frame capture
extension SilentCameraViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameLock.lock()
        latestFrame = buffer
        frameLock.unlock()
    }
}

// MARK: - Preview layer host
private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

// MARK: - Captured photos
/// 撮影した1枚。高画質のJPEGと一覧用の小さなサムネイルだけを持つ(生ビットマップは持たない)。
struct CapturedPhoto {
    let jpeg: Data
    let thumb: UIImage
}

final class CapturedPhotoSet {
    var items: [CapturedPhoto]
    init(items: [CapturedPhoto] = []) { self.items = items }
}

enum PhotoCodec {
    /// JPEGを長辺maxPixel以下に縮小してデコードする(全解像度をメモリに展開しない)。
    static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Zoom dial
/// iPhone純正カメラ風の、回転するズームダイヤル(対数目盛)。現在の倍率が常に上中央に来る。
final class ZoomDialView: UIView {
    private var current: CGFloat = 1
    private var minZoom: CGFloat = 1
    private var maxZoom: CGFloat = 1
    private let degreesPerOctave: CGFloat = 34

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(current: CGFloat, minZoom: CGFloat, maxZoom: CGFloat) {
        self.current = current
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        setNeedsDisplay()
    }

    private func label(for z: CGFloat) -> String {
        abs(z - z.rounded()) < 0.01 ? String(format: "%.0f", z) : String(format: "%.1f", z)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), bounds.width > 0 else { return }
        let radius = bounds.width * 0.78
        let center = CGPoint(x: bounds.midX, y: radius + 6)

        // 円盤
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.5).cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.fillPath()

        let curLog = log2(max(current, 0.01))
        let degToRad = CGFloat.pi / 180
        let majors: [CGFloat] = [0.5, 1, 2, 5, 10]

        var z: CGFloat = max(0.5, (minZoom * 10).rounded(.up) / 10)
        while z <= maxZoom + 0.001 {
            let theta = (log2(z) - curLog) * degreesPerOctave * degToRad
            if abs(theta) < 72 * degToRad {
                let isMajor = majors.contains { abs($0 - z) < 0.005 }
                let isInteger = abs(z - z.rounded()) < 0.005
                let length: CGFloat = isMajor ? 15 : (isInteger ? 11 : 7)
                let dir = CGPoint(x: sin(theta), y: -cos(theta))
                let outer = CGPoint(x: center.x + dir.x * (radius - 3), y: center.y + dir.y * (radius - 3))
                let inner = CGPoint(x: center.x + dir.x * (radius - 3 - length), y: center.y + dir.y * (radius - 3 - length))
                ctx.setStrokeColor(UIColor.white.withAlphaComponent(isMajor || isInteger ? 0.9 : 0.5).cgColor)
                ctx.setLineWidth(isMajor ? 2 : 1)
                ctx.move(to: outer)
                ctx.addLine(to: inner)
                ctx.strokePath()

                // 中央付近のラベルは、黄色の現在値と重なるので出さない
                if isMajor, abs(theta) > 7 * degToRad {
                    let text = NSAttributedString(string: label(for: z), attributes: [
                        .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
                        .foregroundColor: UIColor.white.withAlphaComponent(0.9)
                    ])
                    let size = text.size()
                    let r = radius - 3 - 15 - 16
                    let p = CGPoint(x: center.x + sin(theta) * r, y: center.y - cos(theta) * r)
                    ctx.saveGState()
                    ctx.translateBy(x: p.x, y: p.y)
                    ctx.rotate(by: theta)
                    text.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2))
                    ctx.restoreGState()
                }
            }
            z += 0.1
        }

        // 現在値(黄色)と目印の三角
        let marker = UIBezierPath()
        let top = CGPoint(x: bounds.midX, y: 26)
        marker.move(to: CGPoint(x: top.x, y: top.y))
        marker.addLine(to: CGPoint(x: top.x - 4, y: top.y + 7))
        marker.addLine(to: CGPoint(x: top.x + 4, y: top.y + 7))
        marker.close()
        UIColor.systemYellow.setFill()
        marker.fill()

        let value = NSAttributedString(string: label(for: current) + "×", attributes: [
            .font: UIFont.systemFont(ofSize: 16, weight: .bold),
            .foregroundColor: UIColor.systemYellow
        ])
        let valueSize = value.size()
        value.draw(at: CGPoint(x: bounds.midX - valueSize.width / 2, y: top.y + 12))
    }
}
