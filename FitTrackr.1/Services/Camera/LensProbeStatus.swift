import Foundation
import SwiftUI

#if DEBUG
/// 【查勘#2 探针屏上 HUD】探针跑起来的可见反馈——Q3/Q4 把实时状态写这里,CameraScreen 顶部显示。
/// 探针会 stop app 相机 → 预览变黑,靠这行大字确认"跑没跑 + 当前数"(不用翻 PerfLog)。
final class LensProbeStatus: ObservableObject {
    static let shared = LensProbeStatus()
    private init() {}
    @Published var line: String = ""    // 空 = 没探针在跑
    /// 修复1:探针中断恢复失败时「还相机给 app」的通道(CameraScreen onAppear 装配 = { vm.start() })
    var restoreCameraHook: (() -> Void)? = nil
    func set(_ s: String) { DispatchQueue.main.async { self.line = s } }
    func clear()          { DispatchQueue.main.async { self.line = "" } }
}

/// 探针 HUD 视图:有内容才显示(cyan 大字,黑屏可读)。加到 CameraScreen ZStack。
struct LensProbeHUDView: View {
    @ObservedObject var status = LensProbeStatus.shared
    var body: some View {
        if !status.line.isEmpty {
            VStack {
                Text(status.line)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan)
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 130)
                Spacer()
            }
        }
    }
}
#endif
