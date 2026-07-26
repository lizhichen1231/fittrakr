import Foundation
import AVFoundation
import CoreImage
import Combine
import UIKit
import Vision

final class CameraViewModel: NSObject, ObservableObject {

    // 帧源:tracking 只依赖 FrameSource,不再直接依赖 AVCaptureSession。
    // 默认 LiveCameraSource(实时摄像头,行为同改造前);回放界面传入 VideoFileSource。
    private let source: FrameSource
    private let follow  = FollowEngine()
    private let recorder = AVWriterRecorder()
    private let gesture = GestureFactory.make()
    private let ciContext = CIContext()
    

    

    // æ˜¾ç¤º/å åŠ
    @Published var processedCGImage: CGImage?          // 刀2 兜底路径(池失败时)
    @Published var processedPB: CVPixelBuffer?         // 刀2:显示主路径,CanvasView 的 AVSampleBufferDisplayLayer 直吃
    @Published var handLandmarks: [CGPoint] = []
    @Published var personBox: CGRect?
    @Published var isTracking = false
    @Published var trackingInfo: String = ""
    @Published var perfHUD: String = ""        // 性能 HUD：阶段耗时 + 实际 FPS
    @Published var perfMini: String = ""       // FPS 测量专用精简行(FPS/rect/tot),DEBUG 始终显示,凉机脱机直接读
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
    // 三态锁定状态机 HUD:badge/cont/thr/候选/事件,来自 follow.dbgStateLine();stateTag 驱动颜色
    @Published var stateHUD = ""
    @Published var stateTag = "U"
    // 【方案B·刀3+刀4】镜头仲裁常驻 HUD(Tier/模式/三Z/最近指令/锁定态),来自 follow.dbgLensShadow
    @Published var lensHUD = ""
    // 刀4:影子开关(默认 ON=只决策不动设备;OFF=放行执行)。机上 TunerSheet 可切,唯一回滚手段。
    @Published var lensShadowOnlyUI = true {
        didSet { follow.setLensShadowOnly(lensShadowOnlyUI) }
    }
    // 跳变取证:冻结"最近一次显著跳变那一帧"的整行数据(poseValid/srcUsed/rectConf/各Δ)
    @Published var probeHUD = ""
    let probeJumpThreshold: CGFloat = 0.03   // anchorΔ 或 rectBoxΔ 超此(占画面宽 3%)算一次跳,刷新冻结行

    // 第1步:切原生 VisionHandGesture,打开手势(原 false 排除 MediaPipe 负载)。每 N 帧一次,降频保持。
    var gestureEnabled = true
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
    @Published var gestureMode: GestureTriggerMode = .off {   // 手势封存(Zc 2026-07-26):算法是核心,手势分支等算法完毕再启。
        didSet { applyGestureConfig() }                       // 用现成 .off 档休眠整条管线(process 进门即返),不注释代码=不造死路径;
    }                                                         // 参数面板「手势触发」随时可拨回 victory/wave,完全可逆。
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

    // 目标锁定（录制开始时手动触发,或自动锁定常态）
    private var shouldLockTarget = false
    // 产品常态:架起来就自动锁定最大/最近的人(=用户),不用手点。默认开。实时+replay 都走 handleFrame,都生效。
    var autoLockEnabled = true

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
            #if DEBUG
            LensLoadMeter.shared.tickFrame()   // 【查勘#2 刀B】基线计量帧计数(不计量时零成本早退)·probe/lens-recon 用完即撤
            #endif
            self?.handleFrame(wide: wide, telephoto: tele, pts: pts)
        }
        source.onAudio = { [weak self] sb in
            self?.handleAudio(sb)
        }

        // 配置实际工作的 follow 引擎
        follow.applyPreset(.fitness)
        follow.updateTunables(tunables)
        // 刀4 保险丝:只有实时相机源允许执行镜头切换;回放/文件源实例永远影子(防串台写真相机 zoom)
        follow.lensExecutionAllowed = (source is LiveCameraSource)

       
    


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
    func start() {
        // 会话开始重置锁(PersonIdentifier 是单例,切换视频/重开相机时清掉上一会话的锁与颜色档案)→ 本会话自动锁定新主角。
        // 这是会话生命周期,不是录制生命周期:录制开关全程不碰锁。
        PersonIdentifier.shared.unlock()
        source.start()
    }
    func stop()  { source.stop(); stopTimer() }

    #if DEBUG
    /// 【查勘#2 探针专用·probe/lens-recon】停 app 相机,teardown 落地后回调 → 探针在回调里才开摄像头,避免争用崩溃。
    func stopCameraForProbe(_ done: @escaping () -> Void) {
        stopTimer()
        if let live = source as? LiveCameraSource {
            live.stopForProbe(done)
        } else {
            source.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { done() }
        }
    }
    #endif
    func toggleRecord() { isRecording ? stopRecord() : startRecord() }
    func toggleLock() { hardLock.toggle() }

    private func startRecord() {
        guard processedPB != nil || processedCGImage != nil || videoSize != .zero else { return }
        recorder.start(size: lastOutputSize)
        isRecording = true
        follow.isRecordingActive = true   // 刀1:开录 → renderCrop 开始多渲 CVPixelBuffer 供 Recorder 直吃
        // 解耦:录制不碰锁。锁是常态(自动锁定一直在你身上),录制只管存不存视频,不重锁/不改锁。
        startTimer()
    }
    private func stopRecord() {
        isRecording = false
        follow.isRecordingActive = false   // 刀1:停录 → renderCrop 不再多渲 pixelBuffer(回到零新增)
        stopTimer()
        // 解耦:停录【不】解锁,锁原样保持在你身上(不再 unlock 后靠自动重锁救场)。
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

    // 方案iii:以锁定目标 pose 的手腕为中心圈手部 ROI,从 wide【原分辨率】裁(不缩),喂 VNDetectHumanHandPose。
    // 返回 (ROI 像素 buffer, ROI 归一化 top-left 供叠加映射)。手腕 conf 低/出界 → nil(本帧跳过手势)。
    let wristRoiSideFrac: CGFloat = 0.32   // ROI 边长 = 人体框宽 × 此(覆盖张开手掌/手指,可调 0.25~0.4)
    let wristRoiMinPx: CGFloat = 256       // ROI 像素下限(140→256:提 landmark 质量;f1001 证明 381px 时 minConf 0.71 能过门)
    private func makeWristROIBuffer(pose: VNHumanBodyPoseObservation, wide: CVPixelBuffer) -> (CVPixelBuffer, CGRect)? {
        // 手腕(Vision 归一化, bottom-left)。选举起来的那只:y 更大=更高;conf 达标
        func wrist(_ j: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let p = try? pose.recognizedPoint(j), p.confidence >= 0.3 else { return nil }
            return p.location
        }
        let cands = [wrist(.leftWrist), wrist(.rightWrist)].compactMap { $0 }
        guard let w = cands.max(by: { $0.y < $1.y }) else { return nil }   // y 大=高=举起的那只

        let W = CGFloat(CVPixelBufferGetWidth(wide)), H = CGFloat(CVPixelBufferGetHeight(wide))
        let wxTL = w.x * W, wyTL = (1 - w.y) * H                            // Vision bottom-left → top-left 像素
        guard wxTL >= 0, wxTL <= W, wyTL >= 0, wyTL <= H else { return nil } // 手腕出界 → 跳过

        // ROI 边长 = 人体框宽(像素)× frac;给像素下限;不超帧
        let boxWnorm = self.personBox?.width ?? 0.3
        let side = min(min(W, H), max(wristRoiMinPx, boxWnorm * W * wristRoiSideFrac))
        var roi = CGRect(x: wxTL - side/2, y: wyTL - side/2, width: side, height: side)
        roi.origin.x = clamp(roi.origin.x, 0, W - side)
        roi.origin.y = clamp(roi.origin.y, 0, H - side)
        roi = roi.integral

        // 从 wide 原分辨率裁(CIImage 是 bottom-left,翻 y),不缩放 → 输出 = ROI 像素尺寸
        let ci = CIImage(cvPixelBuffer: wide)
        let cropBL = CGRect(x: roi.minX, y: H - roi.maxY, width: roi.width, height: roi.height)
        let cropped = ci.cropped(to: cropBL).transformed(by: CGAffineTransform(translationX: -cropBL.minX, y: -cropBL.minY))
        let wI = Int(roi.width), hI = Int(roi.height)
        guard wI >= 2, hI >= 2 else { return nil }
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, wI, hI, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        ciContext.render(cropped, to: buf)
        CVPixelBufferUnlockBaseAddress(buf, [])
        let roiN = CGRect(x: roi.minX / W, y: roi.minY / H, width: roi.width / W, height: roi.height / H)
        return (buf, roiN)
    }

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

        // 0.5) 自动锁定常态:未锁定就持续尝试锁最大框(检测到人即锁,锁成后不再试);或录制手动触发。
        //      lockLargest 无人时返回 false → 下一帧重试,直到检测到人。锁定后 isLocked=true → 条件假 → 停。
        if shouldLockTarget || (autoLockEnabled && !PersonIdentifier.shared.isLocked) {
            let wasManual = shouldLockTarget
            shouldLockTarget = false
            let sensorSize = CGSize(
                width: CGFloat(CVPixelBufferGetWidth(wideFrame)),
                height: CGFloat(CVPixelBufferGetHeight(wideFrame))
            )
            if PersonIdentifier.shared.lockLargest(in: wideFrame, sensorSize: sensorSize) {
                print(wasManual ? "🎯 手动锁定目标" : "🎯 自动锁定目标(最大框)")
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

        // 3) 手势识别 —— 方案iii:以锁定目标 pose 的手腕为中心圈手部ROI,从 wide 原分辨率裁(不缩到224/512)。
        // 手占满 ROI → 召回好;ROI 小 → 像素少 → 快、不掉帧。每 gestureEveryN 帧一次。
        let _tGest = CACurrentMediaTime()
        gestureTick &+= 1
        if gestureEnabled, gestureMode != .off, gestureTick % gestureEveryN == 0 {
            var decided: GestureDecision = .none
            if let pose = follow.lastPoseObservation,
               let (pbRoi, roiN) = self.makeWristROIBuffer(pose: pose, wide: wideFrame) {
                self.currentGestureRoiN = roiN
                decided = gesture.process(pbRoi, nil)
                self.currentGestureRoiN = nil
            } else {
                #if DEBUG
                print("✋ROI skip: \(follow.lastPoseObservation == nil ? "无pose" : "手腕conf低/出界")")
                #endif
            }

            switch decided {
            case .start: if !isRecording { blinkTorch(); toggleRecord() }
            case .stop:  if  isRecording { blinkTorch(); toggleRecord() }
            case .none:  break
            }
        }
        let msGest = (CACurrentMediaTime() - _tGest) * 1000
        let msTotal = (CACurrentMediaTime() - _tFrame) * 1000
        // 刀0:观测者门控。诊断串每帧无条件构造是白烧(拖真实 FPS,Release 也烧)。
        //  - ⏱ 行(console+文件,每30帧):保留 → _perf 仅 need30 或 HUD 开时构造;
        //  - perfMini / probe / lockSummary(HUD 串):仅眼睛开关(showDebugOverlay)开时构造,关时零 String 开销。
        perfFrame += 1
        let _need30 = (perfFrame % 30 == 0)
        let _diagOn = showDebugOverlay

        var _perf = ""
        if _need30 || _diagOn {
            let _cf = String(format: "sh %.2f/%.2f hp %.2f/%.2f",
                             Double(follow.dbgCfLsh), Double(follow.dbgCfRsh),
                             Double(follow.dbgCfLhp), Double(follow.dbgCfRhp))
            _perf = String(format: "FPS %.0f · dt %.0f · rect %.0f pose %.0f skel %.0f gest %.0f rend %.0f · tot %.0f ms",
                           result.fps, follow.dbgRawDtMs, result.msRect, result.msPose, msSkel, msGest, result.msRender, msTotal)
                + " · cf " + _cf + " · " + (follow.dbgZoomSrc.isEmpty ? "—" : follow.dbgZoomSrc)
        }
        if _need30 {
            print("⏱ " + _perf)
            #if DEBUG
            PerfFileLog.shared.line("⏱ " + _perf)   // ②a:脱机 Files app 可取(保留)
            #endif
        }

        // perfMini(FPS/rect/pose/tot,单条轻串)常显供随时屏读;probe/lockSummary(重)仍闸。
        // (横屏诊断 buf 横/竖 已撤——横屏 bug 已在 ef8053b 钉死。)
        let _perfMini = String(format: "FPS %.0f r%.1f p%.1f t%.1f ms",
                               result.fps, result.msRect, result.msPose, msTotal)
        var _probe = ""
        var _probeJump: CGFloat = 0
        if _diagOn {
            var _lockSummary = ""
            #if DEBUG
            _lockSummary = PersonIdentifier.shared.dbgLockSummary(sensorSize: CGSize(width: CVPixelBufferGetWidth(wideFrame), height: CVPixelBufferGetHeight(wideFrame)))
            #endif
            _probe = String(format: "PROBE t=%.2f f=%d poseValid=%@ srcUsed=%@ rectConf=%.2f anchorΔ=%.3f ratioΔ=%.3f rectBoxΔ=%.3f | %@",
                            pts.seconds, follow.frameCount,
                            follow.dbgPoseValid ? "T" : "F",
                            follow.dbgZoomSrc.isEmpty ? "—" : follow.dbgZoomSrc,
                            Double(follow.dbgRectConf), Double(follow.dbgAnchorDelta),
                            Double(follow.dbgRatioDelta), Double(follow.dbgRectBoxDelta),
                            _lockSummary)
            DebugLog.frame(_probe)   // ②b:回放期 ReplayLogger 仍解析(闸内)
            _probeJump = max(follow.dbgAnchorDelta, follow.dbgRectBoxDelta)
        }

        // 4) UI / 录制
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.perfMini = _perfMini   // 刀0 修订:FPS 行常显(轻串),不受眼睛开关 → 随时读
            if _diagOn {   // 重 HUD 串(perfHUD/probe)仅眼睛开关开时刷(其余 UI:personBox/预览照常)
                self.perfHUD = _perf
                if _probeJump > self.probeJumpThreshold {   // 最近一次显著跳变那一帧,冻结给真机直接读
                    self.probeHUD = _probe
                }
            }
            // 一次性:捕获配置就绪后填一次(静态量,启动后几帧内可用)
            if self.captureConfigHUD.isEmpty, !CameraEngine.lastCaptureConfig.isEmpty {
                self.captureConfigHUD = CameraEngine.lastCaptureConfig
            }
            if self.detSpecHUD != self.follow.dbgDetSpec { self.detSpecHUD = self.follow.dbgDetSpec }
            if self.slewHUD != self.follow.dbgSlewLine { self.slewHUD = self.follow.dbgSlewLine }
            if self.fakeHUD != self.follow.dbgFakeHUD { self.fakeHUD = self.follow.dbgFakeHUD }
            if self.trkHUD != self.follow.dbgTrkHUD { self.trkHUD = self.follow.dbgTrkHUD }
            #if DEBUG
            // 【刀4·卡面三】镜头仲裁 HUD 改常驻(不看 Xcode 也能判模式/三Z/指令/锁定态)——不再挂眼睛开关
            if self.lensHUD != self.follow.dbgLensShadow { self.lensHUD = self.follow.dbgLensShadow }
            if self.showDebugOverlay {   // 状态机 HUD:关时不更新,省 @Published churn(SEARCHING 秒数每帧变)
                let _sl = self.follow.dbgStateLine()
                if self.stateHUD != _sl { self.stateHUD = _sl }
                let _st = self.follow.dbgStateTag()
                if self.stateTag != _st { self.stateTag = _st }
            }
            #endif
            if self.showDebugOverlay { self.dbgCropHUD = self.follow.dbgCropLine }   // 关时不更新,省 @Published churn
            self.isTracking = result.confidence > 0.5
            self.trackingInfo = self.isTracking
                ? String(format: "追踪中 %.0f%%  |  缩放 %.2fx", result.confidence * 100, result.zoom)
                : "搜索目标…"

            // 刀2:显示主路径 = pb;pb 缺失(池失败)才用 cgImage 兜底
            if let pb = result.previewPB { self.processedPB = pb }
            else if let cg = result.previewCG { self.processedCGImage = cg }
            
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

            if self.isRecording {
                // 刀1:优先直吃 renderCrop 渲好的 CVPixelBuffer(免 CGContext.draw 软 blit + fill);
                // pb 缺失(池创建失败等异常)才退回 CGImage 兜底路径。
                if let pb = result.previewPB {
                    self.recorder.appendVideo(pixelBuffer: pb, at: result.pts)
                } else if let cg = result.previewCG {
                    self.recorder.appendVideo(cgImage: cg, at: result.pts)
                }
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






