// PersonIdentifier.swift
// 人物身份识别 - 解决多人场景下的目标锁定问题

import Vision
import CoreImage
import CoreGraphics
import AVFoundation
import UIKit

// MARK: - 目标档案
struct TargetProfile {
    // 上半身颜色直方图（总是可用）
    var colorHistogram: [Float] = []

    // 下半身颜色直方图（补充特征）
    var lowerBodyColorHist: [Float] = []

    // 体型特征
    var aspectRatio: Float = 1.8        // 高/宽
    var relativeSize: Float = 0.3       // 占画面比例

    // 最后已知位置（归一化 0~1）
    var lastCenter: CGPoint = .zero

    // 锁定时间
    var lockedAt: Date = Date()
}

// MARK: - 人物识别器
final class PersonIdentifier {

    static let shared = PersonIdentifier()

    // 锁定状态
    private(set) var isLocked: Bool = false
    private(set) var target: TargetProfile?

    // 配置
    struct Config {
        var upperColorWeight: Float = 0.35  // 上半身颜色权重
        var lowerColorWeight: Float = 0.25  // 下半身颜色权重
        var shapeWeight: Float = 0.25       // 体型权重
        var positionWeight: Float = 0.15    // 位置连续性权重

        // 匹配阈值,作用在 finalScore(现 ∈0~1,因 histogramSimilarity 已归一化)。
        // 换算:不是机械的 0.5/2=0.25 —— shapeSim(0.25)+posSim(0.15)上限=0.40 且不受溢出影响,
        // 假人按主角尺寸造 → 几何项可达 ~0.4。门必须 >0.40,否则同尺寸路人单凭体型过门(与颜色无关)。
        // 取 0.50:高于几何下限 0.40、真人(归一化后 ~0.85)余量足、且与 Vision conf>0.5(0~1)同量纲,
        // 消除卡3 跟丢判定的量纲错位。
        var matchThreshold: Float = 0.50
        var colorHistBins: Int = 16         // 颜色直方图 bins
    }
    var config = Config()

    // Vision 追踪（可选优化）
    private var trackingRequest: VNTrackObjectRequest?
    private var sequenceHandler = VNSequenceRequestHandler()
    private var isTrackingActive = false

    private let ciContext = CIContext()

    // MARK: - 锁定目标

    /// 锁定指定 box 的人（录制按钮/点击时调用）
    func lock(personBox: CGRect,
              in pixelBuffer: CVPixelBuffer,
              sensorSize: CGSize) {

        var profile = TargetProfile()

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // 1. 提取上半身颜色特征
        profile.colorHistogram = extractUpperBodyColor(
            from: ciImage,
            personBox: personBox,
            sensorSize: sensorSize
        )

        // 2. 提取下半身颜色特征
        profile.lowerBodyColorHist = extractLowerBodyColor(
            from: ciImage,
            personBox: personBox,
            sensorSize: sensorSize
        )

        // 3. 体型特征
        profile.aspectRatio = Float(personBox.height / max(personBox.width, 1))
        profile.relativeSize = Float((personBox.width * personBox.height) /
                                      (sensorSize.width * sensorSize.height))

        // 4. 位置
        profile.lastCenter = CGPoint(
            x: personBox.midX / sensorSize.width,
            y: personBox.midY / sensorSize.height
        )

        profile.lockedAt = Date()

        self.target = profile
        self.isLocked = true

        // 5. 启动 Vision 追踪（优化）
        startTracking(box: personBox, sensorSize: sensorSize)

        print("🔒 目标已锁定 | 上衣颜色bins: \(profile.colorHistogram.count) | 下装颜色bins: \(profile.lowerBodyColorHist.count)")
    }

    /// 锁定最大的人
    func lockLargest(in pixelBuffer: CVPixelBuffer, sensorSize: CGSize) -> Bool {
        guard let largest = detectAllPersons(in: pixelBuffer, sensorSize: sensorSize)
                .max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return false
        }
        lock(personBox: largest, in: pixelBuffer, sensorSize: sensorSize)
        return true
    }

    /// 解除锁定
    func unlock() {
        isLocked = false
        target = nil
        trackingRequest = nil
        isTrackingActive = false
        print("🔓 目标已解锁")
    }

    // MARK: - 判断是不是目标

    /// 核心方法：这个人是不是我的目标？
    /// colorBuffer 必须与 personBox/sensorSize 同坐标系(wide 全分辨率帧),否则颜色 region 裁错位。
    /// overrideHist: 非 nil 时用预设直方图(给假人注入用),不从 colorBuffer 提(假人无真实像素)。默认 nil → 真人行为不变。
    func isTarget(_ personBox: CGRect,
                  in colorBuffer: CVPixelBuffer,
                  sensorSize: CGSize,
                  overrideHist: (upper: [Float], lower: [Float])? = nil) -> (match: Bool, score: Float) {

        guard isLocked, let target = self.target else {
            return (false, 0)
        }

        var totalScore: Float = 0
        var totalWeight: Float = 0

        // 候选颜色:真人从 colorBuffer 提;假人(overrideHist)用预设直方图
        let personUpperColor: [Float]
        let personLowerColor: [Float]
        if let ov = overrideHist {
            personUpperColor = ov.upper
            personLowerColor = ov.lower
        } else {
            let ciImage = CIImage(cvPixelBuffer: colorBuffer)
            personUpperColor = extractUpperBodyColor(from: ciImage, personBox: personBox, sensorSize: sensorSize)
            personLowerColor = extractLowerBodyColor(from: ciImage, personBox: personBox, sensorSize: sensorSize)
        }

        // 1. 上半身颜色匹配
        if !target.colorHistogram.isEmpty && !personUpperColor.isEmpty {
            let sim = histogramSimilarity(target.colorHistogram, personUpperColor)
            totalScore += config.upperColorWeight * sim
            totalWeight += config.upperColorWeight
        }

        // 2. 下半身颜色匹配
        if !target.lowerBodyColorHist.isEmpty && !personLowerColor.isEmpty {
            let sim = histogramSimilarity(target.lowerBodyColorHist, personLowerColor)
            totalScore += config.lowerColorWeight * sim
            totalWeight += config.lowerColorWeight
        }

        // 3. 体型匹配
        let personAspect = Float(personBox.height / max(personBox.width, 1))
        let personSize = Float((personBox.width * personBox.height) /
                               (sensorSize.width * sensorSize.height))

        let aspectDiff = abs(personAspect - target.aspectRatio) / max(target.aspectRatio, 0.1)
        let sizeDiff = abs(personSize - target.relativeSize) / max(target.relativeSize, 0.01)
        let shapeSim = max(0, 1 - aspectDiff * 0.3 - sizeDiff * 0.5)
        totalScore += config.shapeWeight * shapeSim
        totalWeight += config.shapeWeight

        // 4. 位置连续性
        let personCenter = CGPoint(
            x: personBox.midX / sensorSize.width,
            y: personBox.midY / sensorSize.height
        )
        let dist = Float(hypot(personCenter.x - target.lastCenter.x,
                               personCenter.y - target.lastCenter.y))
        let posSim = max(0, 1 - dist * 2)  // 距离越近分越高
        totalScore += config.positionWeight * posSim
        totalWeight += config.positionWeight

        // 归一化
        let finalScore = totalWeight > 0 ? totalScore / totalWeight : 0
        let isMatch = finalScore > config.matchThreshold

        // 如果匹配，更新最后位置
        if isMatch {
            self.target?.lastCenter = personCenter
        }

        return (isMatch, finalScore)
    }

    /// 在所有人中找到目标（返回 box 和分数）
    /// - detectBuffer: Vision 检测/跟踪用(可降采样 detPB,省算力);坐标按 sensorSize(wide)还原
    /// - colorBuffer:  颜色直方图用(wide 全分辨率帧,与 sensorSize 同坐标系)
    func findTarget(in detectBuffer: CVPixelBuffer,
                    colorBuffer: CVPixelBuffer,
                    sensorSize: CGSize) -> (box: CGRect, score: Float)? {

        guard isLocked else { return nil }

        #if DEBUG
        // 卡2 假人注入:激活时强制走全量竞争(跳过 track 快速路径,否则 track 咬住主角、假人测不到颜色校验)
        if FakePersonInjector.shared.enabled {
            return findTargetWithFake(in: detectBuffer, colorBuffer: colorBuffer, sensorSize: sensorSize)
        }
        #endif

        // 先尝试用 VNTrackObjectRequest（更快）—— 框按 sensorSize(wide)还原,颜色校验用 colorBuffer(wide)
        if isTrackingActive, let tracked = continueTracking(detectBuffer, sensorSize: sensorSize) {
            // 验证追踪结果是不是真的是目标
            let (match, score) = isTarget(tracked, in: colorBuffer, sensorSize: sensorSize)
            if match {
                return (tracked, score)
            }
            // 追踪结果不匹配，可能追错了，重新检测
            isTrackingActive = false
        }

        // 检测所有人，找匹配的（检测在 detectBuffer,颜色校验在 colorBuffer）
        let persons = detectAllPersons(in: detectBuffer, sensorSize: sensorSize)

        var bestBox: CGRect?
        var bestScore: Float = 0

        for person in persons {
            let (match, score) = isTarget(person, in: colorBuffer, sensorSize: sensorSize)
            if match && score > bestScore {
                bestScore = score
                bestBox = person
            }
        }

        if let box = bestBox {
            // 重新启动追踪
            startTracking(box: box, sensorSize: sensorSize)
            return (box, bestScore)
        }

        return nil
    }

    #if DEBUG
    /// 卡2 验证用:强制全量竞争(真人 + 注入假人),颜色校验决定锁谁。逐帧打候选/相似度/锁谁。
    private func findTargetWithFake(in detectBuffer: CVPixelBuffer,
                                    colorBuffer: CVPixelBuffer,
                                    sensorSize: CGSize) -> (box: CGRect, score: Float)? {
        guard isLocked else { return nil }

        var cands: [(label: String, box: CGRect, match: Bool, score: Float)] = []

        // 真人候选(检测在 detectBuffer,颜色在 colorBuffer)
        let persons = detectAllPersons(in: detectBuffer, sensorSize: sensorSize)
        var bestRealBox = CGRect.zero
        var bestRealScore: Float = -1
        for (i, p) in persons.enumerated() {
            let (m, s) = isTarget(p, in: colorBuffer, sensorSize: sensorSize)
            cands.append(("真人\(i)", p, m, s))
            if s > bestRealScore { bestRealScore = s; bestRealBox = p }
        }

        // 注入假人:预设直方图(同色/异色)参与同一套 isTarget 评分
        var fakeBox = CGRect.zero
        var fakeScore: Float = -1
        if let fake = FakePersonInjector.shared.currentFake(target: target, sensorSize: sensorSize) {
            let (m, s) = isTarget(fake.box, in: colorBuffer, sensorSize: sensorSize,
                                  overrideHist: (fake.upper, fake.lower))
            cands.append(("假人", fake.box, m, s))
            fakeBox = fake.box; fakeScore = s
        }

        // 选 match 且 score 最高(与生产路径同口径:同一 isTarget + matchThreshold)
        let winner = cands.filter { $0.match }.max { $0.score < $1.score }

        // 存快照,实际 print 在 detectHuman(带 frameCount/poseValid,帧号对齐)
        var snap = FakePersonInjector.DebugSnapshot()
        snap.realCount = persons.count
        snap.realBox = bestRealBox; snap.realScore = bestRealScore
        snap.fakeBox = fakeBox; snap.fakeScore = fakeScore
        snap.candCount = cands.count
        snap.winner = winner?.label ?? "无"
        FakePersonInjector.shared.lastSnapshot = snap

        if let w = winner {
            startTracking(box: w.box, sensorSize: sensorSize)
            return (w.box, w.score)
        }
        return nil
    }
    #endif

    // MARK: - Vision 追踪（优化性能）

    private func startTracking(box: CGRect, sensorSize: CGSize) {
        // 转换为 Vision 坐标（左下原点，归一化）
        let normalizedBox = CGRect(
            x: box.minX / sensorSize.width,
            y: 1 - (box.maxY / sensorSize.height),
            width: box.width / sensorSize.width,
            height: box.height / sensorSize.height
        )

        let observation = VNDetectedObjectObservation(boundingBox: normalizedBox)
        trackingRequest = VNTrackObjectRequest(detectedObjectObservation: observation)
        trackingRequest?.trackingLevel = .fast
        isTrackingActive = true
    }

    private func continueTracking(_ pixelBuffer: CVPixelBuffer, sensorSize: CGSize) -> CGRect? {
        guard let request = trackingRequest else { return nil }

        do {
            try sequenceHandler.perform([request], on: pixelBuffer)

            if let result = request.results?.first as? VNDetectedObjectObservation,
               result.confidence > 0.5 {

                // 转换回传感器坐标 —— 用 sensorSize(wide),与 detectAllPersons/下游统一,不用 detPB 降采样尺寸
                let sensorW = sensorSize.width
                let sensorH = sensorSize.height
                let vBox = result.boundingBox

                let box = CGRect(
                    x: vBox.minX * sensorW,
                    y: (1 - vBox.maxY) * sensorH,
                    width: vBox.width * sensorW,
                    height: vBox.height * sensorH
                )

                // 更新追踪请求
                trackingRequest = VNTrackObjectRequest(detectedObjectObservation: result)
                trackingRequest?.trackingLevel = .fast

                return box
            }
        } catch {
            // 追踪失败
        }

        isTrackingActive = false
        return nil
    }

    // MARK: - 特征提取

    /// 检测所有人
    private func detectAllPersons(in pixelBuffer: CVPixelBuffer,
                                   sensorSize: CGSize) -> [CGRect] {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                             orientation: .up,
                                             options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let results = request.results else { return [] }

        return results.map { obs in
            CGRect(
                x: obs.boundingBox.minX * sensorSize.width,
                y: (1 - obs.boundingBox.maxY) * sensorSize.height,
                width: obs.boundingBox.width * sensorSize.width,
                height: obs.boundingBox.height * sensorSize.height
            )
        }
    }

    /// 提取上半身颜色直方图
    private func extractUpperBodyColor(from ciImage: CIImage,
                                        personBox: CGRect,
                                        sensorSize: CGSize) -> [Float] {

        // 上半身区域（人体框 20%~50% 的位置，避开头部）
        let upperBody = CGRect(
            x: personBox.minX,
            y: sensorSize.height - personBox.minY - personBox.height * 0.5,
            width: personBox.width,
            height: personBox.height * 0.30
        )

        return extractColorFromRegion(ciImage: ciImage, region: upperBody)
    }

    /// 提取下半身颜色直方图
    private func extractLowerBodyColor(from ciImage: CIImage,
                                        personBox: CGRect,
                                        sensorSize: CGSize) -> [Float] {

        // 下半身区域（人体框 50%~85% 的位置）
        let lowerBody = CGRect(
            x: personBox.minX,
            y: sensorSize.height - personBox.minY - personBox.height * 0.85,
            width: personBox.width,
            height: personBox.height * 0.35
        )

        return extractColorFromRegion(ciImage: ciImage, region: lowerBody)
    }

    /// 从指定区域提取颜色直方图
    private func extractColorFromRegion(ciImage: CIImage, region: CGRect) -> [Float] {
        guard region.width > 10, region.height > 10 else { return [] }

        // 裁剪并缩小
        let cropped = ciImage.cropped(to: region)
        let targetSize = CGSize(width: 24, height: 24)
        let scale = min(targetSize.width / region.width,
                        targetSize.height / region.height)
        let scaled = cropped
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = ciContext.createCGImage(scaled,
                                                     from: CGRect(origin: .zero, size: targetSize)) else {
            return []
        }

        return computeColorHistogram(from: cgImage)
    }

    /// 计算颜色直方图（HSV）
    private func computeColorHistogram(from cgImage: CGImage) -> [Float] {
        guard let data = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else {
            return []
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow

        let bins = config.colorHistBins
        var histH = [Float](repeating: 0, count: bins)
        var histS = [Float](repeating: 0, count: bins / 2)
        var total: Float = 0

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = Float(ptr[offset]) / 255
                let g = Float(ptr[offset + 1]) / 255
                let b = Float(ptr[offset + 2]) / 255

                let (h, s, _) = rgbToHSV(r: r, g: g, b: b)

                let hBin = min(bins - 1, Int(h * Float(bins)))
                let sBin = min(bins / 2 - 1, Int(s * Float(bins / 2)))

                histH[hBin] += 1
                histS[sBin] += 1
                total += 1
            }
        }

        // 归一化
        if total > 0 {
            for i in 0..<histH.count { histH[i] /= total }
            for i in 0..<histS.count { histS[i] /= total }
        }

        return histH + histS
    }

    private func rgbToHSV(r: Float, g: Float, b: Float) -> (h: Float, s: Float, v: Float) {
        let maxVal = max(r, max(g, b))
        let minVal = min(r, min(g, b))
        let delta = maxVal - minVal

        var h: Float = 0
        let s = maxVal > 0 ? delta / maxVal : 0
        let v = maxVal

        if delta > 0 {
            if maxVal == r {
                h = (g - b) / delta
                if h < 0 { h += 6 }
            } else if maxVal == g {
                h = 2 + (b - r) / delta
            } else {
                h = 4 + (r - g) / delta
            }
            h /= 6
        }

        return (h, s, v)
    }

    // MARK: - 相似度计算

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? max(0, dot / denom) : 0
    }

    private func histogramSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        // 直方图 = 「H 段(16 bin,sum=1)+ S 段(8 bin,sum=1)」拼接 → 整体 sum=2。
        // 旧版对整段做 Bhattacharyya = BC_H + BC_S ∈ 0~2(溢出源)。
        // 归一化:两段 BC 各 ∈0~1,等权平均 → 整体 ∈0~1(完全同色=1、完全异色=0、自比≈1)。
        // 等权(非给 H 加权):最简、端点正确、换算可预测;H 判别力更强,若后续撞衫要更强 hue 区分,
        // 可改 0.6·BC_H + 0.4·BC_S(不破坏端点)。当前等权已足够分离真人/异色假人。
        let hLen = config.colorHistBins             // H 段长度(16);其余为 S 段
        var bcH: Float = 0, bcS: Float = 0
        for i in 0..<a.count {
            let v = sqrt(max(0, a[i]) * max(0, b[i]))
            if i < hLen { bcH += v } else { bcS += v }
        }
        return (bcH + bcS) / 2.0
    }

    // MARK: - 调试

    func debugInfo() -> String {
        guard isLocked, let t = target else { return "未锁定" }
        return "锁定中 | 上衣:\(t.colorHistogram.count)bins | 下装:\(t.lowerBodyColorHist.count)bins"
    }
}
