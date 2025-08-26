import SwiftUI

private let AccentA = Color(red: 0.13, green: 0.60, blue: 1.00)
private let AccentB = Color(red: 0.00, green: 0.86, blue: 0.76)
private let BarCorner: CGFloat = 28
/// 可见栏的高度（不含底部安全区）
private let BarHeight: CGFloat = 84
private let GradientHeight: CGFloat = 56

struct CustomTabBar: View {
    @Binding var selectedTab: Int
    @ObservedObject var cameraVM: CameraViewModel

    var body: some View {
        GeometryReader { proxy in
            let bottomInset = proxy.safeAreaInsets.bottom

            ZStack(alignment: .bottom) {
                // 渐隐层：把高度 + bottomInset，这样会延伸进 Home 指示条
                LinearGradient(
                    colors: [Color.black.opacity(0.65), Color.black.opacity(0.2), .clear],
                    startPoint: .bottom, endPoint: .top
                )
                .frame(height: GradientHeight + bottomInset)
                .allowsHitTesting(false)
                .ignoresSafeArea(edges: .bottom)

                // 底盘：整体高度 + bottomInset，真正贴到屏幕底边
                ZStack {
                    UnevenRoundedRectangle(
                        topLeadingRadius: BarCorner,
                        bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                        topTrailingRadius: BarCorner, style: .continuous
                    )
                    .fill(.black.opacity(0.75))
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: BarCorner,
                            bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                            topTrailingRadius: BarCorner, style: .continuous
                        )
                        .fill(.regularMaterial.opacity(0.2))
                    )
                    .overlay(
                        LinearGradient(
                            colors: [.white.opacity(0.02), .clear],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        .clipShape(
                            UnevenRoundedRectangle(
                                topLeadingRadius: BarCorner,
                                bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                                topTrailingRadius: BarCorner, style: .continuous
                            )
                        )
                    )
                    .overlay(
                        UnevenRoundedRectangle(
                            topLeadingRadius: BarCorner,
                            bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                            topTrailingRadius: BarCorner, style: .continuous
                        )
                        .stroke(.white.opacity(0.04), lineWidth: 1)
                    )
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0.0),
                                .init(color: .white, location: 0.55),
                                .init(color: .white.opacity(0.5), location: 0.75),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .bottom, endPoint: .top
                        )
                    )

                    // 交互区：把内容整体抬起 bottomInset，保持相机键等控件的视觉位置不变
                    HStack(spacing: 0) {
                        TabBarButton(icon: "house.fill",
                                     isSelected: selectedTab == 1) { selectedTab = 1 }

                        TabBarButton(icon: "photo.stack",
                                     isSelected: selectedTab == 2) { selectedTab = 2 }

                        Spacer(minLength: 10)

                        RecordButton(isActive: selectedTab == 0,
                                     isRecording: cameraVM.isRecording) {
                            if selectedTab == 0 { cameraVM.toggleRecord() }
                            else { selectedTab = 0 }
                        }
                        .accessibilityLabel(Text(cameraVM.isRecording ? "Stop Recording" : "Start Recording"))
                        .offset(y: 0)

                        Spacer(minLength: 10)

                        TabBarButton(icon: "gearshape.fill",
                                     isSelected: selectedTab == 3) { selectedTab = 3 }

                        TabBarButton(icon: "viewfinder",
                                     isSelected: selectedTab == 0) { selectedTab = 0 }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, max(bottomInset - 12, 6)) // 关键：抬回控件
                }
                .frame(height: BarHeight + bottomInset)
                .ignoresSafeArea(edges: .bottom)
            }
            // 关键：把整个组件向下“越过” safeAreaInset 的边界（即使外层放在 .safeAreaInset 里也能贴底）
            .padding(.bottom, -bottomInset)
        }
        // 对外报告的高度仍是可见高度，便于外部让位
        .frame(height: BarHeight)
        .ignoresSafeArea(edges: .bottom)
    }
}


// 下面这些子视图保持不变……
private struct TabBarButton: View {
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: isSelected ? 24 : 22,
                                  weight: isSelected ? .heavy : .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? AccentA : Color.white.opacity(0.8))
                    .scaleEffect(isSelected ? 1.06 : 1.0)
                    .animation(.spring(response: 0.28, dampingFraction: 0.85), value: isSelected)

                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(LinearGradient(colors: [AccentA, AccentB],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: isSelected ? 18 : 0, height: 3)
                    .opacity(isSelected ? 1 : 0)
                    .animation(.easeInOut(duration: 0.18), value: isSelected)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct RecordButton: View {
    let isActive: Bool
    let isRecording: Bool
    let tap: () -> Void
    var body: some View {
        Button(action: tap) {
            ZStack {
                Circle()
                    .stroke(LinearGradient(colors: [AccentA, AccentB],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 3)
                    .frame(width: 74, height: 74)

                Circle()
                    .fill(isActive && isRecording ? Color.red : AccentA.opacity(0.95))
                    .frame(width: isActive && isRecording ? 28 : 62,
                           height: isActive && isRecording ? 28 : 62)
                    .animation(.spring(response: 0.30, dampingFraction: 0.8), value: isRecording)

                if !(isActive && isRecording) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

