import XCTest
@testable import FitTrackr_1

/// 变焦控制律回归测试。
/// 注意：当前 App target 因 CocoaPods 的 MediaPipeTasksCommon 静态库缺失而无法链接，
/// 故本测试暂时无法在本机 run；它随仓库提交，待 `pod install` 修复后即可执行。
/// 控制律的逐帧数值验证另由独立 swift 脚本完成（见 commit 说明）。
final class ZoomControllerTests: XCTestCase {

    private let fps: CGFloat = 30
    private var dt: CGFloat { 1.0 / fps }

    private func run(_ ratios: [CGFloat], maxZoom: CGFloat, tau: CGFloat = 0.40) -> [CGFloat] {
        var cfg = ZoomConfig()
        cfg.tau = tau
        let c = ZoomController(config: cfg)
        c.setMaxZoom(maxZoom)
        return ratios.map { c.update(measuredRatio: $0, dt: dt) }
    }

    // 线性最小二乘去趋势，返回残差
    private func detrend(_ ys: ArraySlice<CGFloat>) -> [CGFloat] {
        let v = Array(ys); let n = v.count
        guard n > 2 else { return v.map { _ in 0 } }
        var sx: CGFloat = 0, sy: CGFloat = 0, sxx: CGFloat = 0, sxy: CGFloat = 0
        for i in 0..<n { let x = CGFloat(i); sx += x; sy += v[i]; sxx += x*x; sxy += x*v[i] }
        let nn = CGFloat(n), denom = nn*sxx - sx*sx
        let m = denom == 0 ? 0 : (nn*sxy - sx*sy)/denom
        let b = (sy - m*sx)/nn
        return (0..<n).map { v[$0] - (m*CGFloat($0)+b) }
    }
    private func p2p(_ v: [CGFloat]) -> CGFloat { (v.max() ?? 0) - (v.min() ?? 0) }
    private func mean(_ v: [CGFloat]) -> CGFloat { v.isEmpty ? 0 : v.reduce(0,+)/CGFloat(v.count) }
    private func std(_ v: [CGFloat]) -> CGFloat {
        guard !v.isEmpty else { return 0 }; let m = mean(v)
        return (v.reduce(0){ $0 + ($1-m)*($1-m) }/CGFloat(v.count)).squareRoot()
    }

    /// ① 匀速走远：zoom 应单调上升，无来回反转
    func testWalkAway_Monotonic_NoReversal() {
        let n = 150
        let ratios = (0..<n).map { 0.55 + (0.15-0.55)*CGFloat($0)/CGFloat(n-1) }
        let z = run(ratios, maxZoom: 3.0)
        var maxDrop: CGFloat = 0
        for i in 1..<z.count { maxDrop = max(maxDrop, z[i-1]-z[i]) }
        XCTAssertLessThan(maxDrop, 0.002, "走远过程中 zoom 出现回撤=来回泵动")
    }

    /// ② 远距离步态噪声：稳态去趋势残差应很小（无泵动）
    func testGaitNoise_NoPumping() {
        let n = 120, f: CGFloat = 1.5
        let ratios = (0..<n).map { i -> CGFloat in
            let t = CGFloat(i)*dt; return 0.2*(1+0.15*sin(.pi*2*f*t))
        }
        let z = run(ratios, maxZoom: 3.0)
        let res = detrend(z[(n/3)..<n])
        XCTAssertLessThan(std(res), 0.05, "步态噪声下 zoom 抖动过大")
    }

    /// ③ 阶跃：单调收敛，无超调
    func testStep_NoOvershoot() {
        let n = 90
        let ratios = (0..<n).map { CGFloat($0) < 15 ? CGFloat(0.5) : CGFloat(0.3) }
        let z = run(ratios, maxZoom: 3.0)
        let finalZ = z.last!
        let maxAfter = z[15...].max() ?? 0
        XCTAssertLessThanOrEqual(maxAfter - finalZ, 0.001, "阶跃后出现超调")
    }

    /// ④ log 映射使增益与距离无关：远段 vs 近段去趋势“相对”抖动应基本一致
    func testGainIsDistanceIndependent() {
        let n = 180, f: CGFloat = 1.5
        var trend = [CGFloat](), ratios = [CGFloat]()
        for i in 0..<n {
            let tr = 0.55 + (0.12-0.55)*CGFloat(i)/CGFloat(n-1)
            trend.append(tr); ratios.append(tr*(1+0.12*sin(.pi*2*f*CGFloat(i)*dt)))
        }
        let z = run(ratios, maxZoom: 8.0)  // 高上限避免夹顶掩盖
        func relStd(_ lo2: CGFloat, _ hi2: CGFloat) -> CGFloat {
            var lo = -1, hi = -1
            for i in 0..<n where trend[i] >= lo2 && trend[i] <= hi2 { if lo < 0 { lo = i }; hi = i+1 }
            let mz = mean(Array(z[lo..<hi]))
            return mz == 0 ? 0 : std(detrend(z[lo..<hi]))/mz
        }
        let far = relStd(0.45, 0.55)   // ratio≈0.5
        let near = relStd(0.12, 0.18)  // ratio≈0.15
        let ratio = near / max(far, 1e-9)
        // 远近相对抖动比值应接近 1（log 域增益恒定）；放宽到 [0.5, 2.0]
        XCTAssertGreaterThan(ratio, 0.5, "近段相对抖动远小于远段（异常）")
        XCTAssertLessThan(ratio, 2.0, "近段相对抖动被放大（log 映射未生效）")
    }
}
