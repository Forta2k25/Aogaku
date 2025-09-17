import UIKit

final class ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSString, UIImage>()
    private init() {}

    func load(urlString: String?, into imageView: UIImageView, placeholder: UIImage? = nil) {
        imageView.image = placeholder
        guard
            let s = urlString, !s.isEmpty,
            let url = URL(string: s)
        else { return }

        if let cached = cache.object(forKey: s as NSString) {
            imageView.image = cached
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data, let img = UIImage(data: data) else { return }
            self.cache.setObject(img, forKey: s as NSString)
            DispatchQueue.main.async { imageView.image = img }
        }.resume()
    }
}
