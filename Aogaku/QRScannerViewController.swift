import UIKit
import AVFoundation
import Photos
import PhotosUI
import Vision
import FirebaseAuth
import FirebaseFirestore

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate, PHPickerViewControllerDelegate {

    // 呼び出し元へ伝える
    var onFoundID: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer!
    private let guideView = UIView()
    private let myQRButton = UIButton(type: .system)
    private let libraryButton = UIButton(type: .custom)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
        setupUI()
        updateLibraryThumbnailIfPossible()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        session.startRunning()
        updateLibraryThumbnailIfPossible()
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stopRunning()
    }

    private func setupCamera() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            presentErrorAndClose("カメラにアクセスできません")
            return
        }
        if session.canAddInput(input) { session.addInput(input) }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) { session.addOutput(output) }
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.addSublayer(previewLayer)
    }

    private func setupUI() {
        // ナビ
        navigationItem.title = "QRコード"
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })

        // 中央ガイド
        let side: CGFloat = min(view.bounds.width, view.bounds.height) * 0.7
        guideView.frame = CGRect(x: (view.bounds.width-side)/2, y: (view.bounds.height-side)/2 - 40, width: side, height: side)
        guideView.layer.borderWidth = 2
        guideView.layer.cornerRadius = 16
        guideView.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        guideView.backgroundColor = .clear
        view.addSubview(guideView)

        // マイQR
        myQRButton.setTitle("  マイQRコード", for: .normal)
        myQRButton.setImage(UIImage(systemName: "qrcode"), for: .normal)
        myQRButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        myQRButton.tintColor = .black
        myQRButton.setTitleColor(.black, for: .normal)
        myQRButton.backgroundColor = .white
        myQRButton.layer.cornerRadius = 20
        myQRButton.addAction(UIAction { [weak self] _ in self?.showMyQR() }, for: .touchUpInside)
        myQRButton.translatesAutoresizingMaskIntoConstraints = false

        // ライブラリ
        libraryButton.layer.cornerRadius = 10
        libraryButton.clipsToBounds = true
        libraryButton.layer.borderWidth = 2
        libraryButton.layer.borderColor = UIColor.white.cgColor
        libraryButton.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        libraryButton.setImage(UIImage(systemName: "photo.on.rectangle"), for: .normal)
        libraryButton.imageView?.contentMode = .scaleAspectFill
        libraryButton.addAction(UIAction { [weak self] _ in self?.pickFromLibrary() }, for: .touchUpInside)
        libraryButton.translatesAutoresizingMaskIntoConstraints = false

        // 下部説明
        let caption = UILabel()
        caption.text = "QRコードをスキャンして友だち追加などの機能を\n利用できます。"
        caption.numberOfLines = 0
        caption.textAlignment = .center
        caption.textColor = .white
        caption.font = .systemFont(ofSize: 16, weight: .medium)
        caption.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(myQRButton)
        view.addSubview(libraryButton)
        view.addSubview(caption)

        NSLayoutConstraint.activate([
            myQRButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            myQRButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -96),
            myQRButton.heightAnchor.constraint(equalToConstant: 44),
            myQRButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),

            libraryButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            libraryButton.bottomAnchor.constraint(equalTo: myQRButton.bottomAnchor),
            libraryButton.widthAnchor.constraint(equalToConstant: 56),
            libraryButton.heightAnchor.constraint(equalToConstant: 56),

            caption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            caption.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            caption.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
        ])
    }

    // サムネを最新画像で更新
    private func updateLibraryThumbnailIfPossible() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in
                DispatchQueue.main.async { self?.updateLibraryThumbnailIfPossible() }
            }
            return
        }
        guard status == .authorized || status == .limited else { return }

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = 1
        let assets = PHAsset.fetchAssets(with: .image, options: opts)
        guard let asset = assets.firstObject else { return }

        let manager = PHImageManager.default()
        let target = CGSize(width: 112, height: 112)
        let imgOpts = PHImageRequestOptions()
        imgOpts.deliveryMode = .opportunistic
        imgOpts.isSynchronous = false

        manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: imgOpts) { [weak self] image, _ in
            guard let image = image else { return }
            self?.libraryButton.setImage(nil, for: .normal)
            self?.libraryButton.setBackgroundImage(image, for: .normal)
        }
    }

    // スキャン結果
    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              obj.type == .qr,
              let payload = obj.stringValue else { return }
        session.stopRunning()
        handle(payload: payload)
    }

    // 画像から読む
    private func pickFromLibrary() {
        var conf = PHPickerConfiguration(photoLibrary: .shared())
        conf.filter = .images
        let picker = PHPickerViewController(configuration: conf)
        picker.delegate = self
        present(picker, animated: true)
    }
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        dismiss(animated: true)
        guard let item = results.first else { return }
        if item.itemProvider.canLoadObject(ofClass: UIImage.self) {
            item.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] obj, _ in
                guard let image = obj as? UIImage, let cg = image.cgImage else { return }
                let req = VNDetectBarcodesRequest { r, _ in
                    if let qr = (r.results as? [VNBarcodeObservation])?.first(where: { $0.symbology == .QR }),
                       let s = qr.payloadStringValue {
                        DispatchQueue.main.async { self?.handle(payload: s) }
                    }
                }
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                try? handler.perform([req])
            }
        }
    }

    // 自分自身の追加禁止チェックを含むハンドラ
    private func handle(payload: String) {
        guard let id = Self.extractID(from: payload) else {
            presentAlert(title: "QRを解析できません", message: payload)
            session.startRunning()
            return
        }
        isSelfID(id) { [weak self] isSelf in
            guard let self = self else { return }
            if isSelf {
                self.presentAlert(title: "追加できません", message: "自分自身を追加することはできません。")
                self.session.startRunning()
            } else {
                self.confirmAndSend(toID: id)
            }
        }
    }

    // 「@id」または「scheme://...?id=xxx」または生の id を受け付ける
    static func extractID(from s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@") { return String(trimmed.dropFirst()) }
        if let url = URL(string: trimmed),
           let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: {$0.name == "id"})?.value { return id }
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "._-"))
        return trimmed.rangeOfCharacter(from: allowed.inverted) == nil ? trimmed : nil
    }

    // 自分自身かどうか（uid または users/{uid}.id と一致なら true）
    private func isSelfID(_ id: String, completion: @escaping (Bool) -> Void) {
        guard let uid = Auth.auth().currentUser?.uid else { completion(false); return }
        if id == uid { completion(true); return }
        Firestore.firestore().collection("users").document(uid).getDocument { snap, _ in
            let myIdString = (snap?.data()?["id"] as? String) ?? ""
            completion(!myIdString.isEmpty && id == myIdString)
        }
    }

    private func confirmAndSend(toID id: String) {
        let ac = UIAlertController(title: "友だち申請", message: "@\(id) に申請を送りますか？", preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel, handler: { _ in
            self.session.startRunning()
        }))
        ac.addAction(UIAlertAction(title: "送信する", style: .default, handler: { _ in
            // 既存の検索→送信を利用
            FriendService.shared.searchUsers(keyword: "@\(id)") { result in
                switch result {
                case .failure(let err):
                    self.presentAlert(title: "検索に失敗", message: err.localizedDescription)
                    self.session.startRunning()
                case .success(let users):
                    guard let target = users.first else {
                        self.presentAlert(title: "ユーザーが見つかりません", message: "@\(id)")
                        self.session.startRunning()
                        return
                    }
                    // 念のためここでも自己チェック
                    if let uid = Auth.auth().currentUser?.uid, target.uid == uid {
                        self.presentAlert(title: "追加できません", message: "自分自身を追加することはできません。")
                        self.session.startRunning()
                        return
                    }
                    FriendService.shared.sendRequest(to: target) { r in
                        switch r {
                        case .failure(let err):
                            self.presentAlert(title: "申請に失敗しました", message: err.localizedDescription)
                            self.session.startRunning()
                        case .success:
                            self.presentAlert(title: "申請を送信しました", message: "@\(target.idString)")
                            self.onFoundID?(id)
                        }
                    }
                }
            }
        }))
        present(ac, animated: true)
    }

    private func presentErrorAndClose(_ msg: String) {
        presentAlert(title: "エラー", message: msg) { _ in self.dismiss(animated: true) }
    }
    private func presentAlert(title: String, message: String, completion: ((UIAlertAction)->Void)? = nil) {
        let ac = UIAlertController(title: title, message: message, preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "OK", style: .default, handler: completion))
        present(ac, animated: true)
    }

    private func showMyQR() {
        let vc = MyQRCodeViewController()
        navigationController?.pushViewController(vc, animated: true)
    }
}
