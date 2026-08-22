// ═══════════════════════════════════════════════════════════════════════════
// 【新 UI】设计基础层 —— 移植自 claude.design MyTrack.dc.html(2026-08-21 定稿)。
// 本目录 = 正式新 UI 的起点(现有 CameraScreen 系为废案,后续整体替换)。
// 移植原则:几何/时序/缓动常数逐字照抄设计稿;仅平台能力差异处做标注近似:
//   ① 字体 Libre Caslon Display → 系统衬线(New York);
//   ② CSS 多层 backdrop-blur 渐变 → Material + mask 羽化(公开 API 上限);
//   ③ CSS filter 调色(sepia/hue-rotate)→ SwiftUI 调色近似。
// ═══════════════════════════════════════════════════════════════════════════

import SwiftUI
import QuartzCore

enum MT {
    static let accent = Color(red: 1.0, green: 90 / 255.0, blue: 60 / 255.0)      // #FF5A3C
    static let danger = Color(red: 178 / 255.0, green: 92 / 255.0, blue: 92 / 255.0).opacity(0.7)

    /// ease-out-back(设计稿 eob,c1 可调:列表浮现 1.70158,卡片转场 0.6,面板泡泡 0.75)
    static func eob(_ t: Double, c1: Double = 1.70158) -> Double {
        let c3 = c1 + 1
        let u = t - 1
        return 1 + c3 * u * u * u + c1 * u * u
    }
    /// smootherstep(顶部渐隐/底部收拢 mask 用)
    static func ss(_ t: Double) -> Double { t * t * t * (t * (6 * t - 15) + 10) }

    static func wrap(_ v: Double, _ n: Int) -> Double {
        let m = Double(n)
        return ((v.truncatingRemainder(dividingBy: m)) + m).truncatingRemainder(dividingBy: m)
    }
}

/// CADisplayLink 驱动的逐帧循环 —— 对应设计稿的 raf 物理(decay/snap/播放进度)。
/// 回调返回 false 即停;dt 与设计稿同款 clamp 0.05。
final class MTTicker {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var step: ((Double) -> Bool)?

    func run(_ step: @escaping (Double) -> Bool) {
        stop()
        self.step = step
        last = CACurrentMediaTime()
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }
    @objc private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.05, now - last); last = now
        if !(step?(dt) ?? false) { stop() }
    }
    func stop() { link?.invalidate(); link = nil; step = nil }
    var running: Bool { link != nil }
    deinit { link?.invalidate() }
}

/// 手势速度:与设计稿一致的 90ms 轨迹窗差分(不用系统 predicted 值,保口感一致)
struct MTTrail {
    private var pts: [(t: CFTimeInterval, x: CGFloat, y: CGFloat)] = []
    mutating func reset(_ p: CGPoint) { pts = [(CACurrentMediaTime(), p.x, p.y)] }
    mutating func push(_ p: CGPoint) {
        let now = CACurrentMediaTime()
        pts.append((now, p.x, p.y))
        while pts.count > 2 && now - pts[0].t > 0.09 { pts.removeFirst() }
    }
    var velocity: CGPoint {
        guard pts.count > 1 else { return .zero }
        let a = pts[0], b = pts[pts.count - 1]
        let dt = b.t - a.t
        guard dt > 0.004 else { return .zero }
        return CGPoint(x: (b.x - a.x) / dt, y: (b.y - a.y) / dt)
    }
}

/// 羽化磨砂:Material 被径向渐变 mask —— 设计稿 6 层分级 backdrop-blur 的公开 API 近似。
struct MTFeatherBlur: View {
    var center: UnitPoint
    var rx: CGFloat          // 椭圆横半径(相对宽度倍数)
    var ry: CGFloat
    var inner: CGFloat = 0.3 // 全强度截止
    var dim: Double = 0.22   // 同 mask 的压暗(设计稿 brightness(0.75~0.82) 的近似)
    var body: some View {
        GeometryReader { geo in
            let mask = EllipticalGradient(
                stops: [.init(color: .black, location: 0), .init(color: .black, location: inner), .init(color: .clear, location: 1)],
                center: center,
                startRadiusFraction: 0,
                endRadiusFraction: 0.5)
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(dim)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .mask(mask.scaleEffect(x: rx * 2, y: ry * 2, anchor: center))
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// 设计稿 text-shadow: 0 1px 12px rgba(0,0,0,0.85) 的常用档
    func mtShadow(_ heavy: Bool = true) -> some View {
        shadow(color: .black.opacity(heavy ? 0.7 : 0.3), radius: heavy ? 6 : 3.5, x: 0, y: 1)
    }
    /// 薄玻璃气泡(拍摄页顶部 chip / 设置页可改值)
    func mtChip(height: CGFloat = 26, radius: CGFloat = 10) -> some View {
        frame(height: height)
            .padding(.horizontal, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
    }
}

/// 左尖 chevron(设计稿手绘 svg)
struct MTChevron: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        return p
    }
}
