// 【新 UI】素材库屏 —— 卡组(堆叠⇄网格连续变形)+ 日期弧形转盘 + 底部收拢栏。
// 全部几何照抄设计稿:_baseCard 五档插值、420px/张横滑、320px 竖拉、
// 网格 2 列 pad20 gap12 高 1.45w、转盘 u=gd*0.28 弧、底部 6 层糊化(此处 Material 近似)。

import SwiftUI

// ── 主题背景(共用:素材库/设置/回看;深蓝低饱和 + 48s 漂移)──
struct MTThemeBackground: View {
    var parallax: CGSize = .zero
    @State private var drift = false
    var body: some View {
        GeometryReader { geo in
            ZStack {
                AsyncImage(url: mtThemeURL) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color(red: 0.03, green: 0.05, blue: 0.10)
                }
                // 设计稿 filter: saturate(.5) sepia(.4) hue-rotate(178°) saturate(1.6) brightness(.48) 的近似
                .saturation(0.55)
                .colorMultiply(Color(red: 0.42, green: 0.58, blue: 0.82))
                .brightness(-0.06)
                .frame(width: geo.size.width * 1.2, height: geo.size.height * 1.12)
                .scaleEffect(1.08)
                .offset(x: drift ? -geo.size.width * 0.016 : 0, y: drift ? geo.size.height * 0.009 : 0)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .onAppear { withAnimation(.easeInOut(duration: 24).repeatForever(autoreverses: true)) { drift = true } }
                VStack {
                    Spacer()
                    LinearGradient(colors: [Color(red: 0.008, green: 0.024, blue: 0.07).opacity(0.55), .clear],
                                   startPoint: .bottom, endPoint: UnitPoint(x: 0.5, y: 0.18))
                        .frame(height: geo.size.height * 0.45)
                }
            }
            .offset(parallax)
            .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.9), value: parallax)
        }
        .ignoresSafeArea()
        .clipped()
    }
}

// ── 卡片轨迹带(下沿对齐,厚度=倍率,跟丢=断口)──
struct MTTrackline: View {
    let parts: [MTSeg]
    var thick: Double = 1.75    // 卡上 1.75/级;回看页 4/级
    var base: Double = 1        // lit 基础厚度
    private func segColor(_ k: MTSegKind) -> Color {
        switch k {
        case .lit: return Color.white.opacity(0.45)
        case .dark: return Color.white.opacity(0.2)
        case .gap: return Color.clear
        }
    }
    private func segHeight(_ sg: MTSeg) -> CGFloat {
        switch sg.kind {
        case .lit: return CGFloat(base + (sg.zoom - 1) * thick)
        case .dark: return CGFloat(base)
        case .gap: return 0
        }
    }
    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, sg in
                    Rectangle()
                        .fill(segColor(sg.kind))
                        .frame(width: geo.size.width * CGFloat(sg.frac), height: segHeight(sg))
                }
            }
            .frame(height: geo.size.height, alignment: .bottom)
        }
    }
}

// ── 单张卡几何(设计稿 deck map 的直译)──
struct MTCardGeom {
    var x: Double, y: Double, w: Double, h: Double
    var z: Double, rot: Double, dim: Double, op: Double
    var hidden = false
}

func mtBaseCard(_ p: Int) -> (tx: Double, sc: Double, dim: Double) {
    let tx = [0.0, 22, 40, 54, 64], sc = [1.0, 0.955, 0.915, 0.88, 0.862], dim = [0.0, 0.24, 0.4, 0.52, 0.6]
    let i = max(0, min(p, 4))
    return (tx[i], sc[i], dim[i])
}
func mtLerpBase(_ d: Double) -> (tx: Double, sc: Double, dim: Double) {
    let f = Int(floor(d)), r = d - Double(f)
    let a = mtBaseCard(f), b = mtBaseCard(f + 1)
    return (a.tx + (b.tx - a.tx) * r, a.sc + (b.sc - a.sc) * r, a.dim + (b.dim - a.dim) * r)
}

func mtDeckGeom(i: Int, n: Int, posW: Double, g: Double, scrollY: Double,
                playIdx: Int?, playEff: Double, W: Double, Hd: Double) -> MTCardGeom {
    var d = MT.wrap(Double(i) - posW, n)
    let thr = Double(n) - (n >= 4 ? 1.2 : 0.6)
    if d > thr { d -= Double(n) }
    var geom = MTCardGeom(x: 0, y: 0, w: 0, h: 0, z: 0, rot: 0, dim: 0, op: 1)
    if g < 0.001 && (d > 3.4 || d < -1.2) { geom.hidden = true; return geom }
    // 堆叠端
    let visW = W - 64, Hs = Hd - 100
    var tx = 0.0, sc = 1.0, rot = 0.0, dim = 0.0, z = 100.0, op = 1.0
    if d < 0 { tx = d * 420; rot = d * 8; z = 110 }
    else {
        let b = mtLerpBase(min(d, 4))
        tx = b.tx; sc = b.sc; dim = b.dim
        z = 100 - (min(d, 4) * 10).rounded()
    }
    if d > 2.6 { op = max(0, 1 - (d - 2.6) / 0.8) }
    let sx = 20 + tx + visW * (1 - sc) / 2, sy = Hs * (1 - sc) / 2
    let sw = visW * sc, sh = Hs * sc
    // 网格端
    let pad = 20.0, gap = 12.0
    let colW = (W - pad * 2 - gap) / 2, cardH = (colW * 1.45).rounded()
    let col = Double(i % 2), row = Double(i / 2)
    let gx = pad + col * (colW + gap), gy = 72 + row * (cardH + gap) - scrollY
    func L(_ a: Double, _ b: Double) -> Double { a + (b - a) * g }
    let x = L(sx, gx), y = L(sy, gy), w = L(sw, colW), h = L(sh, cardH)
    if g >= 0.999 && (y + h < -24 || y > Hd + 24) { geom.hidden = true; return geom }
    // 转场:被选卡消隐,其余散开淡出
    var fx = 0.0, fy = 0.0, fop = 1.0
    if playEff > 0.001 {
        if i == playIdx { fop = 0 }
        else {
            fx = (d < 0 ? -1 : 1) * 90 * playEff * (1 - g)
            fy = (i % 2 == 0 ? -1 : 1) * 40 * playEff * g
            fop = 1 - playEff
        }
    }
    geom.x = x + fx; geom.y = y + fy; geom.w = w; geom.h = h
    geom.z = z; geom.rot = rot * (1 - g); geom.dim = dim * (1 - g)
    geom.op = L(op, 1) * fop
    return geom
}

// ── 素材库层 ──
struct MTLibraryView: View {
    @ObservedObject var m: MTAppModel

    var body: some View {
        let g = m.g
        let clips = m.clips
        let posW = MT.wrap(m.pos, m.n)
        let dialDelta = m.dialOpen ? max(-24, min(24, (m.dial0 - m.dialPos) * 4)) : 0
        let parallax = CGSize(
            width: -30 * sin(2 * .pi * posW / Double(max(1, m.n))) * (1 - g),
            height: dialDelta - 10 * g - min(34, m.scrollY * 0.08))

        ZStack(alignment: .topLeading) {
            MTThemeBackground(parallax: parallax)

            // 顶部:日期行(serif,40→22px)+ 进度条
            dayHeader
                .zIndex(3)

            // 卡组区(top 118 → 底)
            deck(clips: clips, g: g)
                .frame(width: m.W, height: m.Hd)
                .offset(y: 118)
                .zIndex(2)

            // 左缘长按热区 → 转盘
            Color.clear
                .frame(width: 22)
                .frame(maxHeight: .infinity)
                .padding(.top, 120).padding(.bottom, 120)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.35) { m.openDial() }
                .zIndex(6)

            if m.dialOpen { MTDialView(m: m).zIndex(8) }
        }
    }

    private var dayHeader: some View {
        let g = m.g
        let fs = 40 - 18 * g
        let s = fs / 40
        let hh = max(1.6, 3 * s)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                // 可点提示短横
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 14 * s, height: hh)
                    .offset(x: m.dialOpen ? -6 : 0, y: -0.26 * fs)
                    .opacity(m.dialOpen ? 0 : 1)
                    .animation(.easeOut(duration: 0.2), value: m.dialOpen)
                Text(m.day.d)
                    .font(.system(size: fs, design: .serif))
                Text("\(m.day.wd) · \(m.day.cat) · \(m.day.n) 条")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.72))
            }
            .padding(.leading, 26).padding(.trailing, 26)
            .padding(.top, 54)
            .contentShape(Rectangle())
            .onTapGesture { m.openDial() }
            // 进度条(top 112,仅堆叠端)
            GeometryReader { _ in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.13))
                    Capsule()
                        .fill(Color.white.opacity(0.7))
                        .frame(width: max(0, (m.W - 64) / CGFloat(m.n)))
                        .offset(x: (m.W - 64) * CGFloat(posWFrac))
                }
            }
            .frame(width: m.W - 64, height: 2)
            .padding(.leading, 20)
            .padding(.top, 58 - 40 * (1 - g) * 0) // top 112 − (54+行高):以下方 offset 对齐
            .opacity(1 - g)
        }
        .mtShadow()
    }
    private var posWFrac: Double { MT.wrap(m.pos, m.n) / Double(max(1, m.n)) }

    private func deck(clips: [MTClip], g: Double) -> some View {
        let playEff = m.playEff
        return ZStack(alignment: .topLeading) {
            ForEach(0..<m.n, id: \.self) { i in
                let geom = mtDeckGeom(i: i, n: m.n, posW: MT.wrap(m.pos, m.n), g: g,
                                      scrollY: m.scrollY, playIdx: m.playIdx, playEff: playEff,
                                      W: Double(m.W), Hd: Double(m.Hd))
                if !geom.hidden {
                    card(clip: clips[i], geom: geom, g: g)
                }
            }
        }
        .mask(deckMask(g: g))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { v in
                    if v.translation == .zero { m.deckDown(v.startLocation) }
                    m.deckMove(v.location)
                }
                .onEnded { _ in m.deckUp() }
        )
    }

    @ViewBuilder private func deckMask(g: Double) -> some View {
        if g < 0.02 {
            Rectangle()
        } else {
            // smootherstep 顶部渐隐 64px(设计稿 8 段)
            LinearGradient(stops: (0...8).map { t in
                let f = MT.ss(Double(t) / 8)
                return Gradient.Stop(color: .black.opacity(1 - (1 - f) * g),
                                     location: Double(t) * 8 / Double(m.Hd))
            }, startPoint: .top, endPoint: .bottom)
        }
    }

    private func card(clip: MTClip, geom: MTCardGeom, g: Double) -> some View {
        func L(_ a: Double, _ b: Double) -> Double { a + (b - a) * g }
        return ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(red: 0.078, green: 0.078, blue: 0.078))
            AsyncImage(url: clip.imgURL) { img in
                img.resizable().scaledToFill()
            } placeholder: { Color(red: 0.078, green: 0.078, blue: 0.078) }
                .saturation(0.72).brightness(-0.1)
                .frame(width: geom.w, height: geom.h)
                .clipped()
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .bottom, endPoint: UnitPoint(x: 0.5, y: 0.66))
                .frame(height: geom.h * 0.34)
                .frame(maxHeight: .infinity, alignment: .bottom)
            Text(clip.dur)
                .font(.system(size: L(12, 10)))
                .foregroundColor(.white.opacity(0.72))
                .monospacedDigit()
                .padding(.trailing, L(20, 12)).padding(.bottom, L(34, 24))
            MTTrackline(parts: clip.parts)
                .frame(height: 5)
                .padding(.horizontal, L(16, 10))
                .padding(.bottom, L(20, 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            Color.black.opacity(geom.dim)
        }
        .frame(width: geom.w, height: geom.h)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .rotationEffect(.degrees(geom.rot))
        .opacity(geom.op)
        .position(x: geom.x + geom.w / 2, y: geom.y + geom.h / 2)
        .zIndex(geom.z)
    }
}

// ── 日期/分类弧形转盘 ──
struct MTDialView: View {
    @ObservedObject var m: MTAppModel

    var body: some View {
        let gposC = m.dialPos + (m.dialPos >= Double(m.cats.count) ? 0.45 :
                    m.dialPos > Double(m.cats.count - 1) ? (m.dialPos - Double(m.cats.count - 1)) * 0.45 : 0)
        ZStack(alignment: .topLeading) {
            Color(red: 0.008, green: 0.016, blue: 0.04).opacity(0.18)
            MTFeatherBlur(center: UnitPoint(x: 0, y: 0.46), rx: 0.85, ry: 0.8)
                .frame(width: 340)
                .opacity(m.dialIn ? 1 : 0)
            // 橙色游标
            Capsule().fill(MT.accent)
                .frame(width: 9, height: 2)
                .position(x: 44 + 4.5, y: m.H * 0.46)
                .opacity(m.dialIn ? 1 : 0)
            ForEach(0..<m.nItems, id: \.self) { i in
                dialItem(i: i, gposC: gposC)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if v.translation == .zero { m.dialDown(v.startLocation) }
                    m.dialMove(v.location)
                }
                .onEnded { _ in m.dialUp() }
        )
    }

    @ViewBuilder private func dialItem(i: Int, gposC: Double) -> some View {
        let gd = Double(i) + (i >= m.cats.count ? 0.45 : 0) - gposC
        if abs(gd) <= 3.8 {
            let u = gd * 0.28
            let y = 230 * sin(u)
            let scF = [1.0, 0.6, 0.35, 0.18, 0.12], opF = [1.0, 0.55, 0.26, 0.09, 0]
            let a = min(3.0, floor(abs(gd))), r = min(1.0, abs(gd) - a)
            let fi = Int(a)
            let sc = scF[fi] + (scF[fi + 1] - scF[fi]) * r
            let op = opF[fi] + (opF[fi + 1] - opF[fi]) * r
            let focus = max(0, 1 - abs(gd) * 2)
            let isCat = i < m.cats.count
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                if isCat {
                    Text(m.cats[i]).font(.system(size: 25))
                } else {
                    let dd = m.days[i - m.cats.count]
                    Text(dd.d).font(.system(size: 42, design: .serif))
                    if focus > 0.05 {
                        Text("\(dd.cat) · \(dd.n) 条")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.7))
                            .opacity(focus)
                    }
                }
            }
            .foregroundColor(.white.opacity(0.55 + 0.45 * focus))
            .mtShadow()
            .scaleEffect(sc * (m.dialIn ? 1 : 0.9), anchor: .leading)
            .opacity(op * (m.dialIn ? 1 : 0))
            .animation(.spring(response: 0.26, dampingFraction: 0.7).delay(abs(gd) * 0.03), value: m.dialIn)
            .position(x: 64 + 130 * (cos(u) - 1) + 60, y: m.H * 0.46 + y)
            .allowsHitTesting(false)
        }
    }
}

// ── 底部收拢栏 + 糊化渐隐(素材库/设置共用)──
struct MTBottomBar: View {
    @ObservedObject var m: MTAppModel
    @State private var breath = false

    var body: some View {
        let k = m.g * max(0, min(1, m.scrollY / 120))  // 收拢进度
        ZStack(alignment: .bottom) {
            // 糊化 + 压暗(设计稿 6 层近似为 Material 羽化 + 精确 scrim)
            bottomFade(k: k)
                .frame(height: 110)
                .allowsHitTesting(false)
            HStack {
                tab(label: "素材库", active: !m.setOpen, k: k) {
                    LibGlyph()
                } action: { m.setOpen = false }
                Spacer()
                shutter
                Spacer()
                tab(label: "设置", active: m.setOpen, k: k) {
                    SetGlyph()
                } action: { m.setOpen = true }
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 14)
            .scaleEffect(1 - 0.16 * k, anchor: .bottom)
            .animation(.easeOut(duration: 0.15), value: k)
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func bottomFade(k: Double) -> some View {
        func lk(_ a: Double, _ b: Double) -> Double { a + (b - a) * k }
        return ZStack {
            MTFeatherBlur(center: .bottom, rx: lk(3.0, 1.04), ry: 1.05, inner: 0.2, dim: 0)
            // 精确移植的压暗 scrim
            EllipticalGradient(stops: [
                .init(color: .black.opacity(0.96), location: 0),
                .init(color: .black.opacity(0.82), location: 0.18),
                .init(color: .black.opacity(0.52), location: 0.42),
                .init(color: .black.opacity(0.24), location: 0.64),
                .init(color: .black.opacity(0.08), location: 0.82),
                .init(color: .clear, location: 0.96),
            ], center: .bottom, startRadiusFraction: 0, endRadiusFraction: 0.5)
            .scaleEffect(x: lk(3.2, 1.2) * 2, y: 2.1, anchor: .bottom)
        }
        .clipped()
    }

    private var shutter: some View {
        Button { m.openCap() } label: {
            ZStack {
                Circle()
                    .fill(Color(red: 0.04, green: 0.055, blue: 0.094).opacity(0.3))
                    .background(Circle().fill(.ultraThinMaterial))
                    .overlay(Circle().strokeBorder(MT.accent.opacity(0.95), lineWidth: 1))
                Circle()
                    .fill(MT.accent)
                    .frame(width: 19, height: 19)
                    .scaleEffect(breath ? 1.14 : 1)
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .clipShape(Circle())
        .onAppear { withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) { breath = true } }
    }

    private func tab(label: String, active: Bool, k: Double,
                     @ViewBuilder icon: () -> some View, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                icon().frame(width: 25, height: 25)
                Text(label)
                    .font(.system(size: 13))
                    .opacity(1 - k)
                    .padding(.top, CGFloat(-14 * k))
            }
            .foregroundColor(active ? .white : .white.opacity(0.5))
        }
        .buttonStyle(.plain)
    }
}

// 素材库图标(设计稿手绘 svg:圆角矩形 + 侧条)
private struct LibGlyph: View {
    var body: some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 4).strokeBorder(lineWidth: 1.6)
                .frame(width: 14, height: 17)
            Capsule().frame(width: 2.4, height: 9.5).opacity(0.7)
        }
    }
}
// 设置图标(两线 + 一圆)
private struct SetGlyph: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Capsule().frame(width: 18, height: 1.6)
            ZStack(alignment: .leading) {
                Capsule().frame(width: 18, height: 1.6)
                Circle().strokeBorder(lineWidth: 1.6).frame(width: 6.5, height: 6.5)
                    .background(Circle().fill(Color.black.opacity(0.6)))
                    .offset(x: 3)
            }
        }
    }
}
