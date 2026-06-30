import Foundation
import AVFoundation
import CoreImage
import Combine
import UIKit

final class CameraViewModel: NSObject, ObservableObject {

    // 帧源:tracking 只依赖 FrameSource,不再直接依赖 AVCaptureSession。
    // 默认 LiveCameraSource(实时摄像头,行为同改造前);回放界面传入 VideoFileSource。
    private let source: FrameSource
    private let follow  = FollowEngine()
    private let recorder = AVWriterRecorder()
    private let gesture = GestureFactory.make()
    private let ciContext = CIContext()
    

    

    // æ˜¾ç¤º/å åŠ
    @Published var processedCGImage: CGImage?
    @Published var handLandmarks: [CGPoint] = []
    @Published var personBox: CGRect?
    @Published var isTracking = false
    @Published var trackingInfo: String = ""
    @Published var perfHUD: String = ""        // 性能 HUD：阶段耗时 + 实际 FPS
    private var perfFrame = 0

    // Debug overlay 总开关(默认关):眼睛图标切它;同时驱动 DebugOverlayView 与 CameraScreen 的死区显隐
    // 同时门控 tracking 的诊断行 format(关时热路径零开销)
    @Published var showDebugOverlay = false {
        didSet {
            follow.hudDebugEnabled = showDebugOverlay
            #if DEBUG
            FakePersonInjector.shared.enabled = showDebugOverlay   // 卡2:眼睛开关 = 假人注入开关
            #endif
        }
    }
    // 临时诊断 HUD 行(cx vs 几何):值来自 follow.dbgCropLine(computeFinalCropRect 本帧算出)
    @Published var dbgCropHUD = ""
    // 一次性捕获配置(format maxFPS vs 当前锁的 fps),来自 CameraEngine.dumpCaptureConfig
    @Published var captureConfigHUD = ""
    // 检测输入规格(wide/tele/Vision/out 尺寸),来自 follow.dbgDetSpec,仅尺寸变化时更新
    @Published var detSpecHUD = ""
    // slew 闸最近一次事件(SNAP/HIT),sticky,来自 follow.dbgSlewLine
    @Published var slewHUD = ""
    // 卡2 最简 HUD:候选人数 + 锁谁(细节看 console),来自 follow.dbgFakeHUD
    @Published var fakeHUD = ""
    // 卡3 最简 HUD:锁谁/状态/找回@,来自 follow.dbgTrkHUD
    @Published var trkHUD = ""
    // 跳变取证:冻结"最近一次显著跳变那一帧"的整行数据(poseValid/srcUsed/rectConf/各Δ)
    @Published var probeHUD = ""
    let probeJumpThreshold: CGFloat = 0.03   // anchorΔ 或 rectBoxΔ 超此(占画面宽 3%)算一次跳,刷新冻结行

    // 手势负载控制（调优阶段）：硬开关默认关闭，确保 MediaPipe 不进每帧预算；开启时也仅每 N 帧跑一次
    var gestureEnabled = false
    let gestureEveryN = 6
    private var gestureTick = 0

    #if DEBUG
    @Published var debugData: DebugData?
    private var debugFrameCounter = 0
    #endif

    //è°ƒå‚
    @Published var tunables: FollowEngine.Tunables
    @Published var deadZoneFraction: CGSize

    // æ‰‹åŠ¿è§¦å‘é…ç½®
    @Published var gestureMode: GestureTriggerMode = .off {   // 自检阶段先关掉手势，排除 MediaPipe 负载
        didSet { applyGestureConfig() }
    }
    @Published var gestureSampleEvery: Int = 3 {
        didSet { applyGestureConfig() }
    }

    // å½•åˆ¶/è°ƒè¯•
    @Published var hudText: String = "å¾…æœº"
    @Published var isRecording: Bool = false
    @Published var elapsed: TimeInterval = 0
    @Published var dbgText: String = ""

    // é”å®š
    @Published var hardLock: Bool = false {
        didSet { follow.setHardLockEnabled(hardLock) }
    }

    private let session = AVCaptureSession()
    // å…¬å¼€åªè¯»è®¿é—®ï¼Œä¾› UI ç»‘å®š/é¢„è§ˆå±‚ä½¿ç”¨
    var captureSession: AVCaptureSession { session }


    private var dbgFrames = 0
    private var dbgTick = Date()
    private var timer: AnyCancellable?

    private var videoSize: CGSize = .zero
    private var lastOutputSize: CGSize = .init(width: 1080, height: 1920)

    // æ‰‹åŠ¿ ROI å›žæ˜ å°„
    private var currentGestureRoiN: CGRect? = nil

    // æ‰‹éƒ¨å…³é"®ç‚¹ç¨³å®šå™¨
    private var lmPrev: [CGPoint]? = nil
    private var lmEMA: [CGPoint]?  = nil
    private let lmAlpha: CGFloat = 0.45
    private let lmJumpGate: CGFloat = 0.25
    private let lmPalmMin: CGFloat = 0.03
    private let lmPalmMax: CGFloat = 0.60

    // 目标锁定（录制开始时自动锁定）
    private var shouldLockTarget = false

    init(source: FrameSource = LiveCameraSource()) {
        // 帧源在 super.init 前先就位(非可选 let)。默认实时摄像头,回放界面传 VideoFileSource。
        self.source = source

        // 用临时引擎拿「应用预设后的」tunables，避免读到默认值
        let tmp = FollowEngine()
        tmp.applyPreset(.fitness)                 // 先上预设
        var t = tmp.getTunables()                 // 再取参数
        t.adaptiveEnabled = true

        // 在 super.init() 之前把存储属性初始化完整
        self.tunables = t
        self.deadZoneFraction = CGSize(width: t.deadZoneW, height: t.deadZoneH)

        super.init()

        // 帧/音频回调接到原来的处理逻辑上(等价于过去的 CameraEngineDelegate)
        source.onFrame = { [weak self] wide, tele, pts in
            self?.handleFrame(wide: wide, telephoto: tele, pts: pts)
        }
        source.onAudio = { [weak self] sb in
            self?.handleAudio(sb)
        }

        // 配置实际工作的 follow 引擎
        follow.applyPreset(.fitness)
        follow.updateTunables(tunables)

       
    


        // æ‰‹éƒ¨å…³é”®ç‚¹å›žè°ƒ â†’ ROI æ˜ å°„ â†’ ç¨³å®šåŒ– â†’ å‘å¸ƒ
        gesture.setLandmarks { [weak self] pts in
            guard let self = self else { return }
            let roi = self.currentGestureRoiN
            let mapped: [CGPoint] = pts.map { p in
                if let r = roi {
                    return CGPoint(x: r.minX + p.x * r.width,
                                   y: r.minY + p.y * r.height)
                } else { return p }
            }
            let stable = self.stabilizeLandmarks(mapped)
            DispatchQueue.main.async { self.handLandmarks = stable }
        }
        applyGestureConfig()
    }

    // MARK: - æŽ§åˆ¶
    func start() { source.start() }   // 实时专属配置(useUltraWideWithGDC)已收进 LiveCameraSource
    func stop()  { source.stop(); stopTimer() }
    func toggleRecord() { isRecording ? stopRecord() : startRecord() }
    func toggleLock() { hardLock.toggle() }

    private func startRecord() {
        guard processedCGImage != nil || videoSize != .zero else { return }
        recorder.start(size: lastOutputSize)
        isRecording = true
        shouldLockTarget = true  // 下一帧自动锁定目标
        startTimer()
    }
    private func stopRecord() {
        isRecording = false
        stopTimer()
        PersonIdentifier.shared.unlock()  // 解除目标锁定
        recorder.stopAndSave { ok in
            DispatchQueue.main.async { self.hudText = ok ? "å·²ä¿å­˜åˆ°ç›¸å†Œ" : "ä¿å­˜å¤±è´¥" }
        }
    }

    private func startTimer() {
        elapsed = 0
        timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.elapsed += 0.2 }
    }
    private func stopTimer() { timer?.cancel(); timer = nil }

    func updateOutputSize(for viewSize: CGSize) {
        guard !isRecording else { return }
        let s = UIScreen.main.scale
        let outW = Int((viewSize.width  * s).rounded())  & ~1
        let outH = Int((viewSize.height * s).rounded()) & ~1
        let size = CGSize(width: outW, height: outH)
        lastOutputSize = size
        follow.setOutputSize(size)
    }

    func applyTunables() {
        follow.updateTunables(tunables)
        deadZoneFraction = CGSize(width: tunables.deadZoneW, height: tunables.deadZoneH)
    }

    func applyGestureConfig() {
        gesture.setMode(gestureMode)
        gesture.setSampleInterval(gestureSampleEvery)
    }

    // MARK: - ROI å€™é€‰ï¼ˆäººæ¡†ä¸¤ä¾§ï¼‰
    private func candidateGestureROIs(from boxN: CGRect) -> [CGRect] {
        let w = boxN.width, h = boxN.height
        guard w > 0.02, h > 0.04 else { return [] }
        let roiW = min(0.36, w * 0.55)
        let roiH = min(0.40, h * 0.85)
        let cy   = clamp(boxN.midY - h*0.05, 0.0, 1.0)
        let rightCx = min(1 - roiW/2, boxN.maxX + w*0.18)
        let leftCx  = max(roiW/2, boxN.minX - w*0.18)
        let right = CGRect(x: rightCx - roiW/2, y: cy - roiH/2, width: roiW, height: roiH).clampedUnit()
        let left  = CGRect(x: leftCx  - roiW/2, y: cy - roiH/2, width: roiW, height: roiH).clampedUnit()
        return [right, left]
    }

    private func makePixelBuffer(from ciFull: CIImage, roiN: CGRect, targetSize: CGSize = CGSize(width: 224, height: 224)) -> CVPixelBuffer? {
        let W = ciFull.extent.width, H = ciFull.extent.height
        let cropPx = CGRect(x: roiN.minX*W, y: (1 - roiN.maxY)*H, width: max(2, roiN.width*W), height: max(2, roiN.height*H)).integral
        let cropped = ciFull.cropped(to: cropPx)
        let sx = targetSize.width  / max(1, cropPx.width)
        let sy = targetSize.height / max(1, cropPx.height)
        let scaled = cropped.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(targetSize.width), Int(targetSize.height),
                                  kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        ciContext.render(scaled, to: buf)
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    private func clamp<T: Comparable>(_ v: T,_ a: T,_ b: T) -> T { max(a, min(b, v)) }

    // æ‰‹éƒ¨å…³é”®ç‚¹ç¨³å®šåŒ–
    private func stabilizeLandmarks(_ pts: [CGPoint]) -> [CGPoint] {
        guard pts.count >= 21 else { lmPrev = nil; lmEMA = nil; return [] }
        
        if let prev = lmPrev, prev.count == pts.count {
                let palmJump = hypot(pts[0].x - prev[0].x, pts[0].y - prev[0].y)
                
                // 如果手掌跳变超过屏幕的30%，认为是切换手
                if palmJump > 0.1 {
                    // 重置稳定化，避免错误的插值
                    lmPrev = pts
                    lmEMA = pts
                    return pts  // 第一帧直接返回，不做平滑
                }
            }

        let palm = hypot(pts[0].x - pts[9].x, pts[0].y - pts[9].y)
        guard palm >= lmPalmMin, palm <= lmPalmMax else { lmPrev = nil; lmEMA = nil; return [] }

        if let prev = lmPrev, prev.count == pts.count {
            let idxs = [0,5,9,13,17,8,12,16,20]
            var acc: CGFloat = 0
            for i in idxs {
                acc += max(abs(pts[i].x - prev[i].x), abs(pts[i].y - prev[i].y))
            }
            if acc / CGFloat(idxs.count) > lmJumpGate {
                lmPrev = pts
                return []
            }
        }

        if var ema = lmEMA, ema.count == pts.count {
            for i in 0..<pts.count {
                ema[i].x = lmAlpha*pts[i].x + (1-lmAlpha)*ema[i].x
                ema[i].y = lmAlpha*pts[i].y + (1-lmAlpha)*ema[i].y
            }
            lmEMA = ema
        } else {
            lmEMA = pts
        }

        lmPrev = pts
        return lmEMA ?? pts
    }
}

private extension CGRect {
    func clampedUnit() -> CGRect {
        var r = self
        if r.minX < 0 { r.origin.x = 0 }
        if r.minY < 0 { r.origin.y = 0 }
        if r.maxX > 1 { r.origin.x = 1 - r.width }
        if r.maxY > 1 { r.origin.y = 1 - r.height }
        return r
    }
}

extension CameraViewModel {
    // tracking 入口:由 FrameSource.onFrame 驱动(过去是 CameraEngineDelegate)。逻辑保持不变。
    func handleFrame(wide wideFrame: CVPixelBuffer,
                     telephoto telephotoFrame: CVPixelBuffer?,
                     pts: CMTime) {
        // 0) 获取髋部数据并传给 FollowEngine
        let hipData = SkeletonAddon.shared.getHipData()
        follow.updateHipCenter(hipData.center, confidence: hipData.confidence)

        // 0.5) 录制开始时自动锁定目标
        if shouldLockTarget {
            shouldLockTarget = false
            let sensorSize = CGSize(
                width: CGFloat(CVPixelBufferGetWidth(wideFrame)),
                height: CGFloat(CVPixelBufferGetHeight(wideFrame))
            )
            if PersonIdentifier.shared.lockLargest(in: wideFrame, sensorSize: sensorSize) {
                print("🎯 录制开始，已锁定目标")
            } else {
                print("⚠️ 录制开始，未检测到目标")
            }
        }

        // 阶段计时（ms）
        let _tFrame = CACurrentMediaTime()

        // 1) 跟随主流程（双帧：广角检测 + 长焦渲染）
        let result = follow.process(wideFrame: wideFrame, telephotoFrame: telephotoFrame, pts: pts)

        // 2) 同步跑骨架（复用主检测 pose，去重，不再自己跑 Vision）
        let _tSkel = CACurrentMediaTime()
        SkeletonAddon.shared.process(pixelBuffer: wideFrame,
                                     orientation: .up,
                                     pts: pts,
                                     follow: result,
                                     pose: follow.lastPoseObservation)
        let msSkel = (CACurrentMediaTime() - _tSkel) * 1000

        // 3) 手势识别 —— 调优阶段默认关闭（gestureEnabled=false），排除 MediaPipe 负载；开启时每 N 帧才跑一次
        let _tGest = CACurrentMediaTime()
        gestureTick &+= 1
        if gestureEnabled, gestureMode != .off, gestureTick % gestureEveryN == 0, let ci = result.ciScaled {
            var decided: GestureDecision = .none

            // 修正：> 1 永远为假，改为 > 0.5
            let rois: [CGRect] = (result.confidence > 0.5 && self.personBox != nil)
                ? candidateGestureROIs(from: self.personBox!)
                : []

            // 限制最多 2 个 ROI
            for roi in rois.prefix(2) {
                if let pbRoi = makePixelBuffer(from: ci, roiN: roi, targetSize: CGSize(width: 224, height: 224)) {
                    self.currentGestureRoiN = roi
                    let d = gesture.process(pbRoi, nil)
                    if d != .none { decided = d; break }
                }
            }

            self.currentGestureRoiN = nil

            // 兜底：全帧
            if decided == .none,
               let pbFull = makePixelBuffer(from: ci,
                                            roiN: CGRect(x: 0, y: 0, width: 1, height: 1),
                                            targetSize: CGSize(width: 224, height: 224)) {
                decided = gesture.process(pbFull, nil)
            }

            switch decided {
            case .start: if !isRecording { blinkTorch(); toggleRecord() }
            case .stop:  if  isRecording { blinkTorch(); toggleRecord() }
            case .none:  break
            }
        }
        let msGest = (CACurrentMediaTime() - _tGest) * 1000
        let msTotal = (CACurrentMediaTime() - _tFrame) * 1000
        let _cf = String(format: "sh %.2f/%.2f hp %.2f/%.2f",
                         Double(follow.dbgCfLsh), Double(follow.dbgCfRsh),
                         Double(follow.dbgCfLhp), Double(follow.dbgCfRhp))
        let _perf = String(format: "FPS %.0f · dt %.0f · rect %.0f pose %.0f skel %.0f gest %.0f rend %.0f · tot %.0f ms",
                           result.fps, follow.dbgRawDtMs, result.msRect, result.msPose, msSkel, msGest, result.msRender, msTotal)
            + " · cf " + _cf + " · " + (follow.dbgZoomSrc.isEmpty ? "—" : follow.dbgZoomSrc)
        perfFrame += 1
        if perfFrame % 30 == 0 { print("⏱ " + _perf) }

        // 跳变取证:每帧拼一行(poseValid/srcUsed/rectConf/各Δ),console 每帧 print + 最大跳帧冻进 HUD
        var _lockSummary = ""
        #if DEBUG
        let _sensorSize = CGSize(width: CVPixelBufferGetWidth(wideFrame), height: CVPixelBufferGetHeight(wideFrame))
        _lockSummary = PersonIdentifier.shared.dbgLockSummary(sensorSize: _sensorSize)
        #endif
        let _probe = String(format: "PROBE t=%.2f f=%d poseValid=%@ srcUsed=%@ rectConf=%.2f anchorΔ=%.3f ratioΔ=%.3f rectBoxΔ=%.3f | %@",
                            pts.seconds, follow.frameCount,
                            follow.dbgPoseValid ? "T" : "F",
                            follow.dbgZoomSrc.isEmpty ? "—" : follow.dbgZoomSrc,
                            Double(follow.dbgRectConf), Double(follow.dbgAnchorDelta),
                            Double(follow.dbgRatioDelta), Double(follow.dbgRectBoxDelta),
                            _lockSummary)
        print(_probe)
        let _probeJump = max(follow.dbgAnchorDelta, follow.dbgRectBoxDelta)

        // 4) UI / 录制
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.perfHUD = _perf
            if _probeJump > self.probeJumpThreshold {   // 最近一次显著跳变那一帧,冻结给真机直接读
                self.probeHUD = _probe
            }
            // 一次性:捕获配置就绪后填一次(静态量,启动后几帧内可用)
            if self.captureConfigHUD.isEmpty, !CameraEngine.lastCaptureConfig.isEmpty {
                self.captureConfigHUD = CameraEngine.lastCaptureConfig
            }
            if self.detSpecHUD != self.follow.dbgDetSpec { self.detSpecHUD = self.follow.dbgDetSpec }
            if self.slewHUD != self.follow.dbgSlewLine { self.slewHUD = self.follow.dbgSlewLine }
            if self.fakeHUD != self.follow.dbgFakeHUD { self.fakeHUD = self.follow.dbgFakeHUD }
            if self.trkHUD != self.follow.dbgTrkHUD { self.trkHUD = self.follow.dbgTrkHUD }
            if self.showDebugOverlay { self.dbgCropHUD = self.follow.dbgCropLine }   // 关时不更新,省 @Published churn
            self.isTracking = result.confidence > 0.5
            self.trackingInfo = self.isTracking
                ? String(format: "追踪中 %.0f%%  |  缩放 %.2fx", result.confidence * 100, result.zoom)
                : "搜索目标…"

            if let cg = result.previewCG { self.processedCGImage = cg }
            
            let crop = result.cropRect
            if let sb = result.stableBox, crop.width > 0, crop.height > 0 {
                self.personBox = CGRect(
                    x: (sb.minX - crop.minX)/crop.width,
                    y: (sb.minY - crop.minY)/crop.height,
                    width:  sb.width / crop.width,
                    height: sb.height / crop.height
                )
            } else {
                self.personBox = nil
            }

            #if DEBUG
            // 每 3 帧更新一次 debugData，减少主线程压力
            self.debugFrameCounter += 1
            if self.debugFrameCounter % 3 == 0 {
                self.debugData = self.follow.getDebugData(fps: CGFloat(result.fps))
            }
            #endif

            if self.isRecording, let ci = result.ciScaled {
                self.recorder.appendVideo(ciImage: ci, at: result.pts)
            }
        }
    }

    func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        if isRecording { recorder.appendAudio(sampleBuffer) }
    }
}



    private func blinkTorch() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            try device.setTorchModeOn(level: 1.0)
            device.unlockForConfiguration()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.18) {
                do {
                    try device.lockForConfiguration(); device.torchMode = .off; device.unlockForConfiguration()
                } catch { }
            }
        } catch { }
    }






