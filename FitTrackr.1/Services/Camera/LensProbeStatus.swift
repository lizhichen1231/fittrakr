import Foundation
import SwiftUI
import AVFoundation

#if DEBUG
/// 【查勘#2 探针屏上 HUD】探针跑起来的可见反馈——Q3/Q4 把实时状态写这里,CameraScreen 顶部显示。
/// 探针会 stop app 相机 → 预览变黑,靠这行大字确认"跑没跑 + 当前数"(不用翻 PerfLog)。
final class LensProbeStatus: ObservableObject {
    static let shared = LensProbeStatus()
    private init() {}
    @Published var line: String = ""       // 事件行(中断/互斥/采样等,随事件更新)
    /// 判决卡·四:常驻运行行——探针在跑期间恒显示,让 Zc 不开 Xcode 分辨「设计性黑屏」和「真故障」。
    /// 格式固定:「探针运行中 · 模式=… · 首帧=✅/❌ · FPS=… · 按■恢复相机」
    @Published var runLine: String = ""    // 空 = 没探针接管相机
    /// 取景修:探针会话的实时预览(黑屏没法对人——前5轮 Q4 跨S窗全无人的根因)。探针 start 设,stop 清。
    @Published var previewSession: AVCaptureSession? = nil
    func setPreviewSession(_ s: AVCaptureSession?) { DispatchQueue.main.async { self.previewSession = s } }
    /// 修复1:探针中断恢复失败时「还相机给 app」的通道(CameraScreen onAppear 装配 = { vm.start() })
    var restoreCameraHook: (() -> Void)? = nil
    func set(_ s: String) { DispatchQueue.main.async { self.line = s } }
    func clear()          { DispatchQueue.main.async { self.line = "" } }
    func setRun(mode: String, firstFrame: Bool, fps: Double?) {
        DispatchQueue.main.async {
            let f = fps.map { String(format: "%.0f", $0) } ?? "—"
            self.runLine = "探针运行中 · 模式=\(mode) · 首帧=\(firstFrame ? "✅" : "❌") · FPS=\(f) · 按■恢复相机"
        }
    }
    func clearRun() { DispatchQueue.main.async { self.runLine = "" } }
}

/// 取景修:探针会话实时预览层(AVCaptureVideoPreviewLayer 直连,零数据路径改动)。竖屏钉同一道 pin。
struct LensProbePreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    final class PreviewHost: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var pl: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> PreviewHost {
        let v = PreviewHost()
        v.pl.videoGravity = .resizeAspectFill
        v.pl.session = session
        if let c = v.pl.connection { pinConnectionPortrait(c) }
        return v
    }
    func updateUIView(_ v: PreviewHost, context: Context) {
        if v.pl.session !== session { v.pl.session = session }
        if let c = v.pl.connection { pinConnectionPortrait(c) }
    }
}

/// 挂载壳:探针设了 previewSession 才显示(全屏,盖住 app 冻结帧;HUD 文字在其上)
struct LensProbeLivePreviewMount: View {
    @ObservedObject var status = LensProbeStatus.shared
    var body: some View {
        if let s = status.previewSession {
            LensProbePreviewView(session: s).ignoresSafeArea()
        }
    }
}

/// 探针 HUD 视图:常驻运行行(黄,恒显)+ 事件行(cyan,随事件)。黑屏可读。加到 CameraScreen ZStack。
struct LensProbeHUDView: View {
    @ObservedObject var status = LensProbeStatus.shared
    var body: some View {
        if !status.runLine.isEmpty || !status.line.isEmpty {
            VStack(spacing: 6) {
                if !status.runLine.isEmpty {
                    Text(status.runLine)
                        .font(.system(size: 14, weight: .heavy, design: .monospaced))
                        .foregroundColor(.yellow)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                }
                if !status.line.isEmpty {
                    Text(status.line)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundColor(.cyan)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                }
                Spacer()
            }
            .padding(.top, 130)
        }
    }
}
#endif
