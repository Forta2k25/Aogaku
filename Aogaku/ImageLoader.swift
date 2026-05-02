import UIKit
import ObjectiveC
import ImageIO

final class ImageLoader {
    static let shared = ImageLoader()
    private init() {}

    // メモリキャッシュ
    private let cache = NSCache<NSString, UIImage>()

    // ディスクキャッシュ（アプリ再起動後も残る）
    private let fm = FileManager.default
    private lazy var diskCacheDir: URL = {
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ImageLoader", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func diskKey(for urlString: String) -> String {
        // URLをそのままファイル名に使えないので SHA-256 的に安全なhex文字列に変換
        var hash: UInt64 = 14695981039346656037
        for byte in urlString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(hash, radix: 16, uppercase: false) + ".jpg"
    }

    private func loadFromDisk(urlString: String) -> UIImage? {
        let file = diskCacheDir.appendingPathComponent(diskKey(for: urlString))
        guard let data = try? Data(contentsOf: file),
              let img = UIImage(data: data) else { return nil }
        cache.setObject(img, forKey: urlString as NSString) // 読み込んだらメモリにも
        return img
    }

    private func saveToDisk(_ img: UIImage, urlString: String) {
        let file = diskCacheDir.appendingPathComponent(diskKey(for: urlString))
        guard let data = img.jpegData(compressionQuality: 0.9) else { return }
        let tmp = file.appendingPathExtension("tmp")
        try? data.write(to: tmp, options: .atomic)
        try? fm.replaceItemAt(file, withItemAt: tmp)
    }

    // ネットワーク設定（タイムアウト/キャッシュポリシー）
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    // この imageView が今どのURLを待っているか
    private static var assocURLKey: UInt8 = 0
    // この imageView に紐づく進行中 task
    private static var assocTaskKey: UInt8 = 0

    /// 既存と同じシグネチャ（呼び出し側は変更不要）
    func load(urlString: String?, into imageView: UIImageView, placeholder: UIImage? = nil) {
        // placeholder は即反映（残像防止）
        if Thread.isMainThread {
            imageView.image = placeholder
        } else {
            DispatchQueue.main.async { imageView.image = placeholder }
        }

        guard let s = urlString, !s.isEmpty, let url = URL(string: s) else {
            // URLが無いなら関連付けもクリア
            objc_setAssociatedObject(imageView, &ImageLoader.assocURLKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            if let oldTask = objc_getAssociatedObject(imageView, &ImageLoader.assocTaskKey) as? URLSessionDataTask {
                oldTask.cancel()
            }
            objc_setAssociatedObject(imageView, &ImageLoader.assocTaskKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return
        }

        // ✅ ここが重要：キャッシュ判定より前に「今は s を待つ」を必ず記録
        objc_setAssociatedObject(imageView, &ImageLoader.assocURLKey, s, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // 進行中タスクがあればキャンセル
        if let oldTask = objc_getAssociatedObject(imageView, &ImageLoader.assocTaskKey) as? URLSessionDataTask {
            oldTask.cancel()
        }
        objc_setAssociatedObject(imageView, &ImageLoader.assocTaskKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // 1) メモリキャッシュ命中なら即反映
        if let cached = cache.object(forKey: s as NSString) {
            DispatchQueue.main.async { imageView.image = cached }
            return
        }

        // 2) ディスク確認 → なければネットワーク（バックグラウンドで一本化）
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak imageView] in
            guard let self, let imageView else { return }

            // ディスクキャッシュ命中
            if let disk = self.loadFromDisk(urlString: s) {
                let current = objc_getAssociatedObject(imageView, &ImageLoader.assocURLKey) as? String
                guard current == s else { return }
                DispatchQueue.main.async {
                    let current2 = objc_getAssociatedObject(imageView, &ImageLoader.assocURLKey) as? String
                    guard current2 == s else { return }
                    imageView.image = disk
                }
                return
            }

            // ── ディスクにも無い → ネットワーク ──
            let task = self.session.dataTask(with: url) { [weak self, weak imageView] data, _, error in
                guard let self, let imageView else { return }
                if let _ = error { return }
                guard let data, !data.isEmpty else { return }

                let target = CGSize(width: 120 * UIScreen.main.scale, height: 120 * UIScreen.main.scale)
                let img = Self.downsample(data: data, to: target) ?? UIImage(data: data)
                guard let img else { return }

                self.cache.setObject(img, forKey: s as NSString)
                self.saveToDisk(img, urlString: s)

                // まだ同じURLを待っている時だけセット（セル再利用対策）
                let current = objc_getAssociatedObject(imageView, &ImageLoader.assocURLKey) as? String
                guard current == s else { return }
                DispatchQueue.main.async {
                    let current2 = objc_getAssociatedObject(imageView, &ImageLoader.assocURLKey) as? String
                    guard current2 == s else { return }
                    imageView.image = img
                }
            }

            // task を関連付け（次回呼び出しでキャンセルできる）
            objc_setAssociatedObject(imageView, &ImageLoader.assocTaskKey, task, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            task.resume()
        }
    }

    private static func downsample(data: Data, to pointSize: CGSize) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let maxDimension = max(pointSize.width, pointSize.height)

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension)
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
