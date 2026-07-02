import Vision
import CoreGraphics
import AVFoundation
import CoreImage
import QuartzCore

#if DEBUG
// 任务二 Q1 临时计时:拆 detectHuman(rect)每帧成本;摊薄每30帧打一行(不改逻辑)
private var _dhFindUs = 0.0, _dhWithConfUs = 0.0, _dhDiagUs = 0.0, _dhN = 0
#endif

// MARK: - 人体检测（骨骼 + 矩形兜底 + 卡尔曼平滑）
extension TrackingController {

    // MARK: - 统一骨骼检测（只跑一次）

    /// 统一的骨骼检测（每帧只跑一次）。
    /// matchingBox 非 nil(锁定中)→ 返回 tightBox 中心最接近它的 pose(= 锁定的你),而非第一个;
    /// nil(未锁定)→ 返回第一个(现行为不变)。这是「多人锁定接到 zoom/构图」的最后一接。
    func detectPose(pb: CVPixelBuffer, matchingBox: CGRect? = nil) -> VNHumanBodyPoseObservation? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        do {
            try handler.perform([poseRequest])
            guard let results = poseRequest.results, !results.isEmpty else { return nil }
            #if DEBUG
            print("👁VNPose results.count=\(results.count) 输入=\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) matched=\(matchingBox != nil)")
            #endif
            // 锁定 + 多人:选 tightBox 中心最接近锁定框的 pose(= 你),爹的 pose 不再喂 zoom/锚点
            guard let target = matchingBox, results.count > 1 else { return results.first }
            let tc = CGPoint(x: target.midX, y: target.midY)
            return results.min { a, b in
                poseCenterDist(a, to: tc) < poseCenterDist(b, to: tc)
            }
        } catch {
            return nil
        }
    }

    /// pose 的 tightBox 中心(wide 传感器坐标)到目标点的距离;无有效 tightBox 视为极远。
    private func poseCenterDist(_ obs: VNHumanBodyPoseObservation, to target: CGPoint) -> CGFloat {
        guard let box = getTightBoxFromPose(obs) else { return .greatestFiniteMagnitude }
        return hypot(box.midX - target.x, box.midY - target.y)
    }

    // MARK: - 骨骼点紧贴框计算

    /// 从 VNHumanBodyPoseObservation 计算紧贴人体的 bounding box
    func getTightBoxFromPose(_ pose: VNHumanBodyPoseObservation) -> CGRect? {
        guard let points = try? pose.recognizedPoints(.all) else { return nil }

        let validPoints = points.values.filter { $0.confidence > 0.3 }
        guard validPoints.count >= 5 else { return nil }

        let xs = validPoints.map { $0.location.x }
        let ys = validPoints.map { $0.location.y }

        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }

        let padX: CGFloat = (maxX - minX) * 0.08
        let padY: CGFloat = (maxY - minY) * 0.08

        let boxMinX = max(0, minX - padX) * sensorW
        let boxMaxY = min(1, maxY + padY)
        let boxMinY = max(0, minY - padY)
        let boxWidth = min(sensorW, (maxX - minX + padX * 2) * sensorW)
        let boxHeight = min(sensorH, (boxMaxY - boxMinY) * sensorH)

        let tightBox = CGRect(
            x: boxMinX,
            y: (1 - boxMaxY) * sensorH,
            width: boxWidth,
            height: boxHeight
        )

        if frameCount % 30 == 0 {
            let heightRatio = boxHeight / sensorH
            print("🦴 骨骼点框: validPts=\(validPoints.count) h=\(String(format: "%.0f", boxHeight)) ratio=\(String(format: "%.2f", heightRatio))")
        }

        return tightBox
    }

    /// 从缓存的 pose 获取高度比例（不再重新检测）
    func getHeightRatioFromPose(_ pose: VNHumanBodyPoseObservation) -> CGFloat? {
        guard let points = try? pose.recognizedPoints(.all) else { return nil }

        let validPoints = points.values.filter { $0.confidence > 0.3 }
        guard validPoints.count >= 5 else { return nil }

        let ys = validPoints.map { $0.location.y }
        guard let minY = ys.min(), let maxY = ys.max() else { return nil }

        return maxY - minY
    }

    /// 躯干高原始测量：两肩中点 → 两髋中点的画面投影距离 ÷ 画面高。
    /// 躯干近似刚体——深蹲/抬手/手脚摆动几乎不改变它，比"全身框高"噪声小且不被原地动作误触发。
    /// 复用已检测的 pose 关键点，不新增检测。
    /// 置信度门控：四点（两肩+两髋）任一低于 cfg.torsoMinConfidence（遮挡/侧身/丢点）即返回 nil →
    /// 由 ingestTorsoMeasurement 冻结在上一有效值，不用低置信点算、也不回退全身框高（尺度不同会突变）。
    func getTorsoRatioFromPose(_ pose: VNHumanBodyPoseObservation) -> CGFloat? {
        guard let points = try? pose.recognizedPoints(.all) else { return nil }

        let minConf = cfg.torsoMinConfidence
        func pt(_ name: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let p = points[name], p.confidence >= minConf else { return nil }
            return p.location
        }
        // 整合 HUD:门控前记四点 conf(取自同一份 points,不另算)
        dbgCfLsh = points[.leftShoulder]?.confidence ?? 0
        dbgCfRsh = points[.rightShoulder]?.confidence ?? 0
        dbgCfLhp = points[.leftHip]?.confidence ?? 0
        dbgCfRhp = points[.rightHip]?.confidence ?? 0
        // 严格四点门控：侧身/遮挡导致任一肩或髋低置信 → 冻结（zoom 基本不动），不用退化点硬算
        guard let ls = pt(.leftShoulder), let rs = pt(.rightShoulder),
              let lh = pt(.leftHip), let rh = pt(.rightHip) else { return nil }

        let shoulder = CGPoint(x: (ls.x + rs.x) / 2, y: (ls.y + rs.y) / 2)
        let hip = CGPoint(x: (lh.x + rh.x) / 2, y: (lh.y + rh.y) / 2)

        // 归一化坐标 → 像素投影距离 ÷ 画面高（与 lastHeightRatio 同尺度：占画面高的比例）
        let dx = (shoulder.x - hip.x) * sensorW
        let dy = (shoulder.y - hip.y) * sensorH
        let ratio = hypot(dx, dy) / sensorH
        guard ratio > 0.01 else { return nil }                // 退化保护
        return ratio
    }

    /// 测量预处理层：门控 → 突变拒绝（离群点）→ 小窗中值，输出写入 lastTorsoRatio。
    /// 设计原则：整条链只有"测量预处理 → ZoomController(log+settle+速率帽)"两层，
    /// 这里不做 EMA/卡尔曼/弹簧——避免多层滤波叠相位滞后。
    func ingestTorsoMeasurement(_ pose: VNHumanBodyPoseObservation) {
        // 当前帧全身框高比(改动1 的标定与回退都用「高度」,非面积/宽度——转身时高度基本不变)
        let boxHeightRatio = getHeightRatioFromTightBox()

        // ===== 有好 torso 的帧:正常更新 + 顺带标定 torso↔box 转换比 =====
        let _torsoRaw = getTorsoRatioFromPose(pose)
        dbgPoseValid = (_torsoRaw != nil)   // 取证:四点 0.5 门是否通过
        if let raw = _torsoRaw {
            torsoLostFrames = 0   // 有 torso 读数 → 清零瞬丢计数
            // 改动1-① 标定:torsoToBoxHeight = EMA(torsoRatio / 全身框高比),仅好 torso 帧更新
            if let boxH = boxHeightRatio, boxH > 0.01 {
                let ratioNow = raw / boxH
                if torsoToBoxHeight <= 0 {
                    torsoToBoxHeight = ratioNow                       // 冷启动初始化
                } else {
                    torsoToBoxHeight = (1 - torsoToBoxCalibAlpha) * torsoToBoxHeight
                                     + torsoToBoxCalibAlpha * ratioNow
                }
                torsoCalibFrames += 1
                if torsoCalibFrames >= torsoToBoxCalibFrames { hasCalibratedRatio = true }
            }

            // 改动B:突变检测 —— 离群不再冻死,而是「惯性续走」;连续超 reset 帧才软 re-baseline
            if let last = lastTorsoRatio, last > 0 {
                let rel = abs(raw - last) / last
                if rel > cfg.torsoOutlierMaxStep {
                    torsoOutlierStreak += 1
                    if torsoOutlierStreak == 1 {
                        print(String(format: "📈 OUTLIER hold-start @frame%d (step=%.2f)", frameCount, rel))
                    }
                    if torsoOutlierStreak >= cfg.torsoOutlierResetFrames {
                        // 视为真实尺度突变:软着陆混合(别硬 snap 到 raw)
                        let blended = last + (raw - last) * torsoCoastBlendAlpha
                        torsoMedianBuf = [blended]
                        lastTorsoRatio = blended
                        torsoOutlierStreak = 0
                        torsoVelocity = 0
                        print(String(format: "📈 OUTLIER snap @frame%d (step=%.2f)", frameCount, rel))
                        recordTorsoRatio(blended)
                    } else {
                        // coast:按最近有效速度外推,保持运动连续,不冻旧值
                        let coasted = last + torsoVelocity
                        lastTorsoRatio = pushTorsoMedian(coasted)
                        torsoVelocity *= torsoCoastVelDecay
                        print(String(format: "📈 OUTLIER coast @frame%d (step=%.2f)", frameCount, rel))
                        if let v = lastTorsoRatio { recordTorsoRatio(v) }
                    }
                    return
                }
            }
            // 有效帧:更新每帧速度(供 coast 外推)+ 中值(窗里残留的 coast 值会自然 blend,不 snap)
            torsoOutlierStreak = 0
            let prevValid = lastTorsoRatio
            let newVal = pushTorsoMedian(raw)
            if let p = prevValid {
                torsoVelocity = torsoVelocity * (1 - torsoVelAlpha) + (newVal - p) * torsoVelAlpha
            }
            lastTorsoRatio = newVal
            recordTorsoRatio(newVal)
            return
        }

        // ===== 无好 torso 的帧(转体/遮挡 torso 四点掉)=====
        torsoOutlierStreak = 0
        // 改A(zoom 侧 coast,对齐位置侧 pose-coast):瞬丢先在上一帧有效 torso 上保持 poseCoastFrames 帧,
        // 别立刻用 bbox 估值 —— 单帧丢检测把 zoom 抽走(框突然缩一下再弹回)就是这条没护住造成的。
        if let last = lastTorsoRatio, last > 0, torsoLostFrames < poseCoastFrames {
            torsoLostFrames += 1
            torsoVelocity *= torsoCoastVelDecay
            recordTorsoRatio(last)         // 保持上一帧值,zoom 不动
            return
        }
        // 久丢(> poseCoastFrames 帧)才回退到 bbox 估值(已标定时);否则冻结走调用方兜底链
        guard hasCalibratedRatio, let boxH = boxHeightRatio, boxH > 0.01 else { return }
        let estTorso = boxH * torsoToBoxHeight   // 转换点连续:estTorso ≈ lastGoodTorso(torsoToBoxHeight 由它标定)
        let prevEst = lastTorsoRatio
        let newEst = pushTorsoMedian(estTorso)
        if let p = prevEst {
            torsoVelocity = torsoVelocity * (1 - torsoVelAlpha) + (newEst - p) * torsoVelAlpha
        }
        lastTorsoRatio = newEst
        recordTorsoRatio(newEst)
    }

    /// 小窗中值(原逻辑抽出复用)
    private func pushTorsoMedian(_ value: CGFloat) -> CGFloat {
        torsoMedianBuf.append(value)
        let w = max(1, cfg.torsoMedianWindow)
        if torsoMedianBuf.count > w { torsoMedianBuf.removeFirst(torsoMedianBuf.count - w) }
        let sorted = torsoMedianBuf.sorted()
        return sorted[sorted.count / 2]
    }

    /// 改动3:记录近期 torso 比例(尺度稳定判定用;含改动1 的估计值)
    private func recordTorsoRatio(_ value: CGFloat) {
        torsoRatioHistory.append(value)
        if torsoRatioHistory.count > torsoScaleHistorySize {
            torsoRatioHistory.removeFirst(torsoRatioHistory.count - torsoScaleHistorySize)
        }
    }

    /// 改动2:当前 pose 是否构成「完整全身框」(含上部 头/肩 + 下部 踝,且置信达标)。
    /// 仅完整时才启用不出框钳位,避免框被截断时误钳。
    func tightBoxIsFullBody(_ pose: VNHumanBodyPoseObservation) -> Bool {
        guard let points = try? pose.recognizedPoints(.all) else { return false }
        func ok(_ name: VNHumanBodyPoseObservation.JointName) -> Bool {
            (points[name]?.confidence ?? 0) >= bodyBoxJointMinConfidence
        }
        let hasTop = ok(.nose) || ok(.neck) || ok(.leftShoulder) || ok(.rightShoulder)
        let hasBottom = ok(.leftAnkle) || ok(.rightAnkle)
        return hasTop && hasBottom
    }

    /// 从缓存的紧贴框获取高度比例（兜底方案）
    func getHeightRatioFromTightBox() -> CGFloat? {
        guard let box = lastTightBox else { return nil }
        return box.height / sensorH
    }

    // MARK: - 检测函数 - 支持身份识别

    /// - pb:   Vision 检测/跟踪用(detPB 降采样,省算力);坐标按 sensorSize(wide)还原
    /// - wide: 颜色直方图用(全分辨率帧,与 sensorSize 同坐标系)
    func detectHuman(pb: CVPixelBuffer, wide: CVPixelBuffer, dt: CGFloat, searchMode: Bool = false) -> (CGRect, CGFloat)? {
        let sensorSize = CGSize(width: sensorW, height: sensorH)   // wide 全分辨率尺寸

        #if DEBUG
        // D-场景:每帧打 LOCK 决策(纯假人固定,确诊 lockLargest 按什么选);不改锁定状态
        PersonIdentifier.shared.diagnoseDLockSelection(frame: frameCount, sensorSize: sensorSize)
        #endif

        // 锁定 → 身份识别路径(findTarget→Kalman→颜色校验);检测在 pb(detPB),颜色在 wide
        if PersonIdentifier.shared.isLocked {
            #if DEBUG
            let _tFind0 = CACurrentMediaTime()   // 临时计时(任务二 Q1:拆 rect=24ms)
            #endif
            // searchMode(状态机 .searching):findTarget 内并入 rect 候选 + 单人安全阀降门,扩大找回面
            let r = PersonIdentifier.shared.findTarget(in: pb, colorBuffer: wide, sensorSize: sensorSize, searchMode: searchMode)
            #if DEBUG
            _dhFindUs += (CACurrentMediaTime() - _tFind0) * 1000   // findTarget(含 gate 的 detectAllPersons#1 + isTarget)
            #endif
            // 刀2:SEARCHING 找回后重种预测历史 → 回 LOCKED 时门从找回位置起(旧 continueTracking 路径不更新历史)
            if searchMode, let box = r?.box {
                PersonIdentifier.shared.seedLockedCenter(CGPoint(x: box.midX / sensorSize.width, y: box.midY / sensorSize.height), at: CACurrentMediaTime())
            }
            #if DEBUG
            // 卡2 验证日志:逐帧打 console(REPLAY + FAKE 两行),带 frameCount/poseValid,可滚动/搜索/复制
            if FakePersonInjector.shared.enabled {
                let s = FakePersonInjector.shared.lastSnapshot
                func bx(_ b: CGRect) -> String { String(format: "(%.0f,%.0f,%.0f,%.0f)", b.minX, b.minY, b.width, b.height) }
                print(String(format: "REPLAY f=%d 检测输入=%dx%d(wide全帧降采样,非crop) 真人数=%d 真人box=%@ conf=%.2f poseValid=%@",
                             frameCount, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb),
                             s.realCount, bx(s.realBox), s.realScore, dbgPoseValid ? "T" : "F"))
                print(String(format: "FAKE inject=ON 假人box=%@ 假人相似度=%.2f 候选=%d [真人:%.2f 假人:%.2f] → 锁定=%@",
                             bx(s.fakeBox), s.fakeScore, s.candCount, s.realScore, s.fakeScore, s.winner))
                dbgFakeHUD = "候选\(s.candCount) 锁:\(s.winner)"
            } else {
                dbgFakeHUD = ""
            }
            dbgTrkHUD = PersonIdentifier.shared.dbgTrkLine()   // 卡3:锁谁/状态/找回@(取自已有状态)
            // 折进 PROBE 的锁定概要:当前锁框 + 是否全帧最大(复检一次全帧候选,仅 DEBUG 锁定时)
            PersonIdentifier.shared.dbgCurrentBox = r?.box
            let _tConf0 = CACurrentMediaTime()
            let cands = PersonIdentifier.shared.detectAllPersonsWithConf(in: pb, sensorSize: sensorSize)  // POSE#2(DEBUG诊断额外全量)
            _dhWithConfUs += (CACurrentMediaTime() - _tConf0) * 1000
            let _tDiag0 = CACurrentMediaTime()
            PersonIdentifier.shared.dbgCandCount = cands.count
            if let b = r?.box {
                let a = b.width * b.height
                let maxA = cands.map { $0.box.width * $0.box.height }.max() ?? 0
                PersonIdentifier.shared.dbgLockedIsLargest = a >= maxA - 1
                PersonIdentifier.shared.diagnoseDrift(currentBox: b, cands: cands, sensorSize: sensorSize)
            }
            _dhDiagUs += (CACurrentMediaTime() - _tDiag0) * 1000
            _dhN += 1
            if _dhN >= 30 {   // 摊薄每30帧一行:rect 里 findTarget / detectAllPersonsWithConf / 诊断 各占多少 ms
                print(String(format: "⏱🔬 detectHuman/帧: findTarget(gate,pose#1)=%.1fms  detectAllPersonsWithConf(pose#2)=%.1fms  diag=%.1fms  (n=%d)",
                             _dhFindUs / Double(_dhN), _dhWithConfUs / Double(_dhN), _dhDiagUs / Double(_dhN), _dhN))
                _dhFindUs = 0; _dhWithConfUs = 0; _dhDiagUs = 0; _dhN = 0
            }
            #endif
            if let result = r {
                return applyKalmanSmoothing(rawRect: result.box, conf: CGFloat(result.score))
            }
            // Part 2:锁定/搜索期身份未命中 → 绝不用「最大人矩形」兜底(那正是漂到路人的后门)。
            // 返回 nil → 状态机 locked→searching(冻结) 或 searching 超时→lost(回全景)。下游只认 lockState。
            #if DEBUG
            // 👻 iou高+候选1 = 后门在救场(该被 SOLO-PASS 接住);iou低/候选≥2 = 在抓替身(正是要堵的)
            if frameCount % 15 == 0, let shadow = detectHumanRectFallback(pb: pb) {
                let fa = sensorSize.width * sensorSize.height
                print(String(format: "👻 SHADOW-FALLBACK box=(%.2f,%.2f,a%.3f) iouWithLast=%.2f candidates=%d → 已拦截(return nil, %@)",
                             shadow.0.midX / sensorSize.width, shadow.0.midY / sensorSize.height,
                             shadow.0.width * shadow.0.height / fa,
                             PersonIdentifier.shared.dbgIoUWithLast(shadow.0),
                             PersonIdentifier.shared.lastCandidateCount,
                             searchMode ? "searching" : "locked"))
            }
            #endif
            return nil
        }
        #if DEBUG
        dbgTrkHUD = PersonIdentifier.shared.dbgTrkLine()   // 未锁定时也刷(显示「未锁定」)
        #endif
        // 未锁定 → 回退现有矩形兜底,行为与卡0(detectHumanRectFallback)一致,不崩、不变行为
        return detectHumanRectFallback(pb: pb)
    }

    // 纯矩形检测兜底（骨骼检测失败时使用，不重复跑骨骼检测）
    func detectHumanRectFallback(pb: CVPixelBuffer) -> (CGRect, CGFloat)? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])

        do {
            try handler.perform([rectRequest])
            guard let list = rectRequest.results, !list.isEmpty else {
                return nil
            }

            func toSensor(_ r: CGRect) -> CGRect {
                CGRect(x: r.minX*sensorW,
                       y: (1-r.maxY)*sensorH,
                       width: r.width*sensorW,
                       height: r.height*sensorH)
            }

            let candidates: [(CGRect, CGFloat)] = list.map { (toSensor($0.boundingBox), CGFloat($0.confidence)) }

            let selected: (CGRect, CGFloat)
            if let lastBox = rawBox {
                selected = candidates.min { a, b in
                    let distA = hypot(a.0.midX - lastBox.midX, a.0.midY - lastBox.midY)
                    let distB = hypot(b.0.midX - lastBox.midX, b.0.midY - lastBox.midY)
                    return distA < distB
                } ?? candidates[0]
            } else {
                selected = candidates.max { a, b in
                    (a.0.width * a.0.height) < (b.0.width * b.0.height)
                } ?? candidates[0]
            }

            return applyKalmanSmoothing(rawRect: selected.0, conf: selected.1)

        } catch {
            return nil
        }
    }

    // 原有的检测逻辑（已弃用，保留供 PersonIdentifier 使用）
    func detectHumanFallback(pb: CVPixelBuffer, dt: CGFloat) -> (CGRect, CGFloat)? {
        if let tightBox = lastTightBox {
            return applyKalmanSmoothing(rawRect: tightBox, conf: 0.9)
        }
        return detectHumanRectFallback(pb: pb)
    }

    // 卡尔曼滤波平滑
    func applyKalmanSmoothing(rawRect: CGRect, conf: CGFloat) -> (CGRect, CGFloat) {
        if kalmanX == nil { setupKalmanFilters() }

        let smoothedRect: CGRect
        if let lastBox = rawBox {
            let iou = iouRect(rawRect, lastBox)
            if iou > 0.05 {
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
                let blendRatio: CGFloat = max(0.05, min(0.2, iou * 4))

                kalmanX?.softReset(value: rawRect.midX, blendRatio: blendRatio)
                kalmanY?.softReset(value: rawRect.midY, blendRatio: blendRatio)
                kalmanW?.softReset(value: rawRect.width, blendRatio: blendRatio)
                kalmanH?.softReset(value: rawRect.height, blendRatio: blendRatio)

                smoothedRect = CGRect(
                    x: lerp(lastBox.midX, rawRect.midX, blendRatio) - rawRect.width/2,
                    y: lerp(lastBox.midY, rawRect.midY, blendRatio) - rawRect.height/2,
                    width: lerp(lastBox.width, rawRect.width, blendRatio),
                    height: lerp(lastBox.height, rawRect.height, blendRatio)
                )
            }
        } else {
            kalmanX?.reset(value: rawRect.midX)
            kalmanY?.reset(value: rawRect.midY)
            kalmanW?.reset(value: rawRect.width)
            kalmanH?.reset(value: rawRect.height)
            smoothedRect = rawRect
        }

        return (smoothedRect, conf)
    }

    // MARK: - 检测降采样（长边 720）：只缩 Vision 输入，不动坐标（归一化）/渲染（全分辨率）
    func downscaledForDetection(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let sw = CGFloat(CVPixelBufferGetWidth(src)), sh = CGFloat(CVPixelBufferGetHeight(src))
        let scale = min(1.0, detLongSide / max(sw, sh))
        if scale > 0.999 { return src }                       // 已经够小，免缩
        let dw = Int((sw * scale).rounded()), dh = Int((sh * scale).rounded())
        if detPool == nil || detPoolW != dw || detPoolH != dh {
            let px: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: dw,
                kCVPixelBufferHeightKey as String: dh,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, px as CFDictionary, &pool)
            detPool = pool; detPoolW = dw; detPoolH = dh
        }
        guard let pool = detPool else { return src }
        var dst: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst)
        guard let out = dst else { return src }
        let ci = CIImage(cvPixelBuffer: src).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        ciContext.render(ci, to: out)
        return out
    }
}
