// DebugData.swift
// Debug 数据结构，汇总追踪、动作分类、景别决策的所有调试信息

import CoreGraphics
import Vision

#if DEBUG

// MARK: - Debug 数据结构

struct DebugData {
    // === 追踪层 ===
    let rawBox: CGRect?                 // 原始检测框（归一化坐标）
    let stableBox: CGRect?              // 卡尔曼滤波后的稳定框
    let confidence: CGFloat             // 检测置信度
    let currentZoom: CGFloat            // 当前缩放倍数
    let fps: CGFloat                    // 处理帧率

    // === 动作分类层 ===
    let actionState: ActionState        // 当前稳定动作状态
    let rawActionState: ActionState     // 逐帧原始分类（未经投票）
    let actionConfidence: CGFloat       // 投票置信度（0-1）
    let overallMotion: CGFloat          // 全身运动幅度
    let upperLowerRatio: CGFloat        // 上下半身运动比
    let handExtension: CGFloat          // 手部伸展度
    let handInCenter: Bool              // 手是否在中心区域

    // === 景别决策层 ===
    let shotType: ShotType              // 当前景别
    let targetShotType: ShotType        // 目标景别（过渡中时和当前不同）
    let stateMachineState: String       // "Holding" / "Transitioning" / "Breathing"
    let transitionProgress: CGFloat     // 过渡进度（0-1，非过渡中为0）
    let timeSinceLastSwitch: CGFloat    // 距离上次景别切换的秒数
    let framingOffset: CGPoint          // 当前构图偏移

    // === 骨骼点 ===
    let jointPositions: [String: CGPoint]?   // 关节点位置（归一化），key 为关节名
    let jointConfidences: [String: CGFloat]? // 关节点置信度

    // === 缩放模式 ===
    let zoomMode: ZoomMode              // 当前缩放模式

    // MARK: - 默认空数据

    static let empty = DebugData(
        rawBox: nil,
        stableBox: nil,
        confidence: 0,
        currentZoom: 1.0,
        fps: 0,
        actionState: .idle,
        rawActionState: .idle,
        actionConfidence: 0,
        overallMotion: 0,
        upperLowerRatio: 0,
        handExtension: 0,
        handInCenter: false,
        shotType: .wide,
        targetShotType: .wide,
        stateMachineState: "Holding",
        transitionProgress: 0,
        timeSinceLastSwitch: 0,
        framingOffset: .zero,
        jointPositions: nil,
        jointConfidences: nil,
        zoomMode: .fixed
    )
}

// MARK: - TrackingController Debug Data Extension

extension TrackingController {

    /// 获取当前 debug 数据
    func getDebugData(fps: CGFloat) -> DebugData {
        // 获取动作分类器信息
        let actionDebug = actionClassifier.getDebugInfo()

        // 获取景别决策器信息
        let (shotType, state, progress) = shotDecider.getCurrentState()

        // 获取骨骼点信息
        var jointPositions: [String: CGPoint]? = nil
        var jointConfidences: [String: CGFloat]? = nil

        if let pose = lastPoseObservation {
            jointPositions = [:]
            jointConfidences = [:]

            let jointNames: [VNHumanBodyPoseObservation.JointName] = [
                .nose, .leftEye, .rightEye, .leftEar, .rightEar,
                .leftShoulder, .rightShoulder,
                .leftElbow, .rightElbow,
                .leftWrist, .rightWrist,
                .leftHip, .rightHip,
                .leftKnee, .rightKnee,
                .leftAnkle, .rightAnkle
            ]

            for jointName in jointNames {
                if let point = try? pose.recognizedPoint(jointName) {
                    let name = jointName.rawValue.rawValue
                    jointPositions?[name] = point.location
                    jointConfidences?[name] = CGFloat(point.confidence)
                }
            }
        }

        // 计算归一化的 box
        let normalizedRawBox: CGRect? = rawBox.map { box in
            CGRect(
                x: box.minX / sensorW,
                y: box.minY / sensorH,
                width: box.width / sensorW,
                height: box.height / sensorH
            )
        }

        let normalizedStableBox: CGRect? = stableBox.map { box in
            CGRect(
                x: box.minX / sensorW,
                y: box.minY / sensorH,
                width: box.width / sensorW,
                height: box.height / sensorH
            )
        }

        return DebugData(
            rawBox: normalizedRawBox,
            stableBox: normalizedStableBox,
            confidence: confidence,
            currentZoom: zoom,
            fps: fps,
            actionState: actionDebug.currentState,
            rawActionState: actionDebug.rawState,
            actionConfidence: actionDebug.confidence,
            overallMotion: actionDebug.overallMotion,
            upperLowerRatio: actionDebug.upperLowerRatio,
            handExtension: actionDebug.handExtension,
            handInCenter: actionDebug.handInCenter,
            shotType: shotType,
            targetShotType: shotType, // TODO: 需要从 ShotDecider 获取目标
            stateMachineState: state.rawValue,
            transitionProgress: progress,
            timeSinceLastSwitch: 0, // TODO: 需要从 ShotDecider 获取
            framingOffset: framingOffset,
            jointPositions: jointPositions,
            jointConfidences: jointConfidences,
            zoomMode: zoomMode
        )
    }
}

#endif
