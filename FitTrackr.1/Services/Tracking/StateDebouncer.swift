import Foundation
import CoreGraphics

// ═══════════════════════════════════════════════════════════════════════════
// 【方案B·刀2 基件】本文件只造件、不接线(刀3 才接)。build 后 app 行为与刀1 逐帧等同。
// 依据:Docs/design-lens-switching.md v1(FROZEN)——§3 参数表 / §4 仲裁表 / §9 StateDebouncer。
// ═══════════════════════════════════════════════════════════════════════════

/// 统一状态防抖原语(设计稿 §9 出生,镜头切换是第一个用户)。
/// 边界钉死:组件只管时序(多久能变、变完锁多久),不管阈值(什么条件算要变)——
/// 双阈值/死区是领域知识,留在业务层(LensArbiter)。防演化成上帝类,违反单一权威铁律。
/// 冷却单边语义(§3「仅锁切向窄」)由业务层通过 cooldownAfter 逐次表达:组件不感知方向。
final class StateDebouncer<State: Equatable> {
    let name: String
    private(set) var state: State
    private let dwellSec: TimeInterval
    private let defaultCooldownSec: TimeInterval
    private var dwellTarget: State?
    private var dwellSince: TimeInterval = 0
    private var cooldownUntil: TimeInterval = -.infinity

    init(name: String, initial: State, dwellSec: TimeInterval, cooldownSec: TimeInterval) {
        self.name = name
        self.state = initial
        self.dwellSec = dwellSec
        self.defaultCooldownSec = cooldownSec
    }

    /// 常规通道:每帧喂「想要的状态」。目标≠当前 且 连续保持 dwellSec 才迁移(驻留连续制——
    /// 喂回当前值或换目标即清零)。冷却期内一律不生效,驻留也不累计(冷却结束后重新驻留)。
    /// cooldownAfter:本次迁移完成后写入的冷却时长(nil=组件默认;0=不锁)。
    @discardableResult
    func request(_ target: State, at now: TimeInterval, cooldownAfter: TimeInterval? = nil) -> State {
        guard now >= cooldownUntil else { dwellTarget = nil; return state }
        guard target != state else { dwellTarget = nil; return state }
        if dwellTarget != target { dwellTarget = target; dwellSince = now; return state }
        guard now - dwellSince >= dwellSec else { return state }
        transition(to: target, at: now, via: "dwell", cooldownAfter: cooldownAfter)
        return state
    }

    /// 紧急通道:跳过驻留,立即迁移,写入冷却(「紧急只对第一次成立」的机制化)。
    /// 冷却期内同样不生效(§9)——业务层靠「切向主摄的迁移不写冷却」保证需要 force 的方向永不被锁。
    func force(_ target: State, at now: TimeInterval, cooldownAfter: TimeInterval? = nil) {
        guard now >= cooldownUntil else { return }
        guard target != state else { return }
        transition(to: target, at: now, via: "force", cooldownAfter: cooldownAfter)
    }

    func cooldownRemaining(at now: TimeInterval) -> TimeInterval { max(0, cooldownUntil - now) }

    /// 硬复位(刀4:影子开关回拨 ON 时回滚用)——状态/驻留/冷却全清,回到指定初态
    func hardReset(to s: State) {
        print("⏲ DEBOUNCE \(name) hardReset → \(s)")
        state = s; dwellTarget = nil; cooldownUntil = -.infinity
    }

    private func transition(to target: State, at now: TimeInterval, via: String, cooldownAfter: TimeInterval?) {
        let cd = cooldownAfter ?? defaultCooldownSec
        print("⏲ DEBOUNCE \(name) \(state)→\(target) via=\(via) cd=\(String(format: "%.1f", cd))")
        state = target
        dwellTarget = nil
        cooldownUntil = now + cd
    }
}

// ═══════════════════════════════════════════════════════════════════════════

/// 物理镜头档位(dualWide 虚拟设备的两个组成)
enum PhysicalLens: String, Equatable { case uw = "UW", wide = "Wide" }

/// 跨S指令(刀4 接线后驱动 device.videoZoomFactor 跨 S;刀3 前仅产出不执行)
enum LensCommand: Equatable { case none, toWide, toUW }

struct LensArbiterInput {
    var zoomReq: CGFloat          // 应用层目标 zoom(ZoomManager 输出,wide 系总倍率)
    var lockedCenter: CGPoint?    // 锁定框中心,wide 系(原点=画面中心,半宽 ±0.5;§3 钉死:触发量是它,非 crop 框非 zoom)
    var centerVel: CGFloat        // 中心速度(wide 系 /s;前置门速度否决用)
    var stateTag: String          // 三态机 "L"=locked "S"=searching "X"=lost "U"=unlocked
    var tier1: Bool               // 能力分层(刀1):false = 整套策略旁路(§0 非目标/§2 降级)
    var deviceZoom: CGFloat       // 当前 device.videoZoomFactor(刀4 前恒 1.0,透传记录用)
}

struct LensArbiterOutput: Equatable {
    var command: LensCommand      // ① 跨S指令
    var inDeadzone: Bool          // ② zoom 是否在死区([S, 2.2])内
    var anchor: Bool              // ③ 指令发出帧锚点(=本帧有指令;刀4 事件驱动豁免窗的起窗信号)
    var lens: PhysicalLens        // 决策后的镜头意图(刀3 影子模式仅日志/HUD,不驱动设备)
    var reason: String = ""       // 刀3 影子日志:本帧走的是仲裁表哪条线(指令帧必非空)
}

/// 镜头仲裁(设计稿 §4 五层,高压低)+ 三层防抖(§3:空间迟滞 / 驻留+速度否决 / 冷却单边)。
/// 纯逻辑零 AVFoundation,时间由调用方注入(可测)。
final class LensArbiter {
    struct Params {
        var S: CGFloat = 2.0               // 切换点(实测转正;实机以 switchOverZoomFactors 读数注入)
        // 【公式修正卡·处置(a)】死区下界 1.9→2.0(=S):Wide 档 Z_digital = Z_total/S,
        // 若允许 Z_total<S 仍留 Wide,则 Z_digital<1 = 请求比 Wide 成分镜头更宽的视场——
        // 边缘像素物理上不存在(上采样解分辨率不解视场),且 dualWide 设 videoZoomFactor<2.0
        // 会自动切回 UW,无法用设备端补偿;构图偏移还违反不变量 I。
        // 下界=S 后 Z_digital ≥1 恒成立;迟滞带整体移到 S 上侧 [2.0, 2.2](宽 0.2 仍在)。
        var deadzoneLo: CGFloat = 2.0      // 死区下界 = S(Wide 档零下探)
        var deadzoneHi: CGFloat = 2.2      // 死区上界 ※
        var exitLine: CGFloat = 0.20       // 出门线(主摄边界 ±0.25 的 80%)※
        var entryLine: CGFloat = 0.15      // 回门线(60%)※
        var velMax: CGFloat = 0.08         // 前置门速度否决 ※
        var dwellSec: TimeInterval = 1.5   // 驻留(连续制)
        var cooldownSec: TimeInterval = 5.0 // 冷却(单边:仅写在切向 UW 的 force 上)※
        var safeZone: CGFloat = 0.20       // 仲裁1「丢失位置在安全区外」阈值(OPEN-2:=出门线)
    }
    let p: Params
    private let debouncer: StateDebouncer<PhysicalLens>
    private var lastKnownCenter: CGPoint?   // §5:SEARCHING 判据用丢失前最后锁定位置

    init(params: Params = Params()) {
        p = params
        debouncer = StateDebouncer(name: "lens", initial: .uw, dwellSec: params.dwellSec, cooldownSec: params.cooldownSec)
    }

    var lens: PhysicalLens { debouncer.state }

    /// 每帧一次。输出跨S指令/死区标志/锚点(§4 仲裁表实现;层序即优先级)。
    func decide(_ input: LensArbiterInput, at now: TimeInterval) -> LensArbiterOutput {
        let deadzone = input.zoomReq >= p.deadzoneLo && input.zoomReq <= p.deadzoneHi
        // Tier 0:整套策略旁路(§2 降级收敛到现状 = 恒 UW)
        guard input.tier1 else {
            return LensArbiterOutput(command: .none, inDeadzone: deadzone, anchor: false, lens: .uw)
        }
        if let c = input.lockedCenter { lastKnownCenter = c }
        // 出门/回门线用切比雪夫距离(主摄 FOV 是中央 50%×50% 的方框,两轴同界)
        func cheb(_ c: CGPoint) -> CGFloat { max(abs(c.x), abs(c.y)) }
        let prev = debouncer.state

        var reason = ""
        if (input.stateTag == "S" || input.stateTag == "X"),
           prev == .wide, let c = lastKnownCenter, cheb(c) > p.safeZone {
            // 仲裁1:SEARCHING/LOST 且丢失位置在安全区外 → 强制 UW 即刻(找人必须全视野);动作写冷却
            debouncer.force(.uw, at: now, cooldownAfter: p.cooldownSec)
            reason = "仲裁1:SEARCHING/LOST 安全区外(|c|>\(p.safeZone))"
        } else if input.stateTag == "L", prev == .wide,
                  let c = input.lockedCenter, cheb(c) > p.exitLine {
            // 仲裁2:通道二 force(锁定中心越出门线)→ 切 UW 即刻;动作写冷却(§3 单边:只锁切向窄)
            debouncer.force(.uw, at: now, cooldownAfter: p.cooldownSec)
            reason = "仲裁2:出门线force(|c|>\(p.exitLine))"
        } else if prev == .wide, input.zoomReq < p.deadzoneLo {
            // 通道一 zoom 下穿 S → 回 UW(迟滞带全在 S 上侧后,下穿即出;无驻留)。
            // 【公式修正卡】改写冷却:下界提到 S 后,zoom 轴贴 S 往返成为现实场景,
            // 第三层(冷却单边)必须把 zoom 轴振荡也封顶——写 5s,仍只锁切向窄,切向广不受限。
            debouncer.force(.uw, at: now, cooldownAfter: p.cooldownSec)
            reason = "通道一:zoom下穿S(\(p.deadzoneLo))回UW"
        } else if input.stateTag == "L",
                  let c = input.lockedCenter, cheb(c) <= p.entryLine,
                  input.centerVel < p.velMax, input.zoomReq > p.deadzoneHi {
            // 仲裁4:通道一 request——前置门三条件(回门线内+速度+zoom 需求)同时且连续 1.5s(驻留连续制,组件管);
            // 冷却期内组件自动不生效(仲裁3);切向主摄的迁移不写冷却(单边)
            debouncer.request(.wide, at: now, cooldownAfter: 0)
            reason = "通道一:前置门驻留成立进Wide"
        } else {
            // 仲裁5:维持现状;喂回当前值 = 驻留清零(条件中断即清零)
            debouncer.request(prev, at: now)
        }

        let lens = debouncer.state
        let command: LensCommand = (lens == prev) ? .none : (lens == .wide ? .toWide : .toUW)
        return LensArbiterOutput(command: command, inDeadzone: deadzone, anchor: command != .none,
                                 lens: lens, reason: command != .none ? reason : "")
    }

    /// HUD 用:冷却剩余
    func cooldownRemaining(at now: TimeInterval) -> TimeInterval { debouncer.cooldownRemaining(at: now) }

    /// 刀4:影子开关回拨 ON 的回滚——镜头意图回 UW,防抖状态全清
    func reset() { debouncer.hardReset(to: .uw); lastKnownCenter = nil }
}
