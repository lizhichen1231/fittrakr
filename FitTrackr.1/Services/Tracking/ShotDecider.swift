// ShotDecider.swift
// 景别决策器：根据动作状态决定使用什么景别
// 包含状态机控制过渡、冷却期、呼吸感等

import CoreGraphics
import Foundation

// MARK: - 景别类型

enum ShotType: String, CaseIterable {
    case closeUp    // 中近景，突出面部表情，zoom ~1.8-2.0x
    case medium     // 中景，展示上半身动作，zoom ~1.3-1.5x
    case wide       // 远景，展示全身，zoom ~1.0x
    case detail     // 局部特写，跟踪手部，zoom ~2.0-2.5x（暂不启用）
}

// MARK: - 缓动曲线

enum EaseCurve: String {
    case easeOut        // 快启慢停，用于推近
    case easeInOut      // 平缓过渡，用于拉远
    case linear         // 线性，用于微调
}

// MARK: - 优先级

enum ShotPriority: Int, Comparable {
    case low = 0        // 微调呼吸，可被任何切换中断
    case normal = 1     // 正常景别切换
    case high = 2       // 高优先切换（如 showAndTell 推特写）

    static func < (lhs: ShotPriority, rhs: ShotPriority) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

// MARK: - 景别指令

struct ShotInstruction {
    let shotType: ShotType
    let targetZoom: CGFloat             // 目标缩放倍数
    let framingOffset: CGPoint          // 构图偏移（归一化，0,0为中心）
    let transitionDuration: CGFloat     // 过渡时长（秒）
    let transitionCurve: EaseCurve      // 缓动类型
    let priority: ShotPriority          // 能否中断当前过渡

    static let idle = ShotInstruction(
        shotType: .wide,
        targetZoom: 1.0,
        framingOffset: .zero,
        transitionDuration: 0,
        transitionCurve: .linear,
        priority: .low
    )
}

// MARK: - 状态机状态

enum ShotStateMachineState: String {
    case holding        // 稳定持有当前景别
    case transitioning  // 正在过渡
    case breathing      // 微调呼吸（暂不启用）
}

// MARK: - 景别决策器

class ShotDecider {

    // MARK: - 配置

    struct Config {
        // 冷却和间隔
        var minSwitchInterval: CGFloat = 2.5        // 最小切换间隔（秒）

        // 呼吸模式（暂不启用）
        var breathingThreshold: CGFloat = 8.0       // 进入呼吸模式的停留时长
        var breathingAmplitude: CGFloat = 0.12      // 呼吸幅度
        var breathingPeriod: CGFloat = 3.5          // 呼吸周期（秒）
        var breathingEnabled: Bool = false          // 是否启用呼吸

        // 缩放限制
        var maxUsableZoom: CGFloat = 2.5            // 最大可用缩放

        // 过渡时长
        var pushInDuration: CGFloat = 0.6           // 推近时长
        var pullOutDuration: CGFloat = 1.2          // 拉远时长
        var sameLevelDuration: CGFloat = 0.8        // 同级切换时长

        // 确认时间
        var pushInConfirmTime: CGFloat = 0.6        // 推近确认时间
        var pullOutConfirmTime: CGFloat = 1.2       // 拉远确认时间
        var sameLevelConfirmTime: CGFloat = 0.8     // 同级切换确认时间

        // 中断阈值
        var interruptThreshold: CGFloat = 0.30      // 过渡进度低于此值可中断
    }

    var config = Config()

    // MARK: - 景别参数定义

    private struct ShotParams {
        let zoom: CGFloat
        let offset: CGPoint
    }

    private let shotParams: [ShotType: ShotParams] = [
        .closeUp: ShotParams(zoom: 1.8, offset: CGPoint(x: 0, y: -0.08)),   // 脸在上1/3
        .medium:  ShotParams(zoom: 1.4, offset: CGPoint(x: 0, y: -0.03)),
        .wide:    ShotParams(zoom: 1.0, offset: CGPoint(x: 0, y: 0)),
        .detail:  ShotParams(zoom: 2.2, offset: CGPoint(x: 0, y: 0))        // 暂不启用
    ]

    // MARK: - 状态变量

    private var stateMachineState: ShotStateMachineState = .holding
    private var currentShotType: ShotType = .wide
    private var targetShotType: ShotType = .wide

    // 过渡控制
    private var transitionProgress: CGFloat = 0     // 0~1
    private var transitionDuration: CGFloat = 0
    private var transitionCurve: EaseCurve = .linear
    private var transitionStartZoom: CGFloat = 1.0
    private var transitionStartOffset: CGPoint = .zero

    // 冷却计时
    private var lastSwitchTime: Date = Date.distantPast
    private var holdingTime: CGFloat = 0

    // 动作确认
    private var pendingAction: ActionState? = nil
    private var pendingActionTime: CGFloat = 0

    // 呼吸相关
    private var breathingPhase: CGFloat = 0

    // 手动模式
    private var isManualOverride: Bool = false
    private var manualOverrideStartTime: Date? = nil
    private let manualOverrideDuration: CGFloat = 5.0  // 手动模式持续5秒

    // 当前输出值
    private var currentZoom: CGFloat = 1.0
    private var currentOffset: CGPoint = .zero

    // MARK: - 公开接口

    /// 每帧调用
    func update(action: ActionState, handPosition: CGPoint? = nil, dt: CGFloat) -> ShotInstruction {
        // 检查手动模式是否过期
        if isManualOverride, let startTime = manualOverrideStartTime {
            if Date().timeIntervalSince(startTime) > Double(manualOverrideDuration) {
                isManualOverride = false
                manualOverrideStartTime = nil
            }
        }

        // 手动模式下不做自动切换
        if isManualOverride {
            return ShotInstruction(
                shotType: currentShotType,
                targetZoom: currentZoom,
                framingOffset: currentOffset,
                transitionDuration: 0,
                transitionCurve: .linear,
                priority: .low
            )
        }

        // 处理 idle 状态：保持当前景别
        if action == .idle {
            pendingAction = nil
            pendingActionTime = 0
            return createCurrentInstruction()
        }

        // 确定目标景别
        let desiredShotType = mapActionToShot(action)

        // 如果目标和当前不同，开始确认计时
        if desiredShotType != currentShotType {
            if pendingAction == action {
                pendingActionTime += dt
            } else {
                pendingAction = action
                pendingActionTime = dt
            }

            // 检查确认时间
            let confirmTime = getConfirmTime(from: currentShotType, to: desiredShotType)
            if pendingActionTime >= confirmTime {
                // 检查冷却期
                let timeSinceLastSwitch = Date().timeIntervalSince(lastSwitchTime)
                if timeSinceLastSwitch >= Double(config.minSwitchInterval) {
                    // 可以切换
                    startTransition(to: desiredShotType)
                    pendingAction = nil
                    pendingActionTime = 0
                }
            }
        } else {
            pendingAction = nil
            pendingActionTime = 0
            holdingTime += dt
        }

        // 更新状态机
        updateStateMachine(dt: dt)

        return createCurrentInstruction()
    }

    /// 用户手动缩放时调用，进入临时手动模式
    func enterManualOverride() {
        isManualOverride = true
        manualOverrideStartTime = Date()

        // 中断当前过渡
        if stateMachineState == .transitioning {
            stateMachineState = .holding
            transitionProgress = 0
        }
    }

    /// 获取当前状态（用于 debug）
    func getCurrentState() -> (shotType: ShotType, state: ShotStateMachineState, progress: CGFloat) {
        return (currentShotType, stateMachineState, transitionProgress)
    }

    /// 重置
    func reset() {
        stateMachineState = .holding
        currentShotType = .wide
        targetShotType = .wide
        transitionProgress = 0
        currentZoom = 1.0
        currentOffset = .zero
        holdingTime = 0
        pendingAction = nil
        pendingActionTime = 0
        breathingPhase = 0
        isManualOverride = false
        manualOverrideStartTime = nil
        lastSwitchTime = Date.distantPast
    }

    // MARK: - 私有方法

    private func mapActionToShot(_ action: ActionState) -> ShotType {
        switch action {
        case .talkingHead:
            return .closeUp
        case .upperBody:
            return .medium
        case .fullBody:
            return .wide
        case .showAndTell:
            // 暂时降级为 closeUp，不启用 detail
            return .closeUp
        case .idle:
            return currentShotType
        }
    }

    private func getConfirmTime(from: ShotType, to: ShotType) -> CGFloat {
        // 判断是推近还是拉远
        let fromZoom = shotParams[from]?.zoom ?? 1.0
        let toZoom = shotParams[to]?.zoom ?? 1.0

        if toZoom > fromZoom {
            // 推近
            return config.pushInConfirmTime
        } else if toZoom < fromZoom {
            // 拉远
            return config.pullOutConfirmTime
        } else {
            // 同级
            return config.sameLevelConfirmTime
        }
    }

    private func getTransitionDuration(from: ShotType, to: ShotType) -> CGFloat {
        let fromZoom = shotParams[from]?.zoom ?? 1.0
        let toZoom = shotParams[to]?.zoom ?? 1.0

        if toZoom > fromZoom {
            return config.pushInDuration
        } else if toZoom < fromZoom {
            return config.pullOutDuration
        } else {
            return config.sameLevelDuration
        }
    }

    private func getTransitionCurve(from: ShotType, to: ShotType) -> EaseCurve {
        let fromZoom = shotParams[from]?.zoom ?? 1.0
        let toZoom = shotParams[to]?.zoom ?? 1.0

        if toZoom > fromZoom {
            return .easeOut  // 推近：快启慢停
        } else {
            return .easeInOut  // 拉远或同级：平缓
        }
    }

    private func startTransition(to newShotType: ShotType) {
        // 检查是否可以中断当前过渡
        if stateMachineState == .transitioning {
            if transitionProgress > config.interruptThreshold {
                // 不可中断
                return
            }
        }

        targetShotType = newShotType
        stateMachineState = .transitioning
        transitionProgress = 0
        transitionDuration = getTransitionDuration(from: currentShotType, to: newShotType)
        transitionCurve = getTransitionCurve(from: currentShotType, to: newShotType)
        transitionStartZoom = currentZoom
        transitionStartOffset = currentOffset
        holdingTime = 0
        lastSwitchTime = Date()
    }

    private func updateStateMachine(dt: CGFloat) {
        switch stateMachineState {
        case .holding:
            // 检查是否进入呼吸模式
            if config.breathingEnabled && holdingTime >= config.breathingThreshold {
                stateMachineState = .breathing
                breathingPhase = 0
            }

        case .transitioning:
            // 更新过渡进度
            if transitionDuration > 0 {
                transitionProgress += dt / transitionDuration
            } else {
                transitionProgress = 1
            }

            if transitionProgress >= 1.0 {
                transitionProgress = 1.0
                currentShotType = targetShotType
                stateMachineState = .holding
                holdingTime = 0
            }

            // 计算当前值
            let easedProgress = applyEaseCurve(transitionProgress, curve: transitionCurve)
            let targetParams = shotParams[targetShotType] ?? ShotParams(zoom: 1.0, offset: .zero)
            let targetZoom = min(targetParams.zoom, config.maxUsableZoom)

            currentZoom = lerp(transitionStartZoom, targetZoom, easedProgress)
            currentOffset = lerpPoint(transitionStartOffset, targetParams.offset, easedProgress)

        case .breathing:
            // 呼吸模式（暂不启用）
            if config.breathingEnabled {
                breathingPhase += dt
                let baseParams = shotParams[currentShotType] ?? ShotParams(zoom: 1.0, offset: .zero)
                let breathOffset = config.breathingAmplitude * sin(breathingPhase * 2 * .pi / config.breathingPeriod)
                currentZoom = min(baseParams.zoom + breathOffset, config.maxUsableZoom)
            }
        }
    }

    private func applyEaseCurve(_ t: CGFloat, curve: EaseCurve) -> CGFloat {
        switch curve {
        case .linear:
            return t
        case .easeOut:
            // 快启慢停：1 - (1-t)^2
            return 1 - pow(1 - t, 2)
        case .easeInOut:
            // 两头慢中间快：smoothstep
            return t * t * (3 - 2 * t)
        }
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        return a + (b - a) * t
    }

    private func lerpPoint(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        return CGPoint(
            x: lerp(a.x, b.x, t),
            y: lerp(a.y, b.y, t)
        )
    }

    private func createCurrentInstruction() -> ShotInstruction {
        let params = shotParams[currentShotType] ?? ShotParams(zoom: 1.0, offset: .zero)

        // 如果正在过渡，返回过渡中的值
        if stateMachineState == .transitioning {
            return ShotInstruction(
                shotType: targetShotType,
                targetZoom: currentZoom,
                framingOffset: currentOffset,
                transitionDuration: transitionDuration * (1 - transitionProgress),
                transitionCurve: transitionCurve,
                priority: .normal
            )
        }

        // 稳定状态
        return ShotInstruction(
            shotType: currentShotType,
            targetZoom: min(params.zoom, config.maxUsableZoom),
            framingOffset: params.offset,
            transitionDuration: 0,
            transitionCurve: .linear,
            priority: .low
        )
    }
}
