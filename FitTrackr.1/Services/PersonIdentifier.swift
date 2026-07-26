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

    // 刀3:已删 C8 重锚字段(reanchorInterval/reanchorCounter/dbgReanchorLine)——随 VNTrackObject 一并删。

    var lastCandidateCount = 0      // 本帧重选候选数(状态机 locked→searching 日志 + HUD 读)
    let soloMatchThreshold: Float = 0.30  // Part 3A 单人安全阀:全场仅1人且与锁框高重叠时的放宽门槛
    #if DEBUG
    var dbgCurCont: Float = 0       // 本帧选中的延续分(HUD/状态日志)
    var dbgCurThresh: Float = 0.5   // 本帧生效门槛(安全阀降门时=0.30)
    var dbgSrcMerged = false        // rect 是否并源(searching 时 P+R)
    var dbgBestRejectCont: Float = 0   // nil 帧最佳被拒候选延续分(搜索心跳 bestCont)
    var dbgBestRejectColor: Float = 0  // nil 帧最佳被拒候选颜色分(搜索心跳 bestColor)
    #endif

    // ===== 刀2 连续性主权:LOCKED 邻域门(转正,非DEBUG也编译)=====
    var lockedCenterHist: [(c: CGPoint, t: TimeInterval)] = []  // 近3帧「实际选中」中心(归一)+墙钟
    private let velClampPerSec: CGFloat = 0.5   // 速度幅值上限(归一/秒),防单帧坏值甩飞预测
    let gateR0: CGFloat = 0.06           // Config:邻域门起步半径(待影子日志校准)。阈值按 UW基准系标定
    // 【不变量III·测量归一化】当前设备 zoom(TrackingController 切换时同步写入)。
    // 本类所有归一化距离量(邻域门 d、找回 dFreeze)在与阈值比较前除以它 → 判据恒在 UW基准系。D=1 恒等。
    var lensDeviceZoom: CGFloat = 1.0
    let gateVetoThreshold: Float = 0.25  // Config:颜色否决门槛(明显不是一个人才踢)
    let maxExtrapolationSec: CGFloat = 0.08  // Config:预测外推上限(防历史冻结时 pred 无限跑飞)
    var gateHits = 0, gateMissCount = 0, gateVetoCount = 0, gateDetectorMiss = 0  // 门统计(内存累加,规避每帧print)
    private var gateFrameCounter = 0

    // ===== ⑤ SEARCHING 装牙:三牙找回(色 + margin + 位置先验),缺一不可 =====
    let reacqMargin: Float = 0.15        // ② margin(top1−top2)门槛
    let reacqPosK: Float = 0.002         // ③ 位置预算随 searching 持续帧数线性放宽斜率
    let reacqPosCap: Float = 0.30        // ③ 位置预算上限
    private var searchFrozenPoint: CGPoint?   // 进入 searching 那刻的丢失位置(归一),③ 的基准点
    private var searchingFrames = 0           // 本轮 searching 已持续帧数(③ 预算放宽用)
    private var wasSearchMode = false         // 上一帧是否 searchMode(检测「刚进 searching」那刻)
    var reacqFailCount = 0, reacqFailColor = 0, reacqFailMargin = 0, reacqFailPos = 0, reacqFailDetector = 0

    // SEARCHING 找回后回 LOCKED 的延续基准(lastLockedBox);旧「方案A 重选/迟滞」常量随装牙作废但保留不碍事
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

    // 刀3:已删 Vision 追踪字段(trackingRequest/sequenceHandler/isTrackingActive)。

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
        // 刀2:预测历史种子 = 锁定中心;门统计清零(新一次锁定新账)
        self.lockedCenterHist = [(CGPoint(x: personBox.midX / sensorSize.width, y: personBox.midY / sensorSize.height), CACurrentMediaTime())]
        self.gateHits = 0; self.gateMissCount = 0; self.gateVetoCount = 0; self.gateDetectorMiss = 0
        // ⑤:新一次锁定 = 装牙状态清账
        self.searchFrozenPoint = nil; self.searchingFrames = 0; self.wasSearchMode = false
        self.reacqFailCount = 0; self.reacqFailColor = 0; self.reacqFailMargin = 0; self.reacqFailPos = 0; self.reacqFailDetector = 0
        // 刀3:已删 VNTrackObject 起跟(startTracking)+ sequenceHandler 重置。锁定后 LOCKED 走邻域门,不再起 track。

        let baseEmpty = profile.colorHistogram.isEmpty && profile.lowerBodyColorHist.isEmpty
        print("🔒 目标已锁定 | 上衣颜色bins: \(profile.colorHistogram.count) | 下装颜色bins: \(profile.lowerBodyColorHist.count)\(baseEmpty ? "  ★★基准空!色彩verify失效→易漂(就是这次锁定的问题)" : "")")
    }

    /// 锁定最大的人
    func lockLargest(in pixelBuffer: CVPixelBuffer, sensorSize: CGSize) -> Bool {
        // 【dt尖峰拆分·清A并刀】lockLargest 在阶段计时器之外同步跑,是 dt=106/468 尖峰真身。
        // 三段拆:全帧检测 / 复核打印(DEBUG重复检测) / 建档(双区直方图)→ 决定优化往哪边使劲。
        #if DEBUG
        let _tLk0 = CACurrentMediaTime()
        #endif
        let realBoxes = detectAllPersons(in: pixelBuffer, sensorSize: sensorSize)
        #if DEBUG
        let _tLk1 = CACurrentMediaTime()
        #endif
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
        let _tLk2 = CACurrentMediaTime()   // 复核打印(含 DEBUG 二次全帧检测)段结束
        #endif

        // 【三态机补丁刀】短期黑名单过滤:连续两次超时解锁的位置 10s 内不作自动锁定候选(防重锁循环)
        let _blNow = CACurrentMediaTime()
        lockBlacklist = lockBlacklist.filter { $0.until > _blNow }
        let lockCandidates = lockBlacklist.isEmpty ? realBoxes : realBoxes.filter { box in
            let c = CGPoint(x: box.midX / sensorSize.width, y: box.midY / sensorSize.height)
            return !lockBlacklist.contains { hypot($0.center.x - c.x, $0.center.y - c.y) < wedgeBlacklistRadius }
        }
        guard let largest = lockCandidates
                .max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return false
        }
        lock(personBox: largest, in: pixelBuffer, sensorSize: sensorSize)
        #if DEBUG
        // 【dt尖峰拆分】三段读数(print+落盘,Zc 冒烟锁定即产出;Release 无此段)
        let _tLk3 = CACurrentMediaTime()
        let _lkMsg = String(format: "🔒⏱ lockLargest拆分: 检测=%.0fms 复核打印(DEBUG二次检测)=%.0fms 建档=%.0fms 总=%.0fms",
                            (_tLk1 - _tLk0) * 1000, (_tLk2 - _tLk1) * 1000, (_tLk3 - _tLk2) * 1000, (_tLk3 - _tLk0) * 1000)
        print(_lkMsg); PerfFileLog.shared.line(_lkMsg)
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
        DebugLog.frame(dbgDriftLine)   // ②b:每帧 DRIFT 诊断收编到 verbosity 闸
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
    // 【三态机补丁刀·防重锁循环】超时解锁的目标位置记忆(归一中心)。
    // 连续第 2 次在同位置(半径 0.08)超时解锁 → 进短期黑名单(10s),auto-lock 期间跳过该处候选——
    // 掐断「锁静物→2s→解锁→立刻重锁同一静物」的永久循环。选黑名单而非退 searching:
    // 三牙找回用的是被锁目标自己的颜色档案,锁的是静物时会把静物精准找回=把卡死洗白成稳定错锁。
    private var wedgeUnlockHistory: [(center: CGPoint, at: TimeInterval)] = []
    private var lockBlacklist: [(center: CGPoint, until: TimeInterval)] = []
    private let wedgeBlacklistRadius: CGFloat = 0.08
    private let wedgeBlacklistTTL: TimeInterval = 10

    /// 【不变量III·切换重映射】设备 zoom D1→D2:本类 buffer 空间位置状态绕画面中心一步缩放 k=D2/D1
    /// (lockedCenterHist/searchFrozenPoint 是归一坐标,绕 0.5 缩放;lastLockedBox 是像素矩形,绕传感器中心缩放)。
    /// 不重映射 → 切换帧 pred 在旧空间、候选在新空间,|c|×(D−1) 的假跳变直接打爆邻域门。
    func remapForLensSwitch(k: CGFloat, sensorSize: CGSize) {
        func remapN(_ p: CGPoint) -> CGPoint { CGPoint(x: 0.5 + (p.x - 0.5) * k, y: 0.5 + (p.y - 0.5) * k) }
        lockedCenterHist = lockedCenterHist.map { (remapN($0.0), $0.1) }
        if let f = searchFrozenPoint { searchFrozenPoint = remapN(f) }
        if let b = lastLockedBox {
            let cx = sensorSize.width / 2, cy = sensorSize.height / 2
            lastLockedBox = CGRect(x: cx + (b.origin.x - cx) * k, y: cy + (b.origin.y - cy) * k,
                                   width: b.width * k, height: b.height * k)
        }
        print(String(format: "🎯 PI-REMAP k=%.2f(pred历史/冻结点/lastBox → 新buffer空间)", k))
    }

    /// 三不管地带超时出口(TrackingController.advanceLockState 唯一调用方):记位置→连击判黑名单→解锁
    func forceUnlockWedged(at now: TimeInterval) {
        if let c = predictedCenter(at: now) {   // 卡死态下即冻结的锁定位置(归一)
            wedgeUnlockHistory = wedgeUnlockHistory.filter { now - $0.at < 30 }
            let repeatHit = wedgeUnlockHistory.contains { hypot($0.center.x - c.x, $0.center.y - c.y) < wedgeBlacklistRadius }
            wedgeUnlockHistory.append((c, now))
            if repeatHit {
                lockBlacklist.append((c, now + wedgeBlacklistTTL))
                print(String(format: "⛔ LOCK黑名单: (%.2f,%.2f) 连续两次超时解锁 → %0.fs 内不作候选", c.x, c.y, wedgeBlacklistTTL))
            }
        }
        unlock()
    }

    func unlock() {
        isLocked = false
        target = nil
        lastLockedBox = nil; coastFrames = 0
        lockedCenterHist.removeAll()   // 刀2:清预测历史
        searchFrozenPoint = nil; searchingFrames = 0; wasSearchMode = false   // ⑤:清装牙状态
        #if DEBUG
        dbgLockWho = "无"; dbgTrkState = "未锁定"; dbgRefindNX = -1; dbgRefindNY = -1; lockedBoxArea = -1; dbgReselectLine = ""
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
            DebugLog.frame(String(format: "  isTarget候选 中心=(%.2f,%.2f) 综合分=%.2f 色彩基准=%@ → lastCenter改成此候选",
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

        // ⑤ SEARCHING 计时 + 冻结点(装牙用):进入 searching 那刻记丢失位置,之后按帧放宽位置预算
        if searchMode {
            if !wasSearchMode {
                searchFrozenPoint = lastLockedBox.map { CGPoint(x: $0.midX / sensorSize.width, y: $0.midY / sensorSize.height) }
                searchingFrames = 0
            }
            searchingFrames += 1
        }
        wasSearchMode = searchMode

        // ===== 刀2 连续性主权:LOCKED(非 searchMode)= 预测邻域门;下方全局身份找回仅 SEARCHING 走 =====
        if !searchMode {
            return lockedGate(in: detectBuffer, colorBuffer: colorBuffer, sensorSize: sensorSize)
        }

        // 刀3:已删 SEARCHING 路径的 VNTrackObject 快速路(continueTracking/重锚)。
        // SEARCHING = 身份主权,每帧走下方全局重选(方案A),不再有自漂的 track 兜底。

        // ===== ⑤ SEARCHING 装牙:身份主权全画面找回,三牙齐才认(色 + margin + 位置先验)=====
        var persons = detectAllPersons(in: detectBuffer, sensorSize: sensorSize)

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

        // 每候选颜色综合分(isTarget;撞衫下色主导),按分降序 —— 找回只看身份(色),不再算延续/迟滞
        let scoredC = persons.map { p -> (box: CGRect, color: Float) in
            let (_, s) = isTarget(p, in: colorBuffer, sensorSize: sensorSize)
            return (p, s)
        }.sorted { $0.color > $1.color }
        #if DEBUG
        dbgCurThresh = config.matchThreshold
        #endif

        // 检测断帧(候选0)→ 找回失败(detectorMiss),交状态机(冻结/超时回全景)
        guard let top1 = scoredC.first else {
            reacqFailCount += 1; reacqFailDetector += 1
            #if DEBUG
            dbgCurCont = 0; dbgLockWho = "无"; dbgTrkState = "找回失败"
            DebugLog.frame("🔍 REACQ-FAIL top1=— top2=— margin=— dFreeze=— reason=detectorMiss(候选0)")
            #endif
            return nil
        }
        let top2c: Float = scoredC.count > 1 ? scoredC[1].color : 0
        let t1c = CGPoint(x: top1.box.midX / sensorSize.width, y: top1.box.midY / sensorSize.height)
        // 位置预算:进冻结点起步 gateR0,随 searching 持续帧数线性放宽,封顶 reacqPosCap
        let posBudget = min(Float(gateR0) + reacqPosK * Float(searchingFrames), reacqPosCap)
        let dFreeze: Float = searchFrozenPoint.map { Float(hypot(t1c.x - $0.x, t1c.y - $0.y) / lensDeviceZoom) } ?? 0   // 【不变量III】UW基准系

        // 三牙(缺一不可):① 颜色≥matchThreshold ② margin(top1−top2)>reacqMargin(单候选视为满足) ③ 离冻结点≤预算
        let toothColor  = top1.color >= config.matchThreshold
        let toothMargin = scoredC.count < 2 || (top1.color - top2c > reacqMargin)
        let toothPos    = (searchFrozenPoint == nil) || (dFreeze <= posBudget)

        if toothColor && toothMargin && toothPos {
            #if DEBUG
            dbgCurCont = top1.color
            dbgLockWho = "真人"; dbgTrkState = "找回"
            dbgRefindNX = t1c.x; dbgRefindNY = t1c.y
            #endif
            lastLockedBox = top1.box
            coastFrames = 0
            // 刀2:找回后重种预测历史 → 回 LOCKED 门从找回位置起(不吃丢失前陈旧速度)
            lockedCenterHist = [(t1c, CACurrentMediaTime())]
            return (top1.box, top1.color)
        }

        // 三牙不齐 → 继续 SEARCHING(直到 searchTimeout → LOST);逐条归因
        reacqFailCount += 1
        if !toothColor { reacqFailColor += 1 }
        if !toothMargin { reacqFailMargin += 1 }
        if !toothPos { reacqFailPos += 1 }
        #if DEBUG
        dbgCurCont = 0; dbgLockWho = "无"; dbgTrkState = "找回失败"
        dbgBestRejectColor = top1.color
        var reason = ""
        if !toothColor { reason += "色<0.50 " }
        if !toothMargin { reason += "margin<0.15 " }
        if !toothPos { reason += "偏冻结>预算 " }
        DebugLog.frame(String(format: "🔍 REACQ-FAIL top1=%.2f top2=%.2f margin=%.2f dFreeze=%.3f/预算%.3f reason=%@",
                     top1.color, top2c, top1.color - top2c, dFreeze, posBudget, reason.isEmpty ? "?" : reason))
        #endif
        return nil
    }

    // 刀3:已删 reanchorTarget(C8 重锚)——它只服务已删的 VNTrackObject 快速路,无其它调用点。

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
            return (w.box, w.score)
        }
        return nil
    }
    #endif

    // 刀3:已删 VNTrackObject 全部机制(startTracking / continueTracking 定义)——SEARCHING 不再有 track 兜底。

    // MARK: - ① pose 去重(帧级缓存)

    /// 帧级 pose 缓存:key = 帧 pts,帧入口 beginFramePose 重建,不跨帧持有 observations。
    /// 同帧的 gate(detectAllPersons)/诊断(detectAllPersonsWithConf)/Step B(detectPose)三处共用,
    /// 把原来同帧同 detPB 的 3× VNDetectHumanBodyPose 收敛成 1×。
    private var poseCachePts: CMTime = .invalid
    private var poseCacheObs: [VNHumanBodyPoseObservation] = []

    /// 帧入口:本帧只跑一次 VNDetectHumanBodyPose。pts 命中直接返回(不重复检测);
    /// pts 变即重建(旧 observations 被整体替换 → 不跨帧持有)。检测在 detPB,orientation 恒 .up
    /// (与原 detectPersonsViaPose / Step B detectPose 两处完全一致,VNDetectHumanBodyPoseRequest 均为默认)。
    func beginFramePose(pb: CVPixelBuffer, pts: CMTime) {
        if CMTimeCompare(poseCachePts, pts) == 0 { return }   // 命中:本帧已检测过
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        do { try handler.perform([request]); poseCacheObs = request.results ?? [] }
        catch { poseCacheObs = [] }
        poseCachePts = pts
        #if DEBUG
        DebugLog.frame("👁VNPose[帧检1次] count=\(poseCacheObs.count) 输入=\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))")
        #endif
    }

    /// 读本帧缓存的 pose observations(Step B detectPose 复用,不再自跑检测)。
    func cachedPoseObservations() -> [VNHumanBodyPoseObservation] { poseCacheObs }

    // MARK: - 特征提取

    /// 多人候选源:**复用**本帧缓存的 VNDetectHumanBodyPose observations(① 前是每次自跑一遍)。
    /// 每 pose → tightBox(wide 空间)。坐标约定与 PersonTracker.getTightBoxFromPose 完全一致。
    private func detectPersonsViaPose(in pixelBuffer: CVPixelBuffer,
                                      sensorSize: CGSize) -> [(box: CGRect, conf: Float)] {
        // ① pose 去重:不再自跑检测,读帧入口 beginFramePose 缓存的 observations(pixelBuffer 仅保签名兼容)
        return poseCacheObs.compactMap { obs in
            guard let box = Self.tightBox(from: obs, sensorSize: sensorSize) else { return nil }
            return (box, obs.confidence)
        }
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
    #endif

    // ===== 刀2 连续性主权:运动预测(转正,非DEBUG也编译)+ LOCKED 邻域门 =====

    /// 推进预测历史。只在「系统本帧实际选中一个框」时调用 → 预测跟着现行为走,无反馈。
    func recordLockedCenter(_ c: CGPoint, at t: TimeInterval) {
        lockedCenterHist.append((c, t))
        if lockedCenterHist.count > 3 { lockedCenterHist.removeFirst() }
    }

    /// 重种历史(单点,清空重建)。SEARCHING 找回后调 → 回 LOCKED 时门从找回位置起,不吃冻结的陈旧速度。
    func seedLockedCenter(_ c: CGPoint, at t: TimeInterval) { lockedCenterHist = [(c, t)] }

    /// 预测本帧目标中心 = last + vel·dt。vel = 最近两帧差分/真实dt(不假设恒定帧率),幅值 clamp。
    /// 历史不足 3 帧 → 退化为 last(安全)。无历史 → nil。
    func predictedCenter(at now: TimeInterval) -> CGPoint? {
        guard let last = lockedCenterHist.last else { return nil }
        guard lockedCenterHist.count >= 3 else { return last.c }
        let a = lockedCenterHist[lockedCenterHist.count - 2]
        let dt = last.t - a.t
        guard dt > 1e-4 else { return last.c }
        var vx = (last.c.x - a.c.x) / CGFloat(dt)
        var vy = (last.c.y - a.c.y) / CGFloat(dt)
        let sp = hypot(vx, vy)
        if sp > velClampPerSec { let k = velClampPerSec / sp; vx *= k; vy *= k }
        // ★ 关键:外推时间钳上限。历史一冻结(门连续 miss),now-last.t 会无限增长 →
        //   pred 跑飞出画面 → 永远 miss 死循环。钳到 maxExtrapolationSec 后 pred 停在 last 附近,下帧能重命中。
        let pdt = min(CGFloat(now - last.t), maxExtrapolationSec)
        return CGPoint(x: last.c.x + vx * pdt, y: last.c.y + vy * pdt)
    }

    /// 刀2 LOCKED 邻域门(连续性主权):预测邻域内取离 pred 最近的候选;颜色仅否决(isTarget 分 <
    /// gateVetoThreshold 才踢,永不参与「选谁」);门内零可接受候选 → 返回 nil(→SEARCHING)。
    /// 选中即写 lastLockedBox + 推进历史。坐标全程 wide:候选(detectAllPersons)与 pred(归一 of wide)同系。
    private func lockedGate(in detectBuffer: CVPixelBuffer, colorBuffer: CVPixelBuffer,
                            sensorSize: CGSize) -> (box: CGRect, score: Float)? {
        let now = CACurrentMediaTime()
        gateFrameCounter += 1
        let persons = detectAllPersons(in: detectBuffer, sensorSize: sensorSize)
        lastCandidateCount = persons.count
        func nc(_ b: CGRect) -> CGPoint { CGPoint(x: b.midX / sensorSize.width, y: b.midY / sensorSize.height) }

        // detectorMiss:零候选(刀5 的 gap 补偿输入)
        guard !persons.isEmpty else {
            gateDetectorMiss += 1
            #if DEBUG
            print("🚪 DETECTOR-MISS f\(gateFrameCounter) (results.count=0) → nil→SEARCHING")
            #endif
            return nil
        }
        // 参考中心:预测优先,退化到历史末 / lastLockedBox
        guard let refC: CGPoint = predictedCenter(at: now) ?? lockedCenterHist.last?.c ?? lastLockedBox.map(nc) else {
            gateMissCount += 1
            return nil
        }
        let R = gateR0   // 刀5 再上 R = R0 + k·gap

        // 门内候选:|center − pred| ≤ R,且颜色不被否决;取离 pred 最近
        var best: (box: CGRect, d: CGFloat, score: Float)? = nil
        var inGateCount = 0, vetoedCount = 0
        for p in persons {
            let c = nc(p)
            // 【不变量III】buffer 归一距离 ÷ 设备zoom → UW基准系再比 R(不除则 D=2 时门半径物理上减半)
            let d = hypot(c.x - refC.x, c.y - refC.y) / lensDeviceZoom
            if d > R { continue }
            inGateCount += 1
            let (_, s) = isTarget(p, in: colorBuffer, sensorSize: sensorSize)  // 仅取分做否决,不选谁
            if s < gateVetoThreshold {
                vetoedCount += 1; gateVetoCount += 1
                #if DEBUG
                print(String(format: "🚪 VETO f%d 门内@(%.2f,%.2f) 颜色%.2f<%.2f → 踢", gateFrameCounter, c.x, c.y, s, gateVetoThreshold))
                #endif
                continue
            }
            if best == nil || d < best!.d { best = (p, d, s) }
        }

        guard let pick = best else {
            gateMissCount += 1   // 门内零可接受候选(全出门或全否决)→ nil→SEARCHING
            #if DEBUG
            // 诊断:每候选 中心 + 到pred距 + 到lastLockedBox距。dLast 小 = 目标 pose 在(只是噪声出门,该放宽R);
            //       全部 dLast 大 = 目标 pose 这帧真丢了(该 coast 等它回来,别抓邻居 = 刀5)。
            let lc = lastLockedBox.map(nc)
            let cs = persons.map { p -> String in
                let c = nc(p)
                let dp = hypot(c.x - refC.x, c.y - refC.y)
                let dl = lc.map { hypot(c.x - $0.x, c.y - $0.y) } ?? -1
                return String(format: "(%.2f,%.2f)dP%.3f/dL%.3f", c.x, c.y, dp, dl)
            }.joined(separator: " ")
            print("🚪 GATE-MISS f\(gateFrameCounter) pred=(\(String(format:"%.2f",refC.x)),\(String(format:"%.2f",refC.y))) R=\(String(format:"%.2f",R)) lastBox=\(lc.map{String(format:"(%.2f,%.2f)",$0.x,$0.y)} ?? "—") 候选[\(persons.count)]: \(cs) → nil→SEARCHING")
            #endif
            return nil
        }

        // 选中:门内离 pred 最近
        gateHits += 1
        lastLockedBox = pick.box
        recordLockedCenter(nc(pick.box), at: now)
        #if DEBUG
        dbgLockWho = "真人"; dbgTrkState = "锁定(门)"
        if gateFrameCounter % 60 == 0 {
            print("🚪 GATE hits=\(gateHits) miss=\(gateMissCount) veto=\(gateVetoCount) detMiss=\(gateDetectorMiss) (R=\(String(format: "%.2f", R)))")
        }
        #endif
        return (pick.box, pick.score)
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
