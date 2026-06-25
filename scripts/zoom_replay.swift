// zoom_replay.swift —— 用真实 heightRatio CSV 回放 ZoomController，复算指标（macOS 命令行）
//
// 编译&运行（与真实 ZoomController 源码一起编译，绝不复制其逻辑、不改其参数）：
//   swiftc scripts/zoom_replay.swift FitTrackr.1/Services/Tracking/ZoomController.swift -o /tmp/zoom_replay
//   /tmp/zoom_replay /tmp/hr.csv [out.csv] [maxZoom=3.0]
//
// 输入 CSV 为 video_to_heightratio.swift 的输出（frame,timestamp_s,heightRatio,confidence,heightRatioRaw,boxFound）。
// 回放口径与 App 一致：dt 用真实时间戳；命中帧喂 update(measuredRatio:)，
//   漏检 ≤5 帧 hold 上一次 heightRatio，>5 帧走 command(towardZoom:1.0)（= App 无人回 1x）。
//   maxZoom 默认 3.0（= fitness 预设 cfg.maxZoom；这是 App 运行时配置，非控制器内部参数）。
//   注：原地锁定(in-place)依赖 hip/pose 数据，本回放不含——本工具专门隔离“heightRatio→zoom”这条链。

import Foundation
import CoreGraphics

@main
struct ZoomReplay {

    static func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
    static func std(_ v: [Double]) -> Double {
        if v.isEmpty { return 0 }; let m = mean(v)
        return (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count)).squareRoot()
    }
    /// 线性最小二乘去趋势，返回残差
    static func detrend(_ y: [Double], _ lo: Int, _ hi: Int) -> [Double] {
        let n = hi - lo; if n <= 2 { return Array(repeating: 0, count: max(0, n)) }
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for i in 0..<n { let x = Double(i), yy = y[lo + i]; sx += x; sy += yy; sxx += x * x; sxy += x * yy }
        let nn = Double(n), denom = nn * sxx - sx * sx
        let m = denom == 0 ? 0 : (nn * sxy - sx * sy) / denom
        let b = (sy - m * sx) / nn
        return (0..<n).map { y[lo + $0] - (m * Double($0) + b) }
    }
    static func p2p(_ v: [Double]) -> Double { v.isEmpty ? 0 : (v.max()! - v.min()!) }
    static func err(_ m: String) { FileHandle.standardError.write((m + "\n").data(using: .utf8)!) }

    static func main() {
        let a = CommandLine.arguments
        guard a.count >= 2 else { err("用法: zoom_replay <in.csv> [out.csv] [maxZoom=3.0]"); exit(2) }
        let inURL = URL(fileURLWithPath: a[1])
        let outURL: URL? = a.count >= 3 ? URL(fileURLWithPath: a[2]) : nil
        let maxZoom = a.count >= 4 ? (Double(a[3]) ?? 3.0) : 3.0

        guard let text = try? String(contentsOf: inURL, encoding: .utf8) else { err("❌ 读不了 CSV: \(inURL.path)"); exit(2) }
        var rows: [(frame: Int, t: Double, hr: Double?, found: Bool)] = []
        for line in text.split(separator: "\n").dropFirst() {
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6 else { continue }
            let found = (f[5].trimmingCharacters(in: .whitespaces) == "1")
            rows.append((Int(f[0]) ?? 0, Double(f[1]) ?? 0, found ? Double(f[2]) : nil, found))
        }
        guard rows.count > 2 else { err("❌ CSV 数据不足"); exit(2) }

        // ===== 回放（真实 ZoomController，真实 dt）=====
        let c = ZoomController()
        c.setMaxZoom(CGFloat(maxZoom))
        var zs = [Double](), hrs = [Double](), ts = [Double](), holds = [Bool](), founds = [Bool]()
        var lastHR: CGFloat?, missStreak = 0, prevT: Double?
        for r in rows {
            let dt = prevT == nil ? 1.0 / 30.0 : max(1.0 / 120.0, r.t - prevT!)
            prevT = r.t
            let z: CGFloat
            if r.found, let hr = r.hr {
                lastHR = CGFloat(hr); missStreak = 0
                z = c.update(measuredRatio: CGFloat(hr), dt: CGFloat(dt))
            } else {
                missStreak += 1
                if missStreak <= 5, let lh = lastHR { z = c.update(measuredRatio: lh, dt: CGFloat(dt)) }
                else { z = c.command(towardZoom: 1.0, dt: CGFloat(dt)) }
            }
            zs.append(Double(z)); ts.append(r.t); holds.append(c.isHolding)
            founds.append(r.found); hrs.append(r.found ? (r.hr ?? .nan) : .nan)
        }
        let N = zs.count
        let dur = ts.last! - ts.first!

        // ===== 整体指标 =====
        var deltas = [Double](); for i in 1..<N { deltas.append(zs[i] - zs[i - 1]) }
        let maxRetr = deltas.map { -$0 }.max() ?? 0          // 最大单帧回撤（zoom 下降）
        let frameDeltaStd = std(deltas)
        var rev = 0, prevSign = 0; let eps = 0.002
        for d in deltas { let s = d > eps ? 1 : (d < -eps ? -1 : 0); if s != 0 { if prevSign != 0 && s != prevSign { rev += 1 }; prevSign = s } }
        let revPerSec = dur > 0 ? Double(rev) / dur : 0
        let detected = founds.filter { $0 }.count

        print("===== 真实序列回放（\(inURL.lastPathComponent)）=====")
        print(String(format: "帧数=%d  检测=%d  时长=%.1fs  maxZoom=%.1f", N, detected, dur, maxZoom))
        print(String(format: "heightRatio: min=%.3f max=%.3f  →  zoom: min=%.3fx max=%.3fx",
                     hrs.filter { !$0.isNaN }.min() ?? 0, hrs.filter { !$0.isNaN }.max() ?? 0, zs.min() ?? 0, zs.max() ?? 0))
        print("—— 整体平滑性 ——")
        print(String(format: "  最大单帧回撤 = %.5fx   帧间Δ std = %.5fx   方向反转 = %d 次 (%.2f 次/秒)", maxRetr, frameDeltaStd, rev, revPerSec))

        // ===== 平稳窗（人基本站定）：稳态残差 =====
        let W = 30; let hrThresh = 0.04
        var runs: [(lo: Int, hi: Int, meanHR: Double)] = []
        var i = 0
        while i < N {
            if !founds[i] || hrs[i].isNaN { i += 1; continue }
            var mn = hrs[i], mx = hrs[i], j = i + 1
            while j < N && founds[j] && !hrs[j].isNaN {
                let nmn = min(mn, hrs[j]), nmx = max(mx, hrs[j])
                if nmx - nmn > hrThresh { break }
                mn = nmn; mx = nmx; j += 1
            }
            if j - i >= W { runs.append((i, j, (i..<j).map { hrs[$0] }.reduce(0, +) / Double(j - i))); i = j }
            else { i += 1 }
        }
        // ===== 稳态：subject 站定 + zoom 已锁（hr 稳 且 zoom 稳）的最长窗 → 真实静止抖动 =====
        let holdPct = Double(holds.filter { $0 }.count) / Double(N) * 100
        var sLo = 0, sLen = 0
        do {
            var i2 = 0
            while i2 < N {
                if !founds[i2] || hrs[i2].isNaN { i2 += 1; continue }
                var mnH = hrs[i2], mxH = hrs[i2], mnZ = zs[i2], mxZ = zs[i2], j = i2 + 1
                while j < N && founds[j] && !hrs[j].isNaN {
                    let a1 = min(mnH, hrs[j]), a2 = max(mxH, hrs[j])
                    let b1 = min(mnZ, zs[j]), b2 = max(mxZ, zs[j])
                    if a2 - a1 > 0.04 || b2 - b1 > 0.03 { break }   // hr 稳 且 zoom 稳（排除还在收敛/settling 的段）
                    mnH = a1; mxH = a2; mnZ = b1; mxZ = b2; j += 1
                }
                if j - i2 > sLen { sLen = j - i2; sLo = i2 }
                i2 = max(j, i2 + 1)
            }
        }
        print(String(format: "—— 稳态（subject 站定 + zoom 锁定的最长窗）——   [hold 覆盖 %.0f%%]", holdPct))
        if sLen >= W {
            let res = detrend(zs, sLo, sLo + sLen)
            print(String(format: "  窗 帧[%d..%d) %.2fs meanZoom=%.3fx | 静止 zoom 残差 峰峰=%.5fx std=%.5fx（≈0 → 站定不动）",
                         sLo, sLo + sLen, Double(sLen) * (dur / Double(N)), mean(Array(zs[sLo..<sLo + sLen])), p2p(res), std(res)))
        } else { print("  无足够长的「站定且锁定」窗") }

        // ===== 远/近：两个【内部未夹顶】距离档的 log 域抖动比 =====
        func interiorLogStd(_ r: (lo: Int, hi: Int, meanHR: Double)) -> (mz: Double, lsd: Double) {
            let lz = (r.lo..<r.hi).map { log(max(zs[$0], 1e-9)) }
            return (mean(Array(zs[r.lo..<r.hi])), std(detrend(lz, 0, lz.count)))
        }
        let interior = runs.filter { r in
            let s = interiorLogStd(r)
            return s.mz > 1.02 && s.mz < maxZoom * 0.98 && s.lsd > 1e-4   // 未被 minZoom/maxZoom 夹住、且有可测抖动
        }
        print("—— 远/近 log 域抖动比（需两个内部未夹顶距离档）——")
        if let hiHR = interior.max(by: { $0.meanHR < $1.meanHR }),
           let loHR = interior.min(by: { $0.meanHR < $1.meanHR }),
           hiHR.lo != loHR.lo, hiHR.meanHR / max(loHR.meanHR, 1e-9) >= 1.3 {
            let w = interiorLogStd(hiHR), t = interiorLogStd(loHR)   // hiHR=heightRatio 大=低 zoom；loHR=小=高 zoom
            print(String(format: "  低zoom段 meanHR=%.3f meanZoom=%.2fx log-std=%.4f", hiHR.meanHR, w.mz, w.lsd))
            print(String(format: "  高zoom段 meanHR=%.3f meanZoom=%.2fx log-std=%.4f", loHR.meanHR, t.mz, t.lsd))
            print(String(format: "  ▶ 高/低 log-std 比 = %.2f×（≈1 → 真实噪声下增益与距离无关）", t.lsd / max(w.lsd, 1e-9)))
        } else {
            print("  ⚠️ 本视频没有两个内部未夹顶的距离档（人始终较近：heightRatio 高端→目标 zoom<1 被 minZoom 夹在 1.0x）。")
            print("     要测真实远近增益，需一段人走到更远的视频（heightRatio 出现 ~0.5 与 ~0.25 两个稳定档）。")
        }

        // ===== 采样轨迹 =====
        print("—— 轨迹（每 ~0.5s 采样）——")
        print("   t(s)   heightRatio  zoom    hold")
        var lastPrint = -1.0
        for k in 0..<N {
            if ts[k] - lastPrint >= 0.5 || k == N - 1 {
                let hrStr = hrs[k].isNaN ? "  miss " : String(format: "%.3f", hrs[k])
                print(String(format: "  %5.2f    %@     %.3fx   %@", ts[k], hrStr, zs[k], holds[k] ? "■" : " "))
                lastPrint = ts[k]
            }
        }

        // ===== 导出 =====
        if let outURL = outURL {
            var out = "frame,timestamp_s,heightRatio,zoom,holding,boxFound\n"
            for k in 0..<N {
                let hrStr = hrs[k].isNaN ? "" : String(format: "%.5f", hrs[k])
                out += "\(rows[k].frame),\(String(format: "%.4f", ts[k])),\(hrStr),\(String(format: "%.5f", zs[k])),\(holds[k] ? 1 : 0),\(founds[k] ? 1 : 0)\n"
            }
            try? out.write(to: outURL, atomically: true, encoding: .utf8)
            print("✅ 导出回放序列: \(outURL.path)")
        }
    }
}
