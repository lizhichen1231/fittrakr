// FakePersonInjector.swift
// 卡2 验证用:在「检测吐出人列表」之后注入一个假路人(只在检测/匹配层,不画像素),
// 让你独自能验「路人横穿抢不抢锁」——即现有 isTarget 颜色校验是否真生效。
// 整文件 #if DEBUG:Release 不编译、不存在。

#if DEBUG
import CoreGraphics

final class FakePersonInjector {
    static let shared = FakePersonInjector()

    // 总开关:由 CameraViewModel 绑 showDebugOverlay(眼睛开关)运行时切。默认关。
    var enabled = false

    // ===== 可调常量(改了重 build 切场景)=====
    enum ColorMode { case different, sameAsTarget }
    var colorMode: ColorMode = .different   // 场景1/2 异色;场景3 撞衫=.sameAsTarget
    var sizeRatio: CGFloat = 1.0            // 相对主角框大小;>1 比主角大(场景1变体)
    var crossSpeed: CGFloat = 0.010        // 每帧水平移动(归一化画面宽)
    var startXNorm: CGFloat = -0.10        // 起始 x(归一化,可负=画面外)
    var endXNorm: CGFloat = 1.10           // 终止 x;过界回到 start 循环横穿
    var yNorm: CGFloat = 0.50              // 垂直中心(归一化)
    var overlapStopOnTarget = false        // true:滑到主角 x 处停下重叠(场景2 遮挡换人预演)
    var conf: Float = 0.9                  // 模拟清晰路人(仅语义/日志;isTarget 不按 conf 评分)

    // ===== D-场景:确诊「选择判据」用 —— 两个固定不动的假人 A/B,精确控大小/位置/conf =====
    // 改 dScenario 常量重 build 切场景;开「假人」开关激活。每帧打 LOCK 决策(注入候选,不改选择比较器)。
    enum DScenario { case off, d1, d2, d3 }
    var dScenario: DScenario = .off

    struct DFake { let label: String; let box: CGRect; let conf: Float }

    /// 按 dScenario 返回两个固定假人(wide 传感器坐标)。areaFrac=占全帧面积比例,aspect=高/宽(1.8 仿人)。
    func dFakes(sensorSize: CGSize) -> [DFake] {
        func box(areaFrac: CGFloat, cxN: CGFloat, cyN: CGFloat, aspect: CGFloat = 1.8) -> CGRect {
            let area = areaFrac * sensorSize.width * sensorSize.height
            let h = sqrt(area * aspect), w = h / aspect
            return CGRect(x: cxN * sensorSize.width - w/2, y: cyN * sensorSize.height - h/2, width: w, height: h)
        }
        switch dScenario {
        case .off:
            return []
        case .d1:   // 纯大小:A 大(0.100)居中偏左、B 小(0.025=A的1/4)居中偏右;conf 同。预期按面积→A
            return [DFake(label: "A大", box: box(areaFrac: 0.100, cxN: 0.35, cyN: 0.50), conf: 0.90),
                    DFake(label: "B小", box: box(areaFrac: 0.025, cxN: 0.65, cyN: 0.50), conf: 0.90)]
        case .d2:   // 纯位置:同大小(0.064),A 画面中心、B 边缘;排除大小干扰
            return [DFake(label: "A中心", box: box(areaFrac: 0.064, cxN: 0.50, cyN: 0.50), conf: 0.90),
                    DFake(label: "B边缘", box: box(areaFrac: 0.064, cxN: 0.92, cyN: 0.50), conf: 0.90)]
        case .d3:   // 你爹场景:A 大(0.100)conf 低、B 小(0.025)conf 高;若锁小高conf B = 按conf不按面积
            return [DFake(label: "A大低conf", box: box(areaFrac: 0.100, cxN: 0.35, cyN: 0.50), conf: 0.40),
                    DFake(label: "B小高conf", box: box(areaFrac: 0.025, cxN: 0.65, cyN: 0.50), conf: 0.95)]
        }
    }

    // ===== 内部状态 =====
    private var xNorm: CGFloat = -0.10
    private var started = false

    // 逐帧竞争快照:findTargetWithFake 填,detectHuman 读出来配 frameCount/poseValid 打 console
    struct DebugSnapshot {
        var realCount = 0
        var realBox: CGRect = .zero
        var realScore: Float = -1
        var fakeBox: CGRect = .zero
        var fakeScore: Float = -1     // -1 = 本帧没注入假人
        var candCount = 0
        var winner = "无"
    }
    var lastSnapshot = DebugSnapshot()

    /// 当前帧假人:返回 wide 传感器坐标的 box + 预设上/下半身颜色直方图。
    /// 每帧调一次(findTargetWithFake 内),自推进位置。
    func currentFake(target: TargetProfile?, sensorSize: CGSize) -> (box: CGRect, upper: [Float], lower: [Float])? {
        guard enabled else { return nil }

        if !started { xNorm = startXNorm; started = true }

        // 推进横穿位置;重叠模式滑到主角 x 处停住
        if overlapStopOnTarget, let t = target, xNorm >= t.lastCenter.x {
            xNorm = t.lastCenter.x
        } else {
            xNorm += crossSpeed
            if xNorm > endXNorm { xNorm = startXNorm }   // 循环横穿,便于反复观察
        }

        // 框大小:基于主角面积 × sizeRatio(没主角档案时退默认 0.5 屏高)
        let aspect = CGFloat(target?.aspectRatio ?? 1.8)            // 高/宽
        let baseArea: CGFloat
        if let t = target, t.relativeSize > 0 {
            baseArea = CGFloat(t.relativeSize) * sensorSize.width * sensorSize.height
        } else {
            let h = 0.5 * sensorSize.height
            baseArea = (h / aspect) * h
        }
        let area = baseArea * sizeRatio * sizeRatio
        let h = sqrt(area * aspect)
        let w = h / aspect

        let cx = xNorm * sensorSize.width
        let cy = yNorm * sensorSize.height
        let box = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)

        // 颜色:撞衫→复制主角直方图(应被误锁);异色→构造明显不同的尖峰直方图(应被拒)
        let upper: [Float]
        let lower: [Float]
        switch colorMode {
        case .sameAsTarget:
            upper = target?.colorHistogram ?? Self.spikeHist(hBin: 8, sBin: 7)
            lower = target?.lowerBodyColorHist ?? Self.spikeHist(hBin: 8, sBin: 7)
        case .different:
            upper = Self.spikeHist(hBin: 8, sBin: 7)   // 与典型衣着低重叠
            lower = Self.spikeHist(hBin: 12, sBin: 6)
        }
        return (box, upper, lower)
    }

    /// 构造与 computeColorHistogram 同长(16 H + 8 S)的尖峰归一化直方图。
    private static func spikeHist(hBin: Int, sBin: Int) -> [Float] {
        var hist = [Float](repeating: 0, count: 16 + 8)
        hist[min(15, max(0, hBin))] = 1.0          // H 段(0..<16)集中
        hist[16 + min(7, max(0, sBin))] = 1.0      // S 段(16..<24)集中
        return hist
    }
}
#endif
