import AVFoundation
import Vision
import UIKit

#if DEBUG
/// 【查勘#2 Q3 双流实验 harness】—— OPEN-1 分水岭实测,只查不改,用完即撤(probe/lens-recon)。
/// 两模式(各跑 10min,调用方触发前先 stop app 相机):
///  基线组 startBaseline():超广角单流 videoDataOutput,每帧跑 pose(模拟感知负载)。
///  实验组 startDual():AVCaptureMultiCamSession = 超广角感知流(每帧 pose)+ 主摄显示流(仅收帧)。
/// 每 5s 记 FPS(感知流)/ thermalState / 电量% → PerfFileLog。判据见回执。
final class LensDualStreamProbe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = LensDualStreamProbe()

    private var multiSession: AVCaptureMultiCamSession?
    private let single = AVCaptureSession()
    private let uwOutput = AVCaptureVideoDataOutput()     // 感知流(超广角)
    private let mainOutput = AVCaptureVideoDataOutput()   // 显示流(主摄)
    private let queue = DispatchQueue(label: "probe.q3.dualstream", qos: .userInteractive)
    private let poseReq = VNDetectHumanBodyPoseRequest()
    private var uwFrames = 0
    private var lastTick: TimeInterval = 0
    private var timer: DispatchSourceTimer?
    private var mode = ""
    private(set) var running = false

    func startBaseline() { queue.async { self._start(dual: false) } }
    func startDual()     { queue.async { self._start(dual: true) } }

    private func _start(dual: Bool) {
        guard !running else { return }
        mode = dual ? "双流" : "基线单流"
        UIDevice.current.isBatteryMonitoringEnabled = true
        let ok = dual ? setupDual() : setupSingle()
        guard ok else { PerfFileLog.shared.line("Q3 \(mode): setup 失败,退出"); return }
        uwFrames = 0; lastTick = CACurrentMediaTime(); running = true
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume(); timer = t
        PerfFileLog.shared.line("════ Q3 \(mode) start(超广角感知 + \(dual ? "主摄显示流" : "无显示流"))════")
    }

    private func setupSingle() -> Bool {
        guard let uw = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) else { return false }
        single.beginConfiguration(); single.sessionPreset = .inputPriority
        guard let i = try? AVCaptureDeviceInput(device: uw), single.canAddInput(i) else { single.commitConfiguration(); return false }
        single.addInput(i)
        uwOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        uwOutput.alwaysDiscardsLateVideoFrames = true
        uwOutput.setSampleBufferDelegate(self, queue: queue)
        if single.canAddOutput(uwOutput) { single.addOutput(uwOutput) }
        single.commitConfiguration(); single.startRunning()
        return true
    }

    private func setupDual() -> Bool {
        guard AVCaptureMultiCamSession.isMultiCamSupported,
              let uw = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back),
              let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return false }
        let s = AVCaptureMultiCamSession(); multiSession = s
        s.beginConfiguration()
        // 超广角感知流
        guard let ui = try? AVCaptureDeviceInput(device: uw), s.canAddInput(ui) else { s.commitConfiguration(); return false }
        s.addInputWithNoConnections(ui)
        uwOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        uwOutput.alwaysDiscardsLateVideoFrames = true
        uwOutput.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddOutput(uwOutput) else { s.commitConfiguration(); return false }
        s.addOutputWithNoConnections(uwOutput)
        guard let up = ui.ports(for: .video, sourceDeviceType: .builtInUltraWideCamera, sourceDevicePosition: .back).first else { s.commitConfiguration(); return false }
        let uc = AVCaptureConnection(inputPorts: [up], output: uwOutput)
        if s.canAddConnection(uc) { s.addConnection(uc); pinConnectionPortrait(uc) }
        // 主摄显示流(仅收帧,模拟显示)
        if let wi = try? AVCaptureDeviceInput(device: wide), s.canAddInput(wi) {
            s.addInputWithNoConnections(wi)
            mainOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            mainOutput.alwaysDiscardsLateVideoFrames = true
            mainOutput.setSampleBufferDelegate(self, queue: queue)
            if s.canAddOutput(mainOutput) {
                s.addOutputWithNoConnections(mainOutput)
                if let wp = wi.ports(for: .video, sourceDeviceType: .builtInWideAngleCamera, sourceDevicePosition: .back).first {
                    let wc = AVCaptureConnection(inputPorts: [wp], output: mainOutput)
                    if s.canAddConnection(wc) { s.addConnection(wc); pinConnectionPortrait(wc) }
                }
            }
        }
        s.commitConfiguration(); s.startRunning()
        return true
    }

    func stop() {
        queue.async {
            guard self.running else { return }
            self.timer?.cancel(); self.timer = nil
            if self.single.isRunning { self.single.stopRunning() }
            self.single.inputs.forEach { self.single.removeInput($0) }
            self.single.outputs.forEach { self.single.removeOutput($0) }
            if self.multiSession?.isRunning == true { self.multiSession?.stopRunning() }
            self.multiSession = nil
            self.running = false
            PerfFileLog.shared.line("════ Q3 \(self.mode) stop ════")
        }
    }

    // 感知流:每帧跑 pose = 模拟真实感知负载(超广角流)
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard running else { return }
        if output === uwOutput, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
            _ = try? handler.perform([poseReq])
            uwFrames += 1
        }
        // mainOutput 仅收帧(模拟显示消费),不做处理
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let fps = Double(uwFrames) / max(0.001, now - lastTick)
        uwFrames = 0; lastTick = now
        let tn: String = { switch ProcessInfo.processInfo.thermalState {
            case .nominal: return "nominal"; case .fair: return "fair"
            case .serious: return "serious"; case .critical: return "critical"; @unknown default: return "?" } }()
        PerfFileLog.shared.line(String(format: "Q3 %@ FPS=%.0f thermal=%@ battery=%.0f%%",
                                       mode, fps, tn, UIDevice.current.batteryLevel * 100))
    }
}
#endif
