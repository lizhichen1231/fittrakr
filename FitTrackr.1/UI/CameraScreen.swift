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
                    pixelBuffer: vm.processedPB,
                    image: vm.processedCGImage,
                    handLandmarks: vm.handLandmarks,
                    personBoxN: vm.personBox,
                    // 死区(蓝虚线)随 debug 开关显隐:关时传 .zero → CanvasView 不画。人物框/手部骨架不受影响。
                    deadZoneFraction: vm.showDebugOverlay ? vm.deadZoneFraction : .zero
                )
                SkeletonDebugOverlayView()
                .ignoresSafeArea()

                // Debug Overlay（仅 DEBUG 模式）：总开关绑到共享 showDebugOverlay(默认关),眼睛图标切它
                #if DEBUG
                DebugOverlayView(data: vm.debugData, showAll: $vm.showDebugOverlay)
                LensProbeLivePreviewMount()   // 【查勘#2·取景修】探针实时预览(盖住冻结帧,能对人;不跑时隐藏)
                LensProbeHUDView()   // 【查勘#2】探针跑起来的屏上反馈(cyan 大字;不跑时隐藏)
                #endif

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

                    #if DEBUG
                    // FPS 测量行:DEBUG 始终显示,不依赖眼睛开关 → 凉机脱离 Xcode 也能直接读 FPS/rect/pose/tot
                    HStack {
                        Text(vm.perfMini)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.yellow)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.55), in: Capsule())
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    #endif

                    // 整合诊断行(调试):默认不显示,眼睛开关(showDebugOverlay)打开才出 → 正式画面干净
                    if vm.showDebugOverlay {
                        HStack {
                            Text(vm.perfHUD)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.green)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.55), in: Capsule())
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                    }

                    #if DEBUG
                    // 卡3 跟踪态:锁谁/状态/找回@(showDebugOverlay 开时;单色等宽,接诊断行后)
                    if vm.showDebugOverlay, !vm.trkHUD.isEmpty {
                        HStack {
                            Text(vm.trkHUD)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.white)
                                .lineLimit(1).minimumScaleFactor(0.5)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.black.opacity(0.55), in: Capsule())
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16).padding(.top, 4)
                    }
                    // 三态锁定状态机 HUD:badge 按 stateTag 上色(L绿/S黄/X红/U灰)
                    if vm.showDebugOverlay, !vm.stateHUD.isEmpty {
                        HStack {
                            Text(vm.stateHUD)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(stateColor(vm.stateTag))
                                .lineLimit(1).minimumScaleFactor(0.4)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.black.opacity(0.6), in: Capsule())
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16).padding(.top, 4)
                    }
                    // 【方案B·刀3+刀4】镜头仲裁 HUD:常驻(卡面三——Zc 不看 Xcode 也能判模式/三Z/指令/锁定态)
                    if !vm.lensHUD.isEmpty {
                        HStack {
                            Text(vm.lensHUD)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyan)
                                .lineLimit(1).minimumScaleFactor(0.4)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.black.opacity(0.6), in: Capsule())
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16).padding(.top, 4)
                    }
                    #endif

                    // 跳变取证(调试):默认不显示,眼睛开关打开才出
                    if vm.showDebugOverlay, !vm.probeHUD.isEmpty {
                        HStack {
                            Text(vm.probeHUD)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(.orange)
                                .lineLimit(1)
                                .minimumScaleFactor(0.4)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.black.opacity(0.55), in: Capsule())
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                    }

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
                #if DEBUG
                // 【画质探针·待撤】FTQ_BENCH=1 无头基准:不起相机,纯跑处理链计时(QualityProbeView.swift)
                if QualityProbeBench.benchMode { QualityProbeBench.runIfNeeded(); return }
                #endif
                forcePortrait()   // 兜底:若已卡在横屏进来,掰回竖屏
                vm.updateOutputSize(for: geo.size)
                vm.start()
                #if DEBUG
                // 【查勘#2 修复1】探针中断恢复失败 → 自动还相机给 app 的通道(probe/lens-recon 用完即撤)
                LensProbeStatus.shared.restoreCameraHook = { vm.start() }
                #endif
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

    /// 掰回竖屏(iOS16+):应对「已经卡在横屏进来」的情况。和 AppDelegate 的 .portrait mask 配合。
    #if DEBUG
    // 三态锁定状态机 HUD 色标:L=绿(锁定) S=黄(搜索) X=红(丢失) U=灰(未锁)
    private func stateColor(_ tag: String) -> Color {
        switch tag {
        case "L": return .green
        case "S": return .yellow
        case "X": return .red
        default:  return .gray
        }
    }
    #endif

    private func forcePortrait() {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        let window = scene.keyWindow ?? scene.windows.first
        window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private func toggleGesture() {
        if vm.gestureMode == .off {
            vm.gestureMode = .victory   // 默认比耶✌️
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
        case .victory:
            return "hand.raised.fingers.spread"
        }
    }
    
    private func getGestureText() -> String {
        switch vm.gestureMode {
        case .off:
            return "手势关"
        case .wave:
            return "挥手"
        case .victory:
            return "比耶"
        }
    }
    
    private func getGestureStatusText() -> String {
        if !vm.handLandmarks.isEmpty {
            return "检测到手部"
        } else {
            switch vm.gestureMode {
            case .wave:
                return "挥手开始/停止"
            case .victory:
                return "比耶✌️触发"
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
    #if DEBUG
    @State private var tier0Forced = CameraEngine.forceTier0   // 刀1 验收开关的界面态
    @State private var showQualityProbe = false                // 【画质探针·待撤】临时入口
    @State private var showDenoiseProbe = false                // 【降噪探针·待撤】临时入口
    #endif

    var body: some View {
        NavigationView {
            Form {
                // 【方案B·刀4】影子/执行开关(运行时可切,不需重 build——唯一回滚手段)。
                // ON=影子:只决策+日志+HUD,不动设备(=刀3 行为);OFF=执行:仲裁指令驱动设备 zoom 跨 S。
                Section(header: Text("🎯 镜头切换(刀4)")) {
                    Toggle(vm.lensShadowOnlyUI ? "影子模式(决策不执行)——拨开=放行执行"
                                               : "⚡ 执行中(指令驱动设备zoom)——拨回=回滚到影子",
                           isOn: $vm.lensShadowOnlyUI)
                }

                #if DEBUG
                // 【速率扫描卡·一】五档扫"眼判翻转档";切档即生效,不需重启相机
                Section(header: Text("🎚 缓推速率 (factors/s)")) {
                    Picker("rate", selection: $vm.lensRampRateUI) {
                        ForEach([Float(2.0), 1.5, 1.0, 0.7, 0.5], id: \.self) { r in
                            Text(String(format: "%.1f", r)).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                // 【画质探针·待撤】临时入口:糙,不进正式 UI,新 UI 开工时随探针整体删除
                Section(header: Text("🧪 画质探针(临时)")) {
                    Button("打开画质探针(锐化/去噪/对比)") { showQualityProbe = true }
                }

                // 【降噪探针·待撤】临时入口:时域降噪(Metal 自写核 + 估计对齐)
                Section(header: Text("🌨 降噪探针(临时)")) {
                    Button("打开降噪探针(时域/空域)") { showDenoiseProbe = true }
                }

                // 【贴边卡·四】扫描旋钮对(切档即生效):0.03/0.20 为初值档;扫 {0,0.02,0.04}×{0.10,0.20,0.35}
                Section(header: Text("📐 贴边通道:带宽(buffer) × 出门驻留(s)")) {
                    Picker("edgeBand", selection: $vm.lensEdgeBandUI) {
                        ForEach([CGFloat(0), 0.02, 0.03, 0.04], id: \.self) { v in
                            Text(String(format: "%.2f", v)).tag(v)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("exitDwell", selection: $vm.lensExitDwellUI) {
                        ForEach([0.10, 0.20, 0.35], id: \.self) { v in
                            Text(String(format: "%.2f", v)).tag(v)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                #endif

                #if DEBUG
                // 【方案B·刀1 验收开关】强制 Tier 0(超广角数字裁剪=现状)⇄ 自动(Tier 1 dualWide)。
                // 重启相机生效;控制台看「📷 刀1 能力分层」与「✅ Using:」行确认设备切换。收口时评估撤留。
                Section(header: Text("🔪 刀1 能力分层")) {
                    Button(tier0Forced ? "当前:强制 Tier 0(超广角)→ 点击切回自动(dualWide)"
                                       : "当前:自动 Tier 1(dualWide)→ 点击强制 Tier 0(超广角)") {
                        CameraEngine.forceTier0.toggle()
                        tier0Forced = CameraEngine.forceTier0
                        vm.stop(); vm.start()   // 重启相机让 useUltraWideWithGDC 重选设备
                    }
                }
                // 【查勘#2 探针触发】用完即撤(probe/lens-recon)。stopCameraForProbe 先彻底 teardown app 相机、
                // 回调里(摄像头干净释放后)才起探针会话 → 避免两个 session 抢摄像头崩溃(FigCaptureSourceRemote -17281)。
                Section(header: Text("🔬 镜头查勘探针")) {
                    // 刀B 基线负载对齐:基线组 = app 本身跑典型负载(锁跟踪+录制),不停相机不建会话,只挂计量表。
                    // 自动开录保证「录制 ON」;结束用「计量结束」钮,不要按 ⏹(那是双流/Q4 的恢复钮)。
                    Button("Q3 基线·典型负载 计量开始(自动开录,10min)") {
                        // 修复2:互斥——探针在跑(app 相机已停)时,开录也是假的,整个动作拒绝
                        guard !LensDualStreamProbe.shared.running, !LensContinuityProbe.shared.running else {
                            LensProbeStatus.shared.set("🔬 互斥: 先按⏹停探针,相机恢复后再计量"); return
                        }
                        if !vm.isRecording { vm.toggleRecord() }
                        LensLoadMeter.shared.start("基线(锁跟踪+录制)")
                    }
                    Button("Q3 基线·计量结束(停录保存)") {
                        LensLoadMeter.shared.stop()
                        if vm.isRecording { vm.toggleRecord() }
                    }
                    // 旧裸采集双流:负载未对齐,数据不作 OPEN-1 判决;留作双流通路 + 刀A 交接验证
                    Button("Q3 双流(裸采集·仅通路验证,不作判决)") { vm.stopCameraForProbe { LensDualStreamProbe.shared.startDual() } }
                    Button("Q4 连续性 ramp 1.5→2.5(对准静止目标)") { vm.stopCameraForProbe { LensContinuityProbe.shared.start() } }
                    Button("⏹ 停探针 + 恢复相机", role: .destructive) {
                        LensLoadMeter.shared.stop()   // 刀B:兜底停计量表(没在跑=no-op;录制不动,由「计量结束」管)
                        // 刀A 反向有序恢复:两探针各自确认 session 已释放(completion)后才 vm.start(),杜绝恢复侧 -17281
                        LensContinuityProbe.shared.stop {
                            LensDualStreamProbe.shared.stop {
                                vm.start()
                            }
                        }
                    }
                }
                #endif
                // 手势触发
                Section(header: Text("手势触发")) {
                    Picker("触发方式", selection: $vm.gestureMode) {
                        Text("张开手掌").tag(GestureTriggerMode.wave)
                        Text("比耶✌️").tag(GestureTriggerMode.victory)
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
        #if DEBUG
        // 【画质探针·待撤】全屏探针页,不复用任何现有布局
        .fullScreenCover(isPresented: $showQualityProbe) { QualityProbeView() }
        // 【降噪探针·待撤】同上
        .fullScreenCover(isPresented: $showDenoiseProbe) { DenoiseProbeView() }
        #endif
    }
}

// PreviewCanvasView 和 CanvasView:渲染处理后帧 + overlay(框/死区/手部骨架)。
// 由 fileprivate 放宽为 internal,使模拟器回放界面(VideoTrackingPlaybackView)能复用同一套渲染。
struct PreviewCanvasView: UIViewRepresentable {
    let pixelBuffer: CVPixelBuffer?   // 刀2:主显示路径
    let image: CGImage?               // 刀2:兜底(池失败)
    let handLandmarks: [CGPoint]
    let personBoxN: CGRect?
    let deadZoneFraction: CGSize

    func makeUIView(context: Context) -> CanvasView { CanvasView() }

    func updateUIView(_ uiView: CanvasView, context: Context) {
        uiView.updateFrame(pb: pixelBuffer, cgImage: image)
        uiView.renderOverlays(hand: handLandmarks, personBoxN: personBoxN,
                              deadZone: deadZoneFraction)
    }
}

final class CanvasView: UIView {
    private let sampleLayer = AVSampleBufferDisplayLayer()   // 刀2:主显示层,吃 CVPixelBuffer(零 createCGImage/回读)
    private let contentLayer = CALayer()                     // 刀2:兜底层(池失败→cgImage),默认隐藏
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

        // 刀2:主显示层 = AVSampleBufferDisplayLayer(吃 pb);contentLayer 兜底默认隐藏
        sampleLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(sampleLayer)

        contentLayer.contentsGravity = .resizeAspectFill
        contentLayer.magnificationFilter = .nearest
        contentLayer.isHidden = true
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
        sampleLayer.frame = bounds
        contentLayer.frame = bounds
        personBoxLayer.frame = bounds
        deadZoneLayer.frame  = bounds
        skeletonLayer.frame  = bounds
        CATransaction.commit()
    }

    // 刀2:主显示吃 pb(AVSampleBufferDisplayLayer 直显,零 createCGImage);pb 缺失才用 cgImage 兜底层。
    func updateFrame(pb: CVPixelBuffer?, cgImage: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let pb = pb {
            if contentLayer.isHidden == false { contentLayer.isHidden = true }
            if sampleLayer.isHidden { sampleLayer.isHidden = false }
            enqueue(pb)
        } else if let cg = cgImage {
            if sampleLayer.isHidden == false { sampleLayer.isHidden = true }
            if contentLayer.isHidden { contentLayer.isHidden = false }
            contentLayer.contents = cg
        }
        CATransaction.commit()
    }

    private func enqueue(_ pb: CVPixelBuffer) {
        if sampleLayer.status == .failed { sampleLayer.flush() }
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fmt)
        guard let fmt = fmt else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
                                                 formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb = sb else { return }
        // 立即显示(实时预览语义,不排队等时钟)
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary],
           let dict = arr.first {
            dict[kCMSampleAttachmentKey_DisplayImmediately as NSString] = true
        }
        if sampleLayer.isReadyForMoreMediaData { sampleLayer.enqueue(sb) }
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

