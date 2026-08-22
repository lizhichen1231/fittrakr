// 【新 UI·性能】图片管线 —— 下载一次 → 降采样到目标像素 → 缓存 UIImage。色彩原样。
// 【色差卡】CoreImage 调色已全删:CI 在线性空间做 saturation/brightness,与 CSS 的
// 非线性 sRGB 域数学不同 → 更亮更鲜艳的塑料感。设计稿滤镜改在 SwiftUI 层按数值实现
// (saturation 矩阵同 Rec.709;brightness 乘法用黑 overlay),见各使用处。
// 解码一律钉死 sRGB(不许按 P3 拉伸)。

import SwiftUI
import UIKit
import ImageIO

final class MTImageStore: ObservableObject {
    static let shared = MTImageStore()
    private var cache: [String: UIImage] = [:]        // 主线程读写
    private var inflight = Set<String>()
    private let workQ = DispatchQueue(label: "mt.imagestore", qos: .userInitiated)
    @Published private var generation = 0             // 新图就绪 → 观察方轻量重算

    func image(_ url: URL?, maxPixel: CGFloat) -> UIImage? {
        guard let url else { return nil }
        let key = url.absoluteString + "|\(Int(maxPixel))"
        if let hit = cache[key] { return hit }
        guard !inflight.contains(key) else { return nil }
        inflight.insert(key)
        workQ.async { [weak self] in
            guard let self else { return }
            var out: UIImage? = nil
            if let data = try? Data(contentsOf: url),
               let down = Self.downsample(data: data, maxPixel: maxPixel) {
                out = UIImage(cgImage: Self.forceSRGB(down))
            }
            DispatchQueue.main.async {
                self.inflight.remove(key)
                if let out { self.cache[key] = out; self.generation += 1 }
            }
        }
        return nil
    }

    /// ImageIO 降采样:解码即目标尺寸,不过全尺寸位图
    private static func downsample(data: Data, maxPixel: CGFloat) -> CGImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
        let opts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts)
    }

    /// 【色差卡3】钉死 sRGB:非 sRGB 空间(如 P3)的解码结果重绘进 sRGB 上下文
    private static func forceSRGB(_ cg: CGImage) -> CGImage {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        if let cs = cg.colorSpace, cs.name == CGColorSpace.sRGB { return cg }
        guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return cg }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return ctx.makeImage() ?? cg
    }
}

/// 缓存位图视图:命中即静态 Image(零滤镜零解码);未命中显示占位色并触发加载
struct MTCachedImage: View {
    @ObservedObject private var store = MTImageStore.shared
    let url: URL?
    let maxPixel: CGFloat
    var placeholder = Color(red: 0.078, green: 0.078, blue: 0.078)

    var body: some View {
        if let ui = store.image(url, maxPixel: maxPixel) {
            Image(uiImage: ui).resizable().scaledToFill()
        } else {
            placeholder
        }
    }
}


/// 【主题图】设计稿成品(Assets "MTThemeBG",烘焙自设计稿 CSS 滤镜链)。
/// 原样使用;仅当源像素超过屏幕时做一次性降采样(保色彩空间),结果缓存。
enum MTThemeArt {
    static let image: UIImage = {
        guard let src = UIImage(named: "MTThemeBG") else { return UIImage() }
        let scr = UIScreen.main.bounds.size
        let maxPix = max(scr.width, scr.height) * UIScreen.main.scale
        let srcPix = max(src.size.width, src.size.height) * src.scale
        guard srcPix > maxPix, let data = src.pngData(),
              let ds = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(ds, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPix,
              ] as CFDictionary)
        else { return src }
        return UIImage(cgImage: cg)
    }()
}
