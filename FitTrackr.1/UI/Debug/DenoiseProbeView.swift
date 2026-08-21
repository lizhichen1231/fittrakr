#if DEBUG
// ═══════════════════════════════════════════════════════════════════════════
// 【降噪探针·待撤】真机时域降噪试验入口。★探针,不是功能。
//   全部代码在本文件;挂点两处(CameraScreen:TunerSheet 入口 / fullScreenCover)。
//   新 UI 开工时整体删除——移除自查:grep "降噪探针" 应零命中。登记:Docs/pending-removal.md。
// 链路:A·时域降噪(自写 Metal 内核,环形缓冲 4 前帧,逐像素运动阈值加权平均)
//       + 对齐:整帧全局位移估计(★全程 GPU:亮度 8 抽样 + SAD 全搜索 ±16 格 + CPU 抛物线亚格。
//         初版 CPU 估计在 Debug(-Onone)下单帧数百 ms → 预览 1fps,已迁 GPU 根修;
//         轨迹对齐不可用——逐帧裁剪位移未持久化,相册视频无绑定轨迹,见【真机降噪试验入口】卡·三)
//       B·空域降噪(CINoiseReduction,默认关,作补充/塑料感对照)
// 线程:预览处理在串行后台队列,忙时丢帧不堵主线程;完成标准 = Debug+Release 双 build 过。
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

// MARK: - 参数(UI 绑定)+ 处理快照(跨线程传值,不在后台读 @Published)

final class DenoiseParams: ObservableObject {
    static let shared = DenoiseParams()
    @Published var frameCount: Int = 5          // 参与帧数(含当前帧):3 或 5
    @Published var strength: Double = 0.8       // 时域强度:前帧权重(当前帧恒 1)
    @Published var motionThr: Double = 16       // 运动阈值(灰阶 0-255):亮度差超过则该像素不参与平均
    @Published var spatialOn = false            // B·空域(默认关)
    @Published var spatialLevel: Double = 0.03  // CINoiseReduction.noiseLevel
    @Published var bypass = false               // 长按看原图

    var snapshot: DenoiseSnapshot {
        DenoiseSnapshot(frameCount: frameCount, strength: Float(strength), motionThr: Float(motionThr),
                        spatialOn: spatialOn, spatialLevel: Float(spatialLevel), bypass: bypass)
    }
}

struct DenoiseSnapshot {
    var frameCount: Int
    var strength: Float
    var motionThr: Float
    var spatialOn: Bool
    var spatialLevel: Float
    var bypass: Bool
}

// MARK: - Metal 内核(运行时编译——单文件自足,不引 .metal 构建产物)

private let kKernelSrc = """
#include <metal_stdlib>
using namespace metal;

// ── 时域加权平均(逐像素运动否决)──
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

// ── 亮度 8 抽样(2×2 平均)→ 位移估计网格 ──
kernel void lumaDecim(texture2d<float, access::read> src [[texture(0)]],
                      device float* out [[buffer(0)]],
                      constant int2& gsz [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if ((int)gid.x >= gsz.x || (int)gid.y >= gsz.y) return;
    uint2 p = uint2(gid.x * 8 + 3, gid.y * 8 + 3);
    float3 m = (src.read(p).rgb + src.read(p + uint2(2, 0)).rgb
              + src.read(p + uint2(0, 2)).rgb + src.read(p + uint2(2, 2)).rgb) * 0.25;
    out[gid.y * gsz.x + gid.x] = dot(m, float3(0.299, 0.587, 0.114));
}

// ── SAD 全搜索:一线程一候选位移,prev[x+d] 对 cur[x],隔行采样 ──
kernel void sadSearch(device const float* prev [[buffer(0)]],
                      device const float* cur  [[buffer(1)]],
                      constant int4& g [[buffer(2)]],        // x=w y=h z=R
                      device float* sadOut [[buffer(3)]],
                      uint tid [[thread_position_in_grid]]) {
    int R = g.z, side = 2 * R + 1;
    if ((int)tid >= side * side) return;
    int dx = (int)(tid % side) - R, dy = (int)(tid / side) - R;
    int w = g.x, h = g.y;
    int x0 = max(0, -dx), x1 = min(w, w - dx);
    int y0 = max(0, -dy), y1 = min(h, h - dy);
    if (x1 - x0 < 8 || y1 - y0 < 8) { sadOut[tid] = 1e30; return; }
    float s = 0; int n = 0;
    for (int y = y0; y < y1; y += 2) {
        int pr = (y + dy) * w + dx, cr = y * w;
        for (int x = x0; x < x1; x++) s += fabs(prev[pr + x] - cur[cr + x]);
        n += x1 - x0;
    }
    sadOut[tid] = s / float(max(n, 1));
}
"""

private struct KernelUniforms {   // 与 Metal 端 U 逐字段对齐(48B:4+4+4+4pad+4×8)
    var count: Int32 = 0
    var strength: Float = 0
    var thr: Float = 0
    var pad: Float = 0
    var off = (SIMD2<Float>.zero, SIMD2<Float>.zero, SIMD2<Float>.zero, SIMD2<Float>.zero)
}

// MARK: - 时域降噪器(含 GPU 位移估计)

final class TemporalDenoiser {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let psDenoise: MTLComputePipelineState
    private let psLuma: MTLComputePipelineState
    private let psSad: MTLComputePipelineState
    private var texCache: CVMetalTextureCache?
    // 环形缓冲:私有纹理副本 + 各自累计位移
    private struct Entry { var tex: MTLTexture; var pan: SIMD2<Float> }
    private var ring: [Entry] = []
    private var runningPan = SIMD2<Float>.zero
    // 位移估计:双网格缓冲(prev/cur 交换)+ SAD 输出
    private let searchR = 16                        // ±16 格 × 8px = ±128px
    private var gridA: MTLBuffer?, gridB: MTLBuffer?
    private var sadBuf: MTLBuffer?
    private var curIsA = true
    private var havePrevGrid = false
    private var gw = 0, gh = 0
    private var outPool: CVPixelBufferPool?
    private var poolW = 0, poolH = 0
    private(set) var lastDisp = SIMD2<Float>.zero   // 屏显:最近一帧估计位移(px)

    init?() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(),
              let lib = try? d.makeLibrary(source: kKernelSrc, options: nil),
              let f1 = lib.makeFunction(name: "tdenoise"),
              let f2 = lib.makeFunction(name: "lumaDecim"),
              let f3 = lib.makeFunction(name: "sadSearch"),
              let p1 = try? d.makeComputePipelineState(function: f1),
              let p2 = try? d.makeComputePipelineState(function: f2),
              let p3 = try? d.makeComputePipelineState(function: f3) else { return nil }
        device = d; queue = q; psDenoise = p1; psLuma = p2; psSad = p3
        CVMetalTextureCacheCreate(nil, nil, d, nil, &texCache)
    }

    func reset() { ring.removeAll(); havePrevGrid = false; runningPan = .zero; lastDisp = .zero }

    private func metalTexture(_ pb: CVPixelBuffer) -> MTLTexture? {
        guard let cache = texCache else { return nil }
        var cvTex: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex)
        return cvTex.flatMap { CVMetalTextureGetTexture($0) }
    }

    private func ensureBuffers(w: Int, h: Int) {
        let nw = w / 8, nh = h / 8
        if nw != gw || nh != gh || gridA == nil {
            gw = nw; gh = nh
            gridA = device.makeBuffer(length: gw * gh * 4, options: .storageModeShared)
            gridB = device.makeBuffer(length: gw * gh * 4, options: .storageModeShared)
            let side = 2 * searchR + 1
            sadBuf = device.makeBuffer(length: side * side * 4, options: .storageModeShared)
            havePrevGrid = false
        }
        if w != poolW || h != poolH || outPool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            outPool = pool; poolW = w; poolH = h
        }
    }

    /// 步骤1(GPU):当前帧亮度网格 + 对上一帧网格 SAD 搜索 → 位移(px)。CPU 只做 1089 浮点 argmin+抛物线。
    private func estimateMotion(curTex: MTLTexture) -> SIMD2<Float>? {
        guard let ga = gridA, let gb = gridB, let sb = sadBuf,
              let cb = queue.makeCommandBuffer() else { return nil }
        let curGrid = curIsA ? ga : gb
        let prevGrid = curIsA ? gb : ga
        var gsz = SIMD2<Int32>(Int32(gw), Int32(gh))
        if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(psLuma)
            enc.setTexture(curTex, index: 0)
            enc.setBuffer(curGrid, offset: 0, index: 0)
            enc.setBytes(&gsz, length: MemoryLayout<SIMD2<Int32>>.stride, index: 1)
            let tg = MTLSize(width: 8, height: 8, depth: 1)
            enc.dispatchThreadgroups(MTLSize(width: (gw + 7) / 8, height: (gh + 7) / 8, depth: 1),
                                     threadsPerThreadgroup: tg)
            enc.endEncoding()
        }
        let side = 2 * searchR + 1
        if havePrevGrid, let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(psSad)
            enc.setBuffer(prevGrid, offset: 0, index: 0)
            enc.setBuffer(curGrid, offset: 0, index: 1)
            var g = SIMD4<Int32>(Int32(gw), Int32(gh), Int32(searchR), 0)
            enc.setBytes(&g, length: MemoryLayout<SIMD4<Int32>>.stride, index: 2)
            enc.setBuffer(sb, offset: 0, index: 3)
            enc.dispatchThreadgroups(MTLSize(width: (side * side + 63) / 64, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            enc.endEncoding()
        }
        cb.commit(); cb.waitUntilCompleted()
        defer { curIsA.toggle() }        // 本帧网格成为下一帧的 prev
        guard havePrevGrid else { havePrevGrid = true; return SIMD2<Float>.zero }
        // CPU:argmin + 抛物线亚格(1089 个浮点,-Onone 也无压力)
        let sad = sb.contents().bindMemory(to: Float.self, capacity: side * side)
        var bi = 0; var bv = Float.greatestFiniteMagnitude
        for i in 0..<(side * side) where sad[i] < bv { bv = sad[i]; bi = i }
        let bx = bi % side, by = bi / side
        func para(_ m: Float, _ c: Float, _ p: Float) -> Float {
            let den = m - 2 * c + p
            return den > 1e-6 ? max(-0.5, min(0.5, 0.5 * (m - p) / den)) : 0
        }
        var sx: Float = 0, sy: Float = 0
        if bx > 0 && bx < side - 1 { sx = para(sad[bi - 1], bv, sad[bi + 1]) }
        if by > 0 && by < side - 1 { sy = para(sad[bi - side], bv, sad[bi + side]) }
        return SIMD2<Float>((Float(bx - searchR) + sx) * 8, (Float(by - searchR) + sy) * 8)
    }

    /// 单帧处理:GPU 估位移 → 内核加权平均 → 当前帧入环。返回处理后 buffer(失败回原样)。
    func process(_ pb: CVPixelBuffer, snap: DenoiseSnapshot) -> CVPixelBuffer {
        guard let curTex = metalTexture(pb) else { return pb }
        let w = curTex.width, h = curTex.height
        ensureBuffers(w: w, h: h)
        if let d = estimateMotion(curTex: curTex), havePrevGrid {
            runningPan += d; lastDisp = d
        }
        var out: CVPixelBuffer?
        if let pool = outPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) }
        guard let outPB = out, let outTex = metalTexture(outPB),
              let cb = queue.makeCommandBuffer() else { return pb }
        // 【标签修复】输出补挂输入帧的色彩附件(Primaries/Transfer/Matrix 等)。
        // 池建的 buffer 无附件 → CI 按 sRGB 误读 709 内容 → 中调 −10% 的"变暗"(【降噪链亮度偏差】卡定量)。
        if let atts = CVBufferGetAttachments(pb, .shouldPropagate) {
            CVBufferSetAttachments(outPB, atts, .shouldPropagate)
        }

        let usable = Array(ring.suffix(min(snap.frameCount - 1, 4)))
        var u = KernelUniforms(count: Int32(usable.count), strength: snap.strength,
                               thr: snap.motionThr / 255.0, pad: 0)
        var offs = [SIMD2<Float>](repeating: .zero, count: 4)
        for (i, e) in usable.enumerated().prefix(4) { offs[i] = runningPan - e.pan }
        u.off = (offs[0], offs[1], offs[2], offs[3])

        if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(psDenoise)
            enc.setTexture(curTex, index: 0)
            for i in 0..<4 { enc.setTexture(i < usable.count ? usable[i].tex : curTex, index: 1 + i) }
            enc.setTexture(outTex, index: 5)
            enc.setBytes(&u, length: MemoryLayout<KernelUniforms>.stride, index: 0)
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            enc.dispatchThreadgroups(MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1),
                                     threadsPerThreadgroup: tg)
            enc.endEncoding()
        }
        // 当前帧拷贝入环(输入 buffer 会被播放器/reader 复用,必须留私有副本)
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
    // 【1fps 修】处理移出主线程:串行队列 + 忙时丢帧(display link 只取帧,不等处理)
    private let procQueue = DispatchQueue(label: "dnp.process", qos: .userInitiated)
    private var busy = false

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
        guard let out = videoOutput, !busy else { return }
        let t = out.itemTime(forHostTime: CACurrentMediaTime())
        guard out.hasNewPixelBuffer(forItemTime: t),
              let pb = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return }
        busy = true
        let snap = params.snapshot                  // 主线程取快照,后台不读 @Published
        procQueue.async { [weak self] in
            guard let self else { return }
            let processed: CVPixelBuffer
            if snap.bypass || self.denoiser == nil { processed = pb }
            else { processed = self.denoiser!.process(pb, snap: snap) }
            var img = CIImage(cvPixelBuffer: processed)
            if snap.spatialOn, !snap.bypass {
                let f = CIFilter.noiseReduction()
                f.inputImage = img; f.noiseLevel = snap.spatialLevel; f.sharpness = 0.4
                img = (f.outputImage ?? img).cropped(to: img.extent)
            }
            let disp = self.denoiser?.lastDisp ?? .zero
            DispatchQueue.main.async {
                self.renderer.image = img
                self.boundView?.setNeedsDisplay()
                let now = CACurrentMediaTime()
                self.fpsStamps.append(now); self.fpsStamps.removeAll { now - $0 > 1.0 }
                self.fpsText = "\(self.fpsStamps.count) fps"
                self.dispText = String(format: "(%.1f, %.1f)px", disp.x, disp.y)
                self.busy = false
            }
        }
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
        let snap = params.snapshot
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let t0 = CACurrentMediaTime()
            let result = Self.runExport(url: url, denoiser: den, snap: snap)
            let dt = CACurrentMediaTime() - t0
            DispatchQueue.main.async {
                guard let self else { return }
                self.exporting = false
                self.denoiser?.reset()
                self.player.play()                  // 导出完恢复预览
                switch result {
                case .failure(let msg):
                    self.status = "导出失败:\(msg)"
                case .success(let outURL, let durSec):
                    let perMin = durSec > 0 ? dt / (durSec / 60.0) : 0
                    let line = String(format: "🌨 降噪探针 导出 %.1fs(素材 %.1fs → %.0f 秒/分钟)N=%d s=%.2f thr=%.0f 空域=%@",
                                      dt, durSec, perMin, snap.frameCount, snap.strength, snap.motionThr,
                                      snap.spatialOn ? "开" : "关")
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

    private static func runExport(url: URL, denoiser: TemporalDenoiser, snap: DenoiseSnapshot) -> ExportResult {
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
            var outPB = denoiser.process(pb, snap: snap)
            if snap.spatialOn {
                let f = CIFilter.noiseReduction()
                f.inputImage = CIImage(cvPixelBuffer: outPB)
                f.noiseLevel = snap.spatialLevel; f.sharpness = 0.4
                if let img = f.outputImage, let pool = adaptor.pixelBufferPool {
                    var dst: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst)
                    if let d = dst {
                        // 【标签修复】同上:CI 目标 buffer 也补挂源附件
                        if let atts = CVBufferGetAttachments(outPB, .shouldPropagate) {
                            CVBufferSetAttachments(d, atts, .shouldPropagate)
                        }
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
