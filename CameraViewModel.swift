import Foundation
import AVFoundation
import CoreImage
import Combine
import UIKit

final class CameraViewModel: NSObject, ObservableObject {

    private let camera  = CameraEngine()
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

    // è°ƒå‚
    @Published var tunables: FollowEngine.Tunables
    @Published var deadZoneFraction: CGSize

    // æ‰‹åŠ¿è§¦å‘é…ç½®
    @Published var gestureMode: GestureTriggerMode = .wave {
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

    // æ‰‹éƒ¨å…³é”®ç‚¹ç¨³å®šå™¨
    private var lmPrev: [CGPoint]? = nil
    private var lmEMA: [CGPoint]?  = nil
    private let lmAlpha: CGFloat = 0.45
    private let lmJumpGate: CGFloat = 0.25
    private let lmPalmMin: CGFloat = 0.03
    private let lmPalmMax: CGFloat = 0.60

    override init() {
        let engine = FollowEngine()
        var t = engine.getTunables()
        t.adaptiveEnabled = true
        self.tunables = t
        self.deadZoneFraction = CGSize(width: t.deadZoneW, height: t.deadZoneH)
        super.init()
        camera.delegate = self

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
    func start() { camera.start() }
    func stop()  { camera.stop(); stopTimer() }
    func toggleRecord() { isRecording ? stopRecord() : startRecord() }
    func toggleLock() { hardLock.toggle() }

    private func startRecord() {
        guard processedCGImage != nil || videoSize != .zero else { return }
        recorder.start(size: lastOutputSize)
        isRecording = true
        startTimer()
    }
    private func stopRecord() {
        isRecording = false
        stopTimer()
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

extension CameraViewModel: CameraEngineDelegate {
    func cameraEngine(_ engine: CameraEngine,
                      didOutputVideo pixelBuffer: CVPixelBuffer,
                      pts: CMTime) {
        // 1) 跟随主流程
        let result = follow.process(pixelBuffer: pixelBuffer, pts: pts)

        // 2) 同步跑骨架（与 Follow 引擎的 crop / stableBox 对齐）
        SkeletonAddon.shared.process(pixelBuffer: pixelBuffer,
                                     orientation: .up,
                                     pts: pts,
                                     follow: result)

        // 3) 手势识别（修正 ROI 条件）
        if gestureMode != .off, let ci = result.ciScaled {
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

        // 4) UI / 录制
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
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

            if self.isRecording, let ci = result.ciScaled {
                self.recorder.appendVideo(ciImage: ci, at: result.pts)
            }
        }
    }

    func cameraEngine(_ engine: CameraEngine,
                      didOutputAudio sampleBuffer: CMSampleBuffer) {
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






