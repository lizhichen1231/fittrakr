import AVFoundation
import Vision
import CoreImage

enum CaptureMode { case fitness, dance }

struct FollowResult {
    let fps: Double
    let zoom: CGFloat
    let confidence: CGFloat
    let rawBox: CGRect?
    let stableBox: CGRect?
    let cropRect: CGRect
    let previewCG: CGImage?
    let ciScaled: CIImage?
    let pts: CMTime
    let sensorSize: CGSize
}

// 可热调参数
extension FollowEngine {
    struct Tunables {
        var deadZoneW: CGFloat
        var deadZoneH: CGFloat

        var natFreqHzX: CGFloat
        var natFreqHzY: CGFloat
        var damping:   CGFloat
        var softZoneGain: CGFloat
        var maxVelPxPerSec: CGFloat
        var maxAccPxPerSec2: CGFloat

        var maxZoom: CGFloat
        var zoomDeadband: CGFloat
        var maxZoomChangePerSec: CGFloat
        var maxZoomInPerSec: CGFloat
        var maxZoomOutPerSec: CGFloat
        var targetWidthLower: CGFloat
        var targetWidthUpper: CGFloat

        // 抖抑 & 检测频率
        var microMovePx: CGFloat
        var detInterval: CGFloat

        // 自适应阻尼/频率
        var adaptiveEnabled: Bool
        var jitterLowPx: CGFloat
        var jitterHighPx: CGFloat
    }
}

// 简单的卡尔曼滤波器
class SimpleKalmanFilter {
    private var x: CGFloat = 0  // 状态估计
    private var p: CGFloat = 1  // 估计误差协方差
    private let q: CGFloat  // 过程噪声协方差
    private let r: CGFloat  // 测量噪声协方差
    
    init(processNoise: CGFloat = 0.001, measurementNoise: CGFloat = 0.1) {
        self.q = processNoise
        self.r = measurementNoise
    }
    
    func update(measurement: CGFloat) -> CGFloat {
        // 预测
        let xPred = x
        let pPred = p + q
        
        // 更新
        let k = pPred / (pPred + r)  // 卡尔曼增益
        x = xPred + k * (measurement - xPred)
        p = (1 - k) * pPred
        
        return x
    }
    
    func reset(value: CGFloat) {
        x = value
        p = 1
    }
    
    func softReset(value: CGFloat, blendRatio: CGFloat) {
        x = x * (1 - blendRatio) + value * blendRatio
        p = min(p + 0.1, 1.0)  // 略微增加不确定性
    }
}

// 指数平滑器
class ExponentialSmoother {
    private var value: CGFloat
    private let alpha: CGFloat
    private var initialized = false
    
    init(alpha: CGFloat, initialValue: CGFloat = 1.0) {
        self.alpha = alpha
        self.value = initialValue
    }
    
    func update(_ target: CGFloat) -> CGFloat {
        if !initialized {
            value = target
            initialized = true
            return value
        }
        value = value * (1 - alpha) + target * alpha
        return value
    }
    
    func reset(to: CGFloat? = nil) {
        if let newValue = to {
            value = newValue
        }
        initialized = false
    }
}

// 运动预测器
class MotionPredictor {
    private var positionHistory = [CGPoint]()
    private var velocityHistory = [(x: CGFloat, y: CGFloat)]()
    private let historySize = 5
    
    func update(position: CGPoint, dt: CGFloat) -> CGPoint {
        positionHistory.append(position)
        if positionHistory.count > historySize {
            positionHistory.removeFirst()
        }
        
        // 计算速度
        if positionHistory.count >= 2 {
            let lastPos = positionHistory[positionHistory.count - 2]
            let vel = (x: (position.x - lastPos.x) / dt,
                      y: (position.y - lastPos.y) / dt)
            velocityHistory.append(vel)
            if velocityHistory.count > historySize {
                velocityHistory.removeFirst()
            }
        }
        
        // 预测下一帧位置
        if velocityHistory.count >= 3 {
            let avgVel = velocityHistory.suffix(3).reduce((x: 0, y: 0)) {
                (x: $0.x + $1.x/3, y: $0.y + $1.y/3)
            }
            // 保守的预测，只预测一小部分
            return CGPoint(x: position.x + avgVel.x * dt * 0.3,
                          y: position.y + avgVel.y * dt * 0.3)
        }
        
        return position
    }
    
    func reset() {
        positionHistory.removeAll()
        velocityHistory.removeAll()
    }
}

final class FollowEngine {

    // ——— 优化后的默认参数 ——— //
    private struct Cfg {
        // Detection / Follow - 平衡灵敏和防抖
        var detectIntervalFrames = 1  // 每帧都检测，提高响应速度
        var deadZone = CGSize(width: 0.25, height: 0.35)  // 适中的死区
        var inPlaceDeadZone = CGSize(width: 0.25, height: 0.40)  // 原地运动时的特殊死区

        // PD smoothing - 更灵敏的响应
        var natFreqHzX: CGFloat = 1.9  // 提高频率，更快响应
        var natFreqHzY: CGFloat = 2.1
        var damping: CGFloat = 1.08  // 适中的阻尼
        var softZoneGain: CGFloat = 0.70
        var maxVelPxPerSec: CGFloat = 2200  // 提高最大速度
        var maxAccPxPerSec2: CGFloat = 3500  // 提高最大加速度
        
        // 速度阻尼
        var velocityDamping: CGFloat = 0.95  // 轻微阻尼

        // Zoom - 改进的缩放参数
        var maxZoom: CGFloat = 2.5
        var zoomDeadband: CGFloat = 0.018  // 更小的死区
        var maxZoomChangePerSec: CGFloat = 3.0  // 提高变化速度
        var maxZoomInPerSec: CGFloat = 0.9      // 更快的放大
        var maxZoomOutPerSec: CGFloat = 0.7    // 更快的缩小
        var targetWidthRange: ClosedRange<CGFloat> = 0.46...0.54
        
        // 缩放变化阈值
        var zoomChangeThreshold: CGFloat = 0.001
        
        // 缩放平滑参数
        var zoomSmoothAlpha: CGFloat = 0.1  // 更快的响应，但仍有平滑

        // Anti-jitter - 适度防抖
        var microMovePxOut: CGFloat = 6.0  // 适中的微移阈值
        var jitterThreshold: CGFloat = 3.0  // 抖动阈值
        
        // 最小移动阈值（像素）
        var minMovementPx: CGFloat = 0.5  // 大幅降低，几乎不限制

        // Adaptive（输出像素域）
        var adaptiveEnabled = true
        var jitterLowPx: CGFloat = 2.0  // 调整抖动阈值
        var jitterHighPx: CGFloat = 10.0

        // 原地运动检测阈值 - 改进的参数
        var positionStableThreshold: CGFloat = 0.008  // 更严格
        var aspectChangeThreshold: CGFloat = 0.15
        var inPlaceDetectionFrames = 15  // 减少到15帧
        var preInPlaceDetectionFrames = 3  // 预检测帧数
        var preInPlaceThreshold: CGFloat = 0.005  // 预检测阈值
        
        // 位置滤波系数
        var positionFilterAlpha: CGFloat = 0.25  // 更快的响应速度
        
        // Other
        var lostFramesThreshold = 5  // 降低阈值，更快响应丢失
        var outputSize = CGSize(width: 1080, height: 1920)
    }
    private var cfg = Cfg()
    var deadZoneFraction: CGSize { cfg.deadZone }

    // 运行态
    private var frameCount = 0
    private var missCount = 0
    private var lastTime = Date()
    private var detFrameCount = 0
    private var lastDetTime = Date()

    private var sensorW: CGFloat = 1920
    private var sensorH: CGFloat = 1080

    private var zoom: CGFloat = 1.0
    private var rawBox: CGRect?
    private var stableBox: CGRect?
    private var confidence: CGFloat = 0
    private var velX: CGFloat = 0
    private var velY: CGFloat = 0
    private var lastCropRect: CGRect?

    private var currentMode: CaptureMode = .fitness

    // 自适应统计（输出像素域）
    private var lastOutCenter: CGPoint?
    private var motionHist = [CGFloat]()
    private let windowFrames = 36

    // 缩放平滑相关 - 改进版
    private var zoomHistory = [CGFloat]()
    private let zoomHistorySize = 8  // 增加历史大小
    private var lastDesiredZoom: CGFloat = 1.0
    private var zoomStableFrames = 0
    private var zoomVelocity: CGFloat = 0  // 缩放速度
    private var lockedZoom: CGFloat = 0  // 原地运动时锁定的缩放值
    private var zoomSmoother: ExponentialSmoother!  // 新增缩放平滑器
    
    // 新增：锁定中心点和速度历史
    private var lockedCenter: CGPoint?  // 原地运动时锁定的中心点
    private var lastZoomVelocity: CGFloat = 0  // 上一帧的缩放速度
    private var lastVelX: CGFloat = 0  // 上一帧的X速度
    private var lastVelY: CGFloat = 0  // 上一帧的Y速度
    
    // 原地运动检测相关 - 改进版
    private var centerHistory = [CGPoint]()
    private let centerHistorySize = 20
    private var aspectRatioHistory = [CGFloat]()
    private let aspectHistorySize = 10
    private var isDoingExerciseInPlace = false
    private var positionStableFrames = 0
    private var wasInPlace = false  // 上一帧是否在原地运动
    
    // 新增：预检测机制
    private var preInPlaceFrames = 0
    private var zoomFrozen = false

    // 位置滤波相关
    private var lastFilteredX: CGFloat = 0
    private var lastFilteredY: CGFloat = 0
    
    // 卡尔曼滤波器
    private var kalmanX: SimpleKalmanFilter?
    private var kalmanY: SimpleKalmanFilter?
    private var kalmanW: SimpleKalmanFilter?
    private var kalmanH: SimpleKalmanFilter?
    
    // 运动预测器
    private var motionPredictor = MotionPredictor()

    private let ciContext = CIContext(options: [
        .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
        .outputColorSpace : CGColorSpaceCreateDeviceRGB()
    ])
    
    // 初始化时创建滤波器
    init() {
        setupKalmanFilters()
        setupZoomSmoother()
    }
    
    // 设置卡尔曼滤波器 - 优化参数
    private func setupKalmanFilters() {
        // 动态调整噪声参数
        let processNoise: CGFloat = currentMode == .fitness ? 0.0005 : 0.001
        let measurementNoise: CGFloat = currentMode == .fitness ? 0.05 : 0.03
        
        kalmanX = SimpleKalmanFilter(processNoise: processNoise, measurementNoise: measurementNoise)
        kalmanY = SimpleKalmanFilter(processNoise: processNoise, measurementNoise: measurementNoise)
        
        // 宽高使用不同的参数（变化较小）
        kalmanW = SimpleKalmanFilter(processNoise: processNoise * 0.5, measurementNoise: measurementNoise * 0.8)
        kalmanH = SimpleKalmanFilter(processNoise: processNoise * 0.5, measurementNoise: measurementNoise * 0.8)
    }
    
    // 设置缩放平滑器
    private func setupZoomSmoother() {
        zoomSmoother = ExponentialSmoother(alpha: cfg.zoomSmoothAlpha, initialValue: 1.0)
    }

    // MARK: - 公共 API
    func setOutputSize(_ size: CGSize) { cfg.outputSize = size }

    func getTunables() -> Tunables {
        Tunables(
            deadZoneW: cfg.deadZone.width, deadZoneH: cfg.deadZone.height,
            natFreqHzX: cfg.natFreqHzX, natFreqHzY: cfg.natFreqHzY,
            damping: cfg.damping, softZoneGain: cfg.softZoneGain,
            maxVelPxPerSec: cfg.maxVelPxPerSec, maxAccPxPerSec2: cfg.maxAccPxPerSec2,
            maxZoom: cfg.maxZoom, zoomDeadband: cfg.zoomDeadband,
            maxZoomChangePerSec: cfg.maxZoomChangePerSec,
            maxZoomInPerSec: cfg.maxZoomInPerSec,
            maxZoomOutPerSec: cfg.maxZoomOutPerSec,
            targetWidthLower: cfg.targetWidthRange.lowerBound,
            targetWidthUpper: cfg.targetWidthRange.upperBound,
            microMovePx: cfg.microMovePxOut, detInterval: CGFloat(cfg.detectIntervalFrames),
            adaptiveEnabled: cfg.adaptiveEnabled,
            jitterLowPx: cfg.jitterLowPx, jitterHighPx: cfg.jitterHighPx
        )
    }

    func updateTunables(_ t: Tunables) {
        let lower = max(0.30, min(t.targetWidthLower, 0.90))
        let upper = max(lower + 0.01, min(t.targetWidthUpper, 0.95))
        cfg.deadZone = CGSize(width: max(0, min(t.deadZoneW, 0.20)),
                              height: max(0, min(t.deadZoneH, 0.25)))
        cfg.natFreqHzX = max(0.2, min(t.natFreqHzX, 8))
        cfg.natFreqHzY = max(0.2, min(t.natFreqHzY, 8))
        cfg.damping    = max(0.5, min(t.damping, 1.2))
        cfg.softZoneGain = max(0.5, min(t.softZoneGain, 1.0))
        cfg.maxVelPxPerSec  = max(200, min(t.maxVelPxPerSec, 6000))
        cfg.maxAccPxPerSec2 = max(2000, min(t.maxAccPxPerSec2, 40000))
        cfg.maxZoom = max(1.0, min(t.maxZoom, 5.0))
        cfg.zoomDeadband = max(0.0, min(t.zoomDeadband, 0.10))
        cfg.maxZoomChangePerSec = max(0.05, min(t.maxZoomChangePerSec, 2.0))
        cfg.maxZoomInPerSec = max(0.1, min(t.maxZoomInPerSec, 3.0))
        cfg.maxZoomOutPerSec = max(0.05, min(t.maxZoomOutPerSec, 2.0))
        cfg.targetWidthRange = lower...upper

        cfg.microMovePxOut = max(0, min(t.microMovePx, 12))
        cfg.detectIntervalFrames = max(1, min(Int(round(t.detInterval)), 5))

        cfg.adaptiveEnabled = t.adaptiveEnabled
        cfg.jitterLowPx  = max(0.2, min(t.jitterLowPx, 20))
        cfg.jitterHighPx = max(cfg.jitterLowPx + 0.2, min(t.jitterHighPx, 40))
    }
    // 在 FollowEngine 类中添加
    func setHardLockEnabled(_ on: Bool) {
        // 空实现 - 硬锁功能已移除
        // 保留此方法是为了兼容性
        print("⚠️ 硬锁功能已暂时禁用")
    }

    func applyPreset(_ mode: CaptureMode) {
        currentMode = mode  // 保存当前模式
        
        switch mode {
        case .fitness:
            // 针对健身动作优化 - 灵敏但平滑
            cfg.targetWidthRange = 0.46...0.54
            cfg.maxZoom = 2.5
            
            // 适中的死区，平衡灵敏度和稳定性
            cfg.deadZone = CGSize(width: 0.08, height: 0.10)
            cfg.inPlaceDeadZone = CGSize(width: 0.15, height: 0.18)  // 原地运动时的特殊死区
            
            // 适度防抖
            cfg.microMovePxOut = 6.0
            cfg.jitterThreshold = 3.0
            cfg.zoomDeadband = 0.008
            cfg.minMovementPx = 0.5
            
            // 缩放速度 - 更平滑
            cfg.maxZoomInPerSec = 1.5    // 提高放大速度
            cfg.maxZoomOutPerSec = 1.2   // 提高缩小速度
            cfg.maxZoomChangePerSec = 1.8 // 提高变化速度
            cfg.zoomChangeThreshold = 0.002
            cfg.zoomSmoothAlpha = 0.12  // 适中的平滑
            
            // PD控制器 - 平衡响应和平滑
            cfg.natFreqHzX = 2.8
            cfg.natFreqHzY = 3.0
            cfg.damping = 0.98
            cfg.velocityDamping = 0.94
            
            // 位置滤波 - 快速但平滑
            cfg.positionFilterAlpha = 0.20
            
            // 自适应抖动阈值
            cfg.jitterLowPx = 3.0
            cfg.jitterHighPx = 12.0
            
            // 原地运动检测 - 更快速响应
            cfg.positionStableThreshold = 0.008
            cfg.aspectChangeThreshold = 0.15
            cfg.inPlaceDetectionFrames = 15
            cfg.preInPlaceDetectionFrames = 3
            cfg.preInPlaceThreshold = 0.005
            
        case .dance:
            // 舞蹈模式更灵敏
            cfg.targetWidthRange = 0.40...0.45
            cfg.maxZoom = 1.5
            cfg.maxZoomInPerSec = 2.0    // 舞蹈模式更快
            cfg.maxZoomOutPerSec = 1.8
            cfg.maxZoomChangePerSec = 2.5
            cfg.zoomChangeThreshold = 0.001
            cfg.zoomSmoothAlpha = 0.18  // 更快响应
            
            // 舞蹈模式更灵敏
            cfg.deadZone = CGSize(width: 0.05, height: 0.06)
            cfg.inPlaceDeadZone = CGSize(width: 0.12, height: 0.15)
            cfg.microMovePxOut = 4.0
            cfg.jitterThreshold = 2.5
            cfg.minMovementPx = 0.3  // 更低
            cfg.zoomDeadband = 0.006
            
            // 更快的响应
            cfg.natFreqHzX = 3.5
            cfg.natFreqHzY = 3.7
            cfg.damping = 0.90
            cfg.velocityDamping = 0.96
            
            // 位置滤波 - 快速响应
            cfg.positionFilterAlpha = 0.30
            
            // 舞蹈模式原地运动检测 - 很严格，避免误判
            cfg.positionStableThreshold = 0.006
            cfg.aspectChangeThreshold = 0.20
            cfg.inPlaceDetectionFrames = 20
            cfg.preInPlaceDetectionFrames = 4
            cfg.preInPlaceThreshold = 0.004
        }
        
        // 更新滤波器配置
        setupKalmanFilters()
        setupZoomSmoother()
    }

    // MARK: - 主流程（每帧）
    func process(pixelBuffer: CVPixelBuffer, pts: CMTime) -> FollowResult {
        frameCount += 1
        sensorW = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        sensorH = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        let now = Date()
        let dt = max(1.0/60.0, now.timeIntervalSince(lastTime))
        lastTime = now

        // Detection（按间隔）
        if frameCount % max(1, cfg.detectIntervalFrames) == 0 {
            if let (rect, conf) = detectHuman(pb: pixelBuffer, dt: CGFloat(dt)) {
                rawBox = rect
                confidence = conf
                missCount = 0
                detFrameCount += 1
            } else {
                missCount += 1
                // 关键修改：不立即清空 confidence，而是渐降
                confidence = max(0, confidence - 0.1)
                
                // 保持 rawBox 但降低置信度，而不是设为 nil
                if let lastBox = rawBox {
                    // 虚拟保持最后位置，但标记为低置信度
                    rawBox = lastBox
                }
            }
        }

        // 关键修改：始终尝试维护 stableBox
        if let rb = rawBox {
            if stableBox == nil {
                // 首次出现时，从屏幕中心开始过渡
                let centerBox = CGRect(
                    x: sensorW/2 - rb.width/2,
                    y: sensorH/2 - rb.height/2,
                    width: rb.width,
                    height: rb.height
                )
                stableBox = stabilize(previous: centerBox, target: rb, dt: CGFloat(dt))
            } else {
                // 正常更新，但根据置信度调整响应速度
                stableBox = stabilize(previous: stableBox!, target: rb, dt: CGFloat(dt))
            }
        } else if let sb = stableBox {
            // 没有检测结果时，保持 stableBox 但缓慢回到中心
            let centerTarget = CGRect(
                x: sensorW/2 - sb.width/2,
                y: sensorH/2 - sb.height/2,
                width: sb.width * 0.98,  // 缓慢缩小
                height: sb.height * 0.98
            )
            stableBox = stabilize(previous: sb, target: centerTarget, dt: CGFloat(dt) * 0.1)
            
            // 只有长时间丢失才清空
            if missCount > cfg.lostFramesThreshold * 3 {
                stableBox = nil
            }
        }

        // 固定 AR + 变焦（含原地运动检测）
        let crop = computeCropRect(dt: CGFloat(dt))
        lastCropRect = crop

        // 自适应阻尼/频率
        updateAdaptiveDamping(crop: crop)

        let (cg, ciScaled) = renderCrop(from: pixelBuffer, crop: crop)

        let fps = dt > 0 ? 1.0/dt : 0

        return FollowResult(
            fps: fps, zoom: zoom, confidence: confidence,
            rawBox: rawBox, stableBox: stableBox,
            cropRect: crop, previewCG: cg, ciScaled: ciScaled,
            pts: pts, sensorSize: CGSize(width: sensorW, height: sensorH)
        )
    }

    // 重置跟踪状态
    private func resetTrackingState() {
        centerHistory.removeAll()
        aspectRatioHistory.removeAll()
        isDoingExerciseInPlace = false
        wasInPlace = false
        zoomHistory.removeAll()
        lastDesiredZoom = 1.0
        zoomStableFrames = 0
        positionStableFrames = 0
        lockedZoom = 0
        lockedCenter = nil  // 重置锁定的中心点
        zoomVelocity = 0
        lastZoomVelocity = 0
        lastFilteredX = 0
        lastFilteredY = 0
        lastVelX = 0
        lastVelY = 0
        preInPlaceFrames = 0
        zoomFrozen = false
        zoom = 1.0  // 重置缩放
        motionPredictor.reset()  // 重置运动预测器
        zoomSmoother.reset()  // 重置缩放平滑器
        // 重置卡尔曼滤波器
        kalmanX = nil
        kalmanY = nil
        kalmanW = nil
        kalmanH = nil
    }

    // MARK: 简化的检测函数 - 不再依赖 TargetSelector
    private func detectHuman(pb: CVPixelBuffer, dt: CGFloat) -> (CGRect, CGFloat)? {
        let req = VNDetectHumanRectanglesRequest()
        req.upperBodyOnly = false
        let h = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        
        do {
            try h.perform([req])
            guard let list = req.results, !list.isEmpty else {
                // 没有检测到人，直接返回nil
                return nil
            }

            func toSensor(_ r: CGRect) -> CGRect {
                CGRect(x: r.minX*sensorW,
                       y: (1-r.maxY)*sensorH,
                       width: r.width*sensorW,
                       height: r.height*sensorH)
            }

            let candidates: [(CGRect, CGFloat)] = list.map { (toSensor($0.boundingBox), CGFloat($0.confidence)) }

            // 简单策略：如果有上一帧，选最接近的；否则选最大的
            let selected: (CGRect, CGFloat)
            if let lastBox = rawBox {
                // 选择距离上一帧最近的
                selected = candidates.min { a, b in
                    let distA = hypot(a.0.midX - lastBox.midX, a.0.midY - lastBox.midY)
                    let distB = hypot(b.0.midX - lastBox.midX, b.0.midY - lastBox.midY)
                    return distA < distB
                } ?? candidates[0]
            } else {
                // 第一次检测，选择最大的
                selected = candidates.max { a, b in
                    (a.0.width * a.0.height) < (b.0.width * b.0.height)
                } ?? candidates[0]
            }
            
            let (rawRect, conf) = selected
            
            // 应用卡尔曼滤波平滑识别框
            if kalmanX == nil { setupKalmanFilters() }
            
            let smoothedRect: CGRect
            // 降低IoU阈值，减少重置 - 更渐进的处理
            if let lastBox = rawBox {
                let iou = iouRect(rawRect, lastBox)
                if iou > 0.05 {  // 从0.15降到0.05
                    // 正常更新
                    let smoothX = kalmanX!.update(measurement: rawRect.midX)
                    let smoothY = kalmanY!.update(measurement: rawRect.midY)
                    let smoothW = kalmanW!.update(measurement: rawRect.width)
                    let smoothH = kalmanH!.update(measurement: rawRect.height)
                    
                    smoothedRect = CGRect(
                        x: smoothX - smoothW/2,
                        y: smoothY - smoothH/2,
                        width: smoothW,
                        height: smoothH
                    )
                } else {
                    // 使用基于IoU的渐进混合
                    let blendRatio: CGFloat = max(0.05, min(0.2, iou * 4))  // 基于IoU的渐进混合
                    
                    // 软重置卡尔曼滤波器
                    kalmanX?.softReset(value: rawRect.midX, blendRatio: blendRatio)
                    kalmanY?.softReset(value: rawRect.midY, blendRatio: blendRatio)
                    kalmanW?.softReset(value: rawRect.width, blendRatio: blendRatio)
                    kalmanH?.softReset(value: rawRect.height, blendRatio: blendRatio)
                    
                    // 混合旧框和新框
                    smoothedRect = CGRect(
                        x: lerp(lastBox.midX, rawRect.midX, blendRatio) - rawRect.width/2,
                        y: lerp(lastBox.midY, rawRect.midY, blendRatio) - rawRect.height/2,
                        width: lerp(lastBox.width, rawRect.width, blendRatio),
                        height: lerp(lastBox.height, rawRect.height, blendRatio)
                    )
                }
            } else {
                // 首次检测，完全重置
                kalmanX?.reset(value: rawRect.midX)
                kalmanY?.reset(value: rawRect.midY)
                kalmanW?.reset(value: rawRect.width)
                kalmanH?.reset(value: rawRect.height)
                smoothedRect = rawRect
            }
            
            return (smoothedRect, conf)
            
        } catch {
            return nil
        }
    }

    // MARK: - 改进的 PD stabilizer
    private func stabilize(previous prev: CGRect, target raw: CGRect, dt: CGFloat) -> CGRect {
        let margins = expanded(raw)
        let px = prev.midX, py = prev.midY
        let tx0 = margins.midX, ty0 = margins.midY
        
        // 第一层：指数移动平均滤波（快速响应）
        if lastFilteredX == 0 { lastFilteredX = tx0 }
        if lastFilteredY == 0 { lastFilteredY = ty0 }
        
        let alpha = cfg.positionFilterAlpha
        let filteredX = lastFilteredX * (1 - alpha) + tx0 * alpha
        let filteredY = lastFilteredY * (1 - alpha) + ty0 * alpha
        lastFilteredX = filteredX
        lastFilteredY = filteredY
        
        // 使用运动预测
        let predictedPos = motionPredictor.update(
            position: CGPoint(x: filteredX, y: filteredY),
            dt: dt
        )
        
        // 第二层：现有的PD控制器（平滑运动）
        var dx = predictedPos.x - px
        var dy = predictedPos.y - py

        // 动态调整死区大小
        let movementSpeed = hypot(velX, velY)
        let dynamicDeadZoneScale = movementSpeed > 800 ? 0.8 : 1.1  // 快速移动时稍微减小死区
        
        // 如果在原地运动，使用特殊死区
        let deadZone = isDoingExerciseInPlace ? cfg.inPlaceDeadZone : cfg.deadZone
        
        let deadX = sensorW * deadZone.width * dynamicDeadZoneScale
        let deadY = sensorH * deadZone.height * dynamicDeadZoneScale
        
        let softX = smoothStep(abs(dx), 0, deadX) * cfg.softZoneGain +
                   (1.0 - smoothStep(abs(dx), deadX, deadX * 2))
        let softY = smoothStep(abs(dy), 0, deadY) * cfg.softZoneGain +
                   (1.0 - smoothStep(abs(dy), deadY, deadY * 2))
        
        var tx = px + dx * softX
        var ty = py + dy * softY

        // 增强的抖动抑制
        let jitterThreshold = cfg.jitterThreshold
        let actualDeltaX = tx - px
        let actualDeltaY = ty - py
        
        // 如果移动量太小，使用指数衰减而不是硬阈值
        if abs(actualDeltaX) < jitterThreshold {
            tx = px + actualDeltaX * (abs(actualDeltaX) / jitterThreshold)
        }
        if abs(actualDeltaY) < jitterThreshold {
            ty = py + actualDeltaY * (abs(actualDeltaY) / jitterThreshold)
        }
        
        // 简化的阈值逻辑 - 使用平滑过渡
        let outW = max(cfg.outputSize.width, 1)
        let dynamicThreshold = cfg.microMovePxOut * (sensorW / outW)
        
        // 平滑阈值函数
        func smoothThreshold(_ value: CGFloat, _ threshold: CGFloat) -> CGFloat {
            let absValue = abs(value)
            if absValue < threshold * 0.3 {
                return 0  // 完全停止
            } else if absValue < threshold {
                // 平滑过渡区域 - 二次曲线
                let t = (absValue - threshold * 0.3) / (threshold * 0.7)
                return value * (t * t)
            }
            return value  // 正常移动
        }
        
        // 应用平滑阈值
        let deltaX = tx - px
        let deltaY = ty - py
        let smoothedDeltaX = smoothThreshold(deltaX, dynamicThreshold)
        let smoothedDeltaY = smoothThreshold(deltaY, dynamicThreshold)
        
        tx = px + smoothedDeltaX
        ty = py + smoothedDeltaY

        func step1D(pos: CGFloat, vel: inout CGFloat, tgt: CGFloat, wn: CGFloat, z: CGFloat, dt: CGFloat) -> CGFloat {
            let maxA = cfg.maxAccPxPerSec2, maxV = cfg.maxVelPxPerSec
            
            // 保存上一帧速度
            let lastVel = vel
            
            let err = tgt - pos
            var acc = wn*wn*err - 2*z*wn*vel
            acc = clamp(acc, -maxA, maxA)
            vel = clamp(vel + acc*dt, -maxV, maxV)
            
            // 添加速度平滑
            let maxVelChange = cfg.maxAccPxPerSec2 * dt * 0.5  // 降低速度变化率
            vel = clamp(vel, lastVel - maxVelChange, lastVel + maxVelChange)
            
            // 应用速度阻尼
            vel *= cfg.velocityDamping
            return pos + vel*dt
        }
        
        let wnX = 2 * .pi * cfg.natFreqHzX
        let wnY = 2 * .pi * cfg.natFreqHzY
        let z   = cfg.damping

        lastVelX = velX
        lastVelY = velY
        
        let newCx = step1D(pos: px, vel: &velX, tgt: tx, wn: wnX, z: z, dt: dt)
        let newCy = step1D(pos: py, vel: &velY, tgt: ty, wn: wnY, z: z, dt: dt)
        
        let finalCx = newCx
        let finalCy = newCy

        let w = lerp(prev.width,  margins.width,  0.40)  // 更快的尺寸变化
        let h = lerp(prev.height, margins.height, 0.40)

        var rect = CGRect(x: finalCx - w/2, y: finalCy - h/2, width: w, height: h).integral
        rect = rect.intersection(sensorRect())
        return rect.isNull ? prev : rect
    }

    private func expanded(_ b: CGRect) -> CGRect {
        var w = b.width, h = b.height, x = b.minX, y = b.minY
        let mlr: CGFloat = 0.18, mt: CGFloat = 0.12, mb: CGFloat = 0.18
        x -= w*mlr; y -= h*mt; w += w*(mlr*2); h += h*(mt+mb)
        if b.midY < sensorH*0.4 { let add = h*0.05; y -= add; h += add }
        var r = CGRect(x: x, y: y, width: w, height: h)
        let cap = sensorRect()
        if r.minX < 0 { r.origin.x = 0 }
        if r.minY < 0 { r.origin.y = 0 }
        if r.maxX > cap.maxX { r.origin.x = cap.maxX - r.width }
        if r.maxY > cap.maxY { r.origin.y = cap.maxY - r.height }
        return r
    }

    // MARK: - 改进的变焦 + 固定 AR（含原地运动检测）
    private func computeCropRect(dt: CGFloat) -> CGRect {
        let cap = sensorRect()
        
        // 使用渐变的置信度，而不是硬切换
        let effectiveConfidence = confidence
        let confidenceScale = max(0.1, min(1.0, effectiveConfidence))
        
        // 没有 stableBox 时的处理
        guard let sb = stableBox else {
            // 平滑缩小到1.0，而不是突然跳变
            if zoom > 1.0 {
                let zoomOutSpeed = cfg.maxZoomOutPerSec * dt * 0.5  // 使用较慢速度
                zoom = max(1.0, zoom - zoomOutSpeed)
            } else {
                zoom = 1.0
            }
            
            // 渐进式重置状态
            if isDoingExerciseInPlace {
                isDoingExerciseInPlace = false
                lockedZoom = 0
                lockedCenter = nil
            }
            
            return cap
        }
        
        // === 改进的原地运动检测 ===
        // 只在高置信度时进行原地运动检测
        if effectiveConfidence > 0.6 {
            wasInPlace = isDoingExerciseInPlace
            updateInPlaceDetection(sb: sb)
            updatePreInPlaceDetection(sb: sb)
        } else {
            // 低置信度时逐渐退出原地运动状态
            if isDoingExerciseInPlace {
                positionStableFrames = max(0, positionStableFrames - 1)
                if positionStableFrames == 0 {
                    isDoingExerciseInPlace = false
                    lockedZoom = 0
                    lockedCenter = nil
                }
            }
            preInPlaceFrames = 0
            zoomFrozen = false
        }
        
        // === 三级决策系统（根据置信度调整）===
        if isDoingExerciseInPlace && effectiveConfidence > 0.6 {
            // 第一级：完全锁定（高置信度时）
            if !wasInPlace && isDoingExerciseInPlace {
                lockedZoom = zoom
                lockedCenter = CGPoint(x: sb.midX, y: sb.midY)
            }
            
            if lockedZoom > 0 {
                zoom = lockedZoom
                
                if let locked = lockedCenter {
                    let maxShift: CGFloat = 20.0
                    let dx = clamp(sb.midX - locked.x, -maxShift, maxShift)
                    let dy = clamp(sb.midY - locked.y, -maxShift, maxShift)
                    let constrainedCenter = CGPoint(x: locked.x + dx * 0.2, y: locked.y + dy * 0.2)
                    
                    lockedCenter = constrainedCenter
                    
                    return computeFinalCropRect(
                        zoom: lockedZoom,
                        center: CGRect(x: constrainedCenter.x - sb.width/2,
                                     y: constrainedCenter.y - sb.height/2,
                                     width: sb.width,
                                     height: sb.height),
                        ar: cfg.outputSize.height / cfg.outputSize.width
                    )
                }
            }
            
            return computeFinalCropRect(zoom: zoom, center: sb, ar: cfg.outputSize.height / cfg.outputSize.width)
            
        } else if (zoomFrozen || preInPlaceFrames > 2) && effectiveConfidence > 0.5 {
            // 第二级：预锁定（中等置信度）
            lockedZoom = 0
            lockedCenter = nil
            
            let maxChange: CGFloat = 0.005
            let targetMid = (cfg.targetWidthRange.lowerBound + cfg.targetWidthRange.upperBound) * 0.5
            let personRatio = max(0.001, sb.width / sensorW)
            let desiredZoom = clamp(targetMid / personRatio, 0.8, cfg.maxZoom)
            zoom = clamp(desiredZoom, zoom - maxChange, zoom + maxChange)
            
        } else {
            // 第三级：正常跟踪
            lockedZoom = 0
            lockedCenter = nil
            
            // 计算目标缩放
            let personRatio = max(0.001, sb.width / sensorW)
            let targetMid = (cfg.targetWidthRange.lowerBound + cfg.targetWidthRange.upperBound) * 0.5
            var desiredZoom = targetMid / personRatio
            
            // 限制缩放范围
            desiredZoom = clamp(desiredZoom, 0.8, cfg.maxZoom)
            
            // 低置信度时的额外安全限制
            if effectiveConfidence < 0.5 {
                desiredZoom = min(desiredZoom, 1.5)  // 限制最大缩放
                // 如果当前缩放大于目标，快速缩小
                if zoom > desiredZoom {
                    desiredZoom = zoom - cfg.maxZoomOutPerSec * dt * 0.3
                }
            } else if effectiveConfidence < 0.3 {
                // 极低置信度，趋向于1.0
                desiredZoom = lerp(zoom, 1.0, 0.1)
            }
            
            // 关键修改：根据置信度调整缩放响应速度
            let baseSpeed = zoom > desiredZoom ? cfg.maxZoomOutPerSec : cfg.maxZoomInPerSec
            let zoomSpeed = baseSpeed * confidenceScale * dt
            let zoomDiff = desiredZoom - zoom
            
            // 使用动态死区（低置信度时增大死区）
            let dynamicDeadband = cfg.zoomDeadband * (2.0 - confidenceScale)
            
            if abs(zoomDiff) > dynamicDeadband {
                // 平滑的缩放变化
                let zoomChange = clamp(zoomDiff, -zoomSpeed, zoomSpeed)
                
                // 额外的平滑处理
                // 额外的平滑处理
                if abs(zoomChange) >= 0.001 {  // 只在变化足够大时才更新
                    // 使用指数平滑
                    let smoothingFactor = 0.7 + 0.3 * confidenceScale
                    zoom = zoom * (1 - smoothingFactor) + (zoom + zoomChange) * smoothingFactor
                }
                // 变化太小时不做任何操作，保持当前zoom值
            }
            
            // 确保缩放在合理范围内
            zoom = clamp(zoom, 1.0, cfg.maxZoom)
        }

        return computeFinalCropRect(zoom: zoom, center: sb, ar: cfg.outputSize.height / cfg.outputSize.width)
    }

    // MARK: - 新增：快速预检测
    private func updatePreInPlaceDetection(sb: CGRect) {
        guard centerHistory.count >= 3 else {
            preInPlaceFrames = 0
            zoomFrozen = false
            return
        }
        
        // 快速计算最近几帧的移动
        let recent = Array(centerHistory.suffix(3))
        let avgX = recent.map { $0.x }.reduce(0, +) / CGFloat(recent.count)
        let avgY = recent.map { $0.y }.reduce(0, +) / CGFloat(recent.count)
        
        let variance = recent.reduce(CGFloat(0)) { result, point in
            let dx = point.x - avgX
            let dy = point.y - avgY
            return result + sqrt(dx*dx + dy*dy)
        } / CGFloat(recent.count)
        
        if variance < cfg.preInPlaceThreshold {
            preInPlaceFrames += 1
            if preInPlaceFrames > cfg.preInPlaceDetectionFrames {
                zoomFrozen = true  // 立即冻结缩放
            }
        } else {
            preInPlaceFrames = 0
            if !isDoingExerciseInPlace {
                zoomFrozen = false
            }
        }
    }

    // MARK: - 更严格的原地运动检测
    private func updateInPlaceDetection(sb: CGRect) {
        // 只在高置信度时才进行原地运动检测
        guard confidence > 0.6 else {
            isDoingExerciseInPlace = false
            positionStableFrames = 0
            return
        }
        
        // 记录中心点历史（归一化坐标）
        let center = CGPoint(x: sb.midX / sensorW, y: sb.midY / sensorH)
        centerHistory.append(center)
        if centerHistory.count > centerHistorySize {
            centerHistory.removeFirst()
        }
        
        // 记录高宽比历史
        let aspectRatio = sb.height / max(sb.width, 1)
        aspectRatioHistory.append(aspectRatio)
        if aspectRatioHistory.count > aspectHistorySize {
            aspectRatioHistory.removeFirst()
        }
        
        // 需要足够的历史数据
        guard centerHistory.count >= cfg.inPlaceDetectionFrames,
              aspectRatioHistory.count >= 8 else {
            isDoingExerciseInPlace = false
            return
        }
        
        // 计算位置稳定性
        let recent = Array(centerHistory.suffix(cfg.inPlaceDetectionFrames))
        let avgX = recent.map { $0.x }.reduce(0, +) / CGFloat(recent.count)
        let avgY = recent.map { $0.y }.reduce(0, +) / CGFloat(recent.count)
        
        let varX = recent.map { pow($0.x - avgX, 2) }.reduce(0, +) / CGFloat(recent.count)
        let varY = recent.map { pow($0.y - avgY, 2) }.reduce(0, +) / CGFloat(recent.count)
        let positionVariance = sqrt(varX + varY)
        
        // 计算高宽比变化
        let recentAspect = Array(aspectRatioHistory.suffix(8))
        let minAspect = recentAspect.min() ?? 1.0
        let maxAspect = recentAspect.max() ?? 1.0
        let aspectRange = maxAspect - minAspect
        let avgAspect = recentAspect.reduce(0, +) / CGFloat(recentAspect.count)
        let aspectChangeRatio = aspectRange / max(avgAspect, 0.1)
        
        // 更严格的原地运动特征判断
        let isStablePosition = positionVariance < cfg.positionStableThreshold
        let hasAspectChange = aspectChangeRatio > cfg.aspectChangeThreshold
        let hasHighConfidence = confidence > 0.75
        
        if isStablePosition && hasAspectChange && hasHighConfidence {
            positionStableFrames += 1
        } else {
            positionStableFrames = 0
        }
        
        // 需要连续更多帧满足条件才判定为原地运动
        let requiredFrames = cfg.inPlaceDetectionFrames
        let newInPlace = positionStableFrames > requiredFrames
        
        // 添加迟滞，避免频繁切换
        if !isDoingExerciseInPlace && newInPlace {
            // 进入原地运动需要更严格的确认
            isDoingExerciseInPlace = (positionStableFrames > requiredFrames + 5) &&
                                    (aspectChangeRatio > cfg.aspectChangeThreshold * 1.2)
        } else if isDoingExerciseInPlace && !newInPlace {
            // 退出原地运动可以更快
            isDoingExerciseInPlace = positionStableFrames > requiredFrames / 2
        }
    }

    // MARK: - 增强的平滑缩放计算
    private func computeSmoothZoom(target: CGFloat, current: CGFloat, dt: CGFloat) -> CGFloat {
        // 如果在原地运动或预冻结，返回当前值
        if isDoingExerciseInPlace || zoomFrozen {
            return current
        }
        
        // 使用缩放平滑器
        let smoothedTarget = zoomSmoother.update(target)
        
        // 限制每帧最大变化 - 提高限制，让缩放更快
        let maxDeltaPerFrame: CGFloat = 0.025  // 提高到0.025
        let delta = smoothedTarget - current
        
        // 应用速度限制
        let maxSpeed = delta > 0 ? cfg.maxZoomInPerSec : cfg.maxZoomOutPerSec
        let maxDelta = maxSpeed * CGFloat(dt)
        
        let clampedDelta = clamp(delta, -maxDelta, maxDelta)
        
        // 二次限制，但放宽限制
        let finalDelta = clamp(clampedDelta, -maxDeltaPerFrame, maxDeltaPerFrame)
        
        // 死区处理 - 更小的死区
        if abs(finalDelta) < cfg.zoomDeadband * 0.3 {
            return current
        }
        
        return clamp(current + finalDelta, 1.0, cfg.maxZoom)
    }

    // MARK: - 统一的crop矩形计算方法
    private func computeFinalCropRect(zoom: CGFloat, center: CGRect, ar: CGFloat) -> CGRect {
        let cap = sensorRect()
        var cropW = sensorW / zoom
        var cropH = cropW * ar
        if cropH > sensorH { cropH = sensorH; cropW = cropH / ar }

        var cx = center.midX, cy = center.midY
        
        // 确保crop区域不会超出传感器边界
        func ensureFitsByReducingZoom() -> CGFloat {
            let minCx = cropW/2, maxCx = sensorW - cropW/2
            let minCy = cropH/2, maxCy = sensorH - cropH/2
            let out = (cx < minCx || cx > maxCx || cy < minCy || cy > maxCy)
            guard out, zoom > 1.0 else { return zoom }
            
            let maxWByX = 2 * min(cx, sensorW - cx)
            let maxHByY = 2 * min(cy, sensorH - cy)
            var allowW = maxWByX
            var allowH = allowW * ar
            if allowH > maxHByY { allowH = maxHByY; allowW = allowH / ar }
            
            let newZoom = clamp(sensorW / allowW, 1.0, zoom)
            if newZoom < zoom - 1e-3 {
                self.zoom = newZoom
                cropW = sensorW / newZoom
                cropH = cropW * ar
                if cropH > sensorH { cropH = sensorH; cropW = cropH / ar }
                return newZoom
            }
            return zoom
        }
        
        let finalZoom = ensureFitsByReducingZoom()
        _ = finalZoom
        
        let minCx = cropW/2, maxCx = sensorW - cropW/2
        let minCy = cropH/2, maxCy = sensorH - cropH/2
        cx = clamp(cx, minCx, maxCx)
        cy = clamp(cy, minCy, maxCy)

        let rect = CGRect(x: cx - cropW/2, y: cy - cropH/2, width: cropW, height: cropH).integral
        lastCropRect = rect
        return rect
    }

    // MARK: - 更新自适应阻尼
    private func updateAdaptiveDamping(crop: CGRect) {
        guard cfg.adaptiveEnabled, let sb = stableBox else {
            motionHist.removeAll()
            lastOutCenter = nil
            return
        }
        
        let sx = cfg.outputSize.width / max(crop.width, 1)
        let sy = cfg.outputSize.height / max(crop.height, 1)
        let cOut = CGPoint(x: (sb.midX - crop.minX) * sx, y: (sb.midY - crop.minY) * sy)
        
        if let last = lastOutCenter {
            let d = hypot(cOut.x - last.x, cOut.y - last.y)
            
            if frameCount % (cfg.detectIntervalFrames * 2) == 0 {
                motionHist.append(d)
                if motionHist.count > windowFrames {
                    motionHist.removeFirst()
                }
            }
            
            if motionHist.count >= 10 {
                let sorted = motionHist.sorted()
                let trimmed = Array(sorted.dropFirst(2).dropLast(2))
                let rms = sqrt(trimmed.reduce(0) { $0 + $1*$1 } / CGFloat(max(trimmed.count, 1)))
                
                let t = clamp((rms - cfg.jitterLowPx) / max(cfg.jitterHighPx - cfg.jitterLowPx, 0.001), 0, 1)
                
                // 调整自适应参数范围 - 更灵敏
                let targetDamp: CGFloat = lerp(1.0, 0.92, t * t)  // 适中的阻尼范围
                let targetFx:   CGFloat = lerp(2.5, 3.2, t * 0.7)  // 适中的频率范围
                let targetFy:   CGFloat = lerp(2.7, 3.4, t * 0.7)
                
                let adaptRate: CGFloat = 0.08  // 适中的适应速度
                cfg.damping    = lerp(cfg.damping,    targetDamp, adaptRate)
                cfg.natFreqHzX = lerp(cfg.natFreqHzX, targetFx,   adaptRate)
                cfg.natFreqHzY = lerp(cfg.natFreqHzY, targetFy,   adaptRate)
            }
        }
        lastOutCenter = cOut
    }

    // 渲染
    private func renderCrop(from pixelBuffer: CVPixelBuffer, crop: CGRect) -> (CGImage?, CIImage?) {
        let ciSrc = CIImage(cvPixelBuffer: pixelBuffer)
        let ciCrop = CGRect(x: crop.minX, y: sensorH - crop.maxY, width: crop.width, height: crop.height).integral
        let ciBounds = CGRect(x: 0, y: 0, width: sensorW, height: sensorH)
        let capped = ciCrop.intersection(ciBounds)

        if capped.isNull || capped.width < 4 || capped.height < 4 {
            let sx = cfg.outputSize.width  / sensorW
            let sy = cfg.outputSize.height / sensorH
            let scaled = ciSrc.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            let cg = ciContext.createCGImage(scaled, from: CGRect(origin: .zero, size: cfg.outputSize))
            return (cg, scaled)
        }

        let cropped = ciSrc.cropped(to: capped)
        let moved   = cropped.transformed(by: CGAffineTransform(translationX: -capped.origin.x, y: -capped.origin.y))
        let sx = cfg.outputSize.width  / capped.width
        let sy = cfg.outputSize.height / capped.height
        let scaled = moved.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let cg = ciContext.createCGImage(scaled, from: CGRect(origin: .zero, size: cfg.outputSize))
        return (cg, scaled)
    }

    // MARK: - Helpers
    private func clamp<T: Comparable>(_ v: T,_ a: T,_ b: T) -> T { max(a, min(b, v)) }
    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    private func sensorRect() -> CGRect { CGRect(x: 0, y: 0, width: sensorW, height: sensorH) }
    
    // 平滑阶跃函数
    private func smoothStep(_ x: CGFloat, _ edge0: CGFloat, _ edge1: CGFloat) -> CGFloat {
        let t = clamp((x - edge0) / (edge1 - edge0), 0, 1)
        return t * t * (3 - 2 * t)
    }
    
    private func iouRect(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull { return 0 }
        let i = inter.width * inter.height
        let u = a.width*a.height + b.width*b.height - i
        return u > 0 ? i/u : 0
    }
    
    // 获取缩放状态（用于调试）
    func getZoomStatus() -> String {
        let status = zoomFrozen ? "预冻结" : (isDoingExerciseInPlace ? "锁定" : "跟踪")
        return "缩放: \(String(format: "%.2f", zoom)) | 状态: \(status) | 预检测: \(preInPlaceFrames)"
    }
    
    // 获取原地运动状态（用于调试）
    func getInPlaceStatus() -> String {
        if isDoingExerciseInPlace {
            return "原地运动中 (锁定缩放: \(String(format: "%.2f", lockedZoom)))"
        } else if zoomFrozen {
            return "预锁定 (预检测帧: \(preInPlaceFrames))"
        } else {
            return "正常跟踪 (稳定帧数: \(positionStableFrames)/\(cfg.inPlaceDetectionFrames))"
        }
    }
}

// 别名：让 UI 可以用更直观的命名，不改引擎内部字段
extension FollowEngine.Tunables {
    var smoothFactor: CGFloat {
        get { damping }
        set { damping = newValue }
    }
    var maxMoveSpeedPxPerSec: CGFloat {
        get { maxVelPxPerSec }
        set { maxVelPxPerSec = newValue }
    }
    var maxAccelPxPerSec2: CGFloat {
        get { maxAccPxPerSec2 }
        set { maxAccPxPerSec2 = newValue }
    }
}
