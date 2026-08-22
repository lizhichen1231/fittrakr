// 【新 UI】根视图 —— 屏层叠(设计稿 z 序):素材库 2-3 / 设置 4 / 底栏 5-6 / 回看 7 / 拍摄 8。
// showEmpty = 空状态变体(设计稿 props.showEmpty)。

import SwiftUI

struct MTRootView: View {
    @StateObject private var m = MTAppModel()
    var showEmpty = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if showEmpty {
                    MTEmptyView(m: m)
                } else {
                    MTLibraryView(m: m, mo: m.mo, pane: m.pane)
                    if m.setOpen { MTSettingsView(m: m).zIndex(4) }
                    MTBottomBar(m: m, pane: m.pane).zIndex(6)
                    if m.playIdx != nil { MTPlaybackView(m: m, mo: m.mo, pane: m.pane).zIndex(7) }
                }
                if m.capOpen { MTCaptureView(m: m, mo: m.mo).zIndex(8) }
                // 预览退出角(仅新 UI 预览期:左上长按退回旧 UI;新 UI 转正后删)
                Color.clear
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 1.2) { m.stopAll(); dismiss() }
                    .zIndex(20)
            }
            .onAppear {
                m.W = geo.size.width
                m.H = geo.size.height
            }
            .onChange(of: geo.size) { s in
                m.W = s.width
                m.H = s.height
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onDisappear { m.stopAll() }
    }
}

// ── 空状态(首启)──
struct MTEmptyView: View {
    @ObservedObject var m: MTAppModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            MTThemeBackground()
            LinearGradient(colors: [.black.opacity(0.72), .clear],
                           startPoint: .bottom, endPoint: UnitPoint(x: 0.5, y: 0.2))
                .frame(height: m.H * 0.7)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea()
            Text("MYTRACK")
                .font(.system(size: 12)).kerning(2.6)
                .foregroundColor(.white.opacity(0.8))
                .padding(.leading, 26).padding(.top, 70)
            VStack(alignment: .leading, spacing: 14) {
                Text("手机架好,\n人走开。")
                    .font(.system(size: 38, design: .serif))
                    .lineSpacing(8)
                Text("MyTrack 自动跟着你运镜、必要时切换镜头。训练或跳舞时,不需要碰屏幕一下。")
                    .font(.system(size: 14))
                    .lineSpacing(6)
                    .foregroundColor(.white.opacity(0.78))
                    .frame(maxWidth: 300, alignment: .leading)
                Button { m.openCap() } label: {
                    Text("开始拍摄")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 64)
                        .background(MT.accent, in: RoundedRectangle(cornerRadius: 18))
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 26)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.bottom, 44)
        }
    }
}
