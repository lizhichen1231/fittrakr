// 【卡组物理·UIScrollView 重写】惯性(快甩多张)+ 阻尼(.fast 减速曲线)+ 吸附(整卡)同时成立。
// - 吸附:scrollViewWillEndDragging 把系统惯性终点 round 到最近 page,不加任何额外动画;
// - 循环:首尾各 4 张 buffer;归一跳变只在减速/拖拽结束的静止时刻做
//   (减速中 setContentOffset 会打断系统减速——这是跳变时机的硬约束);
// - 层叠视觉:didScroll 每帧回写 pos(张),SwiftUI 端按 offset 插值直渲,零 animation;
// - 竖拉(堆叠⇄网格/网格滚动)与点击:独立识别器,按起手方向仲裁,横向让给 scrollView。

import SwiftUI
import UIKit

private let mtDeckBuffer = 4   // 首尾复制张数(快甩最多冲 2-3 张,4 张余量)

final class MTDeckScrollUIView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var pageW: CGFloat = 300
    var nCards = 1
    var onPos: ((Double) -> Void)?
    var onTap: ((CGPoint) -> Void)?
    var onVert: ((Int, CGFloat, CGFloat) -> Void)?   // phase 0=began 1=changed 2=ended, dy, vy
    private var vertPan: UIPanGestureRecognizer!
    private var suppressPos = false   // 程序化 offset 变更(configure/jump/归一)不同步回写:
                                      // 它们可能发生在 SwiftUI 视图更新周期内,直接写 @Published 是 UB

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        isPagingEnabled = false
        decelerationRate = .fast
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        addGestureRecognizer(tap)
        vertPan = UIPanGestureRecognizer(target: self, action: #selector(vert(_:)))
        vertPan.delegate = self
        vertPan.cancelsTouchesInView = false
        addGestureRecognizer(vertPan)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(n: Int, pageW: CGFloat, height: CGFloat) {
        let changed = n != nCards || abs(pageW - self.pageW) > 0.5
        nCards = max(1, n)
        self.pageW = max(1, pageW)
        contentSize = CGSize(width: CGFloat(nCards + 2 * mtDeckBuffer) * self.pageW, height: height)
        if changed { jump(toIndex: 0) }
    }

    /// 真实索引 i 的精确 offset
    private func offsetFor(_ i: Int) -> CGFloat { CGFloat(mtDeckBuffer + i) * pageW }

    func jump(toIndex i: Int) {
        suppressPos = true
        contentOffset = CGPoint(x: offsetFor(i), y: 0)
        suppressPos = false
        let p = Double(contentOffset.x / pageW) - Double(mtDeckBuffer)
        DispatchQueue.main.async { [weak self] in self?.onPos?(p) }   // 更新周期外补发
    }

    // ── 层叠视觉驱动:pos(张,可为负/越 n,SwiftUI 侧 wrap)──
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !suppressPos else { return }
        onPos?(Double(contentOffset.x / pageW) - Double(mtDeckBuffer))
    }

    // ── 吸附:改写系统惯性终点到最近 page,不额外加动画 ──
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let idx = (targetContentOffset.pointee.x / pageW).rounded()
        let maxIdx = CGFloat(nCards + 2 * mtDeckBuffer - 1)
        targetContentOffset.pointee.x = min(max(idx, 0), maxIdx) * pageW
    }

    // ── 循环归一:仅在静止时刻(不打断减速)──
    private func normalizeIfNeeded() {
        let i = Int((contentOffset.x / pageW).rounded()) - mtDeckBuffer
        suppressPos = true
        if i < 0 { contentOffset.x += CGFloat(nCards) * pageW }
        else if i >= nCards { contentOffset.x -= CGFloat(nCards) * pageW }
        suppressPos = false
        let p = Double(contentOffset.x / pageW) - Double(mtDeckBuffer)
        DispatchQueue.main.async { [weak self] in self?.onPos?(p) }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { normalizeIfNeeded() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate d: Bool) {
        if !d { normalizeIfNeeded() }
    }

    // ── 点击/竖拉 ──
    @objc private func tapped(_ g: UITapGestureRecognizer) {
        var p = g.location(in: self)
        p.x -= contentOffset.x   // 转视口坐标(SwiftUI 命中用)
        onTap?(p)
    }
    @objc private func vert(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            isScrollEnabled = false   // 竖拉期间横向锁死(同 touch 内 cancel 掉 scroll pan)
            onVert?(0, 0, 0)
        case .changed:
            onVert?(1, g.translation(in: self).y, 0)
        case .ended, .cancelled, .failed:
            onVert?(2, g.translation(in: self).y, g.velocity(in: self).y)
            isScrollEnabled = true
        default: break
        }
    }
    // 竖拉只在起手方向为纵向时成立;横向让给 scrollView 自带 pan
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === vertPan {
            let v = vertPan.velocity(in: self)
            return abs(v.y) > abs(v.x)
        }
        return super.gestureRecognizerShouldBegin(g)
    }
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

struct MTDeckScroll: UIViewRepresentable {
    @ObservedObject var m: MTAppModel
    @ObservedObject var pane: MTPane

    func makeUIView(context: Context) -> MTDeckScrollUIView {
        let v = MTDeckScrollUIView(frame: .zero)
        v.onPos = { [weak m] p in m?.mo.pos = p }
        v.onTap = { [weak m] p in m?.deckTap(p) }
        v.onVert = { [weak m] phase, dy, vy in
            switch phase {
            case 0: m?.vertBegan()
            case 1: m?.vertChanged(dy: Double(dy))
            default: m?.vertEnded(vy: Double(vy))
            }
        }
        context.coordinator.resetSeen = m.deckResetTick
        return v
    }

    func updateUIView(_ v: MTDeckScrollUIView, context: Context) {
        let cardH0 = 0.60 * Double(m.H)
        let cardW0 = min(cardH0 * 9.0 / 16.0, Double(m.W) - 48)
        v.configure(n: m.n, pageW: CGFloat(cardW0 + 10), height: m.Hd)
        v.isScrollEnabled = pane.g < 0.5   // 网格态禁横向
        if context.coordinator.resetSeen != m.deckResetTick {
            context.coordinator.resetSeen = m.deckResetTick
            v.jump(toIndex: 0)
        }
    }

    func makeCoordinator() -> Coord { Coord() }
    final class Coord { var resetSeen = 0 }
}
