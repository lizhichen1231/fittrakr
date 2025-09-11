import SwiftUI
import AVFoundation
import UIKit

struct CameraScreen: View {
    @ObservedObject var vm: CameraViewModel
    @State private var showTuner = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                
                // 预览 + 叠加
                PreviewCanvasView(
                    image: vm.processedCGImage,
                    handLandmarks: vm.handLandmarks,
                    personBoxN: vm.personBox,
                    deadZoneFraction: vm.deadZoneFraction
                )
                SkeletonDebugOverlayView()
                .ignoresSafeArea()

                // 顶部状态信息
                VStack {
                    HStack {
                        // 跟踪状态
                        Text(vm.isTracking ? vm.trackingInfo : "搜索目标…")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                        
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 60)
                    
                    Spacer()
                }
                
                // 右上角控制按钮（中间偏上位置）
                VStack {
                    HStack {
                        Spacer()
                        
                        VStack(spacing: 16) {
                            // 锁定按钮
                            Button { vm.toggleLock() } label: {
                                Image(systemName: vm.hardLock ? "lock.fill" : "lock.open")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 44, height: 44)
                                    .background(
                                        Circle()
                                            .fill(vm.hardLock ? Color.orange.opacity(0.8) : Color.gray.opacity(0.5))
                                            .overlay(
                                                Circle()
                                                    .stroke(.white.opacity(0.2), lineWidth: 1)
                                            )
                                    )
                            }
                            
                            // 参数调节按钮
                            Button { showTuner.toggle() } label: {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 44, height: 44)
                                    .background(
                                        Circle()
                                            .fill(Color.blue.opacity(0.6))
                                            .overlay(
                                                Circle()
                                                    .stroke(.white.opacity(0.2), lineWidth: 1)
                                            )
                                    )
                            }
                        }
                        .padding(.trailing, 20)
                    }
                    .padding(.top, 140) // 中间偏上位置
                    
                    Spacer()
                }
                
                // 左下角手势识别开关
                VStack {
                    Spacer()
                    
                    HStack {
                        Button { toggleGesture() } label: {
                            VStack(spacing: 4) {
                                Image(systemName: getGestureIcon())
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)
                                Text(getGestureText())
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.white.opacity(0.8))
                            }
                            .frame(width: 50, height: 50)
                            .background(
                                Circle()
                                    .fill(vm.gestureMode == .off ?
                                         Color.gray.opacity(0.5) :
                                         Color.green.opacity(0.7))
                                    .overlay(
                                        Circle()
                                            .stroke(.white.opacity(0.2), lineWidth: 1)
                                    )
                            )
                        }
                        .padding(.leading, 20)
                        
                        Spacer()
                    }
                    .padding(.bottom, 120) // 给底部TabBar留空间
                }
                
                // 手势状态提示
                if vm.gestureMode != .off {
                    VStack {
                        HStack {
                            Spacer()
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                                    .overlay(
                                        Circle()
                                            .fill(Color.green.opacity(0.3))
                                            .frame(width: 16, height: 16)
                                            .scaleEffect(vm.handLandmarks.isEmpty ? 1.0 : 1.5)
                                            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: vm.handLandmarks.isEmpty)
                                    )
                                Text(getGestureStatusText())
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.5), in: Capsule())
                            .padding(.trailing, 20)
                        }
                        .padding(.top, 200) // 在控制按钮下方
                        Spacer()
                    }
                }
                
                // 录制状态指示器
                if vm.isRecording {
                    VStack {
                        HStack {
                            // 录制时间
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 10, height: 10)
                                    .overlay(
                                        Circle()
                                            .fill(Color.red.opacity(0.3))
                                            .frame(width: 20, height: 20)
                                            .scaleEffect(1.5)
                                            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: vm.isRecording)
                                    )
                                
                                Text(formatTime(vm.elapsed))
                                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.6), in: Capsule())
                            
                            Spacer()
                        }
                        .padding(.leading, 20)
                        .padding(.top, 100)
                        
                        Spacer()
                    }
                }
            }
            .onAppear {
                vm.updateOutputSize(for: geo.size)
                vm.start()
            }
            .onChange(of: geo.size) { newSize in
                vm.updateOutputSize(for: newSize)
            }
            .onDisappear { vm.stop() }
            .sheet(isPresented: $showTuner) {
                TunerSheet(vm: vm)
                    .presentationDetents([.fraction(0.35), .medium, .large])
            }
        }
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }
    
    // MARK: - 辅助方法
    
    private func toggleGesture() {
        if vm.gestureMode == .off {
            vm.gestureMode = .wave
        } else {
            vm.gestureMode = .off
        }
        vm.applyGestureConfig()
    }
    
    private func getGestureIcon() -> String {
        switch vm.gestureMode {
        case .off:
            return "hand.raised.slash"
        case .wave:
            return "hand.wave"
        case .okThree:
            return "hand.thumbsup"
        }
    }
    
    private func getGestureText() -> String {
        switch vm.gestureMode {
        case .off:
            return "手势关"
        case .wave:
            return "挥手"
        case .okThree:
            return "OK"
        }
    }
    
    private func getGestureStatusText() -> String {
        if !vm.handLandmarks.isEmpty {
            return "检测到手部"
        } else {
            switch vm.gestureMode {
            case .wave:
                return "挥手开始/停止"
            case .okThree:
                return "OK+三指触发"
            default:
                return ""
            }
        }
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

// MARK: - 调参抽屉（保持原有代码）
fileprivate struct TunerSheet: View {
    @ObservedObject var vm: CameraViewModel

    var body: some View {
        NavigationView {
            Form {
                // 手势触发
                Section(header: Text("手势触发")) {
                    Picker("触发方式", selection: $vm.gestureMode) {
                        Text("张开手掌").tag(GestureTriggerMode.wave)
                        Text("OK + 三指").tag(GestureTriggerMode.okThree)
                        Text("关闭").tag(GestureTriggerMode.off)
                    }
                    .onChange(of: vm.gestureMode) { _ in
                        vm.applyGestureConfig()
                    }
                    
                    Stepper(value: $vm.gestureSampleEvery, in: 1...5, step: 1) {
                        Text("采样间隔：每 \(vm.gestureSampleEvery) 帧")
                    }
                    .onChange(of: vm.gestureSampleEvery) { _ in
                        vm.applyGestureConfig()
                    }
                }

                // 跟随（核心参数）
                Section(header: Text("跟随参数")) {
                    HStack {
                        Text("死区宽")
                        Slider(value: $vm.tunables.deadZoneW, in: 0...0.20)
                        Text(String(format:"%.2f", vm.tunables.deadZoneW))
                    }
                    HStack {
                        Text("死区高")
                        Slider(value: $vm.tunables.deadZoneH, in: 0...0.25)
                        Text(String(format:"%.2f", vm.tunables.deadZoneH))
                    }
                    HStack {
                        Text("X 自然频率")
                        Slider(value: $vm.tunables.natFreqHzX, in: 0.2...8)
                        Text(String(format:"%.1f", vm.tunables.natFreqHzX))
                    }
                    HStack {
                        Text("Y 自然频率")
                        Slider(value: $vm.tunables.natFreqHzY, in: 0.2...8)
                        Text(String(format:"%.1f", vm.tunables.natFreqHzY))
                    }
                    HStack {
                        Text("阻尼")
                        Slider(value: $vm.tunables.damping, in: 0.5...1.2)
                        Text(String(format:"%.2f", vm.tunables.damping))
                    }
                }
            }
            .navigationTitle("参数调节")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("应用") {
                        vm.applyTunables()
                    }
                }
            }
        }
    }
}

// PreviewCanvasView 和 CanvasView 保持原有代码不变
fileprivate struct PreviewCanvasView: UIViewRepresentable {
    let image: CGImage?
    let handLandmarks: [CGPoint]
    let personBoxN: CGRect?
    let deadZoneFraction: CGSize

    func makeUIView(context: Context) -> CanvasView { CanvasView() }

    func updateUIView(_ uiView: CanvasView, context: Context) {
        uiView.updateFrameImage(image)
        uiView.renderOverlays(hand: handLandmarks, personBoxN: personBoxN,
                              deadZone: deadZoneFraction)
    }
}

fileprivate final class CanvasView: UIView {
    private let contentLayer = CALayer()
    private let personBoxLayer = CAShapeLayer()
    private let deadZoneLayer  = CAShapeLayer()
    private let skeletonLayer  = CAShapeLayer()

    private let edges: [(Int, Int)] = [
        (0,1),(1,2),(2,3),(3,4),
        (0,5),(5,6),(6,7),(7,8),
        (0,9),(9,10),(10,11),(11,12),
        (0,13),(13,14),(14,15),(15,16),
        (0,17),(17,18),(18,19),(19,20)
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.backgroundColor = UIColor.black.cgColor

        contentLayer.contentsGravity = .resizeAspectFill
        contentLayer.magnificationFilter = .nearest
        layer.addSublayer(contentLayer)

        [personBoxLayer, deadZoneLayer, skeletonLayer].forEach { l in
            l.fillColor = UIColor.clear.cgColor
            l.lineJoin  = .round
            l.lineCap   = .round
            l.contentsScale = UIScreen.main.scale
            layer.addSublayer(l)
        }
        personBoxLayer.strokeColor = UIColor.systemYellow.cgColor
        personBoxLayer.lineWidth   = 2

        deadZoneLayer.strokeColor  = UIColor.systemBlue.withAlphaComponent(0.9).cgColor
        deadZoneLayer.lineDashPattern = [6, 3]
        deadZoneLayer.lineWidth    = 1.5

        skeletonLayer.strokeColor  = UIColor.systemGreen.cgColor
        skeletonLayer.lineWidth    = 2
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.frame = bounds
        personBoxLayer.frame = bounds
        deadZoneLayer.frame  = bounds
        skeletonLayer.frame  = bounds
        CATransaction.commit()
    }

    func updateFrameImage(_ cgImage: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.contents = cgImage
        CATransaction.commit()
    }

    func renderOverlays(hand: [CGPoint], personBoxN: CGRect?, deadZone: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if let b = personBoxN, b.width > 0, b.height > 0 {
            personBoxLayer.path = UIBezierPath(roundedRect: denormRect(b, in: bounds), cornerRadius: 4).cgPath
            personBoxLayer.isHidden = false
        } else {
            personBoxLayer.path = nil
            personBoxLayer.isHidden = true
        }

        if deadZone.width > 0, deadZone.height > 0 {
            let w = bounds.width  * deadZone.width
            let h = bounds.height * deadZone.height
            let rect = CGRect(x: (bounds.width - w)/2, y: (bounds.height - h)/2, width: w, height: h)
            deadZoneLayer.path = UIBezierPath(roundedRect: rect, cornerRadius: 4).cgPath
            deadZoneLayer.isHidden = false
        } else {
            deadZoneLayer.path = nil
            deadZoneLayer.isHidden = true
        }

        if hand.count >= 21 {
            let path = UIBezierPath()
            for (a,b) in edges {
                let pa = denormPoint(hand[a], in: bounds)
                let pb = denormPoint(hand[b], in: bounds)
                path.move(to: pa); path.addLine(to: pb)
            }
            for pt in hand {
                let p = denormPoint(pt, in: bounds)
                path.move(to: CGPoint(x: p.x+1.5, y: p.y))
                path.addArc(withCenter: p, radius: 2.0, startAngle: 0, endAngle: .pi*2, clockwise: true)
            }
            skeletonLayer.path = path.cgPath
            skeletonLayer.isHidden = false
        } else {
            skeletonLayer.path = nil
            skeletonLayer.isHidden = true
        }

        CATransaction.commit()
    }

    private func denormPoint(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
    }
    private func denormRect(_ r: CGRect, in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + r.minX * rect.width,
               y: rect.minY + r.minY * rect.height,
               width: rect.width * r.width, height: rect.height * r.height)
    }
}

