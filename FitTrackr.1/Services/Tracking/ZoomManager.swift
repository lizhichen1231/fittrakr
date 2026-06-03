import Vision
import CoreGraphics
import AVFoundation

// MARK: - 缩放模式

enum ZoomMode {
    case intelligent    // 接受 ShotDecider 的指令
    case fixed          // 原有逻辑，基于 personHeightRatio
}

// MARK: - 缩放控制 + 原地运动检测
extension TrackingController {

    // MARK: - 髋部数据更新
    func updateHipCenter(_ center: CGPoint?, confidence: Float) {
        guard let hip = center, confidence >= 0.3 else { return }

        hipHistory.append(hip)
        if hipHistory.count > hipHistorySize {
            hipHistory.removeFirst()
        }

        guard hipHistory.count >= 8 else {
            hipBasedInPlace = false
            hipStableFrames = 0
            return
        }

        let xValues = hipHistory.map { $0.x }
        let xRange = (xValues.max() ?? 0) - (xValues.min() ?? 0)

        if xRange < hipStableThreshold {
            hipStableFrames += 1
        } else {
            hipStableFrames = max(0, hipStableFrames - 2)
        }

        let wasHipInPlace = hipBasedInPlace
        hipBasedInPlace = hipStableFrames >= hipInPlaceRequiredFrames

        if hipBasedInPlace && !wasHipInPlace {
            print("📍 髋部检测：进入原地状态")
        } else if !hipBasedInPlace && wasHipInPlace {
            print("🚶 髋部检测：退出原地状态")
        }
    }

    /// 更新缩放（委托给单一 log 域控制器 ZoomController）
    /// measuredRatio 来自全画幅矩形高度，不随 zoom 变 → 开环前馈，无闭环反馈震荡。
    func updateZoomLevel(heightRatio: CGFloat, dt: CGFloat) {
        zoom = zoomController.update(measuredRatio: heightRatio, dt: dt)

        if frameCount % 30 == 0 {
            print("📏 缩放: ratio=\(String(format: "%.0f%%", heightRatio * 100)) → zoom=\(String(format: "%.2f", zoom))x hold=\(zoomController.isHolding)")
        }
    }

    // MARK: - 智能模式：执行景别指令

    /// 智能模式：执行 ShotDecider 的景别指令。
    /// 执行端统一走同一 ZoomController（command 路径）；本函数不改 ShotDecider 的决策逻辑。
    /// - Parameters:
    ///   - instruction: 景别指令
    ///   - dt: 时间步长
    func applyInstruction(_ instruction: ShotInstruction, dt: CGFloat) {
        let targetZoom = clamp(instruction.targetZoom, 1.0, cfg.maxZoom)
        zoom = zoomController.command(towardZoom: targetZoom, dt: dt)

        if frameCount % 30 == 0 {
            print("🎬 智能缩放: shot=\(instruction.shotType.rawValue) target=\(String(format: "%.2f", targetZoom))x → zoom=\(String(format: "%.2f", zoom))x")
        }
    }

    // MARK: - 连续缩放 + 固定 AR
    func computeCropRect(dt: CGFloat) -> CGRect {
        let cap = sensorRect()
        let ar = cfg.outputSize.height / cfg.outputSize.width

        // 无人检测时：平滑回到中心 + 1x
        guard let sb = stableBox else {
            // 缩放平滑回 1x（统一走 ZoomController）
            zoom = zoomController.command(towardZoom: 1.0, dt: dt)

            // 位置平滑回中心（不要 reset，用弹簧过渡）
            let centerTarget = CGPoint(x: sensorW / 2, y: sensorH / 2)
            let smoothedCenter = positionSpring.update(target: centerTarget, dt: dt)

            // 清除跟踪状态（但不清除控制器状态）
            // 注意：保留 ZoomController 的 currentLogZoom（不 reset），避免人重新出现时跳变
            isDoingExerciseInPlace = false
            lockedZoom = 0
            lockedCenter = nil
            zoomFrozen = false
            preInPlaceFrames = 0
            positionStableFrames = 0

            // 日志
            if frameCount % 30 == 0 {
                print("👻 无人: zoom=\(String(format: "%.2f", zoom))x center=(\(String(format: "%.0f", smoothedCenter.x)), \(String(format: "%.0f", smoothedCenter.y)))")
            }

            // 用平滑后的位置和缩放计算裁切（不是直接返回 cap）
            let centerRect = CGRect(x: smoothedCenter.x - 100, y: smoothedCenter.y - 200, width: 200, height: 400)
            return computeFinalCropRect(zoom: zoom, center: centerRect, ar: ar)
        }

        // === 原地运动检测（优先使用髋部数据） ===
        wasInPlace = isDoingExerciseInPlace

        if hipHistory.count >= 8 {
            isDoingExerciseInPlace = hipBasedInPlace
        } else if confidence > 0.6 {
            updateInPlaceDetection(sb: sb)
            updatePreInPlaceDetection(sb: sb)
        } else {
            if isDoingExerciseInPlace {
                positionStableFrames = max(0, positionStableFrames - 1)
                hipStableFrames = max(0, hipStableFrames - 1)
                if positionStableFrames == 0 && hipStableFrames < hipInPlaceRequiredFrames {
                    isDoingExerciseInPlace = false
                    lockedZoom = 0
                    lockedCenter = nil
                }
            }
            preInPlaceFrames = 0
        }

        // === 连续缩放系统（所有缩放变化都通过 ZoomController）===

        if isDoingExerciseInPlace && confidence > 0.6 {
            // 原地运动：锁定缩放
            if !wasInPlace {
                lockedZoom = zoom
                lockedCenter = CGPoint(x: sb.midX, y: sb.midY)
            }
            if lockedZoom > 0 {
                // 原地锁定：命令 ZoomController hold 到锁定值（同一控制器，带按秒速率帽）
                zoom = zoomController.command(towardZoom: lockedZoom, dt: dt)
            }
        } else {
            // 正常跟踪：根据高度比例调整缩放
            lockedZoom = 0
            lockedCenter = nil

            if let heightRatio = lastHeightRatio {
                updateZoomLevel(heightRatio: heightRatio, dt: dt)
            } else if let heightRatio = getHeightRatioFromTightBox() {
                updateZoomLevel(heightRatio: heightRatio, dt: dt)
            }
        }

        var centerForCrop = sb
        if isDoingExerciseInPlace, let locked = lockedCenter {
            let maxShift: CGFloat = 20.0
            let dx = clamp(sb.midX - locked.x, -maxShift, maxShift)
            let dy = clamp(sb.midY - locked.y, -maxShift, maxShift)
            let constrainedCenter = CGPoint(x: locked.x + dx * 0.2, y: locked.y + dy * 0.2)
            lockedCenter = constrainedCenter

            centerForCrop = CGRect(
                x: constrainedCenter.x - sb.width/2,
                y: constrainedCenter.y - sb.height/2,
                width: sb.width,
                height: sb.height
            )
        }

        return computeFinalCropRect(zoom: zoom, center: centerForCrop, ar: cfg.outputSize.height / cfg.outputSize.width)
    }

    // MARK: - 新增：快速预检测
    func updatePreInPlaceDetection(sb: CGRect) {
        guard centerHistory.count >= 3 else {
            preInPlaceFrames = 0
            zoomFrozen = false
            return
        }

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
                zoomFrozen = true
            }
        } else {
            preInPlaceFrames = 0
            if !isDoingExerciseInPlace {
                zoomFrozen = false
            }
        }
    }

    // MARK: - 更严格的原地运动检测
    func updateInPlaceDetection(sb: CGRect) {
        guard confidence > 0.6 else {
            isDoingExerciseInPlace = false
            positionStableFrames = 0
            return
        }

        let center = CGPoint(x: sb.midX / sensorW, y: sb.midY / sensorH)
        centerHistory.append(center)
        if centerHistory.count > centerHistorySize {
            centerHistory.removeFirst()
        }

        let aspectRatio = sb.height / max(sb.width, 1)
        aspectRatioHistory.append(aspectRatio)
        if aspectRatioHistory.count > aspectHistorySize {
            aspectRatioHistory.removeFirst()
        }

        guard centerHistory.count >= cfg.inPlaceDetectionFrames,
              aspectRatioHistory.count >= 8 else {
            isDoingExerciseInPlace = false
            return
        }

        let recent = Array(centerHistory.suffix(cfg.inPlaceDetectionFrames))
        let avgX = recent.map { $0.x }.reduce(0, +) / CGFloat(recent.count)
        let avgY = recent.map { $0.y }.reduce(0, +) / CGFloat(recent.count)

        let varX = recent.map { pow($0.x - avgX, 2) }.reduce(0, +) / CGFloat(recent.count)
        let varY = recent.map { pow($0.y - avgY, 2) }.reduce(0, +) / CGFloat(recent.count)
        let positionVariance = sqrt(varX + varY)

        let recentAspect = Array(aspectRatioHistory.suffix(8))
        let minAspect = recentAspect.min() ?? 1.0
        let maxAspect = recentAspect.max() ?? 1.0
        let aspectRange = maxAspect - minAspect
        let avgAspect = recentAspect.reduce(0, +) / CGFloat(recentAspect.count)
        let aspectChangeRatio = aspectRange / max(avgAspect, 0.1)

        let isStablePosition = positionVariance < cfg.positionStableThreshold
        let hasAspectChange = aspectChangeRatio > cfg.aspectChangeThreshold
        let hasHighConfidence = confidence > 0.75

        if isStablePosition && hasAspectChange && hasHighConfidence {
            positionStableFrames += 1
        } else {
            positionStableFrames = 0
        }

        let requiredFrames = cfg.inPlaceDetectionFrames
        let newInPlace = positionStableFrames > requiredFrames

        if !isDoingExerciseInPlace && newInPlace {
            isDoingExerciseInPlace = (positionStableFrames > requiredFrames + 5) &&
                                    (aspectChangeRatio > cfg.aspectChangeThreshold * 1.2)
        } else if isDoingExerciseInPlace && !newInPlace {
            isDoingExerciseInPlace = positionStableFrames > requiredFrames / 2
        }
    }

    // MARK: - 统一的crop矩形计算方法
    func computeFinalCropRect(zoom currentZoom: CGFloat, center: CGRect, ar: CGFloat) -> CGRect {
        // 使用当前 zoom 计算裁切尺寸
        var cropW = sensorW / currentZoom
        var cropH = cropW * ar
        if cropH > sensorH { cropH = sensorH; cropW = cropH / ar }

        var cx = center.midX, cy = center.midY

        // 应用构图偏移（由 ShotDecider 设置）
        // framingOffset 是归一化坐标，需要转换为像素
        let smoothedOffset = smoothFramingOffset(framingOffset)
        cx += smoothedOffset.x * cropW
        cy += smoothedOffset.y * cropH

        // 边界约束：移动中心点而不是改变缩放
        let minCx = cropW/2, maxCx = sensorW - cropW/2
        let minCy = cropH/2, maxCy = sensorH - cropH/2
        cx = clamp(cx, minCx, maxCx)
        cy = clamp(cy, minCy, maxCy)

        let rect = CGRect(x: cx - cropW/2, y: cy - cropH/2, width: cropW, height: cropH)
        lastCropRect = rect
        return rect
    }

    // MARK: - 构图偏移平滑
    private func smoothFramingOffset(_ target: CGPoint) -> CGPoint {
        // 使用简单的 EMA 平滑偏移变化，避免跳变
        let alpha: CGFloat = 0.08
        smoothedFramingOffset = CGPoint(
            x: smoothedFramingOffset.x + (target.x - smoothedFramingOffset.x) * alpha,
            y: smoothedFramingOffset.y + (target.y - smoothedFramingOffset.y) * alpha
        )
        return smoothedFramingOffset
    }

    // MARK: - 调试信息

    func getZoomStatus() -> String {
        let status = isDoingExerciseInPlace ? "原地锁定" : "连续跟踪"
        let hr = lastHeightRatio ?? 0
        return "缩放: \(String(format: "%.2f", zoom))x | 人高: \(String(format: "%.0f%%", hr * 100)) | \(status)"
    }

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
