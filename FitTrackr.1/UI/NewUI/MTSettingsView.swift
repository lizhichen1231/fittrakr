// 【新 UI】设置屏 —— 无卡片无分割线的文字设置;点名字看说明,点值就地改。
// 可改值 = 薄玻璃气泡;开关就地翻转;选项 = 行位锚定的直排选择器(浮现 stagger + 羽化糊)。

import SwiftUI

private struct MTRowFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct MTSettingsView: View {
    @ObservedObject var m: MTAppModel
    @State private var rowFrames: [String: CGRect] = [:]

    var body: some View {
        ZStack(alignment: .topLeading) {
            MTThemeBackground()

            Text("设置")
                .font(.system(size: 22))
                .mtShadow()
                .padding(.leading, 26).padding(.top, 54)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(m.setGroups.enumerated()), id: \.offset) { _, gp in
                        group(gp)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 64)
                .padding(.bottom, 132)
            }
            .padding(.top, 44)
            .mask(topFade)
            .onTapGesture { m.setDesc = nil }
            .onPreferenceChange(MTRowFrameKey.self) { rowFrames = $0 }

            if m.setPick != nil { picker }
        }
        .ignoresSafeArea()
        .coordinateSpace(name: "mtset")
    }

    private var topFade: some View {
        var stops: [Gradient.Stop] = []
        for t in 0...8 {
            let f = MT.ss(Double(t) / 8)
            let loc = (44 + Double(t) * 8) / Double(m.H)
            stops.append(Gradient.Stop(color: Color.black.opacity(f), location: loc))
        }
        stops.append(Gradient.Stop(color: Color.black, location: 1))
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }

    private func group(_ gp: MTSettingGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(gp.name)
                .font(.system(size: 11)).kerning(1.3)
                .foregroundColor(.white.opacity(0.4))
                .mtShadow()
                .padding(.bottom, 7)
            ForEach(gp.rows, id: \.k) { r in
                row(r)
            }
        }
    }

    private func row(_ r: MTSettingRow) -> some View {
        let val = m.setVal(r)
        let descOn = m.setDesc == r.k
        let pickable = (r.opts != nil && !r.act) || r.toggle || r.act
        return HStack(alignment: .lastTextBaseline, spacing: 16) {
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                Text(r.name)
                    .foregroundColor(.white.opacity(0.55))
                    .fixedSize()
                    .mtShadow()
                    .onTapGesture { m.tapSetName(r) }
                Text(r.desc)
                    .font(.system(size: 9.1))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
                    .opacity(descOn ? 1 : 0)
                    .offset(x: descOn ? 0 : -4)
                    .animation(.easeOut(duration: 0.2), value: descOn)
                    .mtShadow()
                    .allowsHitTesting(false)
                Spacer(minLength: 0)
            }
            if !val.isEmpty {
                Group {
                    if pickable && !r.act || r.toggle {
                        Text(val)
                            .font(.system(size: 13)).monospacedDigit()
                            .foregroundColor(.white.opacity(0.9))
                            .mtChip(height: 20, radius: 8)
                    } else if r.act {
                        Text(val)
                            .font(.system(size: 13)).monospacedDigit()
                            .foregroundColor(.white.opacity(0.9))
                            .mtChip(height: 20, radius: 8)
                    } else {
                        Text(val)
                            .font(.system(size: 15)).monospacedDigit()
                            .foregroundColor(.white.opacity(0.9))
                            .mtShadow()
                    }
                }
                .background(GeometryReader { geo in
                    Color.clear.preference(key: MTRowFrameKey.self,
                                           value: [r.k: geo.frame(in: .named("mtset"))])
                })
                .onTapGesture {
                    m.tapSetVal(r, rowFrame: rowFrames[r.k] ?? .zero)
                }
            }
        }
        .font(.system(size: 13))
        .frame(height: 22)
    }

    // 行位锚定的直排选择器
    private var picker: some View {
        let pk = m.setPick ?? ""
        let r = m.setGroups.flatMap(\.rows).first { $0.k == pk }
        let opts = r?.opts ?? []
        let cur = r.map { m.setVal($0) } ?? ""
        let curI = max(0, opts.firstIndex(of: cur) ?? 0)
        let pitch: Double = 40
        let rowY: Double = Double(m.setPickRowFrame.midY)
        let anchored: Double = rowY - Double(curI) * pitch - 9
        let limit: Double = Double(m.H) - 150 - Double(opts.count - 1) * pitch
        let top: Double = max(72.0, min(anchored, limit))
        let blurY: Double = top - 190 + Double(opts.count - 1) * pitch / 2
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)
                .onTapGesture { m.closeSetPick() }
            MTFeatherBlur(center: UnitPoint(x: 0.12, y: 0.5), rx: 0.9, ry: 0.75)
                .frame(width: 320, height: 380)
                .offset(x: -40, y: CGFloat(blurY))
                .opacity(m.setPickIn ? 1 : 0)
            pickList(opts: opts, cur: cur, curI: curI, row: r)
                .padding(.leading, 26)
                .padding(.top, CGFloat(top))
        }
        .zIndex(3)
    }

    private func pickList(opts: [String], cur: String, curI: Int, row r: MTSettingRow?) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(opts.enumerated()), id: \.offset) { i, name in
                pickItem(name: name, isCur: name == cur && !(r?.act ?? false),
                         danger: r?.danger ?? false, dist: abs(i - curI), row: r)
            }
        }
    }

    private func pickItem(name: String, isCur: Bool, danger: Bool, dist: Int, row r: MTSettingRow?) -> some View {
        Button {
            if let r { m.pickSetOpt(r, name) }
        } label: {
            HStack(spacing: 10) {
                Text(name)
                    .font(.system(size: isCur ? 18 : 16))
                    .foregroundColor(danger ? MT.danger : (isCur ? .white : .white.opacity(0.6)))
                if isCur { Capsule().fill(Color.white.opacity(0.75)).frame(width: 9, height: 2) }
            }
        }
        .buttonStyle(.plain)
        .mtShadow()
        .scaleEffect(m.setPickIn ? 1 : 0.9, anchor: .leading)
        .opacity(m.setPickIn ? 1 : 0)
        .animation(.spring(response: 0.26, dampingFraction: 0.7).delay(Double(dist) * 0.03), value: m.setPickIn)
    }
}
