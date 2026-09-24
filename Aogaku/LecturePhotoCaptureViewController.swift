//
//  LecturePhotoCaptureViewController.swift
//  Aogaku
//
//  授業ノート(AI)機能: プリント/スライド/黒板を無音で撮影し、その場で文字認識する
//

import UIKit
import AVFoundation

final class LecturePhotoCaptureViewController: UIViewController {

    private let capture = LecturePhotoCapture()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let flashView = UIView()

    private let captureButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let countLabel = UILabel()
    private let zoomLabel = UILabel()
    private let thumbnailScroll = UIScrollView()
    private let thumbnailStack = UIStackView()

    private var capturedCount = 0
    private var recognizedTexts: [String] = []
    private var currentZoomFactor: CGFloat = 1.0
    private var pinchStartZoom: CGFloat = 1.0

    /// 撮影して認識できたテキストを都度呼び出し元に渡す
    var onTextRecognized: ((String) -> Void)?
    /// 「完了」時に、撮影中に認識できた全テキストをまとめて渡す
    var onFinish: (([String]) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        modalPresentationStyle = .fullScreen

        let layer = capture.previewLayer
        view.layer.addSublayer(layer)
        previewLayer = layer

        flashView.backgroundColor = .white
        flashView.alpha = 0
        flashView.isUserInteractionEnabled = false

        countLabel.text = "0枚"
        countLabel.textColor = .white
        countLabel.font = .systemFont(ofSize: 14, weight: .medium)

        zoomLabel.text = "1.0×"
        zoomLabel.textColor = .white
        zoomLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        zoomLabel.textAlignment = .center
        zoomLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        zoomLabel.layer.cornerRadius = 12
        zoomLabel.layer.masksToBounds = true
        zoomLabel.alpha = 0

        captureButton.setTitle("撮影", for: .normal)
        captureButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        captureButton.setTitleColor(.black, for: .normal)
        captureButton.backgroundColor = .white
        captureButton.layer.cornerRadius = 32
        captureButton.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)

        doneButton.setTitle("完了", for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        doneButton.setTitleColor(.white, for: .normal)
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)

        thumbnailScroll.showsHorizontalScrollIndicator = false
        thumbnailStack.axis = .horizontal
        thumbnailStack.spacing = 8
        thumbnailScroll.addSubview(thumbnailStack)

        [flashView, countLabel, zoomLabel, thumbnailScroll, captureButton, doneButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        thumbnailStack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            flashView.topAnchor.constraint(equalTo: view.topAnchor),
            flashView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            flashView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            flashView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            countLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            countLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            zoomLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            zoomLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            zoomLabel.widthAnchor.constraint(equalToConstant: 64),
            zoomLabel.heightAnchor.constraint(equalToConstant: 32),

            doneButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            doneButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            thumbnailScroll.bottomAnchor.constraint(equalTo: captureButton.topAnchor, constant: -16),
            thumbnailScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            thumbnailScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            thumbnailScroll.heightAnchor.constraint(equalToConstant: 56),

            thumbnailStack.topAnchor.constraint(equalTo: thumbnailScroll.contentLayoutGuide.topAnchor),
            thumbnailStack.leadingAnchor.constraint(equalTo: thumbnailScroll.contentLayoutGuide.leadingAnchor),
            thumbnailStack.trailingAnchor.constraint(equalTo: thumbnailScroll.contentLayoutGuide.trailingAnchor),
            thumbnailStack.bottomAnchor.constraint(equalTo: thumbnailScroll.contentLayoutGuide.bottomAnchor),
            thumbnailStack.heightAnchor.constraint(equalTo: thumbnailScroll.frameLayoutGuide.heightAnchor),

            captureButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            captureButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureButton.widthAnchor.constraint(equalToConstant: 64),
            captureButton.heightAnchor.constraint(equalToConstant: 64)
        ])

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchChanged(_:)))
        view.addGestureRecognizer(pinch)

        LecturePhotoCapture.requestPermission { [weak self] granted in
            guard let self else { return }
            if granted {
                self.capture.start()
            } else {
                self.presentPermissionAlert()
            }
        }

        // アプリ全体はPortrait固定だが、この画面だけは端末の向きに合わせて
        // 撮影方向とボタンの見た目を手動で回転させ、横向きでも撮影できるようにする
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self, selector: #selector(deviceOrientationChanged),
            name: UIDevice.orientationDidChangeNotification, object: nil
        )
        deviceOrientationChanged()
    }

    deinit {
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        capture.stop()
    }

    @objc private func deviceOrientationChanged() {
        let orientation = UIDevice.current.orientation
        let videoOrientation: AVCaptureVideoOrientation
        let rotationAngle: CGFloat

        switch orientation {
        case .landscapeLeft:
            // UIDeviceOrientationとAVCaptureVideoOrientationのlandscapeは名称が逆になる点に注意
            videoOrientation = .landscapeRight
            rotationAngle = .pi / 2
        case .landscapeRight:
            videoOrientation = .landscapeLeft
            rotationAngle = -.pi / 2
        case .portraitUpsideDown:
            videoOrientation = .portraitUpsideDown
            rotationAngle = .pi
        case .portrait:
            videoOrientation = .portrait
            rotationAngle = 0
        default:
            // faceUp/faceDown/unknown時は直前の向きを維持する
            return
        }

        capture.updateVideoOrientation(videoOrientation)
        UIView.animate(withDuration: 0.25) {
            let transform = CGAffineTransform(rotationAngle: rotationAngle)
            self.captureButton.transform = transform
            self.doneButton.transform = transform
            self.countLabel.transform = transform
        }
    }

    @objc private func pinchChanged(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartZoom = currentZoomFactor
            UIView.animate(withDuration: 0.15) { self.zoomLabel.alpha = 1 }
        case .changed:
            let maxZoom = max(capture.maxZoomFactor, 1.0)
            let newZoom = min(max(pinchStartZoom * gesture.scale, 1.0), maxZoom)
            currentZoomFactor = newZoom
            capture.setZoomFactor(newZoom)
            zoomLabel.text = String(format: "%.1f×", newZoom)
        case .ended, .cancelled, .failed:
            UIView.animate(withDuration: 0.25, delay: 0.4, options: []) { self.zoomLabel.alpha = 0 }
        default:
            break
        }
    }

    @objc private func captureTapped() {
        captureButton.isEnabled = false
        showCaptureFlash()
        capture.captureFrame { [weak self] image in
            guard let self else { return }
            self.captureButton.isEnabled = true
            guard let image else { return }
            self.capturedCount += 1
            self.countLabel.text = "\(self.capturedCount)枚"
            let imageView = self.addThumbnail(image)
            LecturePhotoOCR.recognizeText(in: image) { text in
                #if DEBUG
                imageView.debugRecognizedText = text
                #endif
                guard !text.isEmpty else { return }
                self.recognizedTexts.append(text)
                self.onTextRecognized?(text)
            }
        }
    }

    private func showCaptureFlash() {
        flashView.alpha = 1
        UIView.animate(withDuration: 0.25) { self.flashView.alpha = 0 }
    }

    @discardableResult
    private func addThumbnail(_ image: UIImage) -> UIImageView {
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 6
        imageView.layer.borderWidth = 1
        imageView.layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.widthAnchor.constraint(equalToConstant: 56).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 56).isActive = true

        #if DEBUG
        imageView.isUserInteractionEnabled = true
        imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(thumbnailTapped(_:))))
        #endif

        thumbnailStack.addArrangedSubview(imageView)
        DispatchQueue.main.async {
            let rightEdge = CGPoint(x: max(0, self.thumbnailScroll.contentSize.width - self.thumbnailScroll.bounds.width), y: 0)
            self.thumbnailScroll.setContentOffset(rightEdge, animated: true)
        }
        return imageView
    }

    #if DEBUG
    @objc private func thumbnailTapped(_ gesture: UITapGestureRecognizer) {
        guard let imageView = gesture.view as? UIImageView else { return }
        let text = imageView.debugRecognizedText ?? "(認識中、またはテキストなし)"
        DebugTextPreview.present(on: self, title: "この写真の検出テキスト", text: text)
    }
    #endif

    @objc private func doneTapped() {
        onFinish?(recognizedTexts)
        dismiss(animated: true)
    }

    private func presentPermissionAlert() {
        let alert = UIAlertController(title: "カメラを利用できません", message: "設定アプリでカメラへのアクセスを許可してください", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }
}
