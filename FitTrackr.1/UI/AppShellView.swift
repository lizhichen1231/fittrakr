import SwiftUI

struct AppShellView: View {
    @StateObject private var vm = CameraViewModel()
    @State private var tab = 0 // 0=Camera, 1=Home, 2=Library, 3=Settings

    var body: some View {
        ZStack {
            // 主内容区域：按 tab 手动切换
            Group {
                switch tab {
                case 0:
                    CameraScreen(vm: vm)
                        .ignoresSafeArea()
                        .transition(.asymmetric(
                            insertion: .scale.combined(with: .opacity),
                            removal: .opacity
                        ))
                case 1:
                    HomeGlassScreen(username: "Sam") { tab = 0 }
                        .transition(.opacity)

                case 2:
                    LibraryPlaceholder()
                        .transition(.opacity)

                case 3:
                    SettingsPlaceholder()
                        .transition(.opacity)

                default:
                    EmptyView()
                }
            }
            .animation(.easeInOut(duration: 0.3), value: tab)
        }
        .preferredColorScheme(.dark)
        // 让底部栏贴到底部，并让内容自动上移给它"让位"
        // 1) 先让内容给底栏让出空间（高度与底栏可见高度一致）
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 84)   // 与 CustomTabBar 的 BarHeight 保持一致
        }
        // 2) 再把底栏作为覆盖层，直接贴到屏幕底边
        .overlay(alignment: .bottom) {
            CustomTabBar(selectedTab: $tab, cameraVM: vm)
                .ignoresSafeArea(edges: .bottom)
        }

        .onAppear { tab = 0 } // 启动默认进入相机页（按需可改为 1）
    }
}

// 占位视图（保持不变）
struct LibraryPlaceholder: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.9)
            VStack(spacing: 20) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 60))
                    .foregroundColor(.white.opacity(0.3))
                Text("媒体库")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .ignoresSafeArea()
    }
}

struct SettingsPlaceholder: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.9)
            VStack(spacing: 20) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.white.opacity(0.3))
                Text("设置")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .ignoresSafeArea()
    }
}
