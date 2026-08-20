import XCTest
import CoreGraphics
@testable import FitTrackr_1

/// 【方案B·刀2 单元测试】StateDebouncer/LensArbiter 基件验证(不接线,行为学断言)。
/// 夹具:Q4 真机 ramp 的 584 帧 zoom 序列(live_1785012016,判决那轮)。
/// 若 test target 因 Pods 链接暂不可跑,同款断言由独立脚本 scratchpad 验证(本仓先例,见 ZoomControllerTests 头注)。
final class StateDebouncerTests: XCTestCase {

    /// Q4 真机 zoom 序列(584 帧 @60fps,1.52→2.50 跨 S=2.0)
    static let q4Zooms: [CGFloat] = [1.52,1.53,1.53,1.53,1.53,1.53,1.53,1.54,1.54,1.54,1.54,1.54,1.54,1.55,1.55,1.55,1.55,1.55,1.55,1.56,1.56,1.56,1.56,1.56,1.56,1.57,1.57,1.57,1.57,1.57,1.57,1.58,1.58,1.58,1.58,1.58,1.58,1.59,1.59,1.59,1.59,1.59,1.59,1.60,1.60,1.60,1.60,1.60,1.60,1.61,1.61,1.61,1.61,1.61,1.61,1.62,1.62,1.62,1.62,1.62,1.62,1.63,1.63,1.63,1.63,1.63,1.64,1.64,1.64,1.64,1.64,1.64,1.64,1.65,1.65,1.65,1.65,1.65,1.65,1.66,1.66,1.66,1.66,1.66,1.66,1.67,1.67,1.67,1.67,1.67,1.67,1.68,1.68,1.68,1.68,1.68,1.68,1.69,1.69,1.69,1.69,1.69,1.69,1.70,1.70,1.70,1.70,1.70,1.70,1.71,1.71,1.71,1.71,1.71,1.71,1.72,1.72,1.72,1.72,1.72,1.72,1.73,1.73,1.73,1.73,1.74,1.74,1.74,1.74,1.74,1.74,1.74,1.75,1.75,1.75,1.75,1.75,1.75,1.76,1.76,1.76,1.76,1.76,1.76,1.77,1.77,1.77,1.77,1.77,1.77,1.78,1.78,1.78,1.78,1.78,1.78,1.79,1.79,1.79,1.79,1.79,1.79,1.80,1.80,1.80,1.80,1.80,1.80,1.81,1.81,1.81,1.81,1.81,1.81,1.82,1.82,1.82,1.82,1.82,1.82,1.83,1.83,1.83,1.83,1.83,1.84,1.84,1.84,1.84,1.84,1.84,1.84,1.85,1.85,1.85,1.85,1.85,1.85,1.86,1.86,1.86,1.86,1.86,1.86,1.87,1.87,1.87,1.87,1.87,1.87,1.88,1.88,1.88,1.88,1.88,1.88,1.89,1.89,1.89,1.89,1.89,1.89,1.90,1.90,1.90,1.90,1.90,1.90,1.91,1.91,1.91,1.91,1.91,1.91,1.92,1.92,1.92,1.92,1.92,1.92,1.93,1.93,1.93,1.93,1.93,1.93,1.94,1.94,1.94,1.94,1.94,1.94,1.95,1.95,1.95,1.95,1.95,1.95,1.96,1.96,1.96,1.96,1.96,1.96,1.97,1.97,1.97,1.97,1.97,1.97,1.98,1.98,1.98,1.98,1.98,1.98,1.99,1.99,1.99,1.99,1.99,1.99,2.00,2.00,2.00,2.00,2.00,2.00,2.01,2.01,2.01,2.01,2.01,2.01,2.02,2.02,2.02,2.02,2.02,2.02,2.03,2.03,2.03,2.03,2.03,2.04,2.04,2.04,2.04,2.04,2.04,2.04,2.05,2.05,2.05,2.05,2.05,2.05,2.06,2.06,2.06,2.06,2.06,2.06,2.07,2.07,2.07,2.07,2.07,2.07,2.08,2.08,2.08,2.08,2.08,2.08,2.09,2.09,2.09,2.09,2.09,2.09,2.10,2.10,2.10,2.10,2.10,2.10,2.11,2.11,2.11,2.11,2.11,2.11,2.12,2.12,2.12,2.12,2.12,2.12,2.13,2.13,2.13,2.13,2.13,2.14,2.14,2.14,2.14,2.14,2.14,2.14,2.15,2.15,2.15,2.15,2.15,2.15,2.16,2.16,2.16,2.16,2.16,2.16,2.17,2.17,2.17,2.17,2.17,2.17,2.18,2.18,2.18,2.18,2.18,2.18,2.19,2.19,2.19,2.19,2.19,2.19,2.20,2.20,2.20,2.20,2.20,2.20,2.21,2.21,2.21,2.21,2.21,2.21,2.22,2.22,2.22,2.22,2.22,2.22,2.23,2.23,2.23,2.23,2.23,2.23,2.24,2.24,2.24,2.24,2.24,2.24,2.25,2.25,2.25,2.25,2.25,2.25,2.26,2.26,2.26,2.26,2.26,2.26,2.27,2.27,2.27,2.27,2.27,2.27,2.28,2.28,2.28,2.28,2.28,2.28,2.29,2.29,2.29,2.29,2.29,2.29,2.30,2.30,2.30,2.30,2.30,2.30,2.31,2.31,2.31,2.31,2.31,2.32,2.32,2.32,2.32,2.32,2.32,2.33,2.33,2.33,2.33,2.33,2.34,2.34,2.34,2.34,2.34,2.34,2.34,2.35,2.35,2.35,2.35,2.35,2.35,2.36,2.36,2.36,2.36,2.36,2.37,2.37,2.37,2.37,2.37,2.37,2.38,2.38,2.38,2.38,2.38,2.38,2.38,2.39,2.39,2.39,2.39,2.39,2.40,2.40,2.40,2.40,2.40,2.40,2.41,2.41,2.41,2.41,2.41,2.41,2.42,2.42,2.42,2.42,2.42,2.42,2.43,2.43,2.43,2.43,2.43,2.43,2.43,2.44,2.44,2.44,2.44,2.44,2.45,2.45,2.45,2.45,2.45,2.45,2.46,2.46,2.46,2.46,2.46,2.46,2.47,2.47,2.47,2.47,2.47,2.47,2.48,2.48,2.48,2.48,2.48,2.48,2.49,2.49,2.49,2.49,2.49,2.49,2.50,2.50,2.50,2.50]

    private func makeInput(zoom: CGFloat, center: CGPoint? = .zero, vel: CGFloat = 0,
                           tag: String = "L", chain: Int = 999, tier1: Bool = true,
                           edgeGap: CGFloat? = nil) -> LensArbiterInput {
        LensArbiterInput(zoomReq: zoom, lockedCenter: center, centerVel: vel,
                         stateTag: tag, chainFrames: chain, tier1: tier1, deviceZoom: 1.0,
                         edgeGapBuffer: edgeGap)
    }

    /// 【贴边卡】驻留 1.5→2.5s 后,进 Wide 需 ≥150 帧;各用例统一用 180 帧(3s)
    private let dwellFrames = 180

    /// 【单人收口卡·三】前置门第四条=链长:chain<N 永挡 toWide;≥N 且驻留满放行恰一次
    func testChainGateBlocksAndAdmits() {
        let a = LensArbiter()
        var t = 0.0, blocked = 0, admitted = 0
        for _ in 0..<300 {                       // 5s,链长 89<90 → 永不进 Wide
            if a.decide(makeInput(zoom: 2.5, chain: 89), at: t).command != .none { blocked += 1 }
            t += 1.0 / 60.0
        }
        XCTAssertEqual(blocked, 0, "链长 89<90 应挡住 toWide")
        for _ in 0..<300 {                       // 链长达标 → 驻留 2.5s 后放行一次(5s 窗内)
            if a.decide(makeInput(zoom: 2.5, chain: 90), at: t).command != .none { admitted += 1 }
            t += 1.0 / 60.0
        }
        XCTAssertEqual(admitted, 1, "链长≥90 且驻留满应放行恰一次")
    }

    /// ① Q4 584 帧回放:跨 S 窗内指令 ≤1;死区内零指令;唯一指令是 toWide 且发生在死区上界之外
    func testQ4RampSingleCommandDeadzoneSilence() {
        let a = LensArbiter()
        var commands: [(Int, LensCommand, CGFloat, Bool)] = []
        for (i, z) in Self.q4Zooms.enumerated() {
            let out = a.decide(makeInput(zoom: z), at: Double(i) / 60.0)
            if out.command != .none { commands.append((i, out.command, z, out.inDeadzone)) }
        }
        XCTAssertEqual(commands.count, 1, "整段 ramp 应恰好 1 次指令,实得 \(commands)")
        XCTAssertEqual(commands.first?.1, .toWide)
        XCTAssertFalse(commands.first?.3 ?? true, "指令不得发生在死区内")
        XCTAssertGreaterThan(commands.first?.2 ?? 0, 2.2, "指令应在死区上界之外(驻留后)")
    }

    /// ② 抖动用例:1.95–2.05 高频往返(死区内)→ 零指令;1.85/2.25 隔帧横跳(破坏驻留连续性)→ 零指令
    func testJitterNoChatter() {
        let a = LensArbiter()
        var t = 0.0, cmds = 0
        for i in 0..<600 {                      // 10s 死区内抖
            let z: CGFloat = (i % 2 == 0) ? 1.95 : 2.05
            if a.decide(makeInput(zoom: z), at: t).command != .none { cmds += 1 }
            t += 1.0 / 60.0
        }
        XCTAssertEqual(cmds, 0, "死区内高频抖不得出指令")
        for i in 0..<600 {                      // 10s 跨带横跳:驻留连续制应清零
            let z: CGFloat = (i % 2 == 0) ? 1.85 : 2.25
            if a.decide(makeInput(zoom: z), at: t).command != .none { cmds += 1 }
            t += 1.0 / 60.0
        }
        XCTAssertEqual(cmds, 0, "跨带隔帧横跳破坏驻留连续性,不得出指令")
    }

    /// ③ 出/回门线迟滞:方向正确且不对称(0.15<|c|<0.20 的中间带两个方向都不动作 = 未退化成同一条线)
    func testHysteresisAsymmetry() {
        let a = LensArbiter()
        var t = 0.0
        func run(_ n: Int, zoom: CGFloat, cx: CGFloat, vel: CGFloat = 0) -> [LensCommand] {
            var out: [LensCommand] = []
            for _ in 0..<n {
                let o = a.decide(makeInput(zoom: zoom, center: CGPoint(x: cx, y: 0), vel: vel), at: t)
                if o.command != .none { out.append(o.command) }
                t += 1.0 / 60.0
            }
            return out
        }
        // 进 Wide:中心 0、zoom 2.4、静止,驻留 2.5s 后应切【贴边卡·三.2 提驻留后 120→180 帧】
        XCTAssertEqual(run(dwellFrames, zoom: 2.4, cx: 0), [.toWide], "前置门满足+驻留 2.5s → 恰一次 toWide")
        // 中间带(0.17):在 Wide 上不算出门 → 不动作
        XCTAssertEqual(run(120, zoom: 2.4, cx: 0.17), [], "0.15<|c|<0.20 在门内不算出——迟滞下沿")
        // 越出门线(0.21):force 即刻回 UW
        let exit = run(3, zoom: 2.4, cx: 0.21)
        XCTAssertEqual(exit, [.toUW], "越 ±0.20 出门线应即刻 force 回 UW")
        // 中间带(0.17):在 UW 上不算进门 → 前置门不开(若与出门线退化成同一条线,这里会重进)
        XCTAssertEqual(run(240, zoom: 2.4, cx: 0.17), [], "0.15<|c|<0.20 在门外不算进——迟滞上沿,双线不重合")
        // 回门线内(0.10):冷却 5s 内不得重进;冷却过后 + 驻留 2.5s → 重进
        let reenter = run(60 * 8, zoom: 2.4, cx: 0.10)
        XCTAssertEqual(reenter, [.toWide], "冷却+驻留后恰一次重进")
    }

    /// ④ 冷却单边(§3):切向 UW 后 5s 内锁切向窄;切向 UW 方向永不被锁(出门 force 在刚切完 Wide 时也立即生效)
    func testCooldownSingleDirection() {
        let a = LensArbiter()
        var t = 0.0
        func step(zoom: CGFloat, cx: CGFloat) -> LensCommand {
            let o = a.decide(makeInput(zoom: zoom, center: CGPoint(x: cx, y: 0)), at: t)
            t += 1.0 / 60.0
            return o.command
        }
        // 进 Wide(toWide 不写冷却)【贴边卡·三.2 驻留 2.5s → 180 帧】
        var got: [LensCommand] = []
        for _ in 0..<dwellFrames { let c = step(zoom: 2.4, cx: 0); if c != .none { got.append(c) } }
        XCTAssertEqual(got, [.toWide])
        // 刚切完立刻越线:force 回 UW 必须即刻生效(toWide 未写冷却 → 切向广不被锁)
        XCTAssertEqual(step(zoom: 2.4, cx: 0.30), .toUW, "切向广永不被冷却锁住")
        // 随后 5s 内条件再好也不得重进(冷却锁切向窄)
        var reentry: [LensCommand] = []
        for _ in 0..<(60 * 4) { let c = step(zoom: 2.4, cx: 0); if c != .none { reentry.append(c) } }
        XCTAssertEqual(reentry, [], "冷却 5s 内禁止切向窄")
    }

    /// ⑥【公式修正卡】贴S悬停(死区下界=S 后的新风险面):恰一次出,此后静默
    func testHoverAtSNoChatter() {
        let a = LensArbiter()
        var t = 0.0, got: [LensCommand] = []
        for _ in 0..<dwellFrames { let c = a.decide(makeInput(zoom: 2.4), at: t).command; if c != .none { got.append(c) }; t += 1.0/60.0 }
        for i in 0..<600 {
            let z: CGFloat = (i % 2 == 0) ? 1.98 : 2.05
            let c = a.decide(makeInput(zoom: z), at: t).command; if c != .none { got.append(c) }; t += 1.0/60.0
        }
        XCTAssertEqual(got, [.toWide, .toUW], "贴S悬停应恰一次出 Wide,此后静默")
    }

    /// ⑦【公式修正卡】锯齿 1.95↔2.30(周期6s×4):zoom-exit 写冷却后频率被封顶(4 次而非 8 次)
    func testSawtoothCooldownCaps() {
        let a = LensArbiter()
        var t = 0.0, got: [LensCommand] = []
        for _ in 0..<4 {
            for _ in 0..<180 { let c = a.decide(makeInput(zoom: 2.30), at: t).command; if c != .none { got.append(c) }; t += 1.0/60.0 }
            for _ in 0..<180 { let c = a.decide(makeInput(zoom: 1.95), at: t).command; if c != .none { got.append(c) }; t += 1.0/60.0 }
        }
        XCTAssertEqual(got, [.toWide, .toUW, .toWide, .toUW], "24s 锯齿应仅 4 次迁移(冷却封顶)")
    }

    /// ⑧【贴边卡·一/二】主摄段贴边驻留满 → force UW;★stateTag=L/S 均触发(解闸门核心断言)。
    /// 中心居中(cheb=0)→ 仲裁1/2 均不可能触发,指令只能来自贴边通道。
    func testEdgeChannelFiresInLockedAndSearching() {
        for tag in ["L", "S"] {
            let a = LensArbiter()
            var t = 0.0, got: [LensCommand] = []
            for _ in 0..<dwellFrames { let c = a.decide(makeInput(zoom: 2.4), at: t).command; if c != .none { got.append(c) }; t += 1.0/60.0 }
            XCTAssertEqual(got, [.toWide], "前置:先进 Wide")
            // 贴边(gap 0.02 ≤ 带 0.03),驻留 0.2s(12帧)后 force;给 30 帧余量
            for _ in 0..<30 {
                let c = a.decide(makeInput(zoom: 2.4, center: .zero, tag: tag, edgeGap: 0.02), at: t).command
                if c != .none { got.append(c) }; t += 1.0/60.0
            }
            XCTAssertEqual(got, [.toWide, .toUW], "tag=\(tag) 贴边驻留满应 force 回 UW(不依赖 stateTag==L)")
        }
    }

    /// ⑨【贴边卡·三.3】miss 保持:贴边 1 帧后全 miss,保持窗(0.5s)内驻留续计仍触发
    func testEdgeMissHoldKeepsDwell() {
        let a = LensArbiter()
        var t = 0.0, got: [LensCommand] = []
        for _ in 0..<dwellFrames { let c = a.decide(makeInput(zoom: 2.4), at: t).command; if c != .none { got.append(c) }; t += 1.0/60.0 }
        _ = a.decide(makeInput(zoom: 2.4, edgeGap: 0.01), at: t); t += 1.0/60.0   // 1 帧贴边后即 miss
        for _ in 0..<24 {                                                          // 0.4s 全 miss(≤0.5s 保持)
            let c = a.decide(makeInput(zoom: 2.4, tag: "S", edgeGap: nil), at: t).command
            if c != .none { got.append(c) }; t += 1.0/60.0
        }
        XCTAssertEqual(got, [.toWide, .toUW], "贴边后立刻 miss:保持窗内驻留续计,0.2s 时应触发")
    }

    /// ⑩【贴边卡】驻留连续制 + 段界:锯齿贴边(每段 0.05s<0.2s)不累计;UW 段贴边输入零触发;
    /// miss 超 0.5s 保持窗后不得再凭旧贴边状态触发
    func testEdgeDwellContinuityUWSilenceAndHoldExpiry() {
        // UW 段:gap=0 也不得出指令(prev==.uw 无"回"可回)
        let a = LensArbiter()
        var t = 0.0
        for _ in 0..<300 {
            XCTAssertEqual(a.decide(makeInput(zoom: 1.5, edgeGap: 0.0), at: t).command, .none, "UW 段贴边零触发")
            t += 1.0/60.0
        }
        // Wide 段锯齿贴边:3帧触/3帧离 → 驻留清零,不得触发
        let b = LensArbiter()
        var got: [LensCommand] = []
        t = 0
        for _ in 0..<dwellFrames { let c = b.decide(makeInput(zoom: 2.4), at: t).command; if c != .none { got.append(c) }; t += 1.0/60.0 }
        for i in 0..<120 {
            let gap: CGFloat = (i / 3) % 2 == 0 ? 0.01 : 0.20
            let c = b.decide(makeInput(zoom: 2.4, edgeGap: gap), at: t).command
            if c != .none { got.append(c) }; t += 1.0/60.0
        }
        XCTAssertEqual(got, [.toWide], "锯齿贴边(每段 0.05s)驻留连续制应清零,不得触发")
        // 保持窗超时:最后有效框贴边,随后 miss 0.6s(>0.5s)→ 贴边状态已清,
        // 再连续 miss 也不得触发(交还 SEARCHING 通路)。构造:贴边 1 帧 + 驻留改不可能满足前先断开——
        // 用 exitDwell 默认 0.2s,故这里以「贴边 1 帧→非贴边 1 帧→miss」确保驻留未攒满即断
        let c3 = LensArbiter()
        var got3: [LensCommand] = []
        t = 0
        for _ in 0..<dwellFrames { let c = c3.decide(makeInput(zoom: 2.4), at: t).command; if c != .none { got3.append(c) }; t += 1.0/60.0 }
        _ = c3.decide(makeInput(zoom: 2.4, edgeGap: 0.01), at: t); t += 1.0/60.0   // 贴边 1 帧
        _ = c3.decide(makeInput(zoom: 2.4, edgeGap: 0.20), at: t); t += 1.0/60.0   // 离开带内 → 驻留清零、held=false
        for _ in 0..<60 {                                                           // 1s 全 miss:held=false 保持无从触发
            let c = c3.decide(makeInput(zoom: 2.4, tag: "S", edgeGap: nil), at: t).command
            if c != .none { got3.append(c) }; t += 1.0/60.0
        }
        XCTAssertEqual(got3, [.toWide], "最后有效框非贴边 → miss 期不得凭更早的贴边状态触发")
    }

    /// ⑤ Tier 0 旁路:整套策略不产出任何指令
    func testTier0Bypass() {
        let a = LensArbiter()
        for i in 0..<300 {
            let o = a.decide(makeInput(zoom: 2.4, tier1: false), at: Double(i) / 60.0)
            XCTAssertEqual(o.command, .none)
            XCTAssertEqual(o.lens, .uw)
        }
    }
}
