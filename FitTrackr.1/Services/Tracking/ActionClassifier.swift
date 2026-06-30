// ActionClassifier.swift
// 动作分类器：从骨骼点提取特征，判断当前动作状态
// 用于智能构图系统，决定应该使用什么景别

import Vision
import CoreGraphics

// MARK: - 动作状态枚举

enum ActionState: String, CaseIterable {
    case talkingHead    // 静态讲解：人基本不动，对着镜头说话
    case fullBody       // 全身动作：跳舞、走动、全身健身
    case upperBody      // 上半身动作：做饭、弹琴、桌前操作
    case showAndTell    // 展示意图：手伸出展示物品
    case idle           // 无法判断或无人
}

// MARK: - Debug 信息结构体

struct ActionDebugInfo {
    let currentState: ActionState
    let rawState: ActionState           // 未经投票的逐帧结果
    let overallMotion: CGFloat
    let upperLowerRatio: CGFloat
    let handExtension: CGFloat
    let handInCenter: Bool
    let confidence: CGFloat             // 投票置信度（最高票占比）
}

// MARK: - 动作分类器

class ActionClassifier {

    // MARK: - 配置参数

    struct Config {
        // 运动阈值
        var motionThresholdLow: CGFloat = 0.01      // 低于此值认为静止
        var motionThresholdHigh: CGFloat = 0.03     // 高于此值认为有明显运动
        var legMotionThreshold: CGFloat = 0.03     // 腿部运动阈值

        // 手部特征阈值
        var handExtensionThreshold: CGFloat = 1.5   // 手伸展度阈值
        var handCenterRegion: CGFloat = 0.20        // 中心区域占比
        var handCenterHoldTime: CGFloat = 1.5       // 手部中心停留时间（秒）

        // 置信度阈值
        var minJointConfidence: Float = 0.3         // 最低关节点置信度

        // 投票参数
        var votingWindowSize: Int = 20              // 投票窗口大小
        var votingThreshold: CGFloat = 0.65         // 投票通过阈值

        // 状态转换确认帧数
        var framesToFullBody: Int = 8               // talkingHead → fullBody
        var framesToTalkingHead: Int = 15           // fullBody → talkingHead
        var framesToShowAndTell: Int = 20           // 任何 → showAndTell
        var framesFromShowAndTell: Int = 10         // showAndTell → 其他

        // 特征平滑
        var featureSmoothingAlpha: CGFloat = 0.3    // 特征 EMA 平滑系数
    }

    var config = Config()

    // MARK: - 状态变量

    // 上一帧的关节点位置（用于计算位移）
    private var lastJointPositions: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]

    // 特征历史（用于移动平均）
    private var motionHistory: [CGFloat] = []
    private var upperMotionHistory: [CGFloat] = []
    private var lowerMotionHistory: [CGFloat] = []
    private let historySize = 10

    // 平滑后的特征值
    private var smoothedOverallMotion: CGFloat = 0
    private var smoothedUpperMotion: CGFloat = 0
    private var smoothedLowerMotion: CGFloat = 0

    // 手部中心停留计时
    private var handInCenterTimer: CGFloat = 0
    private var lastHandPosition: CGPoint = .zero

    // 投票缓冲区
    private var voteBuffer: [ActionState] = []

    // 当前稳定输出状态
    private var currentState: ActionState = .idle
    private var rawState: ActionState = .idle

    // 状态转换计数器
    private var pendingState: ActionState? = nil
    private var pendingFrameCount: Int = 0

    // 最后一次更新时间
    private var lastUpdateTime: Date = Date()

    // MARK: - 需要用到的关节点

    private let requiredJoints: [VNHumanBodyPoseObservation.JointName] = [
        .nose,
        .leftShoulder, .rightShoulder,
        .leftWrist, .rightWrist,
        .leftHip, .rightHip,
        .leftAnkle, .rightAnkle
    ]

    // MARK: - 公开接口

    /// 每帧调用，传入骨骼点观测
    func update(pose: VNHumanBodyPoseObservation?) -> ActionState {
        let now = Date()
        let dt = CGFloat(now.timeIntervalSince(lastUpdateTime))
        lastUpdateTime = now

        // 无骨骼点数据
        guard let pose = pose else {
            rawState = .idle
            addVote(.idle)
            lastJointPositions.removeAll()
            return currentState
        }

        // 提取关节点
        guard let joints = extractJoints(from: pose) else {
            rawState = .idle
            addVote(.idle)
            return currentState
        }

        // 计算特征
        let features = computeFeatures(joints: joints, dt: dt)

        // 分类
        rawState = classify(features: features)

        // 投票
        addVote(rawState)

        // 更新当前位置为下一帧的"上一帧"
        lastJointPositions = joints

        return currentState
    }

    /// 获取 debug 信息
    func getDebugInfo() -> ActionDebugInfo {
        let confidence = computeVotingConfidence()
        return ActionDebugInfo(
            currentState: currentState,
            rawState: rawState,
            overallMotion: smoothedOverallMotion,
            upperLowerRatio: smoothedLowerMotion > 0.001 ? smoothedUpperMotion / smoothedLowerMotion : 0,
            handExtension: 0, // TODO: 需要缓存
            handInCenter: handInCenterTimer >= config.handCenterHoldTime,
            confidence: confidence
        )
    }

    /// 重置状态
    func reset() {
        lastJointPositions.removeAll()
        motionHistory.removeAll()
        upperMotionHistory.removeAll()
        lowerMotionHistory.removeAll()
        smoothedOverallMotion = 0
        smoothedUpperMotion = 0
        smoothedLowerMotion = 0
        handInCenterTimer = 0
        voteBuffer.removeAll()
        currentState = .idle
        rawState = .idle
        pendingState = nil
        pendingFrameCount = 0
    }

    // MARK: - 私有方法：提取关节点

    private func extractJoints(from pose: VNHumanBodyPoseObservation) -> [VNHumanBodyPoseObservation.JointName: CGPoint]? {
        var joints: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
        var validCount = 0

        for jointName in requiredJoints {
            if let point = try? pose.recognizedPoint(jointName),
               point.confidence >= config.minJointConfidence {
                // Vision 坐标系：左下角为原点，y 向上
                joints[jointName] = CGPoint(x: point.location.x, y: point.location.y)
                validCount += 1
            }
        }

        // 至少需要 5 个有效关节点
        guard validCount >= 5 else { return nil }

        return joints
    }

    // MARK: - 私有方法：计算特征

    private struct Features {
        var overallMotion: CGFloat = 0
        var upperMotion: CGFloat = 0
        var lowerMotion: CGFloat = 0
        var handExtension: CGFloat = 0
        var handInCenter: Bool = false
    }

    private func computeFeatures(joints: [VNHumanBodyPoseObservation.JointName: CGPoint], dt: CGFloat) -> Features {
        var features = Features()

        // 如果没有上一帧数据，无法计算位移
        guard !lastJointPositions.isEmpty else {
            return features
        }

        // 1. 计算各关节位移
        var displacements: [VNHumanBodyPoseObservation.JointName: CGFloat] = [:]
        for (name, pos) in joints {
            if let lastPos = lastJointPositions[name] {
                let dx = pos.x - lastPos.x
                let dy = pos.y - lastPos.y
                displacements[name] = sqrt(dx * dx + dy * dy)
            }
        }

        // 2. 全身运动幅度（所有关节平均位移）
        if !displacements.isEmpty {
            let totalDisplacement = displacements.values.reduce(0, +)
            let avgDisplacement = totalDisplacement / CGFloat(displacements.count)

            motionHistory.append(avgDisplacement)
            if motionHistory.count > historySize {
                motionHistory.removeFirst()
            }

            // 移动平均
            let avgMotion = motionHistory.reduce(0, +) / CGFloat(motionHistory.count)
            smoothedOverallMotion = smoothedOverallMotion * (1 - config.featureSmoothingAlpha) + avgMotion * config.featureSmoothingAlpha
            features.overallMotion = smoothedOverallMotion
        }

        // 3. 上肢运动（手腕位移）
        let leftWristDisp = displacements[.leftWrist] ?? 0
        let rightWristDisp = displacements[.rightWrist] ?? 0
        let upperMotion = (leftWristDisp + rightWristDisp) / 2

        upperMotionHistory.append(upperMotion)
        if upperMotionHistory.count > historySize {
            upperMotionHistory.removeFirst()
        }
        let avgUpperMotion = upperMotionHistory.reduce(0, +) / CGFloat(upperMotionHistory.count)
        smoothedUpperMotion = smoothedUpperMotion * (1 - config.featureSmoothingAlpha) + avgUpperMotion * config.featureSmoothingAlpha
        features.upperMotion = smoothedUpperMotion

        // 4. 下肢运动（脚踝位移）
        let leftAnkleDisp = displacements[.leftAnkle] ?? 0
        let rightAnkleDisp = displacements[.rightAnkle] ?? 0
        let lowerMotion = (leftAnkleDisp + rightAnkleDisp) / 2

        lowerMotionHistory.append(lowerMotion)
        if lowerMotionHistory.count > historySize {
            lowerMotionHistory.removeFirst()
        }
        let avgLowerMotion = lowerMotionHistory.reduce(0, +) / CGFloat(lowerMotionHistory.count)
        smoothedLowerMotion = smoothedLowerMotion * (1 - config.featureSmoothingAlpha) + avgLowerMotion * config.featureSmoothingAlpha
        features.lowerMotion = smoothedLowerMotion

        // 5. 手部伸展度
        features.handExtension = computeHandExtension(joints: joints)

        // 6. 手部是否在中心区域
        features.handInCenter = checkHandInCenter(joints: joints, dt: dt)

        return features
    }

    private func computeHandExtension(joints: [VNHumanBodyPoseObservation.JointName: CGPoint]) -> CGFloat {
        var maxExtension: CGFloat = 0

        // 左手伸展度
        if let leftWrist = joints[.leftWrist],
           let leftShoulder = joints[.leftShoulder],
           let leftHip = joints[.leftHip] {
            let wristToHip = distance(leftWrist, leftHip)
            let shoulderToHip = distance(leftShoulder, leftHip)
            if shoulderToHip > 0.01 {
                let ext = wristToHip / shoulderToHip
                maxExtension = max(maxExtension, ext)
            }
        }

        // 右手伸展度
        if let rightWrist = joints[.rightWrist],
           let rightShoulder = joints[.rightShoulder],
           let rightHip = joints[.rightHip] {
            let wristToHip = distance(rightWrist, rightHip)
            let shoulderToHip = distance(rightShoulder, rightHip)
            if shoulderToHip > 0.01 {
                let ext = wristToHip / shoulderToHip
                maxExtension = max(maxExtension, ext)
            }
        }

        return maxExtension
    }

    private func checkHandInCenter(joints: [VNHumanBodyPoseObservation.JointName: CGPoint], dt: CGFloat) -> Bool {
        // 检测手部是否在画面中心区域
        let centerRegion = config.handCenterRegion
        let centerMin = 0.5 - centerRegion / 2
        let centerMax = 0.5 + centerRegion / 2

        var handInCenter = false
        var handPos: CGPoint = .zero

        // 检查左右手
        for wrist in [VNHumanBodyPoseObservation.JointName.leftWrist, .rightWrist] {
            if let pos = joints[wrist] {
                if pos.x >= centerMin && pos.x <= centerMax &&
                   pos.y >= centerMin && pos.y <= centerMax {
                    handInCenter = true
                    handPos = pos
                    break
                }
            }
        }

        if handInCenter {
            // 检查手部是否静止（位移小）
            let handDisplacement = distance(handPos, lastHandPosition)
            if handDisplacement < 0.02 {
                handInCenterTimer += dt
            } else {
                handInCenterTimer = max(0, handInCenterTimer - dt * 2)
            }
            lastHandPosition = handPos
        } else {
            handInCenterTimer = max(0, handInCenterTimer - dt * 2)
        }

        return handInCenterTimer >= config.handCenterHoldTime
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }

    // MARK: - 私有方法：分类

    private func classify(features: Features) -> ActionState {
        // 规则按优先级排列

        // 1. 如果整体运动很小且上下肢都没动 → talkingHead
        if features.overallMotion < config.motionThresholdLow &&
           features.upperMotion < config.motionThresholdLow &&
           features.lowerMotion < config.motionThresholdLow {
            return .talkingHead
        }

        // 2. showAndTell（暂时禁用，按任务要求先不做）
        // if features.handExtension > config.handExtensionThreshold &&
        //    features.handInCenter &&
        //    features.upperMotion < config.motionThresholdLow {
        //     return .showAndTell
        // }

        // 3. 下肢有运动 → fullBody
        if features.lowerMotion > config.legMotionThreshold {
            return .fullBody
        }

        // 4. 上肢有运动但下肢没动 → upperBody
        if features.upperMotion > config.motionThresholdHigh &&
           features.lowerMotion < config.motionThresholdLow {
            return .upperBody
        }

        // 5. 有一些运动但不明确 → 维持之前的状态或 idle
        if features.overallMotion > config.motionThresholdLow {
            // 有运动但无法明确分类，返回 idle 让投票机制处理
            return .idle
        }

        return .idle
    }

    // MARK: - 私有方法：投票机制

    private func addVote(_ state: ActionState) {
        voteBuffer.append(state)
        if voteBuffer.count > config.votingWindowSize {
            voteBuffer.removeFirst()
        }

        // 统计票数
        var counts: [ActionState: Int] = [:]
        for s in voteBuffer {
            counts[s, default: 0] += 1
        }

        // 找出最高票
        guard let (topState, topCount) = counts.max(by: { $0.value < $1.value }) else {
            return
        }

        let ratio = CGFloat(topCount) / CGFloat(voteBuffer.count)

        // 状态转换逻辑
        if topState != currentState {
            // 开始计数或继续计数
            if pendingState == topState {
                pendingFrameCount += 1
            } else {
                pendingState = topState
                pendingFrameCount = 1
            }

            // 根据转换类型决定需要的确认帧数
            let requiredFrames = getRequiredFrames(from: currentState, to: topState)

            // 检查是否达到确认条件
            if ratio >= config.votingThreshold && pendingFrameCount >= requiredFrames {
                currentState = topState
                pendingState = nil
                pendingFrameCount = 0
            }
        } else {
            // 状态一致，清除 pending
            pendingState = nil
            pendingFrameCount = 0
        }
    }

    private func getRequiredFrames(from: ActionState, to: ActionState) -> Int {
        switch (from, to) {
        case (.talkingHead, .fullBody):
            return config.framesToFullBody
        case (.fullBody, .talkingHead):
            return config.framesToTalkingHead
        case (_, .showAndTell):
            return config.framesToShowAndTell
        case (.showAndTell, _):
            return config.framesFromShowAndTell
        default:
            return 10 // 默认确认帧数
        }
    }

    private func computeVotingConfidence() -> CGFloat {
        guard !voteBuffer.isEmpty else { return 0 }

        var counts: [ActionState: Int] = [:]
        for s in voteBuffer {
            counts[s, default: 0] += 1
        }

        guard let (_, topCount) = counts.max(by: { $0.value < $1.value }) else {
            return 0
        }

        return CGFloat(topCount) / CGFloat(voteBuffer.count)
    }
}
