#if DEBUG
// ═══════════════════════════════════════════════════════════════════════════
// 【降噪探针·待撤】真机时域降噪试验入口。★探针,不是功能。
//   全部代码在本文件;挂点两处(CameraScreen:TunerSheet 入口 / fullScreenCover)。
//   新 UI 开工时整体删除——移除自查:grep "降噪探针" 应零命中。登记:Docs/pending-removal.md。
// 链路:A·时域降噪(自写 Metal 内核,环形缓冲 4 前帧,逐像素运动阈值加权平均)
//       + 对齐:整帧全局位移估计(两级 SAD + 抛物线亚格;★轨迹对齐不可用——
//         逐帧裁剪位移未持久化,相册视频无绑定轨迹,见【真机降噪试验入口】卡·三)
//       B·空域降噪(CINoiseReduction,默认关,作补充/塑料感对照)
// 完成标准 = Debug+Release 双 build 过;真机效果 Zc 自验。
// ═══════════════════════════════════════════════════════════════════════════

import SwiftUI
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import MetalKit
import PhotosUI
import Photos
import UniformTypeIdentifiers

// MARK: - 参数

final class DenoiseParams: ObservableObject {
    static let shared = DenoiseParams()
    @Published var frameCount: Int = 5          // 参与帧数(含当前帧):3 或 5
    @Published var strength: Double = 0.8       // 时域强度:前帧权重(当前帧恒 1)
    @Published var motionThr: Double = 16       // 运动阈值(灰阶 0-255):亮度差超过则该像素不参与平均
    @Published var spatialOn = false            // B·空域(默认关)
    @Published var spatialLevel: Double = 0.03  // CINoiseReduction.noiseLevel
    @Published var bypass = false               // 长按看原图
}

// MARK: - 全局位移估计(两级 SAD;CPU,十六抽样粗搜 → 四抽样精搜 + 抛物线亚格)

struct LumaGrids {
    var g16: [Float]; var w16: Int; var h16: Int
    var g4: [Float];  var w4: Int;  var h4: Int
}

enum GlobalMotion {
    static func grids(from pb: CVPixelBuffer) -> LumaGrids? {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        func decimate(_ d: Int) -> ([Float], Int, Int) {
            let gw = w / d, gh = h / d
            var g = [Float](repeating: 0, count: gw * gh)
            for y in 0..<gh {
                let row = p + (y * d) * stride
                for x in 0..<gw {
                    let o = (x * d) * 4
                    // BGRA → 快速亮度 (b + 2g + r)/4
                    g[y * gw + x] = (Float(row[o]) + 2 * Float(row[o + 1]) + Float(row[o + 2])) * 0.25
                }
            }
            return (g, gw, gh)
        }
        let (a, aw, ah) = decimate(16)
        let (b, bw, bh) = decimate(4)
        return LumaGrids(g16: a, w16: aw, h16: ah, g4: b, w4: bw, h4: bh)
    }

    /// SAD:prev 平移 (dx,dy)(格单位)与 cur 重叠区平均绝对差
    private static func sad(_ prev: [Float], _ cur: [Float], _ w: Int, _ h: Int, _ dx: Int, _ dy: Int) -> Float {
        let x0 = max(0, -dx), x1 = min(w, w - dx)
        let y0 = max(0, -dy), y1 = min(h, h - dy)
        if x1 - x0 < 4 || y1 - y0 < 4 { return .greatestFiniteMagnitude }
        var s: Float = 0
        prev.withUnsafeBufferPointer { pp in cur.withUnsafeBufferPointer { cp in
            for y in y0..<y1 {
                let pr = (y + dy) * w + dx, cr = y * w
                for x in x0..<x1 { s += abs(pp[pr + x] - cp[cr + x]) }
            }
        }}
        return s / Float((x1 - x0) * (y1 - y0))
    }

    /// 返回:prev 中与 cur 对齐所需采样偏移(满分辨率像素):prev[x+off] ≈ cur[x]
    static func estimate(prev: LumaGrids, cur: LumaGrids) -> SIMD2<Float> {
        // 一级:16 抽样全搜索 ±8 格(±128px)
        var best: (d: (Int, Int), v: Float) = ((0, 0), .greatestFiniteMagnitude)
        for dy in -8...8 { for dx in -8...8 {
            let v = sad(prev.g16, cur.g16, prev.w16, prev.h16, dx, dy)
            if v < best.v { best = ((dx, dy), v) }
        }}
        // 二级:4 抽样围绕粗解 ±3 格精搜(粗格=4细格)
        let cx = best.d.0 * 4, cy = best.d.1 * 4
        var fine: (d: (Int, Int), v: Float) = ((cx, cy), .greatestFiniteMagnitude)
        var surface = [Int: Float]()   // 键 dx*1000+dy,抛物线用
        for dy in (cy - 3)...(cy + 3) { for dx in (cx - 3)...(cx + 3) {
            let v = sad(prev.g4, cur.g4, prev.w4, prev.h4, dx, dy)
            surface[dx * 1000 + dy] = v
            if v < fine.v { fine = ((dx, dy), v) }
        }}
        // 抛物线亚格 refine(各轴独立;邻点缺失则跳过)
        func para(_ vm: Float?, _ v0: Float, _ vp: Float?) -> Float {
            guard let a = vm, let b = vp else { return 0 }
            let den = a - 2 * v0 + b
            return den > 1e-6 ? max(-0.5, min(0.5, 0.5 * (a - b) / den)) : 0
        }
        let (fx, fy) = fine.d
        let sx = para(surface[(fx - 1) * 1000 + fy], fine.v, surface[(fx + 1) * 1000 + fy])
        let sy = para(surface[fx * 1000 + fy - 1], fine.v, surface[fx * 1000 + fy + 1])
        return SIMD2<Float>((Float(fx) + sx) * 4, (Float(fy) + sy) * 4)   // 4 抽样格 → 满分辨率 px
    }
}

// MARK: - 时域降噪核(Metal,运行时编译——单文件自足,不引 .metal 构建产物)

private let kKernelSrc = """
#include <metal_stdlib>
using namespace metal;
struct U { int count; float strength; float thr; float pad; float2 off[4]; };
kernel void tdenoise(texture2d<float, access::read>  cur  [[texture(0)]],
                     texture2d<float, access::sample> p0  [[texture(1)]],
                     texture2d<float, access::sample> p1  [[texture(2)]],
                     texture2d<float, access::sample> p2  [[texture(3)]],
                     texture2d<float, access::sample> p3  [[texture(4)]],
                     texture2d<float, access::write> outT [[texture(5)]],
                     constant U& u [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outT.get_width() || gid.y >= outT.get_height()) return;
    constexpr sampler smp(coord::pixel, address::clamp_to_edge, filter::linear);
    float4 c = cur.read(gid);
    float lc = dot(c.rgb, float3(0.299, 0.587, 0.114));
    float3 acc = c.rgb; float wsum = 1.0;
    for (int i = 0; i < u.count; i++) {
        float2 pos = float2(gid) + 0.5 + u.off[i];
        float4 p;
        if (i == 0) p = p0.sample(smp, pos);
        else if (i == 1) p = p1.sample(smp, pos);
        else if (i == 2) p = p2.sample(smp, pos);
        else p = p3.sample(smp, pos);
        float lp = dot(p.rgb, float3(0.299, 0.587, 0.114));
        float w = (fabs(lc - lp) < u.thr) ? u.strength : 0.0;   // 逐像素运动否决
        acc += p.rgb * w; wsum += w;
    }
    outT.write(float4(acc / wsum, c.a), gid);
}
"""

private struct KernelUniforms {   // 与 Metal 端 U 逐字段对齐(48B:4+4+4+4pad+4×8)
    var count: Int32 = 0
    var strength: Float = 0
    var thr: Float = 0
    var pad: Float = 0
    var off = (SIMD2<Float>.zero, SIMD2<Float>.zero, SIMD2<Float>.zero, SIMD2<Float>.zero)
}

final class TemporalDenoiser {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var texCache: CVMetalTextureCache?
    // 环形缓冲:私有纹理副本 + 各自累计位移 + 亮度网格(估计用)
    private struct Entry { var tex: MTLTexture; var pan: SIMD2<Float>; }
    private var ring: [Entry] = []
    private var lastGrids: LumaGrids?
    private var runningPan = SIMD2<Float>.zero
    private var outPool: CVPixelBufferPool?
    private var poolW = 0, poolH = 0
    private(set) var lastDisp = SIMD2<Float>.zero   // 屏显:最近一帧估计位移(px)

    init?() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(),
              let lib = try? d.makeLibrary(source: kKernelSrc, options: nil),
              let fn = lib.makeFunction(name: "tdenoise"),
              let ps = try? d.makeComputePipelineState(function: fn) else { return nil }
        device = d; queue = q; pipeline = ps
        CVMetalTextureCacheCreate(nil, nil, d, nil, &texCache)
    }

    func reset() { ring.removeAll(); lastGrids = nil; runningPan = .zero; lastDisp = .zero }

    private func metalTexture(_ pb: CVPixelBuffer) -> MTLTexture? {
        guard let cache = texCache else { return nil }
        var cvTex: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex)
        return cvTex.flatMap { CVMetalTextureGetTexture($0) }
    }

    private func makePool(w: Int, h: Int) {
        guard w != poolW || h != poolH || outPool == nil else { return }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        outPool = pool; poolW = w; poolH = h
    }

    /// 单帧处理:估计位移 → 内核加权平均 → 入环。返回处理后 buffer(失败回原样)。
    func process(_ pb: CVPixelBuffer, params: DenoiseParams) -> CVPixelBuffer {
        guard let curTex = metalTexture(pb), let grids = GlobalMotion.grids(from: pb) else { return pb }
        let w = curTex.width, h = curTex.height
        makePool(w: w, h: h)
        // 位移:cur vs 上一帧;环中各前帧偏移 = runningPan - entry.pan
        if let lg = lastGrids {
            let d = GlobalMotion.estimate(prev: lg, cur: grids)
            runningPan += d; lastDisp = d
        }
        lastGrids = grids
        var out: CVPixelBuffer?
        if let pool = outPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) }
        guard let outPB = out, let outTex = metalTexture(outPB),
              let cb = queue.makeCommandBuffer() else { return pb }

        let usable = Array(ring.suffix(min(params.frameCount - 1, 4)))
        var u = KernelUniforms(count: Int32(usable.count), strength: Float(params.strength),
                               thr: Float(params.motionThr) / 255.0, pad: 0)
        var offs = [SIMD2<Float>](repeating: .zero, count: 4)
        for (i, e) in usable.enumerated().prefix(4) { offs[i] = runningPan - e.pan }
        u.off = (offs[0], offs[1], offs[2], offs[3])

        if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(pipeline)
            enc.setTexture(curTex, index: 0)
            for i in 0..<4 { enc.setTexture(i < usable.count ? usable[i].tex : curTex, index: 1 + i) }
            enc.setTexture(outTex, index: 5)
            enc.setBytes(&u, length: MemoryLayout<KernelUniforms>.stride, index: 0)
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let grid = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)
            enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }
        // 当前帧拷贝入环(输入 buffer 会被播放器复用,必须留私有副本)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]; desc.storageMode = .private
        if let copy = device.makeTexture(descriptor: desc), let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: curTex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                      sourceSize: MTLSize(width: w, height: h, depth: 1),
                      to: copy, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
            blit.endEncoding()
            ring.append(Entry(tex: copy, pan: runningPan))
            if ring.count > 4 { ring.removeFirst(ring.count - 4) }
        }
        cb.commit(); cb.waitUntilCompleted()
        return outPB
    }
}

// MARK: - 预览渲染(MTKView + CIContext 直渲 drawable)

final class DenoisePreviewRenderer: NSObject, MTKViewDelegate {
    let device = MTLCreateSystemDefaultDevice()!
    lazy var queue = device.makeCommandQueue()!
    lazy var ciCtx = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    var image: CIImage?
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let img = image, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        let dw = CGFloat(drawable.texture.width), dh = CGFloat(drawable.texture.height)
        let s = min(dw / img.extent.width, dh / img.extent.height)
        let scaled = img.transformed(by: .init(scaleX: s, y: s))
            .transformed(by: .init(translationX: (dw - img.extent.width * s) / 2,
                                   y: (dh - img.extent.height * s) / 2))
        ciCtx.render(scaled, to: drawable.texture, commandBuffer: cb,
                     bounds: CGRect(x: 0, y: 0, width: dw, height: dh),
                     colorSpace: CGColorSpaceCreateDeviceRGB())
        cb.present(drawable); cb.commit()
    }
}

// MARK: - 模型

final class DenoiseProbeModel: NSObject, ObservableObject {
    let params = DenoiseParams.shared
    let renderer = DenoisePreviewRenderer()
    private let denoiser = TemporalDenoiser()
    private let player = AVPlayer()
    private var videoOutput: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private var loopObs: NSObjectProtocol?
    private var currentURL: URL?
    weak var boundView: MTKView?

    @Published var status = "未加载:先从相册选视频"
    @Published var fpsText = "—"
    @Published var dispText = "—"
    @Published var exporting = false
    @Published var showPicker = false
    private var fpsStamps: [CFTimeInterval] = []

    // MARK: 加载与预览

    func load(url: URL) {
        currentURL = url
        denoiser?.reset()
        let item = AVPlayerItem(url: url)
        let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                    kCVPixelBufferMetalCompatibilityKey as String: true]
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(out)
        videoOutput = out
        player.replaceCurrentItem(with: item)
        if let o = loopObs { NotificationCenter.default.removeObserver(o) }
        loopObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                         object: item, queue: .main) { [weak self] _ in
            self?.denoiser?.reset()
            self?.player.seek(to: .zero); self?.player.play()
        }
        if displayLink == nil {
            let dl = CADisplayLink(target: self, selector: #selector(tick))
            dl.add(to: .main, forMode: .common)
            displayLink = dl
        }
        player.play()
        status = "已加载:\(url.lastPathComponent)"
    }

    @objc private func tick() {
        guard let out = videoOutput else { return }
        let t = out.itemTime(forHostTime: CACurrentMediaTime())
        guard out.hasNewPixelBuffer(forItemTime: t),
              let pb = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return }
        let processed: CVPixelBuffer
        if params.bypass || denoiser == nil {
            processed = pb
        } else {
            processed = denoiser!.process(pb, params: params)
        }
        var img = CIImage(cvPixelBuffer: processed)
        if params.spatialOn, !params.bypass {
            let f = CIFilter.noiseReduction()
            f.inputImage = img; f.noiseLevel = Float(params.spatialLevel); f.sharpness = 0.4
            img = (f.outputImage ?? img).cropped(to: img.extent)
        }
        renderer.image = img
        boundView?.setNeedsDisplay()
        // FPS(滚动 1s)+ 位移读数
        let now = CACurrentMediaTime()
        fpsStamps.append(now); fpsStamps.removeAll { now - $0 > 1.0 }
        fpsText = "\(fpsStamps.count) fps"
        if let d = denoiser?.lastDisp { dispText = String(format: "(%.1f, %.1f)px", d.x, d.y) }
    }

    /// 长按 bypass:结束时清环重预热,避免陈旧帧错位入平均
    func setBypass(_ on: Bool) {
        params.bypass = on
        if !on { denoiser?.reset() }
    }

    func teardown() {
        player.pause()
        displayLink?.invalidate(); displayLink = nil
        if let o = loopObs { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: 导出(逐帧全处理,计时;不覆盖原片)

    func export() {
        guard let url = currentURL else { status = "先加载视频"; return }
        guard let den = denoiser else { status = "Metal 不可用"; return }
        exporting = true
        player.pause()
        status = "导出中…(全帧处理,与预览同链)"
        let p = params
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let t0 = CACurrentMediaTime()
            let result = Self.runExport(url: url, denoiser: den, params: p)
            let dt = CACurrentMediaTime() - t0
            DispatchQueue.main.async {
                guard let self else { return }
                self.exporting = false
                switch result {
                case .failure(let msg):
                    self.status = "导出失败:\(msg)"
                case .success(let outURL, let durSec):
                    let perMin = durSec > 0 ? dt / (durSec / 60.0) : 0
                    let line = String(format: "🌨 降噪探针 导出 %.1fs(素材 %.1fs → %.0f 秒/分钟)N=%d s=%.2f thr=%.0f 空域=%@",
                                      dt, durSec, perMin, p.frameCount, p.strength, p.motionThr, p.spatialOn ? "开" : "关")
                    PerfFileLog.shared.line(line); print(line)
                    self.status = String(format: "导出 %.1fs = %.0f 秒/分钟素材,存相册中…", dt, perMin)
                    PHPhotoLibrary.requestAuthorization { s in
                        guard s == .authorized || s == .limited else {
                            DispatchQueue.main.async { self.status += " 无相册权限" }; return
                        }
                        PHPhotoLibrary.shared().performChanges({
                            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outURL)
                        }) { ok, _ in
                            DispatchQueue.main.async {
                                self.status = String(format: "导出 %.1fs = %.0f 秒/分钟素材 | %@",
                                                     dt, perMin, ok ? "已存相册✓" : "存相册失败")
                            }
                        }
                    }
                }
            }
        }
    }

    private enum ExportResult { case success(URL, Double); case failure(String) }

    private static func runExport(url: URL, denoiser: TemporalDenoiser, params: DenoiseParams)
        -> ExportResult {
        let asset = AVAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return .failure("reader 创建失败") }
        let dur = asset.duration.seconds
        let rout = AVAssetReaderTrackOutput(track: track, outputSettings:
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
             kCVPixelBufferMetalCompatibilityKey as String: true])
        reader.add(rout)
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dnp_\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: outURL)
        guard let writer = try? AVAssetWriter(outputURL: outURL, fileType: .mp4) else { return .failure("writer 创建失败") }
        let sz = track.naturalSize
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(sz.width), AVVideoHeightKey: Int(sz.height)])
        vin.transform = track.preferredTransform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(sz.width), kCVPixelBufferHeightKey as String: Int(sz.height),
            kCVPixelBufferMetalCompatibilityKey as String: true])
        writer.add(vin)
        guard writer.startWriting(), reader.startReading() else { return .failure("start 失败") }
        writer.startSession(atSourceTime: .zero)
        denoiser.reset()
        let ciCtx = CIContext(options: [.cacheIntermediates: false])
        while let sb = rout.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            var outPB = denoiser.process(pb, params: params)
            if params.spatialOn {
                let f = CIFilter.noiseReduction()
                f.inputImage = CIImage(cvPixelBuffer: outPB)
                f.noiseLevel = Float(params.spatialLevel); f.sharpness = 0.4
                if let img = f.outputImage, let pool = adaptor.pixelBufferPool {
                    var dst: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst)
                    if let d = dst {
                        ciCtx.render(img.cropped(to: CIImage(cvPixelBuffer: outPB).extent), to: d)
                        outPB = d
                    }
                }
            }
            while !vin.isReadyForMoreMediaData { usleep(2000) }
            adaptor.append(outPB, withPresentationTime: pts)
        }
        vin.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        return writer.status == .completed ? .success(outURL, dur) : .failure(writer.error?.localizedDescription ?? "?")
    }
}

// MARK: - 页面(糙,按卡面零视觉投入)

struct DenoiseProbeView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var m = DenoiseProbeModel()
    @ObservedObject private var params = DenoiseParams.shared

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                DenoiseMTKBinder(m: m)
                    .background(Color.black)
                VStack(alignment: .leading, spacing: 2) {
                    Text("对齐=估计(整帧全局位移)——轨迹不可用")
                        .font(.caption2.bold()).foregroundColor(.orange)
                    Text("disp=\(m.dispText)  预览 \(m.fpsText)")
                        .font(.caption2.monospaced()).foregroundColor(.green)
                    Text(String(format: "N=%d  s=%.2f  thr=%.0f  空域=%@%@",
                                params.frameCount, params.strength, params.motionThr,
                                params.spatialOn ? "开" : "关",
                                params.bypass ? "  ◀原图" : ""))
                        .font(.caption2.monospaced()).foregroundColor(params.bypass ? .yellow : .white)
                }.padding(6).background(Color.black.opacity(0.5))
            }
            .frame(maxHeight: 420)

            Text("按住看原图(松开回处理后)")
                .font(.callout.bold()).frame(maxWidth: .infinity).padding(8)
                .background(Color.gray.opacity(0.35)).cornerRadius(8)
                .onLongPressGesture(minimumDuration: .infinity,
                                    pressing: { m.setBypass($0) }, perform: {})
                .padding(.horizontal, 8)

            ScrollView {
                VStack(spacing: 6) {
                    HStack {
                        Text("参与帧数").font(.footnote)
                        Picker("N", selection: $params.frameCount) {
                            Text("3").tag(3); Text("5").tag(5)
                        }.pickerStyle(.segmented)
                    }
                    slider("时域强度", $params.strength, 0...1, "%.2f")
                    slider("运动阈值", $params.motionThr, 4...48, "%.0f")
                    Toggle("空域 NR(补充/塑料感对照)", isOn: $params.spatialOn).font(.footnote)
                    if params.spatialOn { slider("空域强度", $params.spatialLevel, 0...0.10, "%.3f") }
                }.padding(.horizontal, 10)
            }

            HStack(spacing: 8) {
                Button("相册选视频") { m.showPicker = true }
                Button("导出到相册") { m.export() }.disabled(m.exporting)
                Button("关闭") { m.teardown(); dismiss() }
            }.font(.footnote.bold()).buttonStyle(.bordered)

            Text(m.status).font(.caption2.monospaced()).lineLimit(3).padding(.bottom, 4)
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $m.showPicker) { DenoisePicker { m.load(url: $0) } }
        .onDisappear { m.teardown() }
    }

    @ViewBuilder private func slider(_ name: String, _ v: Binding<Double>,
                                     _ r: ClosedRange<Double>, _ fmt: String) -> some View {
        HStack {
            Text(name).font(.caption).frame(width: 64, alignment: .leading)
            Slider(value: v, in: r)
            Text(String(format: fmt, v.wrappedValue))
                .font(.caption.monospaced()).frame(width: 46, alignment: .trailing)
        }
    }
}

/// MTKView 挂接:把创建的 view 绑回模型(setNeedsDisplay 驱动)
private struct DenoiseMTKBinder: UIViewRepresentable {
    let m: DenoiseProbeModel
    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: m.renderer.device)
        v.delegate = m.renderer
        v.framebufferOnly = false
        v.enableSetNeedsDisplay = true
        v.isPaused = true
        v.colorPixelFormat = .bgra8Unorm
        m.boundView = v
        return v
    }
    func updateUIView(_ v: MTKView, context: Context) {}
}

// MARK: - PHPicker(视频单选;独立副本,随本文件整体删除)

struct DenoisePicker: UIViewControllerRepresentable {
    let onPicked: (URL) -> Void
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration()
        cfg.filter = .videos; cfg.selectionLimit = 1
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: (URL) -> Void
        init(onPicked: @escaping (URL) -> Void) { self.onPicked = onPicked }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider else { return }
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                guard let url else { return }
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent("dnp_pick_\(Int(Date().timeIntervalSince1970)).\(url.pathExtension)")
                try? FileManager.default.removeItem(at: dst)
                do {
                    try FileManager.default.copyItem(at: url, to: dst)
                    DispatchQueue.main.async { self.onPicked(dst) }
                } catch { print("降噪探针:拷贝失败 \(error)") }
            }
        }
    }
}
#endif
