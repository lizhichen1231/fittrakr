// 【新 UI】状态机 + 手势物理 —— 设计稿 Component(state/raf 循环)的逐字移植。
// 物理常数全部照抄:横滑 420px/张、decay e^-3.2t、snap e^-11t、竖拉 320px、
// 转盘 54px/项 snap e^-10t、参数盘 120px/项 · 44px/值、统计层 340px、速度窗 90ms。

import SwiftUI
import QuartzCore

final class MTAppModel: ObservableObject {

    // ── 素材库 ──
    @Published var pos: Double = 0          // 卡组位置(浮点,张)
    @Published var dayIdx = 0
    @Published var g: Double = 0            // 0=堆叠 1=网格
    @Published var scrollY: Double = 0
    // ── 转盘(日期/分类)──
    @Published var dialOpen = false
    @Published var dialIn = false           // 入/出场 stagger 标志(SwiftUI 动画驱动)
    @Published var dialPos: Double = 0
    var dial0: Double = 0                   // 打开时的位置(背景视差 delta 用)
    // ── 单条回看 ──
    @Published var playIdx: Int? = nil
    @Published var playT: Double = 0
    @Published var playing = true
    @Published var playFx: Double = 1       // 转场原始进度 0→1
    @Published var playFxMode: Int = 0      // 1=in -1=out 0=稳态
    @Published var ps: Double = 0           // 统计层进度
    @Published var tagPickOpen = false
    @Published var tagIn = false
    @Published var tagNewOpen = false
    @Published var tagNewText = ""
    @Published var clipCats: [String: String] = [:]
    // ── 设置 ──
    @Published var setOpen = false
    @Published var setVals: [String: String] = [:]
    @Published var setDesc: String? = nil
    @Published var setPick: String? = nil
    @Published var setPickIn = false
    var setPickRowFrame: CGRect = .zero     // 触发行捕获帧(root 空间)
    // ── 拍摄 ──
    @Published var capOpen = false
    @Published var capFx: Double = 1
    @Published var capFxMode: Int = 0
    @Published var recOn = false
    @Published var recT: Double = 0
    @Published var capCat = "力量训练"
    @Published var capTagOpen = false
    @Published var capTagIn = false
    @Published var capRes = "4K"
    @Published var capFps = 60
    @Published var capDialOpen = false
    @Published var capDialIn = false
    @Published var capDialPos: Double = 0
    @Published var capValPos: Double = 0
    @Published var capSel: [Int: Int] = [:]
    @Published var cdActive: Int = 0        // 0 无 1 横 2 竖(拖动中浮出刻度)

    // ── 数据(设计稿假数据;后续任务卡换真源)──
    let days = mtDays()
    lazy var cats: [String] = mtCats(days)
    var day: MTDay { days[min(dayIdx, days.count - 1)] }
    var clips: [MTClip] { mtClips(day) }
    var n: Int { day.n }
    var nItems: Int { cats.count + days.count }
    let capParams = mtCapParams()
    let capDefaults = mtCapDefaults()

    /// 屏幕几何(root GeometryReader 写入;设计稿 W=402 H=874 为缺省)
    var W: CGFloat = 402
    var H: CGFloat = 874
    var Hd: CGFloat { H - 118 }             // 卡组区高(顶部 118 下方)
    var Hs: CGFloat { Hd - 100 }            // 堆叠卡高
    var maxScroll: Double {
        let pad = 20.0, gap = 12.0
        let colW = (Double(W) - pad * 2 - gap) / 2
        let cardH = (colW * 1.45).rounded()
        let rows = Double((n + 1) / 2)
        return max(0, 72 + rows * (cardH + gap) - gap + 124 - Double(Hd))
    }

    // 播放视图有效转场值(设计稿 playEff:in 用 eob(0.6) 回弹,out 反向)
    var playEff: Double {
        guard playIdx != nil else { return 0 }
        switch playFxMode {
        case 1: return MT.eob(playFx, c1: 0.6)
        case -1: return 1 - MT.eob(playFx, c1: 0.6)
        default: return 1
        }
    }
    var capEff: Double {
        guard capOpen else { return 0 }
        switch capFxMode {
        case 1: return capFx
        case -1: return 1 - capFx
        default: return 1
        }
    }

    // ── tickers(对应设计稿各 raf 槽)──
    private let deckTicker = MTTicker()     // _raf: decay/snap
    private let gTicker = MTTicker()        // _graf: g morph / 惯性滚动
    private let dialTicker = MTTicker()     // _draf
    private let playTicker = MTTicker()     // _praf: 播放进度
    private let psTicker = MTTicker()       // _psraf
    private let fxTicker = MTTicker()       // playFx / capFx 转场进度
    private let cdTicker = MTTicker()       // _cdraf: 参数盘 snap
    private let recTicker = MTTicker()      // 录制计时

    func stopAll() {
        [deckTicker, gTicker, dialTicker, playTicker, psTicker, fxTicker, cdTicker, recTicker].forEach { $0.stop() }
    }

    // ═══ 卡组横滑/竖拉(设计稿 dragStart/Move/End + _runPhysics/_runG/_runScroll)═══
    private var drag = false
    private var axis: Int = 0               // 0 未定 1 x 2 y 3 none
    private var x0: CGFloat = 0, y0: CGFloat = 0
    private var p0: Double = 0, g0: Double = 0, s0: Double = 0
    private var trail = MTTrail()

    func deckDown(_ p: CGPoint) {
        deckTicker.stop(); gTicker.stop()
        x0 = p.x; y0 = p.y
        p0 = pos; g0 = g; s0 = scrollY
        drag = true; axis = 0
        trail.reset(p)
    }
    func deckMove(_ p: CGPoint) {
        guard drag else { return }
        trail.push(p)
        let dx = p.x - x0, dy = p.y - y0
        if axis == 0 {
            if max(abs(dx), abs(dy)) < 7 { return }
            axis = abs(dx) > abs(dy) ? 1 : 2
            if axis == 1 && g0 > 0 { axis = 3 }
        }
        if axis == 1 { pos = p0 - Double(dx) / 420 }
        else if axis == 2 {
            if g0 >= 1 {
                let s = s0 - Double(dy)
                if s < 0 { g = max(0, 1 + s / 320); scrollY = 0 }
                else { scrollY = min(maxScroll, s); g = 1 }
            } else { g = max(0, min(1, g0 - Double(dy) / 320)); scrollY = 0 }
        }
    }
    func deckUp() {
        guard drag else { return }
        drag = false
        let v = trail.velocity
        if axis == 0 {  // 轻点:打开单条回看(设计稿网格命中公式)
            if g < 0.5 { openPlay(Int(MT.wrap(pos.rounded(), n))) }
            else if g >= 0.999 {
                let relX = Double(x0), relY = Double(y0) + scrollY
                let pad = 20.0, gap = 12.0
                let colW = (Double(W) - pad * 2 - gap) / 2
                let cardH = (colW * 1.45).rounded()
                let col = relX < pad + colW ? 0 : (relX > pad + colW + gap ? 1 : -1)
                let row = Int(floor((relY - 72) / (cardH + gap)))
                let i = row * 2 + col
                if col >= 0, row >= 0, i < n,
                   (relY - 72).truncatingRemainder(dividingBy: cardH + gap) <= cardH { openPlay(i) }
            }
            return
        }
        if axis == 1 {
            var vv = Double(-v.x) / 420
            vv = max(-9, min(9, vv))
            let moved = pos - p0
            if abs(vv) > 1.4 { runDecay(vv); return }
            var target = pos.rounded()
            if target == p0.rounded(), abs(moved) > 0.16 || abs(vv) > 0.35 {
                target += (moved != 0 ? moved : vv) > 0 ? 1 : -1
            }
            runSnap(target)
        } else if axis == 2 {
            let vy = Double(v.y)
            if g > 0.001 && g < 0.999 {
                runG(vy < -350 ? 1 : vy > 350 ? 0 : (g > 0.5 ? 1 : 0))
            } else if g >= 0.999 && abs(vy) > 300 {
                runScroll(-vy)
            }
        }
    }
    private func runDecay(_ v0: Double) {
        var v = v0
        deckTicker.run { [weak self] dt in
            guard let self else { return false }
            self.pos += v * dt
            v *= exp(-3.2 * dt)
            if abs(v) < 1.2 { self.runSnap((self.pos + v / 3.2).rounded()); return false }
            return true
        }
    }
    private func runSnap(_ target: Double) {
        deckTicker.run { [weak self] dt in
            guard let self else { return false }
            self.pos += (target - self.pos) * (1 - exp(-11 * dt))
            if abs(target - self.pos) < 0.002 { self.pos = MT.wrap(target, self.n); return false }
            return true
        }
    }
    private func runG(_ target: Double) {
        gTicker.run { [weak self] dt in
            guard let self else { return false }
            self.g += (target - self.g) * (1 - exp(-10 * dt))
            if abs(target - self.g) < 0.004 {
                self.g = target
                if target == 0 { self.scrollY = 0 }
                return false
            }
            return true
        }
    }
    private func runScroll(_ v0: Double) {
        var sv = v0
        gTicker.run { [weak self] dt in
            guard let self else { return false }
            var s = self.scrollY + sv * dt
            sv *= exp(-3.4 * dt)
            if s < 0 || s > self.maxScroll { s = max(0, min(self.maxScroll, s)); sv = 0 }
            self.scrollY = s
            return abs(sv) >= 24
        }
    }

    // ═══ 日期/分类转盘 ═══
    private var ddrag = false, dMoved = false
    private var dy0: CGFloat = 0
    private var dp0: Double = 0
    private var dTrail = MTTrail()

    func openDial() {
        guard !setOpen else { return }
        dialTicker.stop()
        let cur = Double(cats.count + dayIdx)
        dial0 = cur
        dialPos = cur
        dialOpen = true
        dialIn = false
        withAnimation(.easeOut(duration: 0.24)) { dialIn = true }
    }
    func closeDial() {
        withAnimation(.easeOut(duration: 0.24)) { dialIn = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, !self.dialIn else { return }
            self.dialOpen = false
        }
    }
    func dialDown(_ p: CGPoint) {
        dialTicker.stop()
        dy0 = p.y; dp0 = dialPos; ddrag = true; dMoved = false
        dTrail.reset(p)
    }
    func dialMove(_ p: CGPoint) {
        guard ddrag else { return }
        dTrail.push(p)
        let dp = Double(dy0 - p.y) / 54
        if abs(dp) > 0.05 { dMoved = true }
        dialPos = max(-0.4, min(Double(nItems) - 0.6, dp0 + dp))
    }
    func dialUp() {
        guard ddrag else { return }
        ddrag = false
        if !dMoved { closeDial(); return }
        var v = Double(-dTrail.velocity.y) / 54
        v = max(-14, min(14, v))
        var target = (dialPos + v / 5).rounded()
        target = max(0, min(Double(nItems - 1), target))
        dialTicker.run { [weak self] dt in
            guard let self else { return false }
            self.dialPos += (target - self.dialPos) * (1 - exp(-10 * dt))
            if abs(target - self.dialPos) < 0.004 {
                self.dialPos = target
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { self.applyDial(Int(target)) }
                return false
            }
            return true
        }
    }
    private func applyDial(_ idx: Int) {
        deckTicker.stop()
        if idx < cats.count {
            let name = cats[idx]
            dayIdx = name == "全部" ? 0 : max(0, days.firstIndex(where: { $0.cat == name }) ?? 0)
        } else { dayIdx = idx - cats.count }
        pos = 0; scrollY = 0
        closeDial()
    }

    // ═══ 单条回看 ═══
    func openPlay(_ i: Int) {
        playIdx = i; playT = 0; playing = true; ps = 0
        playFxMode = 1; playFx = 0
        runFx(duration: 0.42) { [weak self] t in self?.playFx = t } done: { [weak self] in self?.playFxMode = 0 }
        runPlayLoop()
    }
    func closePlay() {
        psTicker.stop()
        ps = 0
        playFxMode = -1; playFx = 0
        runFx(duration: 0.42) { [weak self] t in self?.playFx = t } done: { [weak self] in
            self?.playTicker.stop()
            self?.playIdx = nil; self?.playFxMode = 0
        }
    }
    private func runFx(duration: Double, _ set: @escaping (Double) -> Void, done: @escaping () -> Void) {
        var t = 0.0
        fxTicker.run { dt in
            t = min(1, t + dt / duration)
            set(t)
            if t >= 1 { done(); return false }
            return true
        }
    }
    private var scrubbing = false
    private func runPlayLoop() {
        playTicker.run { [weak self] dt in
            guard let self, self.playIdx != nil else { return false }
            if self.playing && !self.scrubbing {
                let secs = Double(self.clips[min(self.playIdx!, self.n - 1)].secs)
                var t = self.playT + dt / max(1, secs)
                if t >= 1 { t = 0 }
                self.playT = t
            }
            return true
        }
    }
    func togglePlay() {
        guard !psMoved else { return }
        playing.toggle()
        if playing { runPlayLoop() }
    }
    // 统计层竖拉
    private var psDragOn = false
    private(set) var psMoved = false
    private var psY0: CGFloat = 0, ps0: Double = 0
    private var psTrail = MTTrail()
    func psDown(_ p: CGPoint) {
        guard !tagPickOpen else { return }
        psY0 = p.y; ps0 = ps; psDragOn = true; psMoved = false
        psTrail.reset(p)
    }
    func psMove(_ p: CGPoint) {
        guard psDragOn else { return }
        psTrail.push(p)
        let dy = p.y - psY0
        if abs(dy) > 7 { psMoved = true }
        if psMoved { ps = max(0, min(1, ps0 - Double(dy) / 340)) }
    }
    func psUp() {
        guard psDragOn else { return }
        psDragOn = false
        guard psMoved else { return }
        let vy = Double(psTrail.velocity.y)
        let target: Double = vy < -300 ? 1 : vy > 300 ? 0 : (ps > 0.5 ? 1 : 0)
        psTicker.run { [weak self] dt in
            guard let self else { return false }
            self.ps += (target - self.ps) * (1 - exp(-10 * dt))
            if abs(target - self.ps) < 0.004 { self.ps = target; return false }
            return true
        }
        // 点按判定窗结束后复位(togglePlay 用)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.psMoved = false }
    }
    // 复盘带擦洗
    func bandScrub(_ frac: Double, ended: Bool) {
        scrubbing = !ended
        playT = max(0, min(1, frac))
    }
    // 标签选择
    func openTagPick() {
        tagPickOpen = true; tagNewOpen = false; tagIn = false
        withAnimation(.easeOut(duration: 0.24)) { tagIn = true }
    }
    func closeTagPick() {
        withAnimation(.easeOut(duration: 0.24)) { tagIn = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.48) { [weak self] in
            guard let self, !self.tagIn else { return }
            self.tagPickOpen = false; self.tagNewOpen = false
        }
    }
    var tagNames: [String] {
        var seen = Set<String>(), out: [String] = []
        for c in cats.dropFirst() where !seen.contains(c) { seen.insert(c); out.append(c) }
        for c in clipCats.values where !seen.contains(c) { seen.insert(c); out.append(c) }
        return out
    }
    func clipCat(_ i: Int) -> String { clipCats["\(dayIdx)-\(i)"] ?? day.cat }
    func pickTag(_ name: String) {
        if let i = playIdx { clipCats["\(dayIdx)-\(i)"] = name }
        closeTagPick()
    }
    func commitNewTag() {
        let t = tagNewText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let i = playIdx else { return }
        clipCats["\(dayIdx)-\(i)"] = t
        tagPickOpen = false; tagNewOpen = false; tagNewText = ""
    }

    // ═══ 设置 ═══
    lazy var setGroups: [MTSettingGroup] = mtSettingGroups(cats: cats)
    func setVal(_ r: MTSettingRow) -> String { setVals[r.k] ?? r.defVal }
    func tapSetName(_ r: MTSettingRow) { setDesc = setDesc == r.k ? nil : r.k }
    func tapSetVal(_ r: MTSettingRow, rowFrame: CGRect) {
        setDesc = nil
        if r.toggle { setVals[r.k] = setVal(r) == "开" ? "关" : "开"; return }
        guard r.opts != nil else { return }
        setPickRowFrame = rowFrame
        setPick = r.k
        setPickIn = false
        withAnimation(.easeOut(duration: 0.24)) { setPickIn = true }
    }
    func closeSetPick() {
        guard setPick != nil else { return }
        withAnimation(.easeOut(duration: 0.24)) { setPickIn = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.48) { [weak self] in
            guard let self, !self.setPickIn else { return }
            self.setPick = nil
        }
    }
    func pickSetOpt(_ r: MTSettingRow, _ name: String) {
        if !r.act { setVals[r.k] = name }
        closeSetPick()
    }

    // ═══ 拍摄 ═══
    func openCap() {
        capOpen = true; recOn = false; recT = 0
        capFxMode = 1; capFx = 0
        runFx(duration: 0.3) { [weak self] t in self?.capFx = t } done: { [weak self] in self?.capFxMode = 0 }
    }
    func closeCap() {
        if recOn { stopRec() }
        capFxMode = -1; capFx = 0
        runFx(duration: 0.3) { [weak self] t in self?.capFx = t } done: { [weak self] in
            guard let self else { return }
            self.capOpen = false; self.capFxMode = 0
            self.capDialOpen = false; self.capTagOpen = false
        }
    }
    func capSelOf(_ i: Int) -> Int { capSel[i] ?? capDefaults[i] }
    private func startRec() {
        recOn = true; recT = 0; capTagOpen = false
        recTicker.run { [weak self] dt in
            guard let self, self.recOn else { return false }
            self.recT += dt
            return true
        }
    }
    private func stopRec() { recTicker.stop(); recOn = false }
    func toggleRec() {
        if !recOn {
            if capDialOpen {  // 面板开着:先走关闭动效,再开始录制
                closeCapDial()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self, !self.recOn else { return }
                    self.startRec()
                }
                return
            }
            startRec()
        } else { stopRec() }
    }
    func openCapTag() {
        guard !recOn else { return }
        capTagOpen = true; capTagIn = false
        withAnimation(.easeOut(duration: 0.24)) { capTagIn = true }
    }
    func closeCapTag() {
        withAnimation(.easeOut(duration: 0.24)) { capTagIn = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.48) { [weak self] in
            guard let self, !self.capTagIn else { return }
            self.capTagOpen = false
        }
    }
    func openCapDial() {
        guard !recOn else { return }
        if capDialOpen { closeCapDial(); return }  // 图标再点 = 收起
        capValPos = Double(capSelOf(Int(capDialPos.rounded())))
        capDialOpen = true; capDialIn = false
        withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { capDialIn = true }
    }
    func closeCapDial() {
        withAnimation(.easeIn(duration: 0.24)) { capDialIn = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
            guard let self, !self.capDialIn else { return }
            self.capDialOpen = false
        }
    }
    func capReset() {
        capSel = [:]
        let i = max(0, min(capDefaults.count - 1, Int(capDialPos.rounded())))
        capValPos = Double(capDefaults[i])
    }
    // 两级手势:横滑=换参数,竖滑=调值
    private var cdDragOn = false, cdMoved = false
    private var cdX0: CGFloat = 0, cdY0: CGFloat = 0
    private var cdPh: Double = 0, cdPv: Double = 0
    private var cdAxis = 1
    func cdDown(_ p: CGPoint) {
        cdTicker.stop()
        cdX0 = p.x; cdY0 = p.y
        cdPh = capDialPos; cdPv = capValPos
        cdDragOn = true; cdMoved = false
        // 按起手位置定轴:值列一带(距屏底 >205)= 竖滑,弧盘一带 = 横滑
        cdAxis = (H - p.y) > 205 ? 2 : 1
    }
    func cdMove(_ p: CGPoint) {
        guard cdDragOn else { return }
        let dx = Double(p.x - cdX0), dy = Double(p.y - cdY0)
        if !cdMoved {
            if max(abs(dx), abs(dy)) < 5 { return }
            cdMoved = true
            if abs(dy) > abs(dx) * 1.5 { cdAxis = 2 }
            else if abs(dx) > abs(dy) * 1.5 { cdAxis = 1 }
            cdActive = cdAxis
        }
        if cdAxis == 1 {
            capDialPos = max(-0.3, min(Double(capParams.count) - 0.7, cdPh - dx / 120))
        } else {
            let len = capParams[max(0, min(capParams.count - 1, Int((capDialPos).rounded())))].vals.count
            var v = cdPv - dy / 44
            if v < 0 { v *= 0.35 }
            else if v > Double(len - 1) { v = Double(len - 1) + (v - Double(len - 1)) * 0.35 }
            capValPos = v
        }
    }
    func cdUp() {
        guard cdDragOn else { return }
        cdDragOn = false
        cdActive = 0
        guard cdMoved else { return }
        if cdAxis == 1 {
            let target = max(0, min(Double(capParams.count - 1), capDialPos.rounded()))
            cdSnap(\.capDialPos, target) { [weak self] in
                guard let self else { return }
                self.capValPos = Double(self.capSelOf(Int(target)))
            }
        } else {
            let i = max(0, min(capParams.count - 1, Int(capDialPos.rounded())))
            let len = capParams[i].vals.count
            let target = max(0, min(Double(len - 1), capValPos.rounded()))
            cdSnap(\.capValPos, target) { [weak self] in
                self?.capSel[i] = Int(target)   // 松手即生效
            }
        }
    }
    private func cdSnap(_ key: ReferenceWritableKeyPath<MTAppModel, Double>, _ target: Double, done: @escaping () -> Void) {
        cdTicker.run { [weak self] dt in
            guard let self else { return false }
            self[keyPath: key] += (target - self[keyPath: key]) * (1 - exp(-10 * dt))
            if abs(target - self[keyPath: key]) < 0.004 {
                self[keyPath: key] = target
                done()
                return false
            }
            return true
        }
    }
    // 录制中模拟:倍率连续变化 + 跟踪状态周期(设计稿公式)
    var recZ: Double { max(1, min(3, 1.6 + 0.9 * sin(recT * 0.35) + 0.4 * sin(recT * 0.13))) }
    var recState: String {
        let ph = recT.truncatingRemainder(dividingBy: 19)
        return ph < 15 ? "锁定" : ph < 17 ? "搜索中" : "未锁定"
    }
}
