import UIKit
import FirebaseAuth
import FirebaseFirestore
import Photos

final class MyQRCodeViewController: UIViewController {
    private let imageView = UIImageView()
    private let label = UILabel()

    private var qrImage: UIImage?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "マイQRコード"

        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 16, weight: .medium)

        view.addSubview(imageView)
        view.addSubview(label)

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            imageView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.6),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor),

            label.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])

        // 保存 / 共有
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.down"),
            style: .plain,
            target: self,
            action: #selector(saveToPhotos)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.up"),
            style: .plain,
            target: self,
            action: #selector(shareImage)
        )

        loadMyIDAndMakeQR()
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
