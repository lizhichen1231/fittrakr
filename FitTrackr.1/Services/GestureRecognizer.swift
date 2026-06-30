import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import Vision

// 对外接口保持不变
enum GestureDecision { case none, start, stop }
enum GestureTriggerMode: String, CaseIterable { case wave, victory, off }   // victory=比耶✌️(原 okThree 空壳激活)

protocol _HandGestureCore {
    var onLandmarks: (([CGPoint]) -> Void)? { get set }
    func setMode(_ m: GestureTriggerMode)
    func setSampleInterval(_ n: Int)
    func reset()
    func process(pixelBuffer: CVPixelBuffer, roi: CGRect?) -> GestureDecision
}

// MARK: - 工具
fileprivate enum GX {
    @inline(__always) static func clamp<T: Comparable>(_ v: T,_ a: T,_ b: T) -> T { max(a, min(b, v)) }
    @inline(__always) static func dist(_ a: CGPoint,_ b: CGPoint) -> CGFloat { hypot(a.x-b.x, a.y-b.y) }
}

// MARK: - 稳定触发/冷却（基于时间的版本）
fileprivate final class StableToggle {
    private var stable = 0
    private var last: GestureDecision = .stop
    private var lastTriggerTime = Date(timeIntervalSince1970: 0)
    private var needRelease = false   // 触发后必须先松手(active=false)才能再触发 → 治「保持着反复 toggle」

    let needStable: Int
    let cooldownSeconds: TimeInterval

    init(needStable: Int = 2, cooldownSeconds: TimeInterval = 1.2) {
        self.needStable = needStable
        self.cooldownSeconds = cooldownSeconds
    }

    func step(active: Bool) -> GestureDecision {
        // 松手:解除「需松手」+ 清累计(下一次比耶重新开始数)
        if !active {
            needRelease = false
            stable = 0
            return .none
        }
        // active=true:
        let now = Date()
        if now.timeIntervalSince(lastTriggerTime) < cooldownSeconds { return .none }  // 冷却期不响应
        if needRelease { return .none }   // 触发后还没松手 → 一直举着也不重复触发
        stable += 1
        if stable >= needStable {
            stable = 0
            needRelease = true            // 必须松手才能下一次
            lastTriggerTime = now
            last = (last == .start) ? .stop : .start
            print("🎬 手势触发: \(last == .start ? "开始" : "停止")录制")
            return last
        }
        return .none
    }

    func reset() {
        stable = 0
        last = .stop
        needRelease = false
        lastTriggerTime = Date(timeIntervalSince1970: 0)  // 重置时清除冷却
    }

    #if DEBUG
    var dbgStable: Int { stable }
    var dbgNeed: Int { needStable }
    var dbgCooldownRemain: TimeInterval { max(0, cooldownSeconds - Date().timeIntervalSince(lastTriggerTime)) }
    #endif
}

// MARK: - 公共判定：张开手掌判定
fileprivate struct OpenPalmRule {
    static func isOpenPalm(_ pts: [CGPoint], prevPts: [CGPoint]? = nil) -> Bool {
        guard pts.count >= 21 else { return false }
        let wrist = pts[0]
        let palm = max(1e-6, GX.dist(wrist, pts[9]))
        
        if palm < 0.04 { return false }
        
        func extended(_ tip: Int, _ mcp: Int, k: CGFloat) -> Bool { GX.dist(pts[tip], pts[mcp]) > k * palm }
        let idxExt = extended(8, 5, k: 0.75)
        let midExt = extended(12, 9, k: 0.80)
        let rngExt = extended(16, 13, k: 0.80)
        let lttExt = extended(20, 17, k: 0.78)
        let extCount = [idxExt, midExt, rngExt, lttExt].filter { $0 }.count
        guard extCount >= 3 else { return false }

        if let prev = prevPts, prev.count == pts.count {
            let prevPalm = max(1e-6, GX.dist(prev[0], prev[9]))
            if palm < prevPalm * 0.6 { return false }
        }

        let thumbAbduct = GX.dist(pts[4], pts[5]) > 0.55 * palm
        guard thumbAbduct else { return false }

        let s1 = GX.dist(pts[8], pts[12])
        let s2 = GX.dist(pts[12], pts[16])
        let s3 = GX.dist(pts[16], pts[20])
        let wideGap = [s1, s2, s3].filter { $0 > 0.28 * palm }.count >= 2
        guard wideGap else { return false }

        let tipsY = [pts[8].y, pts[12].y, pts[16].y, pts[20].y]
        let mcpsY = [pts[5].y, pts[9].y, pts[13].y, pts[17].y]
        let upEnough = zip(tipsY, mcpsY).filter { (t, m) in t < m - 0.02 }.count >= 3
        guard upEnough else { return false }

        return true
    }

    #if DEBUG
    /// 诊断版:返回(过?, 不过的那道门 + 关键量)。门与 isOpenPalm 完全一致,只为打日志。
    static func reason(_ pts: [CGPoint]) -> (Bool, String) {
        guard pts.count >= 21 else { return (false, "点数<21") }
        let wrist = pts[0]; let palm = max(1e-6, GX.dist(wrist, pts[9]))
        if palm < 0.04 { return (false, String(format: "palm=%.3f<0.04(手太小/糊)", palm)) }
        func ext(_ tip: Int,_ mcp: Int,_ k: CGFloat) -> Bool { GX.dist(pts[tip], pts[mcp]) > k*palm }
        let extCount = [ext(8,5,0.75), ext(12,9,0.80), ext(16,13,0.80), ext(20,17,0.78)].filter { $0 }.count
        if extCount < 3 { return (false, "伸直指=\(extCount)<3(手没张开/握拳)") }
        if GX.dist(pts[4], pts[5]) <= 0.55*palm { return (false, "拇指外展不足") }
        let gaps = [GX.dist(pts[8],pts[12]), GX.dist(pts[12],pts[16]), GX.dist(pts[16],pts[20])].filter { $0 > 0.28*palm }.count
        if gaps < 2 { return (false, "指缝宽=\(gaps)<2(手指并拢)") }
        let up = zip([pts[8].y,pts[12].y,pts[16].y,pts[20].y], [pts[5].y,pts[9].y,pts[13].y,pts[17].y]).filter { $0 < $1 - 0.02 }.count
        if up < 3 { return (false, "指尖朝上=\(up)<3(手没竖起)") }
        return (true, String(format: "过(palm=%.3f 伸%d 缝%d 上%d)", palm, extCount, gaps, up))
    }
    #endif
}

// MARK: - 比耶✌️判定（食/中伸直朝上 + 无名/小指收拢；负条件防误触握拳/张掌）
fileprivate struct VictoryRule {
    // 方向无关:不判朝上(正/反/左/右/横/斜比都认)。只要 食/中伸 + 无名/小指收。阈值 0.7→0.6 更易过。
    static func isVictory(_ pts: [CGPoint]) -> Bool {
        guard pts.count >= 21 else { return false }
        let palm = max(1e-6, GX.dist(pts[0], pts[9]))     // wrist→middleMCP
        if palm < 0.04 { return false }
        let idxExt  = GX.dist(pts[8],  pts[5])  > 0.6 * palm   // 食指伸
        let midExt  = GX.dist(pts[12], pts[9])  > 0.6 * palm   // 中指伸
        let ringFold = GX.dist(pts[16], pts[13]) < 0.5 * palm  // 无名收(★负条件,防误触)
        let litFold  = GX.dist(pts[20], pts[17]) < 0.5 * palm  // 小指收(★负条件,防误触)
        return idxExt && midExt && ringFold && litFold
        // 误触涨再开 V 形分离:&& GX.dist(pts[8], pts[12]) > 0.3 * palm
    }

    #if DEBUG
    static func reason(_ pts: [CGPoint]) -> (Bool, String) {
        guard pts.count >= 21 else { return (false, "点数<21") }
        let palm = max(1e-6, GX.dist(pts[0], pts[9]))
        if palm < 0.04 { return (false, String(format: "palm=%.3f<0.04", palm)) }
        let idxE = GX.dist(pts[8],pts[5])/palm,  midE = GX.dist(pts[12],pts[9])/palm
        let ringF = GX.dist(pts[16],pts[13])/palm, litF = GX.dist(pts[20],pts[17])/palm
        if !(idxE > 0.6)  { return (false, String(format: "食指没伸 %.2f<0.6", idxE)) }
        if !(midE > 0.6)  { return (false, String(format: "中指没伸 %.2f<0.6", midE)) }
        if !(ringF < 0.5) { return (false, String(format: "无名没收 %.2f>0.5", ringF)) }
        if !(litF < 0.5)  { return (false, String(format: "小指没收 %.2f>0.5", litF)) }
        return (true, String(format: "过(食%.2f 中%.2f 无名%.2f 小%.2f V%.2f)", idxE, midE, ringF, litF, GX.dist(pts[8],pts[12])/palm))
    }
    #endif
}

// MARK: - MediaPipe 实现
#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision

final class MPHandGesture: _HandGestureCore {
    private var landmarker: HandLandmarker?
    private var tsMs: Int64 = 0
    private var framePeriodMs: Int64 = 33
    private var mode: GestureTriggerMode = .wave
    private var sampleEvery: Int = 6  // 每6帧检测一次（进一步降低频率）
    private var frame = 0
    private let toggle = StableToggle(needStable: 1, cooldownSeconds: 1.2)  // needStable 2→1(降一档,单帧即触发);松手门控+1.2s冷却防重复
    private var initTime = Date()
    var onLandmarks: (([CGPoint]) -> Void)?

    // 异步处理：不阻塞主线程
    private let detectQueue = DispatchQueue(label: "gesture.detect", qos: .userInitiated)
    private var isProcessing = false
    private var pendingDecision: GestureDecision = .none
    private let stateLock = NSLock()

    // 缓存上一次的landmarks用于回调
    private var cachedLandmarks: [CGPoint] = []

    init?() {
        do {
            var opts = HandLandmarkerOptions()
            var base = BaseOptions()
            guard let url = Bundle.main.url(forResource: "hand_landmarker", withExtension: "task") else {
                return nil
            }
            base.modelAssetPath = url.path
            opts.baseOptions = base
            opts.runningMode = .video
            opts.numHands = 1  // 只检测1个手，减少计算量
            opts.minHandDetectionConfidence = 0.35
            opts.minHandPresenceConfidence = 0.35
            opts.minTrackingConfidence = 0.50
            landmarker = try HandLandmarker(options: opts)
        } catch {
            return nil
        }
    }

    func setMode(_ m: GestureTriggerMode) {
        mode = m
        reset()
    }

    func setSampleInterval(_ n: Int) {
        sampleEvery = max(1, n)
    }

    func reset() {
        stateLock.lock()
        frame = 0
        tsMs = 0
        pendingDecision = .none
        isProcessing = false
        cachedLandmarks = []
        stateLock.unlock()
        toggle.reset()
        initTime = Date()
    }

    func process(pixelBuffer: CVPixelBuffer, roi: CGRect?) -> GestureDecision {
        // 初始化保护期（0.5秒），防止刚切换就误触发
        if Date().timeIntervalSince(initTime) < 0.5 {
            return .none
        }

        if mode == .off {
            onLandmarks?([])
            return .none
        }

        frame &+= 1
        if (frame % sampleEvery) != 0 {
            // 非采样帧：返回缓存的landmarks和pending decision
            stateLock.lock()
            let cached = cachedLandmarks
            let decision = pendingDecision
            if decision != .none { pendingDecision = .none }
            stateLock.unlock()

            if !cached.isEmpty { onLandmarks?(cached) }
            return decision
        }

        // 检查是否正在处理中
        stateLock.lock()
        let alreadyProcessing = isProcessing
        if !alreadyProcessing { isProcessing = true }
        let currentDecision = pendingDecision
        if currentDecision != .none { pendingDecision = .none }
        let cached = cachedLandmarks
        stateLock.unlock()

        // 如果上一帧还没处理完，直接返回缓存结果
        if alreadyProcessing {
            if !cached.isEmpty { onLandmarks?(cached) }
            return currentDecision
        }

        guard let lm = landmarker else {
            stateLock.lock()
            isProcessing = false
            stateLock.unlock()
            onLandmarks?([])
            return .none
        }

        // 记录当前时间戳用于异步处理
        let currentTs = tsMs
        tsMs &+= framePeriodMs * Int64(sampleEvery)

        // 尝试创建 MPImage（这个操作很快）
        let mpImage: MPImage
        do {
            mpImage = try MPImage(pixelBuffer: pixelBuffer)
        } catch {
            stateLock.lock()
            isProcessing = false
            stateLock.unlock()
            onLandmarks?([])
            return currentDecision
        }

        // 异步执行检测
        let currentMode = mode
        let toggleRef = toggle
        let landmarksCallback = onLandmarks

        detectQueue.async { [weak self] in
            guard let self = self else { return }

            defer {
                self.stateLock.lock()
                self.isProcessing = false
                self.stateLock.unlock()
            }

            do {
                let result = try lm.detect(videoFrame: mpImage, timestampInMilliseconds: Int(currentTs))

                guard !result.landmarks.isEmpty else {
                    self.stateLock.lock()
                    self.cachedLandmarks = []
                    self.stateLock.unlock()
                    DispatchQueue.main.async { landmarksCallback?([]) }
                    return
                }

                var openHand: [CGPoint]? = nil
                var anyOpen = false

                for hand in result.landmarks {
                    let pts: [CGPoint] = hand.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }

                    let passed = (currentMode == .victory) ? VictoryRule.isVictory(pts) : OpenPalmRule.isOpenPalm(pts)
                    if passed {
                        anyOpen = true
                        if openHand == nil {
                            openHand = pts
                        }
                    }
                }

                let finalPts: [CGPoint]
                if let hand = openHand {
                    finalPts = hand
                } else {
                    let firstHand = result.landmarks.first!
                    finalPts = firstHand.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
                }

                // 更新缓存
                self.stateLock.lock()
                self.cachedLandmarks = finalPts
                self.stateLock.unlock()

                // 回调landmarks
                DispatchQueue.main.async { landmarksCallback?(finalPts) }

                // 计算decision
                if currentMode != .off {   // wave / victory 都走 toggle
                    let decision = toggleRef.step(active: anyOpen)
                    if decision != .none {
                        self.stateLock.lock()
                        self.pendingDecision = decision
                        self.stateLock.unlock()
                    }
                }

            } catch {
                self.stateLock.lock()
                self.cachedLandmarks = []
                self.stateLock.unlock()
                DispatchQueue.main.async { landmarksCallback?([]) }
            }
        }

        // 立即返回上一帧的缓存结果（不阻塞）
        if !cached.isEmpty { onLandmarks?(cached) }
        return currentDecision
    }
}
#endif

// MARK: - Vision 降级实现
final class VisionHandGesture: _HandGestureCore {
    private var mode: GestureTriggerMode = .wave
    private var sampleEvery: Int = 3
    private var frame = 0
    private let toggle = StableToggle(needStable: 1, cooldownSeconds: 1.2)  // needStable 2→1(降一档,单帧即触发);松手门控+1.2s冷却防重复
    private var initTime = Date()
    var onLandmarks: (([CGPoint]) -> Void)?

    func setMode(_ m: GestureTriggerMode) {
        mode = m
        reset()
    }
    
    func setSampleInterval(_ n: Int) {
        sampleEvery = max(1, n)
    }
    
    func reset() {
        frame = 0
        toggle.reset()
        initTime = Date()
    }

    func process(pixelBuffer: CVPixelBuffer, roi: CGRect?) -> GestureDecision {
        // 初始化保护期（0.5秒）
        if Date().timeIntervalSince(initTime) < 0.5 {
            return .none
        }
        
        if mode == .off {
            onLandmarks?([])
            return .none
        }
        
        frame &+= 1
        if (frame % sampleEvery) != 0 { return .none }

        let req = VNDetectHumanHandPoseRequest()
        req.maximumHandCount = 2  // 检测最多2个手
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        do {
            #if DEBUG
            let _tHand = CFAbsoluteTimeGetCurrent()
            #endif
            try handler.perform([req])
            #if DEBUG
            // 第2步验证:原生手部检测单次耗时 + 召回几个手(输入是 224×224 ROI)
            let _handMs = (CFAbsoluteTimeGetCurrent() - _tHand) * 1000
            let _inW = CVPixelBufferGetWidth(pixelBuffer), _inH = CVPixelBufferGetHeight(pixelBuffer)
            print(String(format: "✋VNHand %.1fms 召回手=%d 输入=%dx%d", _handMs, req.results?.count ?? 0, _inW, _inH))
            #endif

            guard let observations = req.results, !observations.isEmpty else {
                onLandmarks?([])
                return .none
            }

            let names: [VNHumanHandPoseObservation.JointName] = [
                .wrist,
                .thumbCMC,.thumbMP,.thumbIP,.thumbTip,
                .indexMCP,.indexPIP,.indexDIP,.indexTip,
                .middleMCP,.middlePIP,.middleDIP,.middleTip,
                .ringMCP,.ringPIP,.ringDIP,.ringTip,
                .littleMCP,.littlePIP,.littleDIP,.littleTip
            ]
            
            var openHand: [CGPoint]? = nil
            var anyOpen = false
            var firstValidHand: [CGPoint]? = nil
            
            for (_, obs) in observations.enumerated() {
                var pts = [CGPoint](repeating: .zero, count: 21)
                var valid = true
                
                for (i,n) in names.enumerated() {
                    guard let p = try? obs.recognizedPoint(n), p.confidence >= 0.15 else {
                        valid = false
                        break
                    }
                    pts[i] = CGPoint(x: CGFloat(p.location.x), y: CGFloat(1 - p.location.y))
                }
                
                if valid {
                    if firstValidHand == nil {
                        firstValidHand = pts
                    }
                    // 按模式选判定:victory=比耶✌️,wave=张掌(OpenPalm 留着可回退)
                    let passed = (mode == .victory) ? VictoryRule.isVictory(pts) : OpenPalmRule.isOpenPalm(pts)
                    if passed {
                        anyOpen = true
                        if openHand == nil {
                            openHand = pts
                        }
                    }
                }
            }
            
            if let hand = openHand {
                onLandmarks?(hand)
            } else if let hand = firstValidHand {
                onLandmarks?(hand)
            } else {
                onLandmarks?([])
            }

            #if DEBUG
            // 全链路诊断:每只手 21点 conf 门(<0.15被丢)→ OpenPalmRule 过不过+原因
            print("HAND 召回手=\(observations.count)")
            for (hi, obs) in observations.enumerated() {
                var confs = [Float](); var pts = [CGPoint](repeating: .zero, count: 21); var got = 0
                for (i, n) in names.enumerated() {
                    if let p = try? obs.recognizedPoint(n) {
                        confs.append(p.confidence)
                        pts[i] = CGPoint(x: CGFloat(p.location.x), y: CGFloat(1 - p.location.y))
                        if p.confidence >= 0.15 { got += 1 }
                    }
                }
                let minC = confs.min() ?? 0, avgC = confs.isEmpty ? 0 : confs.reduce(0,+)/Float(confs.count)
                if got == 21 {
                    let (ok, why) = (mode == .victory) ? VictoryRule.reason(pts) : OpenPalmRule.reason(pts)
                    let g = (mode == .victory) ? "比耶" : "OpenPalm"
                    print(String(format: "  hand%d: 21点全过conf门 minConf=%.2f avg=%.2f → %@ %@", hi, minC, avgC, g, ok ? "过 \(why)" : "不过(\(why))"))
                } else {
                    print(String(format: "  hand%d: 过conf门=%d/21 minConf=%.2f → 被conf门丢(某点<0.15,手糊/遮挡)", hi, got, minC))
                }
            }
            #endif

            if mode != .off {   // wave / victory 都走 toggle
                let decision = toggle.step(active: anyOpen)
                #if DEBUG
                print(String(format: "  anyOpen=%@ | StableToggle 累计=%d/%d 冷却剩=%.1fs 触发=%@",
                             anyOpen ? "Y" : "N", toggle.dbgStable, toggle.dbgNeed, toggle.dbgCooldownRemain, decision != .none ? "Y" : "N"))
                #endif
                return decision
            }

            return .none
            
        } catch {
            onLandmarks?([])
            return .none
        }
    }
}

// MARK: - 工厂
enum GestureFactory {
    static func make() -> (
        process: (CVPixelBuffer, CGRect?) -> GestureDecision,
        setLandmarks: (@escaping ([CGPoint]) -> Void) -> Void,
        reset: () -> Void,
        setMode: (GestureTriggerMode) -> Void,
        setSampleInterval: (Int) -> Void
    ) {
        // 第1步:切原生 VisionHandGesture(不走 MediaPipe,可逆——把下面整块取消注释即恢复 MediaPipe 优先)。
        // 验证原生 FPS/触发够用后,第3步再删 MediaPipe pod 解锁 git。
        /*
        #if canImport(MediaPipeTasksVision)
        if let mp = MPHandGesture() {
            return (
                { pb, roi in mp.process(pixelBuffer: pb, roi: roi) },
                { cb in mp.onLandmarks = cb },
                { mp.reset() },
                { m in mp.setMode(m) },
                { n in mp.setSampleInterval(n) }
            )
        }
        #endif
        */

        let v = VisionHandGesture()
        return (
            { pb, roi in v.process(pixelBuffer: pb, roi: roi) },
            { cb in v.onLandmarks = cb },
            { v.reset() },
            { m in v.setMode(m) },
            { n in v.setSampleInterval(n) }
        )
    }
}

