#if DEBUG
// ═══════════════════════════════════════════════════════════════════════════
// 【画质探针·待撤】真机试验入口:锐化/去噪/局部对比对深裁素材的效果 + 导出耗时。
// ★探针,不是功能。全部代码在本文件;挂点仅两处(CameraScreen:TunerSheet 入口按钮 /
//   onAppear FTQ_BENCH 分流)。新 UI 开工时整体删除——移除自查:grep "画质探针" 应零命中。
//   登记:Docs/pending-removal.md。
// 处理链(导出真实路径,预览与导出共用同一 AVVideoComposition 构造):
//   CINoiseReduction → CISharpenLuminance(主力) → CIUnsharpMask(备选对照) → CIHighlightShadowAdjust
// 无头基准:环境变量 FTQ_BENCH=1 启动 → 不起相机,自动用 bundle 的 clip_1(1079×1920,60s)
//   跑吞吐(600帧 identity vs chain)+ 全片导出(identity vs chain),结果落 PerfFileLog(📽 行)。
// ═══════════════════════════════════════════════════════════════════════════

import SwiftUI
import AVFoundation
import AVKit
import CoreImage
import CoreImage.CIFilterBuiltins
import PhotosUI
import Photos
import UniformTypeIdentifiers

// MARK: - 参数(可开关 + 强度;bypass = 长按看原图)

final class QualityProbeParams: ObservableObject {
    static let shared = QualityProbeParams()   // 页面与模型共用;基准模式自建独立实例
    @Published var denoiseOn = true
    @Published var noiseLevel: Double = 0.02      // CINoiseReduction.noiseLevel
    @Published var denoiseSharp: Double = 0.40    // CINoiseReduction.sharpness
    @Published var sharpenOn = true
    @Published var slSharpness: Double = 0.60     // CISharpenLuminance.sharpness(主力)
    @Published var unsharpOn = false              // 备选对照,与 SL 二选一开
    @Published var usRadius: Double = 2.5
    @Published var usIntensity: Double = 0.5
    @Published var contrastOn = true
    @Published var shadowAmount: Double = 0.20    // CIHighlightShadowAdjust.shadowAmount(0=不动)
    @Published var highlightAmount: Double = 0.90 // 1=不动,<1 压高光
    @Published var bypass = false                 // 长按看原图

    var summary: String {
        String(format: "NR%@(%.3f/%.2f) SL%@(%.2f) US%@(r%.1f/i%.2f) HS%@(s%.2f/h%.2f)",
               denoiseOn ? "" : "×", noiseLevel, denoiseSharp,
               sharpenOn ? "" : "×", slSharpness,
               unsharpOn ? "" : "×", usRadius, usIntensity,
               contrastOn ? "" : "×", shadowAmount, highlightAmount)
    }

    /// 处理链本体(预览/导出/基准共用)。clamp 防滤镜采样边缘发黑,尾部裁回原 extent 保尺寸。
    func apply(to input: CIImage) -> CIImage {
        if bypass { return input }
        var img = input.clampedToExtent()
        if denoiseOn {
            let f = CIFilter.noiseReduction()
            f.inputImage = img; f.noiseLevel = Float(noiseLevel); f.sharpness = Float(denoiseSharp)
            img = f.outputImage ?? img
        }
        if sharpenOn {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = img; f.sharpness = Float(slSharpness)
            img = f.outputImage ?? img
        }
        if unsharpOn {
            let f = CIFilter.unsharpMask()
            f.inputImage = img; f.radius = Float(usRadius); f.intensity = Float(usIntensity)
            img = f.outputImage ?? img
        }
        if contrastOn {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = img; f.shadowAmount = Float(shadowAmount); f.highlightAmount = Float(highlightAmount)
            img = f.outputImage ?? img
        }
        return img.cropped(to: input.extent)
    }
}

// MARK: - 共用渲染件

enum QualityProbeRender {
    static let ctx = CIContext(options: [.cacheIntermediates: false])

    /// 预览与导出共用的合成(★同一路径,预览即导出画质)
    static func makeComposition(asset: AVAsset, params: QualityProbeParams,
                                onFrame: (() -> Void)? = nil) -> AVMutableVideoComposition {
        AVMutableVideoComposition(asset: asset) { request in
            onFrame?()
            request.finish(with: params.apply(to: request.sourceImage), context: ctx)
        }
    }

    static var bundledClipURL: URL? {
        Bundle.main.url(forResource: "clip_1_sameshirt_dancetrack0097", withExtension: "mp4",
                        subdirectory: "DebugReplayClips")
    }
}

// MARK: - 预览 FPS 计数(合成 handler 每帧 tick,滚动 1s 窗)

final class QualityProbeFPS {
    private var stamps: [CFTimeInterval] = []
    private let lock = NSLock()
    func tick() {
        lock.lock(); defer { lock.unlock() }
        let now = CACurrentMediaTime()
        stamps.append(now)
        stamps.removeAll { now - $0 > 1.0 }
    }
    var fps: Int { lock.lock(); defer { lock.unlock() }; return stamps.count }
}

// MARK: - 页面

struct QualityProbeView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var m = QualityProbeModel()
    @ObservedObject private var params = QualityProbeParams.shared

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                VideoPlayer(player: m.player)
                    .background(Color.black)
                Text(params.bypass ? "◀ 原图" : "处理后 ▶")
                    .font(.caption.bold()).padding(6)
                    .background(params.bypass ? Color.yellow : Color.green)
                    .foregroundColor(.black)
            }
            .frame(maxHeight: 380)

            HStack {
                Text("预览 \(m.fpsText)").font(.caption.monospaced())
                Spacer()
                Text(params.summary).font(.system(size: 9, design: .monospaced)).lineLimit(1)
            }.padding(.horizontal, 8)

            Text("按住看原图(松开回处理后)")
                .font(.callout.bold()).frame(maxWidth: .infinity).padding(8)
                .background(Color.gray.opacity(0.35)).cornerRadius(8)
                .onLongPressGesture(minimumDuration: .infinity,
                                    pressing: { m.setBypass($0) }, perform: {})
                .padding(.horizontal, 8)

            ScrollView {
                VStack(spacing: 4) {
                    row(on: $params.denoiseOn, "去噪 NR") {
                        slider("noise", $params.noiseLevel, 0...0.1)
                        slider("sharp", $params.denoiseSharp, 0...2)
                    }
                    row(on: $params.sharpenOn, "锐化 SL(主力)") {
                        slider("sharp", $params.slSharpness, 0...2)
                    }
                    row(on: $params.unsharpOn, "USM(备选对照)") {
                        slider("radius", $params.usRadius, 0...10)
                        slider("inten", $params.usIntensity, 0...2)
                    }
                    row(on: $params.contrastOn, "局部对比 HS") {
                        slider("shadow", $params.shadowAmount, 0...1)
                        slider("highl", $params.highlightAmount, 0.3...1)
                    }
                }.padding(.horizontal, 8)
            }

            HStack(spacing: 6) {
                Button("相册选视频") { m.showPicker = true }
                Button("用回放片") { m.loadBundledClip() }
                Button("导出到相册") { m.export() }.disabled(m.exporting)
                Button("关闭") { m.player.pause(); dismiss() }
            }.font(.footnote.bold()).buttonStyle(.bordered)

            Text(m.status).font(.caption2.monospaced()).lineLimit(3).padding(.bottom, 4)
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $m.showPicker) { QualityProbePicker { m.load(url: $0) } }
        .onAppear { m.startFPSTimer() }
        .onDisappear { m.stopFPSTimer() }
    }

    @ViewBuilder private func row(on: Binding<Bool>, _ title: String,
                                  @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 2) {
            Toggle(title, isOn: on).font(.footnote.bold())
            content()
        }
        .padding(6).background(Color.white.opacity(0.08)).cornerRadius(8)
    }

    @ViewBuilder private func slider(_ name: String, _ v: Binding<Double>,
                                     _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(name).font(.system(size: 10, design: .monospaced)).frame(width: 44, alignment: .leading)
            Slider(value: v, in: range)
            Text(String(format: "%.3f", v.wrappedValue))
                .font(.system(size: 10, design: .monospaced)).frame(width: 44, alignment: .trailing)
        }
    }
}

// MARK: - 模型

final class QualityProbeModel: ObservableObject {
    let params = QualityProbeParams.shared
    let player = AVPlayer()
    @Published var fpsText = "—"
    @Published var status = "未加载:先选相册视频或用回放片"
    @Published var showPicker = false
    @Published var exporting = false
    private let fpsCounter = QualityProbeFPS()
    private var timer: Timer?
    private var currentAsset: AVAsset?
    private var loopObs: NSObjectProtocol?

    func loadBundledClip() {
        guard let u = QualityProbeRender.bundledClipURL else { status = "bundle 无回放片"; return }
        load(url: u)
    }

    func load(url: URL) {
        let asset = AVAsset(url: url)
        currentAsset = asset
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = QualityProbeRender.makeComposition(asset: asset, params: params) { [weak self] in
            self?.fpsCounter.tick()
        }
        player.replaceCurrentItem(with: item)
        if let o = loopObs { NotificationCenter.default.removeObserver(o) }
        loopObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                         object: item, queue: .main) { [weak self] _ in
            self?.player.seek(to: .zero); self?.player.play()
        }
        player.play()
        status = "已加载:\(url.lastPathComponent)"
    }

    /// 暂停态下合成不重渲——bypass 切换时原地零容差 seek 强制重渲一帧
    func setBypass(_ on: Bool) {
        params.bypass = on
        if player.rate == 0 {
            let t = player.currentTime()
            player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func startFPSTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.fpsText = self.player.rate > 0 ? "\(self.fpsCounter.fps) fps" : "暂停"
        }
    }
    func stopFPSTimer() { timer?.invalidate(); timer = nil }

    func export() {
        guard let asset = currentAsset else { status = "先加载视频"; return }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            status = "ExportSession 创建失败"; return
        }
        exporting = true
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftq_export_\(Int(Date().timeIntervalSince1970)).mp4")
        session.outputURL = out
        session.outputFileType = .mp4
        session.videoComposition = QualityProbeRender.makeComposition(asset: asset, params: params)
        let t0 = CACurrentMediaTime()
        status = "导出中…"
        session.exportAsynchronously { [weak self] in
            let dt = CACurrentMediaTime() - t0
            DispatchQueue.main.async {
                guard let self else { return }
                self.exporting = false
                guard session.status == .completed else {
                    self.status = String(format: "导出失败 %.1fs:%@", dt, session.error?.localizedDescription ?? "?")
                    return
                }
                let msg = String(format: "📽 画质探针 导出完成 %.1fs 参数=%@", dt, self.params.summary)
                PerfFileLog.shared.line(msg); print(msg)
                self.status = String(format: "导出 %.1fs,存相册中…", dt)
                PHPhotoLibrary.requestAuthorization { s in
                    guard s == .authorized || s == .limited else {
                        DispatchQueue.main.async { self.status = "无相册权限(结果在临时目录)" }; return
                    }
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: out)
                    }) { ok, _ in
                        DispatchQueue.main.async {
                            self.status = String(format: "导出 %.1fs,%@ | %@", dt, ok ? "已存相册✓" : "存相册失败",
                                                 self.params.summary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - PHPicker(视频单选)

struct QualityProbePicker: UIViewControllerRepresentable {
    let onPicked: (URL) -> Void
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration()
        cfg.filter = .videos
        cfg.selectionLimit = 1
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
                // provider 的文件回调后即失效,拷到自己的临时目录
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ftq_pick_\(Int(Date().timeIntervalSince1970)).\(url.pathExtension)")
                try? FileManager.default.removeItem(at: dst)
                do {
                    try FileManager.default.copyItem(at: url, to: dst)
                    DispatchQueue.main.async { self.onPicked(dst) }
                } catch { print("画质探针:拷贝失败 \(error)") }
            }
        }
    }
}

// MARK: - 无头基准(FTQ_BENCH=1;不起相机,结果落 PerfFileLog 的 📽 行)

enum QualityProbeBench {
    static var benchMode: Bool { ProcessInfo.processInfo.environment["FTQ_BENCH"] == "1" }
    private static var ran = false

    static func runIfNeeded() {
        guard benchMode, !ran else { return }
        ran = true
        DispatchQueue.global(qos: .userInitiated).async { run() }
    }

    private static func log(_ s: String) { print(s); PerfFileLog.shared.line(s) }

    private static func run() {
        guard let url = QualityProbeRender.bundledClipURL else { log("📽 基准失败:bundle 无 clip_1"); return }
        let asset = AVAsset(url: url)
        let params = QualityProbeParams()   // 默认档
        let sz = asset.tracks(withMediaType: .video).first?.naturalSize ?? .zero
        log(String(format: "📽 画质基准 start clip_1(%.0fx%.0f, %.1fs) 参数=%@",
                   sz.width, sz.height, asset.duration.seconds, params.summary))

        if let t = throughput(asset: asset, params: nil) { log(String(format: "📽 吞吐 identity 600帧 %.2fs → %.1f fps(解码+渲染基线)", t.0, t.1)) }
        if let t = throughput(asset: asset, params: params) { log(String(format: "📽 吞吐 chain    600帧 %.2fs → %.1f fps(处理链全开)", t.0, t.1)) }

        let tId = exportSync(asset: asset, params: nil)
        log(tId >= 0 ? String(format: "📽 导出 identity 总耗时 %.1fs(%.1fx 实时)", tId, asset.duration.seconds / tId)
                     : "📽 导出 identity 失败")
        let tCh = exportSync(asset: asset, params: params)
        log(tCh >= 0 ? String(format: "📽 导出 chain    总耗时 %.1fs(%.1fx 实时)Δ=+%.1fs=处理链净成本", tCh, asset.duration.seconds / tCh, tCh - max(tId, 0))
                     : "📽 导出 chain 失败")
        log("📽 画质基准 DONE")
    }

    /// 吞吐:AVAssetReader 逐帧解码 → 处理链 → 渲到复用 CVPixelBuffer。params=nil 为 identity 基线。
    private static func throughput(asset: AVAsset, params: QualityProbeParams?, frames: Int = 600) -> (Double, Double)? {
        guard let track = asset.tracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings:
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out)
        guard reader.startReading() else { return nil }
        var dst: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(track.naturalSize.width), Int(track.naturalSize.height),
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &dst)
        guard let dstPB = dst else { return nil }
        var n = 0
        let t0 = CACurrentMediaTime()
        while n < frames, let sb = out.copyNextSampleBuffer() {
            guard let src = CMSampleBufferGetImageBuffer(sb) else { continue }
            var img = CIImage(cvPixelBuffer: src)
            if let p = params { img = p.apply(to: img) }
            QualityProbeRender.ctx.render(img, to: dstPB)
            n += 1
        }
        let dt = CACurrentMediaTime() - t0
        reader.cancelReading()
        return n > 0 ? (dt, Double(n) / dt) : nil
    }

    /// 同步导出计时。params=nil 为 identity(合成过但不处理,量出合成管线本底)。返回秒,失败 -1。
    private static func exportSync(asset: AVAsset, params: QualityProbeParams?) -> Double {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return -1 }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftq_bench_\(params == nil ? "id" : "ch").mp4")
        try? FileManager.default.removeItem(at: out)
        session.outputURL = out
        session.outputFileType = .mp4
        session.videoComposition = AVMutableVideoComposition(asset: asset) { request in
            if let p = params { request.finish(with: p.apply(to: request.sourceImage), context: QualityProbeRender.ctx) }
            else { request.finish(with: request.sourceImage, context: QualityProbeRender.ctx) }
        }
        let sem = DispatchSemaphore(value: 0)
        let t0 = CACurrentMediaTime()
        session.exportAsynchronously { sem.signal() }
        sem.wait()
        let dt = CACurrentMediaTime() - t0
        defer { try? FileManager.default.removeItem(at: out) }
        return session.status == .completed ? dt : -1
    }
}
#endif
