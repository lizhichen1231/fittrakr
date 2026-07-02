// PersonIdentifier.swift
// 人物身份识别 - 解决多人场景下的目标锁定问题

import Vision
import CoreImage
import CoreGraphics
import AVFoundation
import UIKit
import QuartzCore

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

    // C8 重锚:每 reanchorInterval 帧,用 pose 多人检测 + 颜色校验重新确认主角真实框,re-seed VNTrackObject。
    // 治 continueTracking 自漂(VNTrackObject 用自身输出重建 → 框逐帧缩/漂)。re-seed 把它拉回主角当前真实框。
    let reanchorInterval = 15       // ~0.25s@60fps;越小越不漂但检测越频
    private var reanchorCounter = 0
    #if DEBUG
    var dbgReanchorLine = ""        // 最近一次重锚结果(sticky)
    #endif

    var lastCandidateCount = 0      // 本帧重选候选数(状态机 locked→searching 日志 + HUD 读)
    let soloMatchThreshold: Float = 0.30  // Part 3A 单人安全阀:全场仅1人且与锁框高重叠时的放宽门槛
    #if DEBUG
    var dbgCurCont: Float = 0       // 本帧选中的延续分(HUD/状态日志)
    var dbgCurThresh: Float = 0.5   // 本帧生效门槛(安全阀降门时=0.30)
    var dbgSrcMerged = false        // rect 是否并源(searching 时 P+R)
    var dbgBestRejectCont: Float = 0   // nil 帧最佳被拒候选延续分(搜索心跳 bestCont)
    var dbgBestRejectColor: Float = 0  // nil 帧最佳被拒候选颜色分(搜索心跳 bestColor)
    // 刀1 探针:运动预测历史(近3帧「系统实际选中」的锁定中心 + 墙钟时间戳);纯 DEBUG,零行为影响
    private var lockedCenterHist: [(c: CGPoint, t: TimeInterval)] = []
    private let velClampPerSec: CGFloat = 0.5   // 速度幅值上限(归一/秒),防单帧坏值甩飞预测
    #endif

    // 方案A:主跟踪 = 每帧 pose 重选「延续上一帧目标」+ 换人迟滞(治我/爹闪烁;VNTrackObject 死路仅兜底)
    var lastLockedBox: CGRect?      // 上一帧真正锁定的框(算延续/迟滞用)
    let switchMargin: Float = 0.15  // 换人迟滞:挑战者综合分须超当前目标 + 此值才换(大→更黏)
    let continuityFloor: Float = 0.35 // 延续分低于此 = 上一帧目标本帧没检出 → 暂保持(coast)
    let maxCoastFrames = 8          // 连续找不到延续目标最多保持帧数,超则重新捕获(最强颜色匹配)
    private var coastFrames = 0
    // 延续分权重(颜色占大头:你和爹不同色,这是最强区分)
    let wCont_color: Float = 0.60
    let wCont_pos: Float = 0.25
    let wCont_size: Float = 0.15
    #if DEBUG
    var dbgReselectLine = ""
    #endif

    #if DEBUG
    // 卡3 HUD 精简实时态(值取自已有计算,不重算):锁谁 / 状态 / 最近找回位置(sticky)
    var dbgLockWho = "无"          // 真人 / 假人 / 无
    var dbgTrkState = "未锁定"      // 锁定 / 跟丢 / 重检测找回 / 丢失 / 未锁定 / 竞争
    var dbgRefindNX: CGFloat = -1   // 最近一次重检测找回的全帧归一化 x(<0=暂无)
    var dbgRefindNY: CGFloat = -1
    var lockedBoxArea: CGFloat = -1 // 锁定那帧选中框的面积(px²),锁定后每帧对照「大/小」
    // 锁定后每帧概要(折进 PROBE):当前锁框 + 是否全帧最大 + 候选数
    var dbgCurrentBox: CGRect?      // findTarget 本帧返回的框(当前正锁着的)
    var dbgCandCount = 0            // 本帧全帧候选数
    var dbgLockedIsLargest = false  // 当前锁框是不是候选里面积最大的
    var dbgLockMomentCandCount = -1 // ★锁定那一刻候选数(=1 则当时只检出1人,锁它=没得选)
    var dbgLockMomentAreaFrac: CGFloat = -1 // 锁定那一刻锁框面积比
    var dbgLockMomentCenter: CGPoint = .zero // 锁定那一刻锁框中心(归一化),算 track 漂移用
    var dbgDriftLine = ""           // track 漂移诊断:当前框 vs 锁定中心 + 最近候选(向爹/原地缩)
    /// 折进 PROBE 的锁定概要(每帧)。需传 sensorSize 算归一化/面积比。
    func dbgLockSummary(sensorSize: CGSize) -> String {
        guard isLocked, let b = dbgCurrentBox else { return "lock=F" }
        let fa = sensorSize.width * sensorSize.height
        let af = b.width * b.height / fa
        let who = dbgCandCount <= 1 ? "唯一" : (dbgLockedIsLargest ? "近大(最大框)" : "远小(非最大)")
        return String(format: "lock=T 锁框面积=%.3f nx=%.2f ny=%.2f 候选=%d 锁的是=%@ | 锁定瞬间候选=%d 锁框面积=%.3f",
                      af, b.midX / sensorSize.width, b.midY / sensorSize.height, dbgCandCount, who,
                      dbgLockMomentCandCount, Double(dbgLockMomentAreaFrac))
    }
    func dbgTrkLine() -> String {
        let refind = dbgRefindNX >= 0 ? String(format: "找回@(%.2f,%.2f)", dbgRefindNX, dbgRefindNY) : "找回@—"
        return "TRK 锁=\(dbgLockWho) | 状态=\(dbgTrkState) | \(refind)"
    }
    #endif

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
        self.lastLockedBox = personBox   // 方案A:延续/迟滞基准 = 锁定那刻的框(你)
        self.coastFrames = 0
        // 修法2:重置 VNSequenceRequestHandler → 每次锁定 VNTrackObject 从干净状态起跟,抹平「第一次vs之后」暖机差异。
        self.sequenceHandler = VNSequenceRequestHandler()

        // 5. 启动 Vision 追踪（优化）
        startTracking(box: personBox, sensorSize: sensorSize)

        let baseEmpty = profile.colorHistogram.isEmpty && profile.lowerBodyColorHist.isEmpty
        print("🔒 目标已锁定 | 上衣颜色bins: \(profile.colorHistogram.count) | 下装颜色bins: \(profile.lowerBodyColorHist.count)\(baseEmpty ? "  ★★基准空!色彩verify失效→易漂(就是这次锁定的问题)" : "")")
    }

    /// 锁定最大的人
    func lockLargest(in pixelBuffer: CVPixelBuffer, sensorSize: CGSize) -> Bool {
        let realBoxes = detectAllPersons(in: pixelBuffer, sensorSize: sensorSize)
        // 无真人:早返回(自动锁定每帧重试时不打日志/不重复检测)。D-场景(debug)需无真人也注入假人 → 不早返回。
        #if DEBUG
        let dActive = FakePersonInjector.shared.dScenario != .off
        #else
        let dActive = false
        #endif
        if realBoxes.isEmpty && !dActive { return false }

        #if DEBUG
        // D-场景:注入假人到候选表,用【同一】.max(面积)比较器选,并打 LOCK 决策(确诊按什么选)
        if FakePersonInjector.shared.dScenario != .off {
            let fakes = FakePersonInjector.shared.dFakes(sensorSize: sensorSize)
            // 候选 = 真人(conf 在 detectAllPersons 已丢=不可见) + 假人(带配置 conf)
            var cands: [(label: String, box: CGRect, conf: Float)] =
                realBoxes.enumerated().map { ("真人\($0.offset)", $0.element, Float.nan) }
            cands += fakes.map { ($0.label, $0.box, $0.conf) }
            // ★ 与 lockLargest 完全相同的比较器:.max(by 面积)——只注入候选,不改判据
            let winner = cands.max { $0.box.width * $0.box.height < $1.box.width * $1.box.height }
            logLockDecision(tag: "LOCK(实锁)", cands: cands, winner: winner, sensorSize: sensorSize)
            if let w = winner {
                lock(personBox: w.box, in: pixelBuffer, sensorSize: sensorSize)
                return true
            }
            return false
        }
        #endif

        #if DEBUG
        // 锁定触发那一帧:打完整候选列表(box/面积/位置/conf),标最大,复核 lockLargest 是否选最大
        let withConf = detectAllPersonsWithConf(in: pixelBuffer, sensorSize: sensorSize)
        let frameArea = sensorSize.width * sensorSize.height
        let maxA = withConf.map { $0.box.width * $0.box.height }.max() ?? 0
        print("🔒LOCK触发 候选数=\(withConf.count)(源=body pose 多人版)")
        for (i, c) in withConf.enumerated() {
            let a = c.box.width * c.box.height
            let isMax = a >= maxA - 1
            print(String(format: "  候选[%d]: box=(%.0f,%.0f,%.0f,%.0f) 面积=%.4f 位置=(%.2f,%.2f) conf=%.2f%@",
                         i, c.box.minX, c.box.minY, c.box.width, c.box.height,
                         a / frameArea, c.box.midX / sensorSize.width, c.box.midY / sensorSize.height,
                         c.conf, isMax ? " ←面积最大" : ""))
        }
        // 与生产 lockLargest 完全相同比较器,仅为复核打印(实际锁仍用下面 realBoxes)
        if let w = withConf.max(by: { $0.box.width * $0.box.height < $1.box.width * $1.box.height }) {
            let wa = w.box.width * w.box.height
            print(String(format: "  候选数=%d lockLargest选中面积=%.4f 位置=(%.2f,%.2f) 是面积最大?=%@",
                         withConf.count, wa / frameArea, w.box.midX / sensorSize.width, w.box.midY / sensorSize.height,
                         wa >= maxA - 1 ? "YES" : "NO"))
        }
        #endif

        guard let largest = realBoxes
                .max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return false
        }
        lock(personBox: largest, in: pixelBuffer, sensorSize: sensorSize)
        #if DEBUG
        lockedBoxArea = largest.width * largest.height   // 记锁定框面积,供锁定后每帧对照
        // sticky:锁定那一刻矩形候选数 + 锁框面积比 → 折进 PROBE,不用滚回去翻 🔒LOCK触发
        dbgLockMomentCandCount = realBoxes.count
        dbgLockMomentAreaFrac = largest.width * largest.height / (sensorSize.width * sensorSize.height)
        dbgLockMomentCenter = CGPoint(x: largest.midX / sensorSize.width, y: largest.midY / sensorSize.height)
        #endif
        return true
    }

    #if DEBUG
    /// track 漂移诊断:当前 track 框 vs 锁定瞬间中心(漂多少/往哪),并判最近 pose 候选是大(你)还是小(爹)。
    func diagnoseDrift(currentBox: CGRect, cands: [(box: CGRect, conf: Float)], sensorSize: CGSize) {
        let fa = sensorSize.width * sensorSize.height
        let cx = currentBox.midX / sensorSize.width, cy = currentBox.midY / sensorSize.height
        let drift = hypot(cx - dbgLockMomentCenter.x, cy - dbgLockMomentCenter.y)
        // 当前框最近的 pose 候选 + 它是不是最大
        let maxA = cands.map { $0.box.width * $0.box.height }.max() ?? 0
        let nearest = cands.min { a, b in
            hypot(a.box.midX/sensorSize.width - cx, a.box.midY/sensorSize.height - cy) <
            hypot(b.box.midX/sensorSize.width - cx, b.box.midY/sensorSize.height - cy)
        }
        let nearA = nearest.map { $0.box.width * $0.box.height } ?? 0
        let nearIsLargest = nearA >= maxA - 1
        // 判向:漂移小+面积缩=原地缩你;最近候选是小框=漂到爹
        let verdict: String
        if cands.count >= 2 && !nearIsLargest { verdict = "漂到爹(最近候选=小框)" }
        else if drift < 0.05 { verdict = "原地缩(贴着你但框缩水)" }
        else { verdict = "漂移中" }
        dbgDriftLine = String(format: "DRIFT 当前面积=%.3f 锁定面积=%.3f 中心漂=%.3f(Δx=%.3f Δy=%.3f) 最近候选面积=%.3f(最大?=%@) → %@",
                              currentBox.width * currentBox.height / fa, Double(dbgLockMomentAreaFrac), drift,
                              cx - dbgLockMomentCenter.x, cy - dbgLockMomentCenter.y,
                              nearA / fa, nearIsLargest ? "Y" : "N", verdict)
        print(dbgDriftLine)
    }
    #endif

    #if DEBUG
    /// 每帧 D-场景诊断(纯假人,固定不动):用 lockLargest 同一 .max(面积) 选,打 LOCK 决策。不改任何锁定状态。
    func diagnoseDLockSelection(frame: Int, sensorSize: CGSize) {
        guard FakePersonInjector.shared.dScenario != .off else { return }
        let fakes = FakePersonInjector.shared.dFakes(sensorSize: sensorSize)
        guard !fakes.isEmpty else { return }
        let cands = fakes.map { (label: $0.label, box: $0.box, conf: $0.conf) }
        let winner = cands.max { $0.box.width * $0.box.height < $1.box.width * $1.box.height }
        logLockDecision(tag: "LOCK f=\(frame)", cands: cands, winner: winner, sensorSize: sensorSize)
    }

    /// 统一 LOCK 决策日志:候选[label:面积 conf pos] + 选中 + 是否面积最大 + 依据
    private func logLockDecision(tag: String,
                                 cands: [(label: String, box: CGRect, conf: Float)],
                                 winner: (label: String, box: CGRect, conf: Float)?,
                                 sensorSize: CGSize) {
        let frameArea = sensorSize.width * sensorSize.height
        let line = cands.map { c -> String in
            let a = c.box.width * c.box.height / frameArea
            let cf = c.conf.isNaN ? "—" : String(format: "%.2f", c.conf)
            return String(format: "[%@:面积=%.3f conf=%@ pos=(%.2f,%.2f)]",
                          c.label, a, cf, c.box.midX / sensorSize.width, c.box.midY / sensorSize.height)
        }.joined()
        let maxArea = cands.map { $0.box.width * $0.box.height }.max() ?? 0
        let winArea = winner.map { $0.box.width * $0.box.height } ?? 0
        let isMax = winArea >= maxArea - 1   // 容差 1px²
        print("\(tag) 候选\(line) lockLargest选中=\(winner?.label ?? "无") 选中面积=\(String(format: "%.3f", winArea / frameArea)) 是面积最大?=\(isMax ? "YES" : "NO") 依据=.max(面积)(conf/位置不参与)")
    }
    #endif

    /// 解除锁定
    func unlock() {
        isLocked = false
        target = nil
        trackingRequest = nil
        isTrackingActive = false
        reanchorCounter = 0
        lastLockedBox = nil; coastFrames = 0
        #if DEBUG
        dbgLockWho = "无"; dbgTrkState = "未锁定"; dbgRefindNX = -1; dbgRefindNY = -1; lockedBoxArea = -1; dbgReanchorLine = ""; dbgReselectLine = ""
        dbgLockMomentCandCount = -1; dbgLockMomentAreaFrac = -1; dbgLockMomentCenter = .zero; dbgDriftLine = ""
        #endif
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
            #if DEBUG
            // 坐实 #4:每个 match 候选都覆盖 lastCenter。打:中心 + 综合分 + 色彩基准空否(verify 是否生效)。
            // 第一次若 bins=0 → 色彩项跳过 → 别人也 match → lastCenter 被别人覆盖 → 漂。
            print(String(format: "  isTarget候选 中心=(%.2f,%.2f) 综合分=%.2f 色彩基准=%@ → lastCenter改成此候选",
                         personCenter.x, personCenter.y, finalScore,
                         (target.colorHistogram.isEmpty && target.lowerBodyColorHist.isEmpty) ? "★空!verify失效" : "有(上\(target.colorHistogram.count)/下\(target.lowerBodyColorHist.count)bins)"))
            #endif
            self.target?.lastCenter = personCenter
        }

        return (isMatch, finalScore)
    }

    /// 在所有人中找到目标（返回 box 和分数）
    /// - detectBuffer: Vision 检测/跟踪用(可降采样 detPB,省算力);坐标按 sensorSize(wide)还原
    /// - colorBuffer:  颜色直方图用(wide 全分辨率帧,与 sensorSize 同坐标系)
    func findTarget(in detectBuffer: CVPixelBuffer,
                    colorBuffer: CVPixelBuffer,
                    sensorSize: CGSize,
                    searchMode: Bool = false) -> (box: CGRect, score: Float)? {

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
            #if DEBUG
            // LOCK后:走 continueTracking 跟随(非重新 lockLargest)。打当前框面积/位置 + 对照锁定帧大小
            let a = tracked.width * tracked.height, fa = sensorSize.width * sensorSize.height
            let rel = lockedBoxArea > 0 ? (a > lockedBoxArea * 1.2 ? "更大" : (a < lockedBoxArea * 0.8 ? "更小" : "≈锁定")) : "?"
            print(String(format: "LOCK后 分支=continueTracking跟随(非重lockLargest) 当前box面积=%.4f 位置=(%.2f,%.2f) vs锁定帧=%@ 颜色校验=%@(%.2f)",
                         a / fa, tracked.midX / sensorSize.width, tracked.midY / sensorSize.height,
                         rel, match ? "match" : "REJECT", score))
            #endif
            if match {
                #if DEBUG
                dbgLockWho = "真人"; dbgTrkState = "锁定"
                #endif
                // C8 重锚:每 N 帧用「颜色校验确认的主角真实框」re-seed,防 track 自漂/缩水
                reanchorCounter += 1
                if reanchorCounter >= reanchorInterval {
                    reanchorCounter = 0
                    if let re = reanchorTarget(detectBuffer: detectBuffer, colorBuffer: colorBuffer, sensorSize: sensorSize) {
                        startTracking(box: re.box, sensorSize: sensorSize)   // re-seed VNTrackObject 到主角真实框
                        #if DEBUG
                        let fa = sensorSize.width * sensorSize.height
                        dbgReanchorLine = String(format: "重锚✓ track面积%.3f→主角真实%.3f 综合分%.2f 候选%d",
                                                 tracked.width * tracked.height / fa,
                                                 re.box.width * re.box.height / fa, re.score, re.candCount)
                        print("⚓ " + dbgReanchorLine)
                        dbgTrkState = "锁定(重锚)"
                        #endif
                        return (re.box, re.score)
                    } else {
                        #if DEBUG
                        dbgReanchorLine = "重锚✗ 无颜色匹配候选,保持track"; print("⚓ " + dbgReanchorLine)
                        #endif
                    }
                }
                return (tracked, score)
            }
            // 追踪结果不匹配，可能追错了，重新检测
            isTrackingActive = false
            #if DEBUG
            dbgTrkState = "跟丢"
            let dW = CVPixelBufferGetWidth(detectBuffer), dH = CVPixelBufferGetHeight(detectBuffer)
            print(String(format: "🔁 跟丢→重检测 输入=%dx%d(wide全帧降采样,非crop;aspect %.2f vs sensor %.2f) sensorSize=%dx%d",
                         dW, dH, Double(dW) / Double(max(dH, 1)),
                         sensorSize.width / max(sensorSize.height, 1),
                         Int(sensorSize.width), Int(sensorSize.height)))
            #endif
        }

        // ===== 方案A 主跟踪:每帧 pose 候选「延续上一帧目标」+ 换人迟滞(治我/爹闪烁)=====
        var persons = detectAllPersons(in: detectBuffer, sensorSize: sensorSize)
        let fa = sensorSize.width * sensorSize.height
        let poseCount = persons.count   // 之后并入的 rect 候选下标 >= poseCount(供 REJECT 日志标 src)

        // Part 3B:搜索期并入矩形候选(pose 漏检的人靠 VNDetectHumanRectangles 兜),去重(IoU>0.5 视为同人)
        #if DEBUG
        dbgSrcMerged = false
        #endif
        if searchMode {
            let rects = detectAllRects(in: detectBuffer, sensorSize: sensorSize)
            let extra = rects.filter { rc in !persons.contains { iou($0, rc) > 0.5 } }
            if !extra.isEmpty {
                persons.append(contentsOf: extra)
                #if DEBUG
                dbgSrcMerged = true
                print("🔎 SEARCH 并源 pose=\(persons.count - extra.count) +rect=\(extra.count) → 候选=\(persons.count)")
                #endif
            }
        }
        lastCandidateCount = persons.count

        // 每个候选:颜色综合分 + match + 对「上一帧锁定框」的延续分(颜色大头 + 位置 + 尺寸)+ 位置/尺寸子分 + 源
        struct Scored { let box: CGRect; let color: Float; let matched: Bool; let cont: Float; let pos: Float; let size: Float; let src: String }
        let scored: [Scored] = persons.enumerated().map { (idx, p) in
            let (m, s) = isTarget(p, in: colorBuffer, sensorSize: sensorSize)
            var cont: Float = 0, posSim: Float = 0, sizeSim: Float = 0
            if let last = lastLockedBox {
                let posDist = Float(hypot((p.midX - last.midX) / sensorSize.width, (p.midY - last.midY) / sensorSize.height))
                let aP = p.width * p.height, aL = last.width * last.height
                let sizeDist = Float(abs(aP - aL) / max(aL, 1))
                posSim = max(0, 1 - posDist * 2)      // 位置越近越高
                sizeSim = max(0, 1 - sizeDist)         // 尺寸越近越高
                cont = wCont_color * s + wCont_pos * posSim + wCont_size * sizeSim
            } else {
                cont = s                                    // 无上一帧 → 退化为综合分
            }
            return Scored(box: p, color: s, matched: m, cont: cont, pos: posSim, size: sizeSim,
                          src: idx < poseCount ? "pose" : "rect")
        }

        var matched = scored.filter { $0.matched }
        #if DEBUG
        dbgCurThresh = config.matchThreshold
        #endif

        // Part 3A:单人安全阀——全场仅 1 个候选且与上一帧锁框高度重叠(IoU>0.5),
        // 即"就他一个、还站在原地",放宽门槛到 soloMatchThreshold(0.30)接纳,避免光照/角度小波动误判丢失。
        if matched.isEmpty, persons.count == 1, let sole = scored.first, let last = lastLockedBox {
            let ov = iou(sole.box, last)
            if ov > 0.5 && sole.color > soloMatchThreshold {
                matched = [Scored(box: sole.box, color: sole.color, matched: true, cont: sole.cont,
                                  pos: sole.pos, size: sole.size, src: sole.src)]
                #if DEBUG
                dbgCurThresh = soloMatchThreshold
                print(String(format: "🎯 SOLO-PASS cont=%.2f iou=%.2f (色=%.2f 降门%.2f→接纳)",
                             sole.cont, ov, sole.color, soloMatchThreshold))
                #endif
            }
        }

        // 延续候选 = 颜色 match 且「延续分」最高(= 上一帧的你连续过来的)
        let incumbent = matched.max { $0.cont < $1.cont }
        // 挑战者 = 颜色 match 且综合分最高、且不是延续候选本身
        let challenger = matched.filter { $0.box != incumbent?.box }.max { $0.color < $1.color }

        var chosen: Scored?
        var switched = false
        if let inc = incumbent {
            if lastLockedBox != nil && inc.cont < continuityFloor {
                // 上一帧目标本帧没检出(延续分太低)→ 暂保持上一帧框(coast),别跳到爹
                coastFrames += 1
                if coastFrames <= maxCoastFrames, let hold = lastLockedBox {
                    #if DEBUG
                    dbgCurCont = inc.cont
                    dbgReselectLine = String(format: "重选 延续分=%.2f<floor → coast保持(%d/%d) 候选%d", inc.cont, coastFrames, maxCoastFrames, persons.count)
                    print("🧲 " + dbgReselectLine); dbgTrkState = "保持(目标暂失)"
                    #endif
                    return (hold, inc.color)
                }
                // 超 coast → 重新捕获:最强颜色匹配
                chosen = matched.max { $0.color < $1.color }
            } else {
                // 换人迟滞:挑战者综合分须 > 延续候选 + margin 才换,否则黏住延续(你)
                if let ch = challenger, ch.color > inc.color + switchMargin {
                    chosen = ch; switched = true
                } else {
                    chosen = inc
                }
                coastFrames = 0
            }
        }

        #if DEBUG
        let incS = incumbent.map { String(format: "延续%.2f(色%.2f)", $0.cont, $0.color) } ?? "无"
        let chS = challenger.map { String(format: "色%.2f", $0.color) } ?? "无"
        dbgReselectLine = String(format: "重选 人数=%d 延续候选=%@ 挑战者=%@ margin=%.2f 换人=%@ → %@",
                                 persons.count, incS, chS, switchMargin, switched ? "YES" : "NO",
                                 chosen.map { String(format: "面积%.3f@(%.2f,%.2f)色%.2f", $0.box.width*$0.box.height/fa, $0.box.midX/sensorSize.width, $0.box.midY/sensorSize.height, $0.color) } ?? "丢失")
        print("🧲 " + dbgReselectLine)
        #endif

        if let c = chosen {
            #if DEBUG
            dbgCurCont = c.cont
            dbgLockWho = "真人"; dbgTrkState = switched ? "换人" : "锁定(延续)"
            dbgRefindNX = c.box.midX / sensorSize.width; dbgRefindNY = c.box.midY / sensorSize.height
            #endif
            lastLockedBox = c.box
            startTracking(box: c.box, sensorSize: sensorSize)   // 顺带 re-seed VNTrackObject(成功了就走快速路)
            return (c.box, c.color)
        }

        #if DEBUG
        dbgCurCont = 0
        dbgLockWho = "无"; dbgTrkState = "丢失"
        // Part 4.2 REJECT:身份未命中,交状态机(冻结/超时回全景);绝不在此抓最大人。逐候选打归因(色/位/尺崩在哪)
        for (i, sc) in scored.enumerated() {
            print(String(format: "❌ REJECT cand#%d cont=%.2f (color=%.2f pos=%.2f size=%.2f) thresh=%.2f src=%@",
                         i, sc.cont, sc.color, sc.pos, sc.size, dbgCurThresh, sc.src))
        }
        let best = scored.max { $0.cont < $1.cont }
        dbgBestRejectCont = best?.cont ?? 0
        dbgBestRejectColor = best?.color ?? 0
        print(String(format: "🚫 REJECT-ALL 无匹配候选(候选=%d 门槛=%.2f%@) → findTarget nil",
                     persons.count, dbgCurThresh, searchMode ? " searchMode" : ""))
        #endif
        return nil
    }

    /// C8 重锚候选:纠正【当前目标】的框,绝不换人。
    /// ★黏当前目标:在「颜色 verify match 当前 target」的候选里,选【离 lastLockedBox 最近】的那个(延续候选),
    ///   而不是全局颜色分最高(那会被更大/分更高的路人抢→漂)。无 match 延续候选 → 返回 nil(宁可不重锚、保持原框)。
    private func reanchorTarget(detectBuffer: CVPixelBuffer, colorBuffer: CVPixelBuffer, sensorSize: CGSize)
        -> (box: CGRect, score: Float, candCount: Int)? {
        let persons = detectAllPersons(in: detectBuffer, sensorSize: sensorSize)
        guard let anchor = lastLockedBox else { return nil }   // 没有当前框基准 → 不重锚
        let ax = anchor.midX / sensorSize.width, ay = anchor.midY / sensorSize.height
        var best: CGRect?
        var bestScore: Float = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for p in persons {
            let (m, s) = isTarget(p, in: colorBuffer, sensorSize: sensorSize)
            guard m else { continue }                          // 只在颜色 match 当前 target 的候选里选
            let d = hypot(p.midX / sensorSize.width - ax, p.midY / sensorSize.height - ay)
            if d < bestDist { bestDist = d; best = p; bestScore = s }   // ★选离当前框最近的(延续),不是分最高的
        }
        // 延续约束:最近的 match 候选也不能离太远(>20% 画面 = 那不是当前目标的延续,是别人)→ 不重锚
        guard let b = best, bestDist < 0.20 else { return nil }
        return (b, bestScore, persons.count)
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

        // 卡3 HUD 状态(假人模式):锁谁=winner、状态=竞争、找回=winner 全帧归一化
        dbgLockWho = winner?.label ?? "无"
        dbgTrkState = winner == nil ? "丢失" : "竞争"
        if let w = winner {
            dbgRefindNX = w.box.midX / sensorSize.width; dbgRefindNY = w.box.midY / sensorSize.height
        }

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

    /// 多人候选源:VNDetectHumanBodyPose(召回多人,矩形召回弱只出1)。每 pose → tightBox(wide 空间)。
    /// 坐标约定与 PersonTracker.getTightBoxFromPose 完全一致:顶左原点,y=(1-maxY)*h,8% padding。
    private func detectPersonsViaPose(in pixelBuffer: CVPixelBuffer,
                                      sensorSize: CGSize) -> [(box: CGRect, conf: Float)] {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        guard let results = request.results else { return [] }
        let boxes: [(box: CGRect, conf: Float)] = results.compactMap { obs in
            guard let box = Self.tightBox(from: obs, sensorSize: sensorSize) else { return nil }
            return (box, obs.confidence)
        }
        #if DEBUG
        print("👁VNPose候选 results.count=\(results.count) 有效box=\(boxes.count) 输入=\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
        #endif
        return boxes
    }

    /// 单个 pose → 紧贴 bounding box(wide 传感器坐标)。与 getTightBoxFromPose 同逻辑,sensorSize 版。
    private static func tightBox(from obs: VNHumanBodyPoseObservation, sensorSize: CGSize) -> CGRect? {
        guard let points = try? obs.recognizedPoints(.all) else { return nil }
        let valid = points.values.filter { $0.confidence > 0.3 }
        guard valid.count >= 5 else { return nil }
        let xs = valid.map { $0.location.x }, ys = valid.map { $0.location.y }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        let padX = (maxX - minX) * 0.08, padY = (maxY - minY) * 0.08
        let boxMinX = max(0, minX - padX)
        let boxMaxY = min(1, maxY + padY)
        let boxMinY = max(0, minY - padY)
        let w = min(sensorSize.width, (maxX - minX + padX * 2) * sensorSize.width)
        let h = min(sensorSize.height, (boxMaxY - boxMinY) * sensorSize.height)
        return CGRect(x: boxMinX * sensorSize.width, y: (1 - boxMaxY) * sensorSize.height, width: w, height: h)
    }

    #if DEBUG
    /// 诊断/锁定候选(带 conf):换源到 body pose 多人版(矩形召回弱已弃用)。
    func detectAllPersonsWithConf(in pixelBuffer: CVPixelBuffer,
                                  sensorSize: CGSize) -> [(box: CGRect, conf: Float)] {
        return detectPersonsViaPose(in: pixelBuffer, sensorSize: sensorSize)
    }
    #endif

    /// 检测所有人(候选源)= body pose 多人版。lockLargest/重选在这些候选里选,逻辑不变。
    private func detectAllPersons(in pixelBuffer: CVPixelBuffer,
                                   sensorSize: CGSize) -> [CGRect] {
        return detectPersonsViaPose(in: pixelBuffer, sensorSize: sensorSize).map { $0.box }
    }

    /// Part 3B 搜索期兜底候选源:VNDetectHumanRectangles(pose 漏检时能召回人)。
    /// 坐标统一到 wide(顶左原点,y=(1-maxY)*h),与 detectAllPersons / tightBox 同坐标系(★这里栽过两次)。
    private func detectAllRects(in pixelBuffer: CVPixelBuffer, sensorSize: CGSize) -> [CGRect] {
        let request = VNDetectHumanRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        guard let results = request.results else { return [] }
        return results.map { obs in
            let r = obs.boundingBox   // Vision 归一化,左下原点
            return CGRect(x: r.minX * sensorSize.width,
                          y: (1 - r.maxY) * sensorSize.height,   // 翻到顶左原点 = wide
                          width: r.width * sensorSize.width,
                          height: r.height * sensorSize.height)
        }
    }

    /// 两框 IoU(同一坐标系)。用于 rect 并源去重 + 单人安全阀重叠判定 + shadow 诊断。
    func iou(_ a: CGRect, _ b: CGRect) -> Float {
        let inter = a.intersection(b)
        if inter.isNull || inter.width <= 0 || inter.height <= 0 { return 0 }
        let ai = inter.width * inter.height
        let au = a.width * a.height + b.width * b.height - ai
        return au > 0 ? Float(ai / au) : 0
    }

    #if DEBUG
    /// 诊断:给定框与「上一帧锁框」的 IoU(HUD/shadow 日志用)。无锁框返回 -1。
    func dbgIoUWithLast(_ box: CGRect) -> Float {
        guard let last = lastLockedBox else { return -1 }
        return iou(box, last)
    }

    // ===== 刀1 探针:运动预测 + 影子门(零行为变更,只算+打日志)=====

    /// 推进预测历史。只在「系统本帧实际选中一个框」时调用(actual=findTarget 返回框中心),
    /// 预测跟着现行为走,不吃影子门结果 → 无反馈。
    func dbgRecordLockedCenter(_ c: CGPoint, at t: TimeInterval) {
        lockedCenterHist.append((c, t))
        if lockedCenterHist.count > 3 { lockedCenterHist.removeFirst() }
    }

    /// 预测本帧目标中心 = last + vel·dt。vel = 最近两帧差分/真实dt(不假设恒定帧率),幅值 clamp。
    /// 历史不足 3 帧 → 退化为 last(安全)。无历史 → nil。
    func dbgPredictedCenter(at now: TimeInterval) -> CGPoint? {
        guard let last = lockedCenterHist.last else { return nil }
        guard lockedCenterHist.count >= 3 else { return last.c }
        let a = lockedCenterHist[lockedCenterHist.count - 2]
        let dt = last.t - a.t
        guard dt > 1e-4 else { return last.c }
        var vx = (last.c.x - a.c.x) / CGFloat(dt)
        var vy = (last.c.y - a.c.y) / CGFloat(dt)
        let sp = hypot(vx, vy)
        if sp > velClampPerSec { let k = velClampPerSec / sp; vx *= k; vy *= k }
        let pdt = CGFloat(now - last.t)
        return CGPoint(x: last.c.x + vx * pdt, y: last.c.y + vy * pdt)
    }

    /// 影子门:对本帧全部候选按 R∈{.05,.07,.10} 三档评估(门内数 / 门会选谁 / 与现行是否一致),
    /// 记 |actual−pred| 与 |actual−last|,打 🌗 SHADOW-GATE 行(ReplayLogger 解析进 SUMMARY)。
    /// 不改任何选择状态;末尾用 actual 推进历史(无反馈)。
    // 刀1-查勘 Q3:二分开关。编译期改这两个值 → 4 组合各重 build 跑 30s,分离「算贵」vs「打贵」:
    //   both on(默认) / compute only(算不打) / log only(不算只打) / both off(探针零成本基线)
    static var shadowGateComputeEnabled = true
    static var shadowGateLogEnabled = true
    // 自计时:每30帧一行 ⏱🌗,直接读出 compute 与 print 各自每帧 µs(both-on 跑一次即定 A/B,免4次重build)
    private static var dbgSgComputeUs = 0.0, dbgSgPrintUs = 0.0, dbgSgN = 0

    func dbgShadowGate(frame: Int, cands: [CGRect], actual: CGRect?, sensorSize: CGSize) {
        let doCompute = Self.shadowGateComputeEnabled
        let doLog = Self.shadowGateLogEnabled
        if !doCompute && !doLog { return }   // both off:探针零成本
        let tStart = CACurrentMediaTime()
        func nc(_ b: CGRect) -> CGPoint { CGPoint(x: b.midX / sensorSize.width, y: b.midY / sensorSize.height) }
        var pred: CGPoint? = nil, last: CGPoint? = nil, actualC: CGPoint? = nil
        var inGate = [0, 0, 0]
        var agree = ["?", "?", "?"]
        var dPred = -1.0, dLast = -1.0, miss = "off"
        if doCompute {
            pred = dbgPredictedCenter(at: tStart)
            last = lockedCenterHist.last?.c
            actualC = actual.map(nc)
            let candCs = cands.map(nc)
            let Rs: [CGFloat] = [0.05, 0.07, 0.10]
            let ref = pred ?? last   // 无预测时门围着 last
            for (i, R) in Rs.enumerated() {
                guard let r = ref else { continue }
                let ing = candCs.filter { hypot($0.x - r.x, $0.y - r.y) <= R }
                inGate[i] = ing.count
                let pick = ing.min { hypot($0.x - r.x, $0.y - r.y) < hypot($1.x - r.x, $1.y - r.y) }
                if let p = pick, let a = actualC {
                    agree[i] = hypot(p.x - a.x, p.y - a.y) < 0.02 ? "Y" : "N"   // 门选的 ≈ 现行选中?
                } else if pick == nil, actualC != nil {
                    agree[i] = "N"   // 门会漏(现行选了但门内空)= gateMiss = 未来行为差异点
                }
            }
            dPred = (pred != nil && actualC != nil) ? Double(hypot(actualC!.x - pred!.x, actualC!.y - pred!.y)) : -1
            dLast = (last != nil && actualC != nil) ? Double(hypot(actualC!.x - last!.x, actualC!.y - last!.y)) : -1
            if cands.isEmpty { miss = "detectorMiss(count=0)" }
            else {
                let m = zip([".05", ".07", ".10"], inGate).filter { $0.1 == 0 }.map { $0.0 }
                miss = m.isEmpty ? "none" : "gateMiss@" + m.joined(separator: ",")
            }
            if let a = actualC { dbgRecordLockedCenter(a, at: tStart) }   // 只用现行选中推进,无反馈
        }
        let tAfterCompute = CACurrentMediaTime()
        if doLog {
            print(String(format: "🌗 SHADOW-GATE f%d pred=(%@) actual=(%@) dPred=%.3f dLast=%.3f inGate[.05/.07/.10]=%d/%d/%d agree=%@/%@/%@ miss=%@",
                         frame,
                         pred.map { String(format: "%.2f,%.2f", $0.x, $0.y) } ?? "—",
                         actualC.map { String(format: "%.2f,%.2f", $0.x, $0.y) } ?? "—",
                         dPred, dLast, inGate[0], inGate[1], inGate[2], agree[0], agree[1], agree[2], miss))
        }
        // 自计时汇报(每30帧摊薄一行):compute=tStart→tAfterCompute、print=tAfterCompute→此刻
        Self.dbgSgComputeUs += (tAfterCompute - tStart) * 1e6
        Self.dbgSgPrintUs += (CACurrentMediaTime() - tAfterCompute) * 1e6
        Self.dbgSgN += 1
        if Self.dbgSgN >= 30 {
            print(String(format: "⏱🌗 shadowGate/帧 compute=%.0fµs print=%.0fµs (compute开=%@ log开=%@ n=%d)",
                         Self.dbgSgComputeUs / Double(Self.dbgSgN), Self.dbgSgPrintUs / Double(Self.dbgSgN),
                         doCompute ? "Y" : "N", doLog ? "Y" : "N", Self.dbgSgN))
            Self.dbgSgComputeUs = 0; Self.dbgSgPrintUs = 0; Self.dbgSgN = 0
        }
    }
    #endif

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
