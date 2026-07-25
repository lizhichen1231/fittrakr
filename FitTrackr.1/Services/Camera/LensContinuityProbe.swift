import AVFoundation
import Vision
import UIKit

#if DEBUG
/// 【查勘#2 Q4 连续性探针】—— 只查不改,用完即撤(probe/lens-recon)。
/// dualWide 独立会话,videoZoomFactor 1.5→2.5 缓推(10s)跨切换点 S=2.0,逐帧记:
/// buffer WxH / 当前 zoom / 最大 pose 中心(nx,ny,归一)/ GDC 状态 → 定设计稿 §6 豁免宽度。
/// ⚠️ 起自己的 session,触发前调用方先 stop 掉 app 相机(避免双会话打架)。输出进 PerfFileLog。
fileprivate func plog(_ s: String) { print(s); PerfFileLog.shared.line(s) }   // 埋点3:同时上控制台+落盘

final class LensContinuityProbe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = LensContinuityProbe()
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "probe.q4.continuity")
    private var device: AVCaptureDevice?
    private var rampStart: TimeInterval = 0
    private let poseReq = VNDetectHumanBodyPoseRequest()
    private var frameN = 0
    private(set) var running = false

    // 调用方已用 vm.stopCameraForProbe 回调保证 app 相机 teardown;留 0.3s 小余量兜硬件释放
    func start() { queue.asyncAfter(deadline: .now() + 0.3) { self._start() } }
    private func _start() {
        guard !running else { return }
        // 修复2:计量器互斥——探针启动即停基线计量表(app 相机将被停,计量表继续打=假数)
        if LensLoadMeter.shared.running {
            plog("⚠️ 互斥断言: 基线计量表在跑 → 强制停(Q4 探针启动)")
            LensLoadMeter.shared.stop()
        }
        guard let dw = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) else {
            PerfFileLog.shared.line("Q4: dualWide 不可用,探针退出"); return
        }
        device = dw
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        guard let input = try? AVCaptureDeviceInput(device: dw), session.canAddInput(input) else {
            session.commitConfiguration(); PerfFileLog.shared.line("Q4: 加输入失败"); return
        }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        if let conn = output.connection(with: .video) { pinConnectionPortrait(conn) }
        session.commitConfiguration()
        try? dw.lockForConfiguration(); dw.videoZoomFactor = 1.5; dw.unlockForConfiguration()
        observe(session)   // 埋点3+修复1:中断/错误/恢复(放 startRunning 前——更早会在 bail 路径漏 token)
        session.startRunning()
        rampStart = CACurrentMediaTime(); frameN = 0; running = true
        PerfFileLog.shared.line("════ Q4 连续性探针 start(dualWide,ramp 1.5→2.5 跨 S=2.0,静止目标对准)════")
    }

    private var obsTokens: [NSObjectProtocol] = []

    /// 埋点3+修复1(Q4 版):中断 reason+时间戳 / RuntimeError code / 中断结束→尝试恢复,失败自动停探针还相机。
    private func observe(_ s: AVCaptureSession) {
        let nc = NotificationCenter.default
        obsTokens.append(nc.addObserver(forName: .AVCaptureSessionWasInterrupted, object: s, queue: nil) { note in
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int).map { String($0) } ?? "?"
            plog(String(format: "Q4 ⚠️ 会话被中断 t=%.3f reason=%@(1=后台 2=被其他client占用 3=多前台App 4=系统压力)", CACurrentMediaTime(), reason))
            LensProbeStatus.shared.set("🔬 Q4 会话中断 reason=\(reason)")
        })
        obsTokens.append(nc.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: s, queue: nil) { [weak self] _ in
            plog(String(format: "Q4 会话中断结束 t=%.3f → 尝试恢复 startRunning", CACurrentMediaTime()))
            guard let self = self else { return }
            self.queue.async {
                guard self.running else { return }
                if !s.isRunning { s.startRunning() }
                if s.isRunning {
                    plog("Q4 ✅ 中断恢复成功 isRunning=true")
                } else {
                    plog("Q4 ❌❌ 中断恢复失败(isRunning=false)→ 自动停探针,还相机给 app")
                    LensProbeStatus.shared.set("🔬 Q4 恢复失败,已自动还相机")
                    self.stop { LensProbeStatus.shared.restoreCameraHook?() }
                }
            }
        })
        obsTokens.append(nc.addObserver(forName: .AVCaptureSessionRuntimeError, object: s, queue: nil) { note in
            let e = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            plog(String(format: "Q4 ❌ RuntimeError t=%.3f code=%d domain=%@ %@", CACurrentMediaTime(), e?.code ?? 0, e?.domain ?? "?", e?.localizedDescription ?? "?"))
        })
    }

    /// 刀A:completion = 反向有序恢复——探针 session 确认释放后(主线程)才放行调用方 vm.start()。
    /// 未在跑也必须回调,否则「停探针+恢复相机」链断掉。ramp 到 2.5 的自停走 completion=nil,不受影响。
    func stop(_ completion: (() -> Void)? = nil) {
        queue.async {
            guard self.running else {
                if let c = completion { DispatchQueue.main.async(execute: c) }
                return
            }
            self.obsTokens.forEach { NotificationCenter.default.removeObserver($0) }   // block token 正确移除
            self.obsTokens.removeAll()
            if self.session.isRunning { self.session.stopRunning() }
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            self.output.setSampleBufferDelegate(nil, queue: nil)   // 刀A:delegate 置 nil(下次 start 由 _start 重挂)
            self.running = false
            PerfFileLog.shared.line("════ Q4 stop → 探针session已释放 isRunning=\(self.session.isRunning) → 允许恢复 app 相机 ════")
            LensProbeStatus.shared.set("🔬 Q4 完成(ramp 到 2.5,已停)")
            if let c = completion { DispatchQueue.main.async(execute: c) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard running, let dw = device, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // ramp:0.1/s,10s 从 1.5 推到 2.5
        let z = min(2.5, 1.5 + CGFloat(CACurrentMediaTime() - rampStart) * 0.1)
        try? dw.lockForConfiguration(); dw.videoZoomFactor = z; dw.unlockForConfiguration()
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var cx = -1.0, cy = -1.0
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        if (try? handler.perform([poseReq])) != nil,
           let obs = (poseReq.results?.max { a, b in (a.confidence) < (b.confidence) }),
           let pts = try? obs.recognizedPoints(.all) {
            let valid = pts.values.filter { $0.confidence > 0.3 }
            if !valid.isEmpty {
                cx = valid.map { Double($0.location.x) }.reduce(0,+) / Double(valid.count)
                cy = valid.map { Double($0.location.y) }.reduce(0,+) / Double(valid.count)
            }
        }
        frameN += 1
        let gdc = dw.isGeometricDistortionCorrectionSupported ? dw.isGeometricDistortionCorrectionEnabled : false
        let lens = z < 2.0 ? "UW" : "Wide"   // S=2.0 为界(近似;真实切换由虚拟设备内部管,看 buf/center 是否跳)
        let msg = String(format: "Q4 f%d zoom=%.2f lens≈%@ buf=%dx%d poseC=(%.3f,%.3f) GDC=%@",
                         frameN, Double(z), lens, w, h, cx, cy, gdc ? "Y" : "N")
        PerfFileLog.shared.line(msg)
        LensProbeStatus.shared.set("🔬 " + msg)   // 屏上 HUD
        if z >= 2.5 { stop() }
    }
}
#endif
