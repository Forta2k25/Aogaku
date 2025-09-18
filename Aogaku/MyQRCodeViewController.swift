import UIKit
import FirebaseAuth
import FirebaseFirestore
import Photos

final class MyQRCodeViewController: UIViewController {
    private let imageView = UIImageView()
    private let label = UILabel()

    // 追加：ボタンUI
    private let saveButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let saveCaption = UILabel()
    private let shareCaption = UILabel()
    private let buttonsStack = UIStackView()        // 水平：保存 / 共有

    private var qrImage: UIImage?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "マイQRコード"

        // QR表示
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false

        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = .secondaryLabel

        view.addSubview(imageView)
        view.addSubview(label)

        // --- ナビバーの保存/共有は使わない（画面中央へ配置するため削除） ---

        // 保存/共有 ボタンUI（中央・大きめ・黒色＋下にラベル）
        configureActionButtons()

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -80),
            imageView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.6),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor),

            label.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            // ▼ ここを変更
            buttonsStack.topAnchor.constraint(greaterThanOrEqualTo: label.bottomAnchor, constant: 16),
            buttonsStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            buttonsStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            buttonsStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            buttonsStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -110) // ← 下に固定
        ])


        loadMyIDAndMakeQR()
    }

    private func configureActionButtons() {
        func makeIconButton(_ systemName: String, title: String, action: Selector) -> (UIButton, UILabel, UIStackView) {
            let btn = UIButton(type: .system)
            let cfg = UIImage.SymbolConfiguration(pointSize: 34, weight: .bold) // ← 大きめ
            btn.setImage(UIImage(systemName: systemName, withConfiguration: cfg), for: .normal)
            btn.tintColor = .black                                     // ← 黒アイコン
            btn.backgroundColor = .clear
            btn.addTarget(self, action: action, for: .touchUpInside)
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.widthAnchor.constraint(equalToConstant: 64).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 64).isActive = true

            let cap = UILabel()
            cap.text = title                                            // 「保存」/「共有」
            cap.textAlignment = .center
            cap.font = .systemFont(ofSize: 14, weight: .semibold)
            cap.textColor = .label

            let v = UIStackView(arrangedSubviews: [btn, cap])
            v.axis = .vertical
            v.alignment = .center
            v.spacing = 6
            return (btn, cap, v)
        }

        let (sBtn, sCap, sStack) = makeIconButton("square.and.arrow.down", title: "保存", action: #selector(saveToPhotos))
        let (shBtn, shCap, shStack) = makeIconButton("square.and.arrow.up", title: "共有", action: #selector(shareImage))
        saveButton.setImage(sBtn.image(for: .normal), for: .normal); saveButton.copy(from: sBtn)
        shareButton.setImage(shBtn.image(for: .normal), for: .normal); shareButton.copy(from: shBtn)
        saveCaption.text = sCap.text; shareCaption.text = shCap.text

        buttonsStack.axis = .horizontal
        buttonsStack.alignment = .center
        buttonsStack.distribution = .equalSpacing
        buttonsStack.spacing = 48
        buttonsStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(buttonsStack)
        buttonsStack.addArrangedSubview(sStack)
        buttonsStack.addArrangedSubview(shStack)
    }

    private func loadMyIDAndMakeQR() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        Firestore.firestore().collection("users").document(uid).getDocument { snap, _ in
            let idStr = (snap?.data()?["id"] as? String) ?? uid
            self.label.text = "@\(idStr)"
            self.qrImage = Self.generateQRCode(from: "@\(idStr)")
            self.imageView.image = self.qrImage
        }
    }

    static func generateQRCode(from string: String) -> UIImage? {
        let data = string.data(using: .utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return UIImage(ciImage: scaled)
    }

    // 画面上のQRだけを画像化（白余白付き）
    private func buildShareImage() -> UIImage? {
        guard let qr = qrImage else { return nil }
        let padding: CGFloat = 24
        let size = CGSize(width: qr.size.width + padding*2, height: qr.size.height + padding*2)
        UIGraphicsBeginImageContextWithOptions(size, true, 0)
        UIColor.white.setFill(); UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        qr.draw(in: CGRect(x: padding, y: padding, width: qr.size.width, height: qr.size.height))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }

    @objc private func saveToPhotos() {
        guard let image = buildShareImage() else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                guard status == .authorized || status == .limited else {
                    self.presentAlert(title: "保存できません", message: "写真へのアクセスを許可してください。")
                    return
                }
                UIImageWriteToSavedPhotosAlbum(image, self, #selector(self.didFinishSave(_:didFinishSavingWithError:contextInfo:)), nil)
            }
        }
    }
    @objc private func didFinishSave(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeMutableRawPointer?) {
        presentAlert(title: error == nil ? "保存しました" : "保存に失敗しました",
                     message: error?.localizedDescription ?? "")
    }

    @objc private func shareImage() {
        guard let image = buildShareImage() else { return }
        let vc = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        present(vc, animated: true)
    }

    private func presentAlert(title: String, message: String) {
        let ac = UIAlertController(title: title, message: message, preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "OK", style: .default))
        present(ac, animated: true)
    }
}

// UIButton設定をコピーする小ユーティリティ
private extension UIButton {
    func copy(from other: UIButton) {
        self.tintColor = other.tintColor
        self.backgroundColor = other.backgroundColor
        self.contentEdgeInsets = other.contentEdgeInsets
        self.configuration = other.configuration
        self.removeTarget(nil, action: nil, for: .allEvents)
        if let acts = other.actions(forTarget: other.allTargets.first, forControlEvent: .touchUpInside) {
            for a in acts { self.addTarget(other.allTargets.first, action: Selector(a), for: .touchUpInside) }
        }
    }
}
