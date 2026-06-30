import CoreGraphics

// MARK: - 辅助类

/// 临界阻尼弹簧：平滑的加速减速曲线，无振荡
/// 用于缩放和位置的平滑过渡
class CriticalDampedSpring {
    var position: CGFloat
    var velocity: CGFloat = 0
    private let stiffness: CGFloat    // 弹簧刚度（越大响应越快）
    private let damping: CGFloat      // 阻尼系数（临界阻尼 = 2 * sqrt(stiffness)）
    private let maxVelocity: CGFloat  // 最大速度限制

    /// 初始化临界阻尼弹簧
    /// - Parameters:
    ///   - initialValue: 初始位置
    ///   - responseTime: 响应时间（秒），越小响应越快
    ///   - maxVelocity: 最大速度限制
    init(initialValue: CGFloat = 0, responseTime: CGFloat = 0.3, maxVelocity: CGFloat = .infinity) {
        self.position = initialValue
        // 从响应时间计算弹簧参数
        // 临界阻尼下，~3*responseTime 到达 95% 目标
        self.stiffness = pow(2.0 / responseTime, 2)
        self.damping = 2.0 * sqrt(stiffness)  // 临界阻尼
        self.maxVelocity = maxVelocity
    }

    /// 更新弹簧状态
    /// - Parameters:
    ///   - target: 目标位置
    ///   - dt: 时间步长
    /// - Returns: 当前位置
    func update(target: CGFloat, dt: CGFloat) -> CGFloat {
        let error = target - position

        // 弹簧力学：加速度 = 刚度 * 误差 - 阻尼 * 速度
        let acceleration = stiffness * error - damping * velocity

        // 更新速度和位置
        velocity += acceleration * dt
        velocity = max(-maxVelocity, min(maxVelocity, velocity))
        position += velocity * dt

        // 接近目标时停止
        if abs(error) < 0.001 && abs(velocity) < 0.01 {
            position = target
            velocity = 0
        }

        return position
    }

    /// 重置到指定值
    func reset(to value: CGFloat) {
        position = value
        velocity = 0
    }
}

/// 2D 临界阻尼弹簧
class CriticalDampedSpring2D {
    var springX: CriticalDampedSpring
    var springY: CriticalDampedSpring

    init(initialValue: CGPoint = .zero, responseTime: CGFloat = 0.3, maxVelocity: CGFloat = .infinity) {
        springX = CriticalDampedSpring(initialValue: initialValue.x, responseTime: responseTime, maxVelocity: maxVelocity)
        springY = CriticalDampedSpring(initialValue: initialValue.y, responseTime: responseTime, maxVelocity: maxVelocity)
    }

    func update(target: CGPoint, dt: CGFloat) -> CGPoint {
        let x = springX.update(target: target.x, dt: dt)
        let y = springY.update(target: target.y, dt: dt)
        return CGPoint(x: x, y: y)
    }

    func reset(to value: CGPoint) {
        springX.reset(to: value.x)
        springY.reset(to: value.y)
    }

    var position: CGPoint {
        CGPoint(x: springX.position, y: springY.position)
    }

    var velocity: CGPoint {
        CGPoint(x: springX.velocity, y: springY.velocity)
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
        let xPred = x
        let pPred = p + q
        let k = pPred / (pPred + r)
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
        p = min(p + 0.1, 1.0)
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

        if positionHistory.count >= 2 {
            let lastPos = positionHistory[positionHistory.count - 2]
            let vel = (x: (position.x - lastPos.x) / dt,
                      y: (position.y - lastPos.y) / dt)
            velocityHistory.append(vel)
            if velocityHistory.count > historySize {
                velocityHistory.removeFirst()
            }
        }

        if velocityHistory.count >= 3 {
            let avgVel = velocityHistory.suffix(3).reduce((x: 0, y: 0)) {
                (x: $0.x + $1.x/3, y: $0.y + $1.y/3)
            }
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

// MARK: - 平移控制（PD 稳定器 + 自适应阻尼）
extension TrackingController {

    // 设置卡尔曼滤波器 - 更强的平滑效果
    func setupKalmanFilters() {
        // processNoise 越小 → 滤波器越相信预测（更平滑但响应慢）
        // measurementNoise 越大 → 滤波器越不信任测量（更平滑）
        let processNoise: CGFloat = currentMode == .fitness ? 0.0002 : 0.0005
        let measurementNoise: CGFloat = currentMode == .fitness ? 0.12 : 0.08

        kalmanX = SimpleKalmanFilter(processNoise: processNoise, measurementNoise: measurementNoise)
        kalmanY = SimpleKalmanFilter(processNoise: processNoise, measurementNoise: measurementNoise)
        kalmanW = SimpleKalmanFilter(processNoise: processNoise * 0.3, measurementNoise: measurementNoise * 1.2)
        kalmanH = SimpleKalmanFilter(processNoise: processNoise * 0.3, measurementNoise: measurementNoise * 1.2)
    }

    // MARK: - 改进的弹簧稳定器（平滑加速减速曲线）
    func stabilize(previous prev: CGRect, target raw: CGRect, dt: CGFloat) -> CGRect {
        let margins = expanded(raw)

        // 目标位置和尺寸
        let targetCenter = CGPoint(x: margins.midX, y: margins.midY)
        let targetSize = CGPoint(x: margins.width, y: margins.height)

        // 初始化弹簧位置（首次调用）
        if positionSpring.position == .zero {
            positionSpring.reset(to: targetCenter)
        }
        if sizeSpring.position == .zero {
            sizeSpring.reset(to: targetSize)
        }

        // 死区处理：在死区内减少目标的移动
        // 修:死区按 zoom 缩,使其在【输出空间】恒定(全帧死区 / zoom),而不是整帧恒定。
        //   1x 不变;4x 收紧到 1/4(0.12·W→0.03·W)→ 高 zoom 下 crop 跟得紧,残差不再被放大成左右甩。
        let deadZone = isDoingExerciseInPlace ? cfg.inPlaceDeadZone : cfg.deadZone
        let zoomForDead = max(1.0, zoom)
        let deadX = sensorW * deadZone.width  / zoomForDead
        let deadY = sensorH * deadZone.height / zoomForDead

        let currentCenter = positionSpring.position
        let dx = targetCenter.x - currentCenter.x
        let dy = targetCenter.y - currentCenter.y

        // 应用死区：在死区内衰减移动量
        var adjustedTarget = targetCenter
        if abs(dx) < deadX {
            let factor = smoothStep(abs(dx), deadX * 0.3, deadX)
            adjustedTarget.x = currentCenter.x + dx * factor
        }
        if abs(dy) < deadY {
            let factor = smoothStep(abs(dy), deadY * 0.3, deadY)
            adjustedTarget.y = currentCenter.y + dy * factor
        }

        // 使用弹簧系统更新位置（平滑加速减速）
        let newCenter = positionSpring.update(target: adjustedTarget, dt: dt)

        // 尺寸也使用弹簧系统
        var sizeTarget = targetSize
        if isDoingExerciseInPlace || zoomFrozen {
            // 原地运动时锁定尺寸
            sizeTarget = sizeSpring.position
        }
        let newSize = sizeSpring.update(target: sizeTarget, dt: dt)

        // 更新速度变量（用于其他逻辑）
        velX = positionSpring.springX.velocity
        velY = positionSpring.springY.velocity

        // 构建最终矩形
        var rect = CGRect(
            x: newCenter.x - newSize.x / 2,
            y: newCenter.y - newSize.y / 2,
            width: newSize.x,
            height: newSize.y
        )

        // 边界约束
        rect = rect.intersection(sensorRect())
        return rect.isNull ? prev : rect
    }

    func expanded(_ b: CGRect) -> CGRect {
        let padX: CGFloat = 15
        let padY: CGFloat = 20

        var r = CGRect(
            x: b.minX - padX,
            y: b.minY - padY,
            width: b.width + padX * 2,
            height: b.height + padY * 2
        )

        let cap = sensorRect()
        if r.minX < 0 { r.origin.x = 0 }
        if r.minY < 0 { r.origin.y = 0 }
        if r.maxX > cap.maxX { r.origin.x = cap.maxX - r.width }
        if r.maxY > cap.maxY { r.origin.y = cap.maxY - r.height }
        r = r.intersection(cap)

        return r.isNull ? b : r
    }

    // MARK: - 更新自适应阻尼
    func updateAdaptiveDamping(crop: CGRect) {
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

                let targetDamp: CGFloat = lerp(1.0, 0.92, t * t)
                let targetFx:   CGFloat = lerp(2.5, 3.2, t * 0.7)
                let targetFy:   CGFloat = lerp(2.7, 3.4, t * 0.7)

                let adaptRate: CGFloat = 0.08
                cfg.damping    = lerp(cfg.damping,    targetDamp, adaptRate)
                cfg.natFreqHzX = lerp(cfg.natFreqHzX, targetFx,   adaptRate)
                cfg.natFreqHzY = lerp(cfg.natFreqHzY, targetFy,   adaptRate)
            }
        }
        lastOutCenter = cOut
    }
}
