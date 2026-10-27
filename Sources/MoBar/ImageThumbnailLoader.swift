import AppKit
import ImageIO

/// 剪贴板图片缩略图专用加载与缓存器。
/// 使用 CGImageSource 下采样（downsampling）直接在解码阶段按需缩放，
/// 避免将数十兆的原始大图完整载入内存，且在后台线程异步生成。
final class ImageThumbnailLoader {
    static let shared = ImageThumbnailLoader()

    private let cache = NSCache<NSURL, NSImage>()

    init() {
        cache.countLimit = 150
        cache.totalCostLimit = 25 * 1024 * 1024 // 25 MB 上限
    }

    func cachedThumbnail(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func removeCachedThumbnail(for url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }

    func loadThumbnail(for url: URL, targetPixelSize: CGFloat, completion: @escaping (NSImage?) -> Void) {
        if let cached = cache.object(forKey: url as NSURL) {
            completion(cached)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(targetPixelSize)
            ]

            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let size = NSSize(width: CGFloat(cgImage.width) / 2.0, height: CGFloat(cgImage.height) / 2.0)
            let image = NSImage(cgImage: cgImage, size: size)
            let cost = cgImage.width * cgImage.height * 4

            self?.cache.setObject(image, forKey: url as NSURL, cost: cost)

            DispatchQueue.main.async {
                completion(image)
            }
        }
    }
}
