// 【新 UI】状态机 + 手势物理 —— 设计稿 Component(state/raf 循环)的逐字移植。
// 物理常数全部照抄:横滑 420px/张、decay e^-3.2t、snap e^-11t、竖拉 320px、
// 转盘 54px/项 snap e^-10t、参数盘 120px/项 · 44px/值、统计层 340px、速度窗 90ms。

import SwiftUI
import QuartzCore
import os

// 【吸附确定化】真机日志:log stream --predicate 'subsystem == "com.zhichenli.FitTrackr-1"'
let mtDeckLog = Logger(subsystem: "com.zhichenli.FitTrackr-1", category: "deck.snap")

// 【掉帧卡·粒度】高频每帧量单独成对象:订阅方精确到"真的每帧要动的视图"。
// mo.pos 甩动时 BottomBar/DayHeader 不再整屏重建;mo.recT 走表时拍摄页只有 HUD 重建。
final class MTMotion: ObservableObject {
    @Published var pos: Double = 0          // 卡组位置(浮点,张)
    @Published var dialPos: Double = 0
    @Published var playT: Double = 0
    @Published var playFx: Double = 1
    @Published var ps: Double = 0
    @Published var capFx: Double = 1
    @Published var capDialPos: Double = 0
    @Published var capValPos: Double = 0
    @Published var recT: Double = 0
    // 录制中模拟:倍率连续变化 + 跟踪状态周期(设计稿公式)
    var recZ: Double { max(1, min(3, 1.6 + 0.9 * sin(recT * 0.35) + 0.4 * sin(recT * 0.13))) }
    var recState: String {
        let ph = recT.truncatingRemainder(dividingBy: 19)
        return ph < 15 ? "锁定" : ph < 17 ? "搜索中" : "未锁定"
    }
}
/// 竖拉/收拢(仅竖向手势期间高频)
final class MTPane: ObservableObject {
    @Published var g: Double = 0            // 0=堆叠 1=网格
    @Published var scrollY: Double = 0
}

final class MTAppModel: ObservableObject {
    let mo = MTMotion()
    let pane = MTPane()

    // ── 素材库 ──
    @Published var dayIdx = 0
    // ── 转盘(日期/分类)──
    @Published var dialOpen = false
    @Published var dialIn = false           // 入/出场 stagger 标志(SwiftUI 动画驱动)
    var dial0: Double = 0                   // 打开时的位置(背景视差 delta 用)
    // ── 单条回看 ──
    @Published var playIdx: Int? = nil
    @Published var playing = true
    @Published var playFxMode: Int = 0      // 1=in -1=out 0=稳态
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
    @Published var capFxMode: Int = 0
    @Published var recOn = false
    @Published var capCat = "力量训练"
    @Published var capTagOpen = false
    @Published var capTagIn = false
    @Published var capRes = "4K"
    @Published var capFps = 60
    @Published var capDialOpen = false
    @Published var capDialIn = false
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
        let pad = 24.0, gap = 12.0
        let colW = (Double(W) - pad * 2 - gap) / 2
        let cardH = (colW * 4.0 / 3.0).rounded()
        let rows = Double((n + 1) / 2)
        return max(0, 72 + rows * (cardH + gap) - gap + 124 - Double(Hd))
    }

    // 播放视图有效转场值(设计稿 playEff:in 用 eob(0.6) 回弹,out 反向)
    var playEff: Double {
        guard playIdx != nil else { return 0 }
        switch playFxMode {
        case 1: return MT.eob(mo.playFx, c1: 0.6)
        case -1: return 1 - MT.eob(mo.playFx, c1: 0.6)
        default: return 1
        }
    }
    var capEff: Double {
        guard capOpen else { return 0 }
        switch capFxMode {
        case 1: return mo.capFx
        case -1: return 1 - mo.capFx
        default: return 1
        }
    }

    // ── tickers(对应设计稿各 raf 槽)──
    private let gTicker = MTTicker()        // _graf: pane.g morph / 惯性滚动
    private let dialTicker = MTTicker()     // _draf
    private let playTicker = MTTicker()     // _praf: 播放进度
    private let psTicker = MTTicker()       // _psraf
    private let fxTicker = MTTicker()       // mo.playFx / mo.capFx 转场进度
    private let cdTicker = MTTicker()       // _cdraf: 参数盘 snap
    private let recTicker = MTTicker()      // 录制计时

    func stopAll() {
        [gTicker, dialTicker, playTicker, psTicker, fxTicker, cdTicker, recTicker].forEach { $0.stop() }
    }

    // ═══ 卡组横滑/竖拉(设计稿 dragStart/Move/End + _runPhysics/_runG/_runScroll)═══
    private var drag = false
    private var axis: Int = 0               // 0 未定 1 x 2 y 3 none
    private var x0: CGFloat = 0, y0: CGFloat = 0
    private var p0: Double = 0, g0: Double = 0, s0: Double = 0
    private var trail = MTTrail()

    func deckDown(_ p: CGPoint) {
        gTicker.stop()
        x0 = p.x; y0 = p.y
        p0 = mo.pos; g0 = pane.g; s0 = pane.scrollY
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
        if axis == 1 { mo.pos = p0 - Double(dx) / 420 }
        else if axis == 2 {
            if g0 >= 1 {
                let s = s0 - Double(dy)
                if s < 0 { pane.g = max(0, 1 + s / 320); pane.scrollY = 0 }
                else { pane.scrollY = min(maxScroll, s); pane.g = 1 }
            } else { pane.g = max(0, min(1, g0 - Double(dy) / 320)); pane.scrollY = 0 }
        }
    }
    /// 堆叠卡吸附位(顶层卡 minX;XCUITest 断言同源)
    var deckSnapX: Double {
        let cardW = min(0.60 * Double(H) * 9.0 / 16.0, Double(W) - 48)
        return (Double(W) - cardW) / 2
    }
    func deckUp(predicted: CGSize = .zero) {
        guard drag else { return }
        drag = false
        let v = trail.velocity
        if axis == 0 {  // 轻点:打开单条回看(设计稿网格命中公式)
            if pane.g < 0.5 { openPlay(Int(MT.wrap(mo.pos.rounded(), n))) }
            else if pane.g >= 0.999 {
                let relX = Double(x0), relY = Double(y0) + pane.scrollY
                let pad = 24.0, gap = 12.0
                let colW = (Double(W) - pad * 2 - gap) / 2
                let cardH = (colW * 4.0 / 3.0).rounded()
                let col = relX < pad + colW ? 0 : (relX > pad + colW + gap ? 1 : -1)
                let row = Int(floor((relY - 72) / (cardH + gap)))
                let i = row * 2 + col
                if col >= 0, row >= 0, i < n,
                   (relY - 72).truncatingRemainder(dividingBy: cardH + gap) <= cardH { openPlay(i) }
            }
            return
        }
        if axis == 1 {
            // 【吸附确定化】唯一收尾路径:predictedEnd 定目标索引 → spring 动画到精确 offset。
            // 不存在自由停靠:慢拖/快甩/停顿后松手,一律动画到整数索引。
            let cardW = min(0.60 * Double(H) * 9.0 / 16.0, Double(W) - 48)
            let thr = cardW * 0.3
            let pw = Double(predicted.width)
            let target: Double
            if pw < -thr { target = floor(mo.pos) + 1 }        // 左甩/左拖过阈 → 下一张
            else if pw > thr { target = ceil(mo.pos) - 1 }     // 右甩 → 上一张
            else { target = mo.pos.rounded() }                 // 未过阈 → 回弹最近
            mtDeckLog.info("deckUp pos=\(self.mo.pos, format: .fixed(precision: 3)) predictedW=\(pw, format: .fixed(precision: 1)) thr=\(thr, format: .fixed(precision: 1)) target=\(Int(target)) snapX=\(self.deckSnapX, format: .fixed(precision: 1))")
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { mo.pos = target }
        } else if axis == 2 {
            let vy = Double(v.y)
            if pane.g > 0.001 && pane.g < 0.999 {
                runG(vy < -350 ? 1 : vy > 350 ? 0 : (pane.g > 0.5 ? 1 : 0))
            } else if pane.g >= 0.999 && abs(vy) > 300 {
                runScroll(-vy)
            }
        }
    }
    private func runG(_ target: Double) {
        gTicker.run { [weak self] dt in
            guard let self else { return false }
            self.pane.g += (target - self.pane.g) * (1 - exp(-10 * dt))
            if abs(target - self.pane.g) < 0.004 {
                self.pane.g = target
                if target == 0 { self.pane.scrollY = 0 }
                return false
            }
            return true
        }
    }
    private func runScroll(_ v0: Double) {
        var sv = v0
        gTicker.run { [weak self] dt in
            guard let self else { return false }
            var s = self.pane.scrollY + sv * dt
            sv *= exp(-3.4 * dt)
            if s < 0 || s > self.maxScroll { s = max(0, min(self.maxScroll, s)); sv = 0 }
            self.pane.scrollY = s
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
        mo.dialPos = cur
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
        dy0 = p.y; dp0 = mo.dialPos; ddrag = true; dMoved = false
        dTrail.reset(p)
    }
    func dialMove(_ p: CGPoint) {
        guard ddrag else { return }
        dTrail.push(p)
        let dp = Double(dy0 - p.y) / 54
        if abs(dp) > 0.05 { dMoved = true }
        mo.dialPos = max(-0.4, min(Double(nItems) - 0.6, dp0 + dp))
    }
    func dialUp() {
        guard ddrag else { return }
        ddrag = false
        if !dMoved { closeDial(); return }
        var v = Double(-dTrail.velocity.y) / 54
        v = max(-14, min(14, v))
        var target = (mo.dialPos + v / 5).rounded()
        target = max(0, min(Double(nItems - 1), target))
        dialTicker.run { [weak self] dt in
            guard let self else { return false }
            self.mo.dialPos += (target - self.mo.dialPos) * (1 - exp(-10 * dt))
            if abs(target - self.mo.dialPos) < 0.004 {
                self.mo.dialPos = target
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { self.applyDial(Int(target)) }
                return false
            }
            return true
        }
    }
    private func applyDial(_ idx: Int) {
        if idx < cats.count {
            let name = cats[idx]
            dayIdx = name == "全部" ? 0 : max(0, days.firstIndex(where: { $0.cat == name }) ?? 0)
        } else { dayIdx = idx - cats.count }
        mo.pos = 0; pane.scrollY = 0
        closeDial()
    }

    // ═══ 单条回看 ═══
    func openPlay(_ i: Int) {
        playIdx = i; mo.playT = 0; playing = true; mo.ps = 0
        playFxMode = 1; mo.playFx = 0
        runFx(duration: 0.42) { [weak self] t in self?.mo.playFx = t } done: { [weak self] in self?.playFxMode = 0 }
        runPlayLoop()
    }
    func closePlay() {
        psTicker.stop()
        mo.ps = 0
        playFxMode = -1; mo.playFx = 0
        runFx(duration: 0.42) { [weak self] t in self?.mo.playFx = t } done: { [weak self] in
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
                var t = self.mo.playT + dt / max(1, secs)
                if t >= 1 { t = 0 }
                self.mo.playT = t
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
        guard p.y > 108 else { return }   // 【回扫A3】顶部返回带 44pt 内不启动统计层拖拽
        psY0 = p.y; ps0 = mo.ps; psDragOn = true; psMoved = false
        psTrail.reset(p)
    }
    func psMove(_ p: CGPoint) {
        guard psDragOn else { return }
        psTrail.push(p)
        let dy = p.y - psY0
        if abs(dy) > 7 { psMoved = true }
        if psMoved { mo.ps = max(0, min(1, ps0 - Double(dy) / 340)) }
    }
    func psUp() {
        guard psDragOn else { return }
        psDragOn = false
        guard psMoved else { return }
        let vy = Double(psTrail.velocity.y)
        let target: Double = vy < -300 ? 1 : vy > 300 ? 0 : (mo.ps > 0.5 ? 1 : 0)
        psTicker.run { [weak self] dt in
            guard let self else { return false }
            self.mo.ps += (target - self.mo.ps) * (1 - exp(-10 * dt))
            if abs(target - self.mo.ps) < 0.004 { self.mo.ps = target; return false }
            return true
        }
        // 点按判定窗结束后复位(togglePlay 用)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.psMoved = false }
    }
    // 复盘带擦洗
    func bandScrub(_ frac: Double, ended: Bool) {
        scrubbing = !ended
        mo.playT = max(0, min(1, frac))
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
        capOpen = true; recOn = false; mo.recT = 0
        capFxMode = 1; mo.capFx = 0
        runFx(duration: 0.3) { [weak self] t in self?.mo.capFx = t } done: { [weak self] in self?.capFxMode = 0 }
    }
    func closeCap() {
        if recOn { stopRec() }
        capFxMode = -1; mo.capFx = 0
        runFx(duration: 0.3) { [weak self] t in self?.mo.capFx = t } done: { [weak self] in
            guard let self else { return }
            self.capOpen = false; self.capFxMode = 0
            self.capDialOpen = false; self.capTagOpen = false
        }
    }
    func capSelOf(_ i: Int) -> Int { capSel[i] ?? capDefaults[i] }
    private func startRec() {
        recOn = true; mo.recT = 0; capTagOpen = false
        recTicker.run { [weak self] dt in
            guard let self, self.recOn else { return false }
            self.mo.recT += dt
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
        mo.capValPos = Double(capSelOf(Int(mo.capDialPos.rounded())))
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
        let i = max(0, min(capDefaults.count - 1, Int(mo.capDialPos.rounded())))
        mo.capValPos = Double(capDefaults[i])
    }
    // 两级手势:横滑=换参数,竖滑=调值
    private var cdDragOn = false, cdMoved = false
    private var cdX0: CGFloat = 0, cdY0: CGFloat = 0
    private var cdPh: Double = 0, cdPv: Double = 0
    private var cdAxis = 1
    func cdDown(_ p: CGPoint) {
        cdTicker.stop()
        cdX0 = p.x; cdY0 = p.y
        cdPh = mo.capDialPos; cdPv = mo.capValPos
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
            mo.capDialPos = max(-0.3, min(Double(capParams.count) - 0.7, cdPh - dx / 120))
        } else {
            let len = capParams[max(0, min(capParams.count - 1, Int((mo.capDialPos).rounded())))].vals.count
            var v = cdPv - dy / 44
            if v < 0 { v *= 0.35 }
            else if v > Double(len - 1) { v = Double(len - 1) + (v - Double(len - 1)) * 0.35 }
            mo.capValPos = v
        }
    }
    func cdUp() {
        guard cdDragOn else { return }
        cdDragOn = false
        cdActive = 0
        guard cdMoved else { return }
        if cdAxis == 1 {
            let target = max(0, min(Double(capParams.count - 1), mo.capDialPos.rounded()))
            cdSnap(\.capDialPos, target) { [weak self] in
                guard let self else { return }
                self.mo.capValPos = Double(self.capSelOf(Int(target)))
            }
        } else {
            let i = max(0, min(capParams.count - 1, Int(mo.capDialPos.rounded())))
            let len = capParams[i].vals.count
            let target = max(0, min(Double(len - 1), mo.capValPos.rounded()))
            cdSnap(\.capValPos, target) { [weak self] in
                self?.capSel[i] = Int(target)   // 松手即生效
            }
        }
    }
    private func cdSnap(_ key: ReferenceWritableKeyPath<MTMotion, Double>, _ target: Double, done: @escaping () -> Void) {
        cdTicker.run { [weak self] dt in
            guard let self else { return false }
            self.mo[keyPath: key] += (target - self.mo[keyPath: key]) * (1 - exp(-10 * dt))
            if abs(target - self.mo[keyPath: key]) < 0.004 {
                self.mo[keyPath: key] = target
                done()
                return false
            }
            return true
        }
    }
}
