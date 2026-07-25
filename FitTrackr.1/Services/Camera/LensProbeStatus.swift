import Foundation
import SwiftUI

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
