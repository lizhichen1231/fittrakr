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
        // 改动2:仅完整全身框时给「不出框」上钳,否则 nil(维持原 maxZoom 上钳)
        zoom = zoomController.update(measuredRatio: heightRatio, dt: dt,
                                    bodyMaxLogZoom: bodyMaxLogZoom())

        if frameCount % 30 == 0 {
            print("📏 缩放: ratio=\(String(format: "%.0f%%", heightRatio * 100)) → zoom=\(String(format: "%.2f", zoom))x hold=\(zoomController.isHolding)")
        }
    }

    /// 改动2:全身不出框上钳(log 域)。tightBoxHeightRatio 用 smoothedTightBox 高度比;
    /// 仅 lastTightBoxIsFullBody 时返回值,否则 nil(不钳)。
    func bodyMaxLogZoom() -> CGFloat? {
        guard lastTightBoxIsFullBody, let box = smoothedTightBox else { return nil }
        let h = box.height / sensorH
        guard h > 0.01 else { return nil }
        return log(targetBodyFraction / h)
    }

    /// 改动3:近期 torso 比例是否稳定(尺度不变)。样本不足 → true(不阻止锁定,维持原 hip-only 行为)。
    func isScaleStable() -> Bool {
        guard torsoRatioHistory.count >= scaleStableMinSamples,
              let cur = lastTorsoRatio, cur > 0 else { return true }
        let recent = torsoRatioHistory.suffix(torsoScaleHistorySize)
        let range = (recent.max() ?? cur) - (recent.min() ?? cur)
        return (range / cur) < scaleStableThreshold
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
            return computeFinalCropRect(zoom: zoom, center: centerRect, ar: ar)   // target 直接喂出口二阶弹簧
        }

        // === 原地运动检测（优先使用髋部数据） ===
        wasInPlace = isDoingExerciseInPlace

        if disableInPlaceLock {
            // 整条 lock 已禁用:isDoingExerciseInPlace 恒 false;髋判定 + isScaleStable(尺度逃逸)一并旁路(死代码)
            isDoingExerciseInPlace = false
        } else if hipHistory.count >= 8 {
            // 髋横向稳 + 尺度稳 才算原地(已禁用,见上)
            isDoingExerciseInPlace = hipBasedInPlace && isScaleStable()
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
        // 改动A:软锁定 —— 原地不再把 zoom 钉死(删了 command(towardZoom: lockedZoom)),
        // 改为「提高刚度、慢跟随真实 target」,永不 dead-stop → 顿挫消失。
        // dtEff = dt / stiffness 喂控制器:等价 tau_eff = tau×stiffness、rateCap_eff = maxLogZoomRate/stiffness。
        let inPlaceActive = isDoingExerciseInPlace && confidence > 0.6 && !disableInPlaceLock

        // 事件日志(临时):LOCK engage/release
        if inPlaceActive != prevInPlaceActive {
            print(String(format: "🔒 LOCK %@ @frame%d (hipStable=%@ scaleStable=%@ zoom=%.2f)",
                         inPlaceActive ? "engage" : "release", frameCount,
                         hipBasedInPlace ? "T" : "F", isScaleStable() ? "T" : "F", zoom))
            prevInPlaceActive = inPlaceActive
        }

        // 锚点:crop 横向+纵向都锚 pose 框(smoothedTightBox)中心,与显示的人对齐、零偏置。
        // 改A:pose 丢失不立刻回退 rect(那会把锚拽来拽去漂)——先在上一帧 pose 锚 coast poseCoastFrames 帧;
        // 超过仍没回来,才把目标切到 rect,由下游 slewGate 限速过渡(不 snap)。
        let anchorMidX: CGFloat
        let anchorMidY: CGFloat
        if let stb = smoothedTightBox {
            anchorMidX = stb.midX; anchorMidY = stb.midY
            lastPoseAnchorX = stb.midX; lastPoseAnchorY = stb.midY
            poseAnchorValid = true
            poseLostFrames = 0
        } else if poseAnchorValid && poseLostFrames < poseCoastFrames {
            poseLostFrames += 1
            anchorMidX = lastPoseAnchorX; anchorMidY = lastPoseAnchorY   // coast:保持上一帧 pose 锚
        } else {
            anchorMidX = sb.midX; anchorMidY = sb.midY                   // 久无 pose → 过渡到 rect(slewGate 限速)
        }
        // 取证:锚中心相对上帧跳变量(占画面宽比例)
        dbgAnchorDelta = (dbgPrevAnchorX >= 0) ? hypot(anchorMidX - dbgPrevAnchorX, anchorMidY - dbgPrevAnchorY) / max(sensorW, 1) : 0
        dbgPrevAnchorX = anchorMidX; dbgPrevAnchorY = anchorMidY
        // 取证:锚中心相对上帧跳变量(占画面宽比例)
        dbgAnchorDelta = (dbgPrevAnchorX >= 0) ? hypot(anchorMidX - dbgPrevAnchorX, anchorMidY - dbgPrevAnchorY) / max(sensorW, 1) : 0
        dbgPrevAnchorX = anchorMidX; dbgPrevAnchorY = anchorMidY

        // 位置锁(与 zoom 无关,保留原行为):进入记锁定中心(用 pose 锚),退出清除。zoom 不再钉。
        if inPlaceActive {
            if !wasInPlace { lockedCenter = CGPoint(x: anchorMidX, y: anchorMidY) }
        } else {
            lockedCenter = nil
        }
        lockedZoom = 0   // 不再用 zoom 钉值(保留字段,供别处复位代码引用)

        // 刚度渐入渐出(~lockRampTime 秒),避免 engage/release 速度突变
        let targetStiffness: CGFloat = inPlaceActive ? lockStiffness : 1.0
        let ramp = min(1.0, dt / lockRampTime)
        lockStiffnessCurrent += (targetStiffness - lockStiffnessCurrent) * ramp
        let dtEff = dt / max(1.0, lockStiffnessCurrent)

        // 缩放主测量(原地/非原地同一路径,只 dtEff 不同 → 无路径切换顿挫)。
        // 躯干高为主(刚体,抗原地动作+低噪声),缺骨骼时回退全身框高/紧贴框高。三级兜底逻辑不变。
        let selectedRatio: CGFloat?
        if let torsoRatio = lastTorsoRatio {
            selectedRatio = torsoRatio
        } else if let heightRatio = lastHeightRatio {
            selectedRatio = heightRatio
        } else if let heightRatio = getHeightRatioFromTightBox() {
            selectedRatio = heightRatio
        } else {
            selectedRatio = nil
        }

        // 单层离群限幅(唯一出口):只在兜底选完的最终值上,把每帧变化 clamp 到 上一帧喂入值 ±maxFedRatioStep。
        // 是「限幅」不是「丢弃/换源」—— 不引入独立 coast、不和三级兜底抢源,避免上一版那种两机制横跳。
        if let raw = selectedRatio {
            let fed: CGFloat
            if let prev = lastFedRatio, prev > 0 {
                let maxStep = prev * maxFedRatioStep
                fed = prev + clamp(raw - prev, -maxStep, maxStep)
            } else {
                fed = raw
            }
            lastFedRatio = fed
            dbgZoomSrc = lastTorsoRatio != nil ? "torso" : (lastHeightRatio != nil ? "rectH" : "tightH")   // 整合 HUD
            dbgRatioDelta = (dbgPrevFedRatio >= 0) ? abs(fed - dbgPrevFedRatio) : 0   // 取证
            dbgPrevFedRatio = fed
            updateZoomLevel(heightRatio: fed, dt: dtEff)
        }

        // crop 中心:横向 anchorMidX、纵向 anchorMidY,都来自 pose 框、零偏置。原地时绕 pose 锚的 lockedCenter 约束。
        var centerForCrop: CGRect
        if isDoingExerciseInPlace, let locked = lockedCenter {
            let maxShift: CGFloat = 20.0
            let dx = clamp(anchorMidX - locked.x, -maxShift, maxShift)   // 横向跟 pose 锚
            let dy = clamp(anchorMidY - locked.y, -maxShift, maxShift)   // 纵向跟 pose 锚
            let constrainedCenter = CGPoint(x: locked.x + dx * 0.2, y: locked.y + dy * 0.2)
            lockedCenter = constrainedCenter

            centerForCrop = CGRect(
                x: constrainedCenter.x - sb.width/2,
                y: constrainedCenter.y - sb.height/2,
                width: sb.width,
                height: sb.height
            )
        } else {
            centerForCrop = CGRect(x: anchorMidX - sb.width/2, y: anchorMidY - sb.height/2,
                                   width: sb.width, height: sb.height)   // midX=pose, midY=pose(对称)
        }

        return computeFinalCropRect(zoom: zoom, center: centerForCrop, ar: cfg.outputSize.height / cfg.outputSize.width)   // target 直接喂出口二阶弹簧
    }

    // MARK: - 全局位置速率闸(流水线最后,所有分支汇合后的兜底)
    /// 对即将传给 computeFinalCropRect 的 crop 中心做单帧 slew clamp(帧率无关:maxPosRate × smoothedDt)。
    /// 上游 spring/EMA 负责日常柔顺,这道闸只削平滑没压住的尖峰(不替代上游平滑)。
    /// cold-start / 重置后首帧直接就位(snap、不夹),其后才限速 → 任何分支都无单帧阶跃。
    func slewGatePosition(_ center: CGRect) -> CGRect {
        guard sensorW > 0, sensorH > 0 else { return center }
        let normX = center.midX / sensorW
        let normY = center.midY / sensorH
        if !prevCropValid {
            prevCropCx = normX; prevCropCy = normY; prevCropValid = true
            #if DEBUG
            dbgSlewLine = String(format: "SNAP pos=(%.3f,%.3f) @f%d 绕过限速", normX, normY, frameCount)
            print("🚦 SLEW " + dbgSlewLine)
            #endif
            return center
        }
        let step = maxPosRate * CGFloat(smoothedDt)
        let dX = normX - prevCropCx, dY = normY - prevCropCy
        let hit = abs(dX) > step || abs(dY) > step
        slewHitStreak = hit ? slewHitStreak + 1 : 0   // 连续顶上限帧数 = 同向冲刺长度(大=持续漂)
        #if DEBUG
        if hit {
            dbgSlewLine = String(format: "HIT pos Δ=(%.3f,%.3f) step=%.3f streak=%d @f%d", dX, dY, step, slewHitStreak, frameCount)
            print("🚦 SLEW " + dbgSlewLine)
        }
        #endif
        let newX = prevCropCx + clamp(dX, -step, step)
        let newY = prevCropCy + clamp(dY, -step, step)
        prevCropCx = newX; prevCropCy = newY
        return CGRect(x: newX * sensorW - center.width / 2,
                      y: newY * sensorH - center.height / 2,
                      width: center.width, height: center.height)
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
        // ===== 二阶临界阻尼跟随(取代出口限速 + slewGate):target → 弹簧 → 最终 cropC/zoom =====
        // 速度惯性本身限制单帧变化 → 废帧被惯性吃掉、下帧拉回,不需也不该再夹限速/clamp。
        let _dtc = CGFloat(smoothedDt)
        if !cropSpringValid {
            cropCenterSpring.reset(to: CGPoint(x: center.midX, y: center.midY))
            cropZoomSpring.reset(to: log(max(currentZoom, 0.01)))
            cropSpringValid = true
        }
        let _sc = cropCenterSpring.update(target: CGPoint(x: center.midX, y: center.midY), dt: _dtc)
        let currentZoom = exp(cropZoomSpring.update(target: log(max(currentZoom, 0.01)), dt: _dtc))
        let center = CGRect(x: _sc.x - center.width / 2, y: _sc.y - center.height / 2,
                            width: center.width, height: center.height)

        // 【刀4 兑换】数字裁剪只承担设备 zoom 之外的余量:Z_digital = Z_total / Z_device。
        // 除法必须在弹簧【后】:弹簧全程跑 Z_total 域(跨切换连续),切换帧 D 跳变与 buffer 光学跳变
        // 同帧互补 → 显示构图数值连续(不变量 I)。除法在弹簧前会让弹簧把跳变滑 0.45s = 可见拉风箱。
        // lensDeviceZoom=1(影子模式/Tier0/多摄长焦路径)时本行恒等,行为冻结。
        let effZoom = max(1.0, currentZoom / max(lensDeviceZoom, 1.0))

        // 使用当前 zoom 计算裁切尺寸
        var cropW = sensorW / effZoom
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

        #if DEBUG
        // 诊断行(HUD 读:CameraViewModel.dbgCropHUD)。仅 showDebugOverlay 开时才 format,平时零开销。
        if hudDebugEnabled, rect.width > 0, rect.height > 0 {
            let clampX = (cx == minCx ? "minCLAMP" : (cx == maxCx ? "maxCLAMP" : "free"))
            if let stb = smoothedTightBox {
                let poseOutX = (stb.midX - rect.minX) / rect.width    // pose 中心落在【输出帧】哪(判定关键)
                dbgCropLine = String(format: "DBG cropC.x=%.2f poseN.x=%.2f poseOut.x=%.2f clampX=%@",
                                     cx / sensorW, stb.midX / sensorW, poseOutX, clampX)
            } else {
                dbgCropLine = String(format: "DBG cropC.x=%.2f poseN.x=-- poseOut.x=-- clampX=%@",
                                     cx / sensorW, clampX)
            }
        }
        #endif

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
