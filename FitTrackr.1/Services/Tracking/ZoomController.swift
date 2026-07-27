import CoreGraphics

// MARK: - 变焦控制律（单一、原理正确、可推理、可单元测试）
//
// 取代历史上层层叠加、互相打架的机制（卡尔曼 / EMA / 临界阻尼弹簧 / 帧限幅 / PD / 面积分割 / 7 档离散）。
// 纯逻辑：不依赖 AVFoundation / Vision / CoreImage，只吃数值、吐数值。
//
// 核心数学（开环前馈——检测跑在全画幅，measuredRatio 不随 zoom 变）：
//   显示画面里人占高度 = measuredRatio × zoom；要让它等于 targetRatio，则 targetZoom = targetRatio / measuredRatio。
//   全部在 log 空间算：targetLogZoom = log(targetRatio) − log(measuredRatio)。增益恒定，远近一致。
//
// 唯一积分点是 settle(...)；对外不暴露可被覆写的 position/velocity，从结构上杜绝“在外部覆写打架”。

struct ZoomConfig {
    /// 期望测量量占画面高度比例（显示画面里 measuredRatio × zoom 收敛到此值）
    /// 测量量已从"全身框高"换成"躯干高"（肩中点→髋中点）——躯干约占全身 1/3~1/2，故按新尺度重标。
    /// 实测 torsoToBoxHeight≈0.280:0.28 目标→全身框≈100%(零余量,易裁头/脚);
    /// 改 0.22→全身框≈0.22/0.280≈79%(上下各留 ~10% 余量)。此时 targetBodyFraction=0.90 退回真·安全网。
    var targetRatio: CGFloat = 0.22
    /// 进入迟滞：偏差进 ±2% 锁住（log(1.02)）—— 激进档：更早起跟
    /// [临时验证] 死区设到极小，验证去死区后 zoom 是否连续跟随、不再死锁
    var enterDeadband: CGFloat = CGFloat(log(1.005))
    /// 退出迟滞：偏差超 ±5% 才解锁跟随（log(1.05)）—— 激进档：死区收窄，不锁太死
    /// [临时验证] 死区设到极小
    var exitDeadband: CGFloat = CGFloat(log(1.005))
    /// 单极点低通时间常数（秒）—— 激进档：更跟手
    var tau: CGFloat = 0.22
    /// 每秒最多变化的 log-zoom，按秒、与帧率无关。
    /// log(1.8)→log(1.4)(每秒最多变 1.4 倍):压 4.5s 那种肉眼可觉的快速变焦;太钝再加重 velTau。
    var maxLogZoomRate: CGFloat = CGFloat(log(1.4))
    /// 速度低通时间常数(秒):对 zoom「速度」做一阶低通,使加/减速指数缓变(起停都圆、无拐角)。
    /// 越大越圆越慢,越小越脆。起手 0.20。注意:平滑只靠它——别拿 tau 做平滑(tau 是位置响应,
    /// 调大 tau = 位置滞后发肉)。
    var velTau: CGFloat = 0.20
    /// 缩放下限
    var minZoom: CGFloat = 1.0
    /// 缩放上限（由 TrackingController 按预设同步 cfg.maxZoom；激进档 5.0，注意数字裁剪画质）
    var maxZoom: CGFloat = 5.0
}

final class ZoomController {

    private(set) var config: ZoomConfig

    /// 唯一状态：log 域当前缩放（初始 0 → zoom = 1.0）
    private var currentLogZoom: CGFloat = 0
    /// 迟滞状态（true = 当前锁在死区内不动）
    private var holding: Bool = false
    /// 速度低通状态:平滑后的 log-zoom 速度（smoothedVel，log/秒），逐帧持续
    private var prevLogVel: CGFloat = 0

    /// 当前 zoom（= exp(currentLogZoom)）
    var zoom: CGFloat { exp(currentLogZoom) }
    /// 是否处于迟滞锁定（调试/状态展示用）
    var isHolding: Bool { holding }

    #if DEBUG
    // 【平滑度收口卡·一】尺度链埋点(只采不馈,TC 🌀 行逐帧读)
    var dbgSlewHit = false            // 本帧速率帽是否真削步
    var dbgLpStepLog: CGFloat = 0     // 限速前低通一步(log)
    var dbgMaxStepLog: CGFloat = 0    // 帽值(log)
    var dbgHoldGapLog: CGFloat = 0    // 迟滞判据 |target−current|(log,进/出死区的那个 d)
    #endif

    init(config: ZoomConfig = ZoomConfig()) {
        self.config = config
    }

    /// 预设切换时同步上限（fitness=3.0 / dance=1.5 …）
    func setMaxZoom(_ z: CGFloat) {
        config.maxZoom = max(config.minZoom, z)
    }

    /// 主路径：测量比 → zoom（开环前馈 + log 域迟滞 + 单极点平滑 + 按秒速率帽）
    @discardableResult
    func update(measuredRatio rawRatio: CGFloat, dt: CGFloat, bodyMaxLogZoom: CGFloat? = nil) -> CGFloat {
        // 1) 下限保护，避免除零 / log 爆炸
        let measuredRatio = max(rawRatio, 0.05)

        // 2) log 域目标（增益恒定，远近一致），并夹到 [log(min), log(max)]
        let lo = log(config.minZoom)
        let hi = log(config.maxZoom)
        var rawTargetLog = clampF(log(config.targetRatio) - log(measuredRatio), lo, hi)

        // 改动2:不出框上钳——只往外拉(降 zoom),不抬下限,且不低于 minZoom。
        // bodyMaxLogZoom = log(targetBodyFraction / 全身框高比),由 TrackingController 在完整全身框时传入。
        if let cap = bodyMaxLogZoom {
            rawTargetLog = max(min(rawTargetLog, cap), lo)
        }

        // 3) 迟滞：进 ±enter 锁住，超 ±exit 才解锁跟随
        let d = abs(rawTargetLog - currentLogZoom)
        #if DEBUG
        dbgHoldGapLog = d
        #endif
        let goalLog: CGFloat
        if holding {
            if d >= config.exitDeadband {
                holding = false
                goalLog = rawTargetLog          // 解锁，跟随
            } else {
                goalLog = currentLogZoom         // 锁住不动
            }
        } else {
            if d < config.enterDeadband {
                holding = true
                goalLog = currentLogZoom         // 进入死区，锁住
            } else {
                goalLog = rawTargetLog           // 跟随
            }
        }

        // 4)~7) 单极点平滑 + 按秒速率帽 + 边界
        return settle(towardLog: goalLog, dt: dt)
    }

    /// 显式目标路径：无人回 1.0 / 原地锁定 hold / 智能模式景别指令。
    /// 跳过测量比与迟滞，但仍走同一平滑器 + 同一按秒速率帽（保持“单一控制器”）。
    @discardableResult
    func command(towardZoom z: CGFloat, dt: CGFloat) -> CGFloat {
        let lo = log(config.minZoom)
        let hi = log(config.maxZoom)
        let goalLog = clampF(log(max(z, config.minZoom)), lo, hi)
        holding = false
        return settle(towardLog: goalLog, dt: dt)
    }

    /// 重置到指定 zoom（默认 1.0）
    func reset(toZoom z: CGFloat = 1.0) {
        currentLogZoom = log(max(z, config.minZoom))
        holding = false
        prevLogVel = 0
    }

    // MARK: - 唯一积分点：单极点低通 + 按秒速率帽 + 边界
    @discardableResult
    private func settle(towardLog goalLog: CGFloat, dt: CGFloat) -> CGFloat {
        let dtc = max(dt, 1.0 / 120.0)                       // 防 dt=0 / 异常大

        // 4) 单极点低通：alpha = 1 − exp(−dt/tau)（按时间常数，帧率无关）
        let alpha = 1 - exp(-dtc / config.tau)
        var next = currentLogZoom + alpha * (goalLog - currentLogZoom)

        // 5) 按秒速率安全帽（log 域）
        let maxStep = config.maxLogZoomRate * dtc
        #if DEBUG
        let lpStep = next - currentLogZoom
        dbgLpStepLog = lpStep; dbgMaxStepLog = maxStep
        dbgSlewHit = abs(lpStep) > maxStep + 1e-9
        if dbgSlewHit {   // 速率帽真正削到 zoom
            print(String(format: "🚦 SLEW HIT zoom Δlog=%.4f maxStep=%.4f", lpStep, maxStep))
        }
        #endif
        next = clampF(next, currentLogZoom - maxStep, currentLogZoom + maxStep)

        // 5.5) 速度低通(velTau):对「速度」做一阶低通 → 速度指数缓变,起停都圆、无拐角
        //      (取代上一版硬 slew-rate;最外层,与软锁定/离群续走兼容)。smoothedVel 复用 prevLogVel。
        let desiredVel = (next - currentLogZoom) / dtc
        let aVel = 1 - exp(-dtc / max(config.velTau, 1e-3))
        prevLogVel = prevLogVel + (desiredVel - prevLogVel) * aVel
        next = currentLogZoom + prevLogVel * dtc

        // 6) 边界
        next = clampF(next, log(config.minZoom), log(config.maxZoom))

        // 存本帧实际速度给下一帧(用边界后的真实位移,避免在 zoom 上下限处速度 windup)
        prevLogVel = (next - currentLogZoom) / dtc
        currentLogZoom = next
        // 7)
        return exp(currentLogZoom)
    }

    private func clampF(_ v: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
        max(a, min(b, v))
    }
}
