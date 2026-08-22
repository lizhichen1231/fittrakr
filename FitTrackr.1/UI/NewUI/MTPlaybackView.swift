// 【新 UI】单条回看屏 —— 卡→播放器矩形变形转场、复盘带擦洗、统计层竖拉、轻量标签选择。
// 几何照抄设计稿:播放器 Lp(20,118)/Lp(92,56)、带 bottom Lp(158,486) h34、
// 统计层 top=H−Lp(−60,452)、转场 420ms eob(0.6)。

import SwiftUI

struct MTPlaybackView: View {
    @ObservedObject var m: MTAppModel
    @ObservedObject var mo: MTMotion
    @ObservedObject var pane: MTPane
    @State private var psBegan = false

    var body: some View {
        let playIdx = min(m.playIdx ?? 0, m.n - 1)
        let clip = m.clips[playIdx]
        let ps = mo.ps
        let playEff = m.playEff
        let uiOp = m.tagPickOpen ? 0.0 : 1.0
        let Lp: (Double, Double) -> Double = { a, b in a + (b - a) * ps }

        return ZStack(alignment: .topLeading) {
            MTThemeBackground().opacity(playEff)

            // 返回行
            Button { m.closePlay() } label: {
                HStack(spacing: 6) {
                    MTChevron().stroke(style: .init(lineWidth: 1.6, lineCap: .round))
                        .frame(width: 6.5, height: 12)
                    Text("\(m.day.d) · 第 \(playIdx + 1) 条")
                }
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.72))
                .padding(8)
            }
            .buttonStyle(.plain)
            .position(x: 22 + 60, y: 58 + 10)
            .opacity(max(0, (playEff - 0.6) / 0.4))
            .zIndex(10)   // 【回扫A3/A4】返回行永远压在视频卡(z2)之上

            // 播放器(转场矩形插值)
            player(clip: clip, playIdx: playIdx, playEff: playEff, Lp: Lp)

            // 实时读数
            Text(readout(clip: clip))
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))
                .position(x: 26 + 40, y: m.H - Lp(212, 540) - 8)
                .opacity(uiOp * (1 - ps) * max(0, (playEff - 0.7) / 0.3))

            // 复盘带(完整版 + 游标 + 擦洗)
            band(clip: clip)
                .frame(width: m.W - 52, height: 34)
                .position(x: m.W / 2, y: m.H - Lp(158, 486) - 17)
                .opacity(uiOp * max(0, (playEff - 0.7) / 0.3))

            // 统计层(竖拉升起,只读无卡片)
            stats(clip: clip, playIdx: playIdx)
                .frame(width: m.W - 60)
                .offset(x: 30, y: m.H - Lp(-60, 452))
                .opacity(max(0, (ps - 0.25) / 0.75))
                .allowsHitTesting(false)

            // 底部操作行
            HStack(alignment: .lastTextBaseline) {
                Button { m.openTagPick() } label: { Text(m.clipCat(playIdx)) }.buttonStyle(.plain)
                Spacer(); Text("导出到相册")
                Spacer(); Text("剪掉跟丢段")
                Spacer(); Text("删除").foregroundColor(MT.danger)
            }
            .font(.system(size: 13))
            .foregroundColor(.white.opacity(0.65))
            .padding(.horizontal, 30)
            .frame(width: m.W)
            .position(x: m.W / 2, y: m.H - 44 - 8)
            .opacity(uiOp * (1 - ps) * max(0, (playEff - 0.8) / 0.2))
            .allowsHitTesting(ps < 0.5 && playEff >= 0.999)

            if m.tagPickOpen { tagPicker(playIdx: playIdx) }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        // 【回扫A3】改 simultaneousGesture:全屏 drag 不再抢走返回按钮的点击;
        // 顶部 44pt 返回带(y<108)内 psDown 直接拒绝启动(m 侧过滤)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !psBegan { psBegan = true; m.psDown(v.startLocation) }
                    m.psMove(v.location)
                }
                .onEnded { _ in psBegan = false; m.psUp() }
        )
    }

    // 播放器矩形:目标 vs 源(堆叠前卡 / 网格该格)按 playEff 插值
    private func player(clip: MTClip, playIdx: Int, playEff: Double, Lp: (Double, Double) -> Double) -> some View {
        let W = Double(m.W), H = Double(m.H)
        // 【回扫B9 固定值】顶部距返回行 16pt(返回行 top58 高20 → 卡顶 94)、左右 24;
        // 高按素材比例(9:16),上限屏高 55%
        let dx = Lp(24, 118), dy = Lp(94, 56)
        let dw = W - 2 * dx
        let dh0 = min(dw * 16.0 / 9.0, H * 0.55)
        let dh = Lp(dh0, H - 56 - 566)
        var x = dx, y = dy, w = dw, h = dh
        if playEff < 0.999 {
            var sxr: Double = 24
            var syr: Double = 118
            var swr: Double = W - 48
            var shr: Double = Double(m.Hd) - 100
            if pane.g >= 0.5 {
                let pad: Double = 24
                let gap: Double = 12
                let colW: Double = (W - pad * 2 - gap) / 2
                let cardH: Double = (colW * 4.0 / 3.0).rounded()
                sxr = pad + Double(playIdx % 2) * (colW + gap)
                syr = 190.0 + Double(playIdx / 2) * (cardH + gap) - pane.scrollY
                swr = colW
                shr = cardH
            }
            let q = playEff
            x = sxr + (dx - sxr) * q
            y = syr + (dy - syr) * q
            w = swr + (dw - swr) * q
            h = shr + (dh - shr) * q
        }
        let cs = Int((mo.playT * Double(clip.secs)).rounded())
        let mm: Int = cs / 60
        let sSec: String = String(format: "%02d", cs % 60)
        let clock: String = "\(mm):\(sSec) / \(clip.dur)"
        let px: CGFloat = CGFloat(x + w / 2)
        let py: CGFloat = CGFloat(y + h / 2)
        return playerBody(clip: clip, clock: clock, w: CGFloat(w), h: CGFloat(h))
            .position(x: px, y: py)
            .onTapGesture { m.togglePlay() }
            .zIndex(2)
    }

    private func clipImage(_ clip: MTClip, w: CGFloat, h: CGFloat) -> some View {
        MTCachedImage(url: clip.imgURL, maxPixel: 1300, tint: .card)
            .frame(width: w, height: h)
            .clipped()
    }

    private func playerBody(clip: MTClip, clock: String, w: CGFloat, h: CGFloat) -> some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 18).fill(Color(red: 0.078, green: 0.078, blue: 0.078))
            clipImage(clip, w: w, h: h)
            if !m.playing {
                Triangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 18, height: 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            Text(clock)
                .font(.system(size: 12)).monospacedDigit()
                .foregroundColor(.white.opacity(0.72))
                .padding(.trailing, 16).padding(.bottom, 14)
                .opacity(m.tagPickOpen ? 0 : 1)
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func readout(clip: MTClip) -> String {
        var acc = 0.0
        for sg in clip.parts {
            if mo.playT < acc + sg.frac {
                switch sg.kind {
                case .gap: return "跟丢"
                case .dark: return "未跟到"
                case .lit: return (sg.zoom == 1 ? "1.0x" : String(format: "%.1fx", sg.zoom)) + " · 跟着"
                }
            }
            acc += sg.frac
        }
        return "跟着"
    }

    private func band(clip: MTClip) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                MTTrackline(parts: clip.parts, thick: 4, base: 2)
                    .frame(height: 12)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 1, height: 18)
                    .offset(x: geo.size.width * CGFloat(mo.playT) - 0.5, y: 3)
            }
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in m.bandScrub(Double(v.location.x / max(1, geo.size.width)), ended: false) }
                    .onEnded { v in m.bandScrub(Double(v.location.x / max(1, geo.size.width)), ended: true) }
            )
        }
    }

    private func stats(clip: MTClip, playIdx: Int) -> some View {
        // 当前时刻参数(随 playT 联动)+ 全片汇总(设计稿公式)
        var zmCur = 1.0, acc = 0.0
        var stateCur = MTSegKind.lit
        for sg in clip.parts { if mo.playT < acc + sg.frac { zmCur = sg.zoom; stateCur = sg.kind; break }; acc += sg.frac }
        let tick = Int(mo.playT * 12)
        let iso = [100, 125, 160, 200, 250, 320][(playIdx * 5 + tick * 3) % 6]
        let wb = [4800, 5000, 5200, 5400, 5600][(playIdx * 3 + tick) % 5]
        let ev = ["-0.3", "0.0", "+0.3", "+0.7"][(playIdx + tick * 2) % 4]
        var lostDur = 0.0; var lostN = 0; var maxZ = 1.0; var zSum = 0.0; var zW = 0.0; var sw = 0
        var prevZ: Double? = nil
        for sg in clip.parts {
            if sg.kind == .gap { lostDur += sg.frac * Double(clip.secs); lostN += 1; prevZ = nil }
            else if sg.kind == .lit {
                maxZ = max(maxZ, sg.zoom); zSum += sg.zoom * sg.frac; zW += sg.frac
                if let p = prevZ, p != sg.zoom { sw += 1 }
                prevZ = sg.zoom
            }
        }
        let cs = Int((mo.playT * Double(clip.secs)).rounded())
        let gapDash = stateCur == .gap
        let summary = "\(cs / 60):" + String(format: "%02d", cs % 60) + " · "
            + (stateCur == .gap ? "跟丢" : stateCur == .dark ? "未跟到" : String(format: "%.1fx · 跟着", zmCur))
        let quality = (m.capRes == "4K" ? "4K" : "1080p") + " · \(m.capFps)fps"

        func row(_ k: String, _ v: String) -> some View {
            HStack {
                Text(k).font(.system(size: 13)).foregroundColor(.white.opacity(0.5))
                Spacer()
                Text(v).font(.system(size: 15)).monospacedDigit().foregroundColor(.white.opacity(0.85))
            }
            .padding(.vertical, 3)
        }
        func head(_ t: String) -> some View {
            Text(t).font(.system(size: 11)).kerning(1.3)
                .foregroundColor(.white.opacity(0.4))
                .padding(.top, 14).padding(.bottom, 7)
        }
        return VStack(alignment: .leading, spacing: 0) {
            Text(summary).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                .padding(.bottom, 18)
            head("拍摄参数").padding(.top, 0)
            row("ISO", gapDash ? "—" : "\(iso)")
            row("白平衡", gapDash ? "—" : "\(wb)K")
            row("曝光补偿", gapDash ? "—" : "\(ev) EV")
            head("拍摄设置")
            row("分辨率 / 帧率", quality)
            head("跟踪统计")
            row("总跟丢时长", lostN > 0 ? "\(Int(lostDur.rounded())) 秒" : "0 秒")
            row("跟丢次数", "\(lostN) 次")
            row("最大倍率", String(format: "%.1fx", maxZ))
            row("平均倍率", String(format: "%.1fx", zW > 0 ? zSum / zW : 1))
            row("镜头切换次数", "\(sw) 次")
            head("文件")
            row("大小 · 拍摄时间 · 导出", String(format: "%.1f GB · %@ 16:42 · 未导出", Double(clip.secs) * 0.055, m.day.d))
        }
        .foregroundColor(.white)
        .drawingGroup()
    }

    // 轻量标签选择:文字压画面 + 左下羽化糊
    private func tagPicker(playIdx: Int) -> some View {
        let names = m.tagNames
        let cur = m.clipCat(playIdx)
        let curI = max(0, names.firstIndex(of: cur) ?? 0)
        return ZStack(alignment: .bottomLeading) {
            Color.black.opacity(0.001)
                .onTapGesture { m.closeTagPick() }
            MTFeatherBlur(center: UnitPoint(x: 0.12, y: 0.55), rx: 0.9, ry: 0.75)
                .frame(width: 320, height: 380)
                .offset(x: -40, y: -88)
                .opacity(m.tagIn ? 1 : 0)
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                    Button { m.pickTag(name) } label: {
                        HStack(spacing: 10) {
                            Text(name).font(.system(size: name == cur ? 18 : 16))
                                .foregroundColor(name == cur ? .white : .white.opacity(0.6))
                            if name == cur { Capsule().fill(MT.accent).frame(width: 9, height: 2) }
                        }
                    }
                    .buttonStyle(.plain)
                    .mtShadow()
                    .scaleEffect(m.tagIn ? 1 : 0.9, anchor: .leading)
                    .opacity(m.tagIn ? 1 : 0)
                    .animation(.spring(response: 0.26, dampingFraction: 0.7).delay(Double(abs(i - curI)) * 0.03), value: m.tagIn)
                }
                if m.tagNewOpen {
                    TextField("分类名称", text: $m.tagNewText)
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .frame(width: 180)
                        .overlay(Rectangle().fill(Color.white.opacity(0.25)).frame(height: 1), alignment: .bottom)
                        .onSubmit { m.commitNewTag() }
                } else {
                    Button { m.tagNewOpen = true } label: {
                        Text("+ 新建分类").font(.system(size: 14)).foregroundColor(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .mtShadow()
                    .scaleEffect(m.tagIn ? 1 : 0.9, anchor: .leading)
                    .opacity(m.tagIn ? 1 : 0)
                    .animation(.spring(response: 0.26, dampingFraction: 0.7).delay(Double(abs(names.count - curI)) * 0.03), value: m.tagIn)
                }
            }
            .padding(.leading, 30)
            .padding(.bottom, 96)
        }
        .zIndex(3)
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
