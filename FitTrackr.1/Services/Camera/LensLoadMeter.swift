import Foundation
import UIKit

#if DEBUG
/// 【查勘#2 刀B · 基线计量表】—— 用完即撤(probe/lens-recon)。
/// 基线组定义修正:判据里的基线 = 「典型负载 = 锁定跟踪 + 录制」,而 app 本身就是
/// 「现状单流跑该负载」。所以基线组不建任何探针会话——app 全链路(pose+跟踪锁定+显示+录制)
/// 照常跑,本表只是挂在 CameraViewModel 帧回调上的纯计量表:数帧,每 5s 记
/// FPS / thermalState / 电量% → PerfFileLog + 屏上 HUD。与双流实验组同判据可比。
fileprivate func mlog(_ s: String) { print(s); PerfFileLog.shared.line(s) }

final class LensLoadMeter {
    static let shared = LensLoadMeter()
    private let queue = DispatchQueue(label: "probe.q3.loadmeter")
    private var frames = 0
    private var lastTick: TimeInterval = 0
    private var timer: DispatchSourceTimer?
    private var label = ""
    /// 帧回调热路径先读它早退(不计量时零成本);探针级容忍非严格同步
    private(set) var running = false

    func start(_ label: String) {
        queue.async {
            guard !self.running else { return }
            self.label = label
            UIDevice.current.isBatteryMonitoringEnabled = true
            self.frames = 0; self.lastTick = CACurrentMediaTime(); self.running = true
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 5, repeating: 5)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume(); self.timer = t
            mlog("════ Q3 \(label) 计量 start(app 全链路照常,仅计数)════")
            LensProbeStatus.shared.set("🔬 Q3 \(label) 计量中…等首个5s采样")
        }
    }

    func stop() {
        queue.async {
            guard self.running else { return }
            self.timer?.cancel(); self.timer = nil
            self.running = false
            mlog("════ Q3 \(self.label) 计量 stop ════")
            LensProbeStatus.shared.clear()
        }
    }

    /// CameraViewModel.onFrame 每帧调一次(#if DEBUG 挂点)
    func tickFrame() {
        guard running else { return }
        queue.async { self.frames += 1 }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let fps = Double(frames) / max(0.001, now - lastTick)
        frames = 0; lastTick = now
        let tn: String = { switch ProcessInfo.processInfo.thermalState {
            case .nominal: return "nominal"; case .fair: return "fair"
            case .serious: return "serious"; case .critical: return "critical"; @unknown default: return "?" } }()
        let msg = String(format: "Q3 %@ FPS=%.0f thermal=%@ battery=%.0f%%",
                         label, fps, tn, UIDevice.current.batteryLevel * 100)
        mlog(msg)
        LensProbeStatus.shared.set("🔬 " + msg)
    }
}
#endif
