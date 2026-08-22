// 【新 UI·性能】图片管线 —— 下载一次 → 降采样到目标像素 → 调色烘焙 → 缓存 UIImage。
// 运行时只渲染现成位图(禁每帧滤镜/重解码;视差与漂移只动 transform)。
// 掉帧排查卡:主题图与卡片封面的每帧 saturation/colorMultiply 滤镜链是嫌疑项,烘焙后归零。

import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

enum MTTint {
    case none
    case card       // saturate(0.72) brightness(0.8)(卡封面/播放器;内容素材调色,非主题图)
}

final class MTImageStore: ObservableObject {
    static let shared = MTImageStore()
    private var cache: [String: UIImage] = [:]        // 主线程读写
    private var inflight = Set<String>()
    private let ciCtx = CIContext(options: [.cacheIntermediates: false])
    private let workQ = DispatchQueue(label: "mt.imagestore", qos: .userInitiated)
    @Published private var generation = 0             // 新图就绪 → 观察方轻量重算

    func image(_ url: URL?, maxPixel: CGFloat, tint: MTTint) -> UIImage? {
        guard let url else { return nil }
        let key = url.absoluteString + "|\(Int(maxPixel))|\(tint)"
        if let hit = cache[key] { return hit }
        guard !inflight.contains(key) else { return nil }
        inflight.insert(key)
        workQ.async { [weak self] in
            guard let self else { return }
            var out: UIImage? = nil
            if let data = try? Data(contentsOf: url),
               let down = Self.downsample(data: data, maxPixel: maxPixel) {
                out = self.bake(down, tint: tint)
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

    /// 调色一次性烘焙(替代运行时 SwiftUI 滤镜链)
    private func bake(_ cg: CGImage, tint: MTTint) -> UIImage {
        guard tint != .none else { return UIImage(cgImage: cg) }
        var img = CIImage(cgImage: cg)
        switch tint {
        case .card:
            let c = CIFilter.colorControls()
            c.inputImage = img; c.saturation = 0.72; c.brightness = -0.055
            img = c.outputImage ?? img
        case .none: break
        }
        guard let out = ciCtx.createCGImage(img, from: img.extent) else { return UIImage(cgImage: cg) }
        return UIImage(cgImage: out)
    }
}

/// 缓存位图视图:命中即静态 Image(零滤镜零解码);未命中显示占位色并触发加载
struct MTCachedImage: View {
    @ObservedObject private var store = MTImageStore.shared
    let url: URL?
    let maxPixel: CGFloat
    let tint: MTTint
    var placeholder = Color(red: 0.078, green: 0.078, blue: 0.078)

    var body: some View {
        if let ui = store.image(url, maxPixel: maxPixel, tint: tint) {
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
