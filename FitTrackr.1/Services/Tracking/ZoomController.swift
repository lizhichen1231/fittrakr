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
    /// 期望人占画面高度比例（显示画面里 measuredRatio × zoom 收敛到此值）
    var targetRatio: CGFloat = 0.55
    /// 进入迟滞：偏差进 ±5% 锁住（log(1.05)）
    var enterDeadband: CGFloat = CGFloat(log(1.05))
    /// 退出迟滞：偏差超 ±12% 才解锁跟随（log(1.12)）
    var exitDeadband: CGFloat = CGFloat(log(1.12))
    /// 单极点低通时间常数（秒）
    var tau: CGFloat = 0.40
    /// 每秒最多变化的 log-zoom（log(2.0) = 每秒最多变 2 倍），按秒、与帧率无关
    var maxLogZoomRate: CGFloat = CGFloat(log(2.0))
    /// 缩放下限
    var minZoom: CGFloat = 1.0
    /// 缩放上限（由 TrackingController 按预设同步 cfg.maxZoom）
    var maxZoom: CGFloat = 3.0
}

final class ZoomController {

    private(set) var config: ZoomConfig

    /// 唯一状态：log 域当前缩放（初始 0 → zoom = 1.0）
    private var currentLogZoom: CGFloat = 0
    /// 迟滞状态（true = 当前锁在死区内不动）
    private var holding: Bool = false

    /// 当前 zoom（= exp(currentLogZoom)）
    var zoom: CGFloat { exp(currentLogZoom) }
    /// 是否处于迟滞锁定（调试/状态展示用）
    var isHolding: Bool { holding }

    init(config: ZoomConfig = ZoomConfig()) {
        self.config = config
    }

    /// 预设切换时同步上限（fitness=3.0 / dance=1.5 …）
    func setMaxZoom(_ z: CGFloat) {
        config.maxZoom = max(config.minZoom, z)
    }

    /// 主路径：测量比 → zoom（开环前馈 + log 域迟滞 + 单极点平滑 + 按秒速率帽）
    @discardableResult
    func update(measuredRatio rawRatio: CGFloat, dt: CGFloat) -> CGFloat {
        // 1) 下限保护，避免除零 / log 爆炸
        let measuredRatio = max(rawRatio, 0.05)

        // 2) log 域目标（增益恒定，远近一致），并夹到 [log(min), log(max)]
        let lo = log(config.minZoom)
        let hi = log(config.maxZoom)
        let rawTargetLog = clampF(log(config.targetRatio) - log(measuredRatio), lo, hi)

        // 3) 迟滞：进 ±enter 锁住，超 ±exit 才解锁跟随
        let d = abs(rawTargetLog - currentLogZoom)
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
        next = clampF(next, currentLogZoom - maxStep, currentLogZoom + maxStep)

        // 6) 边界
        next = clampF(next, log(config.minZoom), log(config.maxZoom))

        currentLogZoom = next
        // 7)
        return exp(currentLogZoom)
    }

    private func clampF(_ v: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
        max(a, min(b, v))
    }
}
