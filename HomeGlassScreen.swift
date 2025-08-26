import SwiftUI

// MARK: - Utilities

extension Color {
    init(hex: String) {
        var h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if h.count == 6 { h += "FF" }
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 24) & 0xFF) / 255
        let g = Double((int >> 16) & 0xFF) / 255
        let b = Double((int >> 8)  & 0xFF) / 255
        let a = Double(int & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// 蓝色主题
private enum BlueTheme {
    static let stops: [Gradient.Stop] = [
        .init(color: Color(hex: "#7DD3FC"), location: 0.0),
        .init(color: Color(hex: "#3B82F6"), location: 0.45),
        .init(color: Color(hex: "#1E3A8A"), location: 1.0)
    ]
    static let chipGradient1: [Color] = [Color(hex:"#93C5FD"), Color(hex:"#1D4ED8")]
    static let chipGradient2: [Color] = [Color(hex:"#60A5FA"), Color(hex:"#1E40AF")]
    static let chipGradient3: [Color] = [Color(hex:"#38BDF8"), Color(hex:"#1E3A8A")]
}

// MARK: - 背景：黑 + 蓝 渐变（轻动态）

private struct BlueFrostBackground: View {
    var animated: Bool = true
    @State private var rotation: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AngularGradient(gradient: Gradient(stops: BlueTheme.stops), center: .center)
                .opacity(0.24)
                .blur(radius: 90)
                .scaleEffect(1.2)
                .rotationEffect(.degrees(rotation))
                .onAppear {
                    guard animated && !reduceMotion else { return }
                    withAnimation(.linear(duration: 50).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }
            LinearGradient(colors: [Color.black.opacity(0.38), .clear],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
            LinearGradient(colors: [.clear, Color.black.opacity(0.45)],
                           startPoint: .center, endPoint: .bottom)
                .ignoresSafeArea()
            Color.black.opacity(0.02).ignoresSafeArea()
        }
    }
}

// MARK: - 右上角圆形头像按钮

private struct ProfileAvatarButton: View {
    var imageName: String = "avatar"
    private var size: CGFloat = 20
    var action: () -> Void = {}
    
    var body: some View {
        Button(action: action) {
            ZStack {
                Image(imageName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                Circle()
                    .stroke(
                        LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.2)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Profile"))
    }
}

// MARK: - 顶部悬浮胶囊栏（透明 Bar，仅胶囊有毛玻璃），贴刘海下方

private struct TopFloatingBar: View {
    var safeTop: CGFloat
    var avatarImageName: String = "avatar"
    var onAvatarTap: () -> Void = {}
    
    // 计算实际占用的总高度（用于外部预留空间）
    static func actualHeight(safeTop: CGFloat) -> CGFloat {
        return 70  // 对应调整后的高度
    }
    
    var body: some View {
        // 透明背景，只放控件
        HStack(spacing: 10) {
            pill("Search",  "magnifyingglass")
            pill("Profile", "person.crop.circle")
            pill("Design",  "paintbrush")
            Spacer(minLength: 0)
            ProfileAvatarButton()
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)   // 稍微往下挪一点
        .padding(.bottom, 10)
        .background(Color.clear.ignoresSafeArea(edges: .top))
        .allowsHitTesting(true)
    }
    
    private func pill(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            Text(title).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.black.opacity(0.7))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.thickMaterial)  // 厚磨砂材质，在深色背景上呈现白色磨砂效果
                .overlay(
                    Capsule()
                        .fill(.white.opacity(0.1))  // 轻微白色叠加增强亮度
                )
                .overlay(Capsule().stroke(.white.opacity(0.4), lineWidth: 0.5))
        )
    }
}

// MARK: - 顶部头图（图片填至最顶 + 更顺滑下渐隐 + 问候语）

private struct HeroHeader: View {
    var imageName: String = "homeHero"
    var height: CGFloat
    var safeTop: CGFloat
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Image(imageName)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .clipped()
                .overlay(
                    LinearGradient(colors: [Color.black.opacity(0.38), .clear],
                                   startPoint: .top, endPoint: .center)
                )
                .mask(
                    LinearGradient(stops: [
                        .init(color: .white,               location: 0.00),
                        .init(color: .white,               location: 0.60),
                        .init(color: .white.opacity(0.92), location: 0.78),
                        .init(color: .white.opacity(0.55), location: 0.90),
                        .init(color: .white.opacity(0.00), location: 1.00),
                    ], startPoint: .top, endPoint: .bottom)
                )
                .ignoresSafeArea(edges: .top) // 图片伸到最顶
            
            Text("ready for being yourself huh ?")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.7), radius: 6, x: 0, y: 2)
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .padding(.horizontal, -16)     // 头图全宽出血
        .padding(.top, -(safeTop))     // 顶到状态栏
    }
}

// MARK: - 功能卡模型与 UI（统一尺寸填充）

private struct FeatureItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let subtitle: String
    let category: String
    let duration: String
    let imageName: String
}

private struct FeatureCardView: View {
    let item: FeatureItem
    let width: CGFloat
    let height: CGFloat
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Image(item.imageName)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height)
                .clipped()
            LinearGradient(colors: [.black.opacity(0.65), .black.opacity(0.0)],
                           startPoint: .bottom, endPoint: .center)
                .frame(width: width, height: height)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(item.category).foregroundColor(.blue.opacity(0.9))
                    Text("•").foregroundColor(.white.opacity(0.7))
                    Text(item.subtitle).foregroundColor(.white.opacity(0.85))
                    Spacer(minLength: 0)
                    Text(item.duration).foregroundColor(.white.opacity(0.85))
                }
                .font(.system(size: 12, weight: .regular))
            }
            .padding(12)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 8)
    }
}

// 两卡并排轮播（可左右滑动、循环；右高左低）

private struct TwoUpFeatureCarousel: View {
    let items: [FeatureItem]               // 建议 3 个
    @State private var selection: Int = 0
    private let verticalOffsetLeft: CGFloat  = 12
    private let verticalOffsetRight: CGFloat = -8
    
    var body: some View {
        GeometryReader { geo in
            let pageW = geo.size.width
            let sidePad: CGFloat = 16
            let spacing: CGFloat = 14
            let cardW = (pageW - sidePad * 2 - spacing) / 2
            let cardH: CGFloat = 220
            
            let n = max(items.count, 1)
            let minIndex = n
            let maxIndex = 2 * n - 1
            let pages = Array(0..<(3 * n))
            
            TabView(selection: $selection) {
                ForEach(pages, id: \.self) { idx in
                    let i = idx % n
                    let left  = items[i]
                    let right = items[(i + 1) % n]
                    
                    HStack(spacing: spacing) {
                        FeatureCardView(item: left,  width: cardW, height: cardH)
                            .offset(y: verticalOffsetLeft)
                        FeatureCardView(item: right, width: cardW, height: cardH)
                            .offset(y: verticalOffsetRight)
                    }
                    .padding(.horizontal, sidePad)
                    .tag(idx)
                }
            }
            .frame(height: cardH + 24 + max(verticalOffsetLeft, -verticalOffsetRight))
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onAppear { selection = minIndex }
            .onChange(of: selection) { newVal in
                if newVal > maxIndex {
                    let target = minIndex + (newVal - maxIndex - 1)
                    DispatchQueue.main.async { withAnimation(.none) { selection = target } }
                } else if newVal < minIndex {
                    let target = maxIndex - (minIndex - newVal - 1)
                    DispatchQueue.main.async { withAnimation(.none) { selection = target } }
                }
            }
        }
    }
}

// MARK: - 毛玻璃容器（复用）

private struct GlassPanel: View {
    var corner: CGFloat = 20
    var opacity: Double = 0.18
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        ZStack {
            if reduceTransparency {
                shape.fill(Color.white.opacity(0.06))
            } else {
                shape.fill(.ultraThinMaterial.opacity(opacity))
            }
        }
        .overlay(
            LinearGradient(colors: [.white.opacity(0.08), .white.opacity(0.02)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .clipShape(shape)
        )
        .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 1))
    }
}

// MARK: - 主屏

struct HomeGlassScreen: View {
    var username: String = "Sam"
    var avatarImageName: String = "avatar"
    var onAvatarTap: () -> Void = {}
    var onGoCapture: () -> Void = {}
    var animatedBackground: Bool = true
    
    private let features: [FeatureItem] = [
        .init(title: "Tracking Engine",    subtitle: "Smooth & robust",     category: "Tracking", duration: "5 mins", imageName: "feature_tracking"),
        .init(title: "Gesture Recording",  subtitle: "Hands-free capture",  category: "Gesture",  duration: "3 mins", imageName: "feature_gesture"),
        .init(title: "Watch Follow View",  subtitle: "Glanceable control",  category: "Watch",    duration: "2 mins", imageName: "feature_watch"),
    ]
    
    var body: some View {
        GeometryReader { geo in
            let safeTop = geo.safeAreaInsets.top
            let topReserve: CGFloat = 70  // 调整为对应新的胶囊位置
            
            ZStack(alignment: .top) {
                // 背景
                BlueFrostBackground(animated: animatedBackground)
                
                // 内容滚动：为悬浮胶囊预留 topReserve，不再与之重叠
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {  // 增加间距避免重叠
                        // 顶部头图（顶到状态栏），问候语在底部
                        let heroHeight = max(geo.size.height * 0.33, 260)
                        HeroHeader(imageName: "homeHero", height: heroHeight, safeTop: safeTop)
                            .padding(.bottom, 12)
                        
                        // 两卡并排功能轮播
                        TwoUpFeatureCarousel(items: features)
                            .frame(height: 256)  // 固定高度避免布局问题
                            .padding(.bottom, 8)
                        
                        // Quick Actions - 确保不与上面的卡片重叠
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Quick Actions")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 8)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    quickActionCard(icon: "camera.viewfinder",
                                                    title: "Open Camera",
                                                    subtitle: "Start recording",
                                                    gradient: BlueTheme.chipGradient1,
                                                    action: onGoCapture)
                                    quickActionCard(icon: "timer",
                                                    title: "Timer 3s",
                                                    subtitle: "Delayed start",
                                                    gradient: BlueTheme.chipGradient2,
                                                    action: {})
                                    quickActionCard(icon: "figure.strengthtraining.traditional",
                                                    title: "Form Check",
                                                    subtitle: "AI coaching",
                                                    gradient: BlueTheme.chipGradient3,
                                                    action: {})
                                }
                                .padding(.horizontal, 8)
                            }
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 12)
                        .background(GlassPanel(corner: 20, opacity: 0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        
                        // Templates
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Templates")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    templatePill("15s Form Check", "wand.and.rays")
                                    templatePill("45m Workout", "figure.walk.motion")
                                    templatePill("Time-lapse", "timelapse")
                                }
                            }
                        }
                        .padding(12)
                        .background(GlassPanel(corner: 20, opacity: 0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        
                        // Recent Sessions
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Recent Sessions")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(0..<3) { index in recentCard(index: index) }
                                }
                            }
                        }
                        .padding(12)
                        .background(GlassPanel(corner: 20, opacity: 0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        
                        // 底部留白，确保最后的内容不被底部栏遮挡
                        Color.clear.frame(height: 20)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, topReserve)   // 正确预留顶部栏的实际高度
                }
                
                // 顶部悬浮（透明 bar，胶囊紧贴灵动岛）
                VStack {
                    TopFloatingBar(safeTop: safeTop, avatarImageName: avatarImageName, onAvatarTap: onAvatarTap)
                    Spacer()
                }
                .ignoresSafeArea(edges: .top)  // 让VStack延伸到顶部
            }
        }
        .preferredColorScheme(.dark)
    }
    
    // MARK: - 子组件

    private func quickActionCard(
        icon: String, title: String, subtitle: String,
        gradient: [Color], action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(LinearGradient(colors: gradient,
                                               startPoint: .topLeading,
                                               endPoint: .bottomTrailing))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: 100)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial.opacity(0.30))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    )
            )
        }
    }
    
    private func templatePill(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium))
            Text(title).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.thinMaterial.opacity(0.25))
                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
        )
    }
    
    private func recentCard(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [Color.white.opacity(0.08), Color.white.opacity(0.03)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 110, height: 65)
                .overlay(Image(systemName: "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.white.opacity(0.4)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12), lineWidth: 1))
            VStack(alignment: .leading, spacing: 1) {
                Text("Session \(index + 1)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.9))
                Text("\(15 + index * 5) mins ago").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial.opacity(0.22))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.10), lineWidth: 1))
        )
    }
}
