import UIKit
import ObjectiveC

final class ImageLoader {
    static let shared = ImageLoader()
    private init() {}

    // メモリキャッシュ
    private let cache = NSCache<NSString, UIImage>()

    // ネットワーク設定（タイムアウト/キャッシュポリシー）
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    // この imageView が今どのURLを待っているかを関連付けるキー
    private static var assocKey: UInt8 = 0

    // 既存と同じシグネチャ
    func load(urlString: String?, into imageView: UIImageView, placeholder: UIImage? = nil) {
        // 先にプレースホルダーをメインスレッドで反映
        DispatchQueue.main.async { imageView.image = placeholder }

        guard let s = urlString, !s.isEmpty, let url = URL(string: s) else { return }

        // キャッシュ命中なら即反映
        if let cached = cache.object(forKey: s as NSString) {
            DispatchQueue.main.async { imageView.image = cached }
            return
        }

        // これからこの imageView は s を待つ、と記録（セル再利用対策）
        objc_setAssociatedObject(imageView, &ImageLoader.assocKey, s, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // ダウンロード
        session.dataTask(with: url) { [weak self, weak imageView] data, _, error in
            guard let self = self, let imageView = imageView else { return }
            if let error = error {
                print("ImageLoader error:", error.localizedDescription)
                return
            }
            guard let data = data, let img = UIImage(data: data) else {
                print("ImageLoader decode failed for:", s)
                return
            }

            self.cache.setObject(img, forKey: s as NSString)

            // まだ同じURLを待っている時だけセット（セル再利用対策）
            let current = objc_getAssociatedObject(imageView, &ImageLoader.assocKey) as? String
            guard current == s else { return }

            DispatchQueue.main.async { imageView.image = img }
        }.resume()
    }
}
