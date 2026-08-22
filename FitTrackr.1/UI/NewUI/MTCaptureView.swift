// 【新 UI】拍摄屏 —— 顶部三 chip、录制 HUD、双轴参数弧盘(iPhone 倍率盘语言)。
// ★本卡为设计稿的模拟行为:预览是静态图 + 调色(EV/白平衡实时作用),录制读数是模拟公式;
//   接真相机管线(CameraEngine/TrackingController)是后续任务卡。
// 几何照抄:弧 u=gd*0.34 R290、值列 44px/项 bottom 218、盘 120px/项、面板 h290 r22 泡泡弹出。

import SwiftUI

struct MTCaptureView: View {
    @ObservedObject var m: MTAppModel
    @ObservedObject var mo: MTMotion
    @State private var breath = false
    @State private var cdBegan = false

    var body: some View {
        let chrome = m.recOn ? 0.0 : 1.0
        ZStack(alignment: .topLeading) {
            preview

            // 顶部:画质 chip(左)· 分类 chip(中)· 恢复默认(右)
            qualityChip
                .position(x: 26 + 46, y: 58 + 13)
                .opacity(chrome)
                .allowsHitTesting(!m.recOn)
            Button { m.openCapTag() } label: {
                Text(m.capCat)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.85))
                    .mtChip()
            }
            .buttonStyle(.plain)
            .position(x: m.W / 2, y: 58 + 13)
            .opacity(chrome)
            .allowsHitTesting(!m.recOn)
            if anyNonDefault {
                Button { m.capReset() } label: {
                    Text("恢复默认")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                        .mtChip()
                }
                .buttonStyle(.plain)
                .position(x: m.W - 26 - 40, y: 58 + 13)
                .opacity(chrome)
                .allowsHitTesting(!m.recOn)
            }

            // 录制 HUD:中央计时 · 左镜头读数 · 右倍率+状态
            recHud

            // 取景框角标
            frameCorners
                .opacity(m.recOn ? 0.45 : (m.capDialOpen ? 0.6 : 1))
                .animation(.easeOut(duration: 0.3), value: m.recOn)
                .allowsHitTesting(false)

            // 底部:返回 · 快门 · 参数入口
            Button { m.closeCap() } label: {
                MTChevron().stroke(style: .init(lineWidth: 1.5, lineCap: .round))
                    .frame(width: 9, height: 17)
                    .padding(10)
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(0.68))
            .position(x: 38 + 14, y: m.H - 36 - 18)
            .opacity(chrome)
            .allowsHitTesting(!m.recOn)
            .zIndex(6)

            shutter.zIndex(6)

            Button { m.openCapDial() } label: {
                ParamGlyph().frame(width: 23, height: 23).padding(10)
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(0.68))
            .position(x: m.W - 38 - 14, y: m.H - 34 - 20)
            .opacity(chrome)
            .allowsHitTesting(!m.recOn)
            .zIndex(6)

            if m.capTagOpen { capTagPicker.zIndex(4) }
            if m.capDialOpen { capDial.zIndex(5) }
        }
        .background(Color.black)
        .opacity(m.capEff)
        .ignoresSafeArea()
    }

    private var anyNonDefault: Bool {
        m.capParams.indices.contains { m.capSelOf($0) != m.capDefaults[$0] }
    }

    // 预览:静态图 + EV/白平衡实时调色(设计稿模拟;真相机接线为后续卡)
    private var preview: some View {
        let evB = [0.62, 0.8, 1.0, 1.22, 1.45]
        let cIdx = max(0, min(m.capParams.count - 1, Int(mo.capDialPos.rounded())))
        var ev = evB[m.capSelOf(2)]
        if cIdx == 2 && m.capDialOpen {
            let c = max(0.0, min(4.0, mo.capValPos))
            let f = Int(floor(c)), r = c - Double(f)
            ev = evB[f] + (evB[min(4, f + 1)] - evB[f]) * r
        }
        let wb = m.capSelOf(1)
        let hue: Double = [0, -6, -14, 12][wb]
        let sat: Double = [1, 1.08, 1.12, 0.92][wb]
        let b = 0.85 * ev   // 设计稿 brightness(0.85·ev),乘法
        return GeometryReader { geo in
            Image(uiImage: MTThemeArt.image)
                .resizable().scaledToFill()
                .saturation(0.72 * sat)
                .hueRotation(.degrees(hue))
                .overlay(Color.black.opacity(b < 1 ? 1 - b : 0))      // ≤1:精确乘法
                .brightness(b > 1 ? (b - 1) * 0.5 : 0)                // >1:无乘法对应,轻加法近似
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
        }
        .ignoresSafeArea()
    }

    private var qualityChip: some View {
        HStack(spacing: 4) {
            Button { m.capRes = m.capRes == "4K" ? "1080" : "4K" } label: {
                Text(m.capRes == "4K" ? "4K" : "1080")
                    .frame(width: m.capRes == "4K" ? 18 : 30, alignment: .leading)
                    .animation(.easeOut(duration: 0.15), value: m.capRes)
            }.buttonStyle(.plain)
            Text("·").opacity(0.55)
            Button { m.capFps = m.capFps == 60 ? 30 : 60 } label: {
                Text("\(m.capFps)").frame(width: 15, alignment: .leading)
            }.buttonStyle(.plain)
        }
        .font(.system(size: 12)).monospacedDigit()
        .foregroundColor(.white.opacity(0.85))
        .mtChip()
    }

    private var recHud: some View {
        let rs = Int(mo.recT)
        let showAux = m.recOn && !m.capDialOpen
        return ZStack(alignment: .topLeading) {
            Text("\(rs / 60):" + String(format: "%02d", rs % 60))
                .font(.system(size: 12)).monospacedDigit()
                .foregroundColor(.white.opacity(0.85))
                .mtShadow(false)
                .frame(width: m.W)
                .position(x: m.W / 2, y: 62 + 8)
                .opacity(m.recOn ? 1 : 0)
            ZStack(alignment: .leading) {
                Text("超广角").opacity(mo.recZ < 1.4 ? 1 : 0)
                Text("主摄").opacity(mo.recZ < 1.4 ? 0 : 1)
            }
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.85))
            .mtShadow(false)
            .animation(.easeOut(duration: 0.2), value: mo.recZ < 1.4)
            .position(x: 26 + 30, y: 62 + 8)
            .opacity(showAux ? 1 : 0)
            HStack(spacing: 6) {
                Text(String(format: "%.1fx", mo.recZ))
                Text(mo.recState)
                    .foregroundColor(mo.recState == "锁定" ? MT.accent : .white.opacity(0.85))
            }
            .font(.system(size: 12)).monospacedDigit()
            .foregroundColor(.white.opacity(0.85))
            .mtShadow(false)
            .position(x: m.W - 26 - 40, y: 62 + 8)
            .opacity(showAux ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.3), value: m.recOn)
        .allowsHitTesting(false)
    }

    private var frameCorners: some View {
        GeometryReader { geo in
            let x0 = geo.size.width * 0.19, x1 = geo.size.width * 0.81
            let y0 = geo.size.height * 0.30, y1 = geo.size.height * 0.68
            ForEach(0..<4, id: \.self) { i in
                let right = i % 2 == 1, bottom = i >= 2
                CornerBracket(right: right, bottom: bottom)
                    .stroke(Color.white.opacity(0.6), lineWidth: 1.5)
                    .frame(width: 16, height: 16)
                    .position(x: (right ? x1 - 8 : x0 + 8), y: (bottom ? y1 - 8 : y0 + 8))
            }
        }
    }

    private var shutter: some View {
        Button { m.toggleRec() } label: {
            ZStack {
                Circle()
                    .fill(Color(red: 0.04, green: 0.055, blue: 0.094).opacity(0.25))
                    .background(Circle().fill(.ultraThinMaterial))
                    .overlay(Circle().strokeBorder(MT.accent.opacity(0.95), lineWidth: 1))
                RoundedRectangle(cornerRadius: m.recOn ? 4 : 9.5)
                    .fill(MT.accent)
                    .frame(width: m.recOn ? 16 : 19, height: m.recOn ? 16 : 19)
                    .scaleEffect(m.recOn ? 1 : (breath ? 1.14 : 1))
                    .animation(.easeOut(duration: 0.25), value: m.recOn)
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .clipShape(Circle())
        .position(x: m.W / 2, y: m.H - 54 - 26)
        .onAppear { withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) { breath = true } }
    }

    // 拍前分类直排选择(左上,复用单条页形态)
    private var capTagPicker: some View {
        let names = m.tagNames
        let curI = max(0, names.firstIndex(of: m.capCat) ?? 0)
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001).onTapGesture { m.closeCapTag() }
            MTFeatherBlur(center: UnitPoint(x: 0.12, y: 0.4), rx: 0.9, ry: 0.75)
                .frame(width: 320, height: 380)
                .offset(x: -40, y: 40)
                .opacity(m.capTagIn ? 1 : 0)
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                    Button { m.capCat = name; m.closeCapTag() } label: {
                        HStack(spacing: 10) {
                            Text(name).font(.system(size: name == m.capCat ? 18 : 16))
                                .foregroundColor(name == m.capCat ? .white : .white.opacity(0.6))
                            if name == m.capCat { Capsule().fill(MT.accent).frame(width: 9, height: 2) }
                        }
                    }
                    .buttonStyle(.plain)
                    .mtShadow()
                    .scaleEffect(m.capTagIn ? 1 : 0.9, anchor: .leading)
                    .opacity(m.capTagIn ? 1 : 0)
                    .animation(.spring(response: 0.26, dampingFraction: 0.7).delay(Double(abs(i - curI)) * 0.03), value: m.capTagIn)
                }
            }
            .padding(.leading, 30)
            .padding(.top, 120)
        }
        .ignoresSafeArea()
    }

    // ── 双轴参数弧盘 ──
    private var capDial: some View {
        let pos = mo.capDialPos
        let cIdx = max(0, min(m.capParams.count - 1, Int(pos.rounded())))
        let hOff = abs(pos - Double(cIdx))
        let vPos = mo.capValPos
        return ZStack(alignment: .bottomLeading) {
            Color.black.opacity(0.001)
            // 浮动玻璃面板(泡泡弹出,原点=参数入口图标)
            glassPanel
            // 面板裁切容器内的内容
            ZStack(alignment: .bottomLeading) {
                ForEach(m.capParams.indices, id: \.self) { i in
                    arcItem(i: i, pos: pos)
                }
                valueColumn(cIdx: cIdx, vPos: vPos, hOff: hOff)
                // 橙色游标
                Capsule().fill(MT.accent)
                    .frame(width: 9, height: 2)
                    .position(x: m.W / 2 - 56, y: m.H - 226 - 1)
                    .opacity((m.capDialIn ? 1 : 0) * (1 - min(1, hOff * 2)))
                ticks(cIdx: cIdx, vPos: vPos, pos: pos)
            }
            .frame(width: m.W, height: m.H)
            .mask(
                RoundedRectangle(cornerRadius: 22)
                    .frame(width: m.W - 16, height: 290)
                    .position(x: m.W / 2, y: m.H - 8 - 145)
            )
            .scaleEffect(m.capDialIn ? 1 : 0.6, anchor: panelAnchor)
            .opacity(m.capDialIn ? 1 : 0)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !cdBegan { cdBegan = true; m.cdDown(v.startLocation) }
                    m.cdMove(v.location)
                }
                .onEnded { _ in cdBegan = false; m.cdUp() }
        )
    }

    private var panelAnchor: UnitPoint {
        UnitPoint(x: (Double(m.W) - 42) / Double(m.W), y: 0.85)
    }

    private var glassPanel: some View {
        RoundedRectangle(cornerRadius: 22)
            .fill(.ultraThinMaterial)
            .overlay(
                LinearGradient(stops: [
                    .init(color: .white.opacity(0.08), location: 0),
                    .init(color: .clear, location: 60 / 290.0),
                    .init(color: .clear, location: 250 / 290.0),
                    .init(color: .black.opacity(0.06), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 22))
            )
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .frame(width: m.W - 16, height: 290)
            .position(x: m.W / 2, y: m.H - 8 - 145)
            .scaleEffect(m.capDialIn ? 1 : 0.6, anchor: panelAnchor)
            .opacity(m.capDialIn ? 1 : 0)
            .allowsHitTesting(false)
    }

    // 第一级:底部弧形轮盘(弧心在屏幕下方外侧)
    @ViewBuilder private func arcItem(i: Int, pos: Double) -> some View {
        let gd = Double(i) - pos
        if abs(gd) <= 2.3 {
            let u = gd * 0.34
            let sc = max(0.4, 1 - 0.15 * abs(gd))
            let op = abs(gd) <= 1 ? max(0.4, 1 - 0.3 * abs(gd)) : max(0, 0.7 - 0.7 * (abs(gd) - 1))
            let center = abs(gd) < 0.5
            VStack(spacing: 2) {
                Text(m.capParams[i].name)
                    .font(.system(size: 19, weight: center ? .medium : .regular))
                    .foregroundColor(center ? .white : .white.opacity(0.7))
                Text(m.capParams[i].vals[m.capSelOf(i)])
                    .font(.system(size: 11)).opacity(0.5)
            }
            .mtShadow(false)
            .scaleEffect(sc, anchor: .bottom)
            .opacity(op)
            .position(x: m.W / 2 + 290 * sin(u),
                      y: m.H - (130 - 290 * (1 - cos(u))) - 20)
            .allowsHitTesting(false)
        }
    }

    // 第二级:当前参数的值列(中心=选中)
    @ViewBuilder private func valueColumn(cIdx: Int, vPos: Double, hOff: Double) -> some View {
        let p = m.capParams[cIdx]
        ForEach(p.vals.indices, id: \.self) { j in
            let vd = Double(j) - vPos
            if abs(vd) <= 1.4 {
                let sc = max(0.4, 1 - 0.15 * abs(vd))
                let fade = 1 - hOff * 2 > 0 ? 1 - hOff * 2 : 0
                let op = max(0.4, 1 - 0.6 * abs(vd)) * fade
                let focus = max(0, 1 - abs(vd) * 2)
                let dsc = focus > 0.05 && j < p.descs.count ? p.descs[j] : ""
                HStack(alignment: .lastTextBaseline, spacing: 12) {
                    Text(p.vals[j])
                        .font(.system(size: 16)).monospacedDigit()
                        .foregroundColor(.white.opacity(0.55 + 0.45 * focus))
                    if !dsc.isEmpty {
                        Text(dsc)
                            .font(.system(size: 8))
                            .foregroundColor(.white)
                            .opacity(0.45 * focus)
                            .lineLimit(1)
                            .frame(maxWidth: 96)
                            .fixedSize()
                    }
                }
                .mtShadow(false)
                .scaleEffect(sc)
                .opacity(op)
                .position(x: m.W / 2 + (dsc.isEmpty ? 0 : 50), y: m.H - (218 - vd * 36) - 8)
                .allowsHitTesting(false)
            }
        }
    }

    // 拖动时浮出的刻度(横/竖各自轴激活时)
    @ViewBuilder private func ticks(cIdx: Int, vPos: Double, pos: Double) -> some View {
        let vOn = m.cdActive == 2 ? 1.0 : 0.0
        let hOn = m.cdActive == 1 ? 1.0 : 0.0
        ForEach(m.capParams[cIdx].vals.indices, id: \.self) { j in
            let vd = Double(j) - vPos
            if abs(vd) <= 3.4 && abs(vd) >= 0.5 {
                Rectangle().fill(Color.white.opacity(0.25))
                    .frame(width: 8, height: 1)
                    .position(x: m.W / 2 - 56, y: m.H - (226 - vd * 36) - 1)
                    .opacity(vOn)
                    .animation(.easeOut(duration: 0.3), value: vOn)
            }
        }
        ForEach(m.capParams.indices, id: \.self) { i in
            let gd = Double(i) - pos
            if abs(gd) <= 2.3 {
                let u = gd * 0.34
                let center = abs(gd) < 0.5
                Rectangle().fill(Color.white.opacity(center ? 0.6 : 0.25))
                    .frame(width: 1, height: center ? 16 : 8)
                    .rotationEffect(.radians(u), anchor: .bottom)
                    .position(x: m.W / 2 + 290 * sin(u),
                              y: m.H - (130 - 290 * (1 - cos(u)) + 44) - (center ? 8 : 4))
                    .opacity(hOn)
                    .animation(.easeOut(duration: 0.3), value: hOn)
            }
        }
    }
}

// 角标(单角:两边线)
struct CornerBracket: Shape {
    var right: Bool, bottom: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        let x = right ? r.maxX : r.minX
        let y = bottom ? r.maxY : r.minY
        p.move(to: CGPoint(x: right ? r.minX : r.maxX, y: y))
        p.addLine(to: CGPoint(x: x, y: y))
        p.addLine(to: CGPoint(x: x, y: bottom ? r.minY : r.maxY))
        return p
    }
}

// 参数入口图标(两线两圆)
struct ParamGlyph: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                Capsule().frame(width: w, height: 1.5).position(x: w / 2, y: w * 0.3)
                Capsule().frame(width: w, height: 1.5).position(x: w / 2, y: w * 0.68)
                Circle().strokeBorder(lineWidth: 1.5).frame(width: 5.5, height: 5.5)
                    .background(Circle().fill(Color.black.opacity(0.5)).frame(width: 4, height: 4))
                    .position(x: w * 0.63, y: w * 0.3)
                Circle().strokeBorder(lineWidth: 1.5).frame(width: 5.5, height: 5.5)
                    .background(Circle().fill(Color.black.opacity(0.5)).frame(width: 4, height: 4))
                    .position(x: w * 0.35, y: w * 0.68)
            }
        }
    }
}
