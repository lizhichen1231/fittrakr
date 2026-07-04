import Foundation
import QuartzCore

#if DEBUG
/// 回放测试专用日志器(纯 DEBUG 工具,不改任何跟踪/锁定/状态机逻辑)。
///
/// 做两件事,全靠**接管进程 stdout**,不碰任何现有 `print` 调用点:
///  1) 把回放期间所有 console 输出(STATE / REJECT / SOLO-PASS / SHADOW-FALLBACK /
///     SEARCHING 心跳 / PROBE / DRIFT / SLEW …)**同步落盘**到
///     `Documents/ReplayLogs/{clip}_{时间戳}.log`(Files app 可直接取,不依赖连 Xcode)。
///  2) 边写边**解析**这些行,累计计数,播完在文件末尾 + console 打一段 REPLAY SUMMARY。
///
/// 实现:`dup2` 把 `STDOUT_FILENO` 重定向进一个 `Pipe`,读端把字节**同时**写回原始
/// stdout(Xcode console 照常可见)和日志文件,并按行喂给解析器。`stop()` 时还原 stdout。
final class ReplayLogger {
    static let shared = ReplayLogger()
    private init() {}

    private(set) var active = false
    private var clip = ""
    private var logURL: URL?
    private var fileHandle: FileHandle?
    private var origStdout: Int32 = -1
    private var pipe: Pipe?
    private var lineBuf = ""
    private var startWall: TimeInterval = 0

    // —— HUD 读:最近一帧号/回放时间(从 PROBE 解析)——
    private(set) var lastFrame = 0
    private(set) var lastTime: Double = 0

    // —— 统计计数 ——
    private var cLockedToSearching = 0
    private var cSearchingToLocked = 0
    private var reacquireTimes: [Double] = []
    private var cSearchingToLost = 0
    private var cUnlockedToLocked = 0            // 初次锁 + 每次 lost 后重锁
    private var cRejectColor = 0, cRejectPos = 0, cRejectSize = 0, cRejectTotal = 0
    private var cSoloPass = 0
    private var cShadow = 0, cShadowRescue = 0   // rescue = iou>0.5 且候选1(本该被 SOLO-PASS 接住)
    private var frames = 0
    private var maxCenterJump: Double = 0
    private var prevLockedNx: Double?, prevLockedNy: Double?
    private var lockedRunStart: Double?          // 当前连续锁定段的起始回放时间
    private var longestLockedSpan: Double = 0
    // —— 刀1 影子门(🌗 SHADOW-GATE)——
    private var dPredList: [Double] = []
    private var dLastList: [Double] = []
    private var gateMiss = [0, 0, 0]      // R=.05/.07/.10 各档门内空帧数(有候选但门内0)
    private var disagree = [0, 0, 0]      // 各档「门会选≠现行选中」帧数(=未来行为差异点)
    private var detectorMissCount = 0     // 纯检测断帧(候选0)——Q7 gap 补偿的输入,单列
    private var shadowFrames = 0
    // —— ⑤ SEARCHING 找回失败(🔍 REACQ-FAIL)——
    private var reacqFail = 0, reacqFailColor = 0, reacqFailMargin = 0, reacqFailPos = 0, reacqFailDetector = 0

    // MARK: - 生命周期

    func start(clip: String) {
        guard !active else { return }
        resetCounters()
        self.clip = clip
        self.startWall = CACurrentMediaTime()

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReplayLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let url = dir.appendingPathComponent("\(clip)_\(stamp).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logURL = url
        fileHandle = try? FileHandle(forWritingTo: url)

        let header = "════ REPLAY LOG \(clip) ════\n"
        fileHandle?.write(header.data(using: .utf8)!)

        // 接管 stdout:保存原 fd,重定向到 pipe
        let p = Pipe()
        origStdout = dup(STDOUT_FILENO)
        // ③:去掉 setvbuf(_IONBF)——原来关缓冲=每条 print 立即 flush,拖慢全体 print。
        // 恢复块缓冲(默认);stop() 的 fflush(stdout) 兜住尾部,解析/落盘不丢行。
        dup2(p.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        p.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self = self else { return }
            let data = h.availableData
            if data.isEmpty { return }
            // 1) 回写真实 stdout → Xcode console 照常可见
            if self.origStdout >= 0 { data.withUnsafeBytes { _ = write(self.origStdout, $0.baseAddress, data.count) } }
            // 2) 落盘
            self.fileHandle?.write(data)
            // 3) 解析
            if let s = String(data: data, encoding: .utf8) { self.ingest(s) }
        }
        pipe = p
        active = true
    }

    func stop() {
        guard active else { return }
        active = false
        fflush(stdout)
        // 还原 stdout(先解绑 handler,再 dup2 回去)
        pipe?.fileHandleForReading.readabilityHandler = nil
        if origStdout >= 0 { dup2(origStdout, STDOUT_FILENO); close(origStdout); origStdout = -1 }
        pipe = nil

        let summary = buildSummary()
        fileHandle?.write(summary.data(using: .utf8)!)
        try? fileHandle?.close()
        fileHandle = nil
        print(summary)   // 此刻 stdout 已还原 → console 也看得到
        if let u = logURL { print("📄 回放日志: \(u.path)") }
    }

    // MARK: - 解析

    private func ingest(_ chunk: String) {
        lineBuf += chunk
        while let nl = lineBuf.firstIndex(of: "\n") {
            let line = String(lineBuf[..<nl])
            lineBuf = String(lineBuf[lineBuf.index(after: nl)...])
            parse(line)
        }
    }

    private func parse(_ line: String) {
        if line.contains("STATE locked→searching") { cLockedToSearching += 1 }
        else if line.contains("STATE searching→locked") {
            cSearchingToLocked += 1
            if let t = firstFloat(in: line, after: "reacquired ", terminator: "s") { reacquireTimes.append(t) }
        }
        else if line.contains("STATE searching→lost") { cSearchingToLost += 1 }
        else if line.contains("STATE unlocked→locked") { cUnlockedToLocked += 1 }

        if line.contains("REJECT cand#") {
            cRejectTotal += 1
            let c = firstFloat(in: line, after: "color=", terminator: " ") ?? 1
            let p = firstFloat(in: line, after: "pos=", terminator: " ") ?? 1
            let s = firstFloat(in: line, after: "size=", terminator: ")") ?? 1
            let m = min(c, min(p, s))
            if m == c { cRejectColor += 1 } else if m == p { cRejectPos += 1 } else { cRejectSize += 1 }
        }
        if line.contains("SOLO-PASS") { cSoloPass += 1 }
        if line.contains("SHADOW-FALLBACK") {
            cShadow += 1
            let iou = firstFloat(in: line, after: "iouWithLast=", terminator: " ") ?? 0
            let cand = firstFloat(in: line, after: "candidates=", terminator: " ") ?? 0
            if iou > 0.5 && Int(cand) == 1 { cShadowRescue += 1 }
        }

        // 刀1 影子门:🌗 SHADOW-GATE f{n} … dPred= dLast= inGate[..]=a/b/c agree=A/B/C miss=…
        if line.contains("SHADOW-GATE") {
            shadowFrames += 1
            if let d = firstFloat(in: line, after: "dPred=", terminator: " "), d >= 0 { dPredList.append(d) }
            if let d = firstFloat(in: line, after: "dLast=", terminator: " "), d >= 0 { dLastList.append(d) }
            let inG = triTokens(line, after: "inGate[.05/.07/.10]=").compactMap { Int($0) }
            let ag  = triTokens(line, after: "agree=")
            let detMiss = line.contains("detectorMiss")
            if detMiss { detectorMissCount += 1 }
            for i in 0..<3 {
                if !detMiss, i < inG.count, inG[i] == 0 { gateMiss[i] += 1 }
                if i < ag.count, ag[i] == "N" { disagree[i] += 1 }
            }
        }

        // ⑤ 找回失败:🔍 REACQ-FAIL … reason=色<0.50 margin<0.15 偏冻结>预算 / detectorMiss(候选0)
        if line.contains("REACQ-FAIL") {
            reacqFail += 1
            if line.contains("detectorMiss") { reacqFailDetector += 1 }
            if line.contains("色<0.50") { reacqFailColor += 1 }
            if line.contains("margin<0.15") { reacqFailMargin += 1 }
            if line.contains("偏冻结") { reacqFailPos += 1 }
        }

        if line.hasPrefix("PROBE t=") {
            frames += 1
            if let f = firstFloat(in: line, after: "f=", terminator: " ") { lastFrame = Int(f) }
            if let t = firstFloat(in: line, after: "PROBE t=", terminator: " ") { lastTime = t }
            let locked = line.contains("lock=T")
            if locked {
                // 最长锁定段
                if lockedRunStart == nil { lockedRunStart = lastTime }
                longestLockedSpan = max(longestLockedSpan, lastTime - (lockedRunStart ?? lastTime))
                // 锁定中心最大单帧跳变
                if let nx = firstFloat(in: line, after: "nx=", terminator: " "),
                   let ny = firstFloat(in: line, after: "ny=", terminator: " ") {
                    if let px = prevLockedNx, let py = prevLockedNy {
                        maxCenterJump = max(maxCenterJump, (Double(nx - px) * Double(nx - px) + Double(ny - py) * Double(ny - py)).squareRoot())
                    }
                    prevLockedNx = nx; prevLockedNy = ny
                }
            } else {
                lockedRunStart = nil; prevLockedNx = nil; prevLockedNy = nil
            }
        }
    }

    /// 从 line 中 `key` 之后取到 `terminator` 之前的第一个浮点数。
    private func firstFloat(in line: String, after key: String, terminator: Character) -> Double? {
        guard let r = line.range(of: key) else { return nil }
        let tail = line[r.upperBound...]
        var num = ""
        for ch in tail {
            if ch == terminator { break }
            if ch.isNumber || ch == "." || ch == "-" { num.append(ch) } else if !num.isEmpty { break }
        }
        return Double(num)
    }

    /// 从 line 中 `key` 之后取到空格前的段,按 "/" 切分(解析 a/b/c、Y/N/?)。
    private func triTokens(_ line: String, after key: String) -> [String] {
        guard let r = line.range(of: key) else { return [] }
        let tail = line[r.upperBound...].prefix { $0 != " " }
        return tail.split(separator: "/").map { String($0) }
    }

    private func pct(_ v: [Double], _ p: Double) -> Double {
        guard !v.isEmpty else { return -1 }
        let s = v.sorted(); let k = (Double(s.count - 1)) * p / 100
        let lo = Int(k.rounded(.down)), hi = Int(k.rounded(.up))
        return lo == hi ? s[lo] : s[lo] + (s[hi] - s[lo]) * (k - Double(lo))
    }

    private func buildSummary() -> String {
        let dur = CACurrentMediaTime() - startWall
        let avgReacq = reacquireTimes.isEmpty ? 0 : reacquireTimes.reduce(0, +) / Double(reacquireTimes.count)
        func dist(_ v: [Double]) -> String {
            v.isEmpty ? "n=0" : String(format: "n=%d p50=%.3f p90=%.3f p99=%.3f max=%.3f",
                                       v.count, pct(v, 50), pct(v, 90), pct(v, 99), v.max() ?? 0)
        }
        return """

        ════ REPLAY SUMMARY \(clip) ════
        frames=\(frames) duration=\(String(format: "%.1f", dur))s (最后帧号f=\(lastFrame) t=\(String(format: "%.1f", lastTime))s)
        STATE transitions: locked→searching=\(cLockedToSearching) searching→locked=\(cSearchingToLocked)(平均找回耗时\(String(format: "%.2f", avgReacq))s)
                           searching→lost=\(cSearchingToLost) unlocked→locked(初锁+重锁)=\(cUnlockedToLocked)
        REJECT total=\(cRejectTotal)(color崩=\(cRejectColor) pos崩=\(cRejectPos) size崩=\(cRejectSize),按最低分项归类)
        SOLO-PASS=\(cSoloPass)  SHADOW-FALLBACK=\(cShadow)(其中iou>0.5且候选1=\(cShadowRescue))
        锁定中心最大单帧跳变=\(String(format: "%.3f", maxCenterJump))(归一 nx/ny)  锁定持续最长段=\(String(format: "%.1f", longestLockedSpan))s
        ──── 刀1 影子门(shadowFrames=\(shadowFrames))────
        dPred |actual−pred|: \(dist(dPredList))
        dLast |actual−last|: \(dist(dLastList))   ← dPred 更小则「挂预测优于挂上一帧」成立
        R=.05  gateMiss=\(gateMiss[0])  disagree=\(disagree[0])
        R=.07  gateMiss=\(gateMiss[1])  disagree=\(disagree[1])
        R=.10  gateMiss=\(gateMiss[2])  disagree=\(disagree[2])
        detectorMiss(候选0,Q7 gap 输入,单列)=\(detectorMissCount)
        ──── ⑤ SEARCHING 找回失败(REACQ-FAIL)────
        reacqFail 总=\(reacqFail) | 色<0.50=\(reacqFailColor) margin<0.15=\(reacqFailMargin) 偏冻结>预算=\(reacqFailPos) detectorMiss(候选0)=\(reacqFailDetector)
        ════════════════════════════════

        """
    }

    private func resetCounters() {
        cLockedToSearching = 0; cSearchingToLocked = 0; reacquireTimes = []; cSearchingToLost = 0
        cUnlockedToLocked = 0; cRejectColor = 0; cRejectPos = 0; cRejectSize = 0; cRejectTotal = 0
        cSoloPass = 0; cShadow = 0; cShadowRescue = 0; frames = 0
        maxCenterJump = 0; prevLockedNx = nil; prevLockedNy = nil; lockedRunStart = nil; longestLockedSpan = 0
        dPredList = []; dLastList = []; gateMiss = [0,0,0]; disagree = [0,0,0]; detectorMissCount = 0; shadowFrames = 0
        reacqFail = 0; reacqFailColor = 0; reacqFailMargin = 0; reacqFailPos = 0; reacqFailDetector = 0
        lastFrame = 0; lastTime = 0; lineBuf = ""
    }
}
#endif
