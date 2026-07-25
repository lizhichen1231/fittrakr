import AVFoundation
import Vision
import UIKit

#if DEBUG
/// 【查勘#2 Q3 双流实验 harness】—— OPEN-1 分水岭实测,只查不改,用完即撤(probe/lens-recon)。
/// 两模式(各跑 10min,调用方触发前先 stop app 相机):
///  基线组 startBaseline():超广角单流 videoDataOutput,每帧跑 pose(模拟感知负载)。
///  实验组 startDual():AVCaptureMultiCamSession = 超广角感知流(每帧 pose)+ 主摄显示流(仅收帧)。
/// 每 5s 记 FPS(感知流)/ thermalState / 电量% → PerfFileLog。判据见回执。
///
/// FPS=0 定位:①相机争用(app 相机没放开 → 会话被 interrupt)→ 启动前留 0.6s 让 app sessionQueue 的 stopRunning 落地;
///           ②双流两个独立设备需各自选 isMultiCamSupported 的 activeFormat,否则连接建了不出帧;
///           ③会话中断/运行时错误/首帧到达 全部落 PerfLog,真 0 帧时日志指名卡点。
///
/// plog:探针诊断同时 print 到 Xcode 控制台 + 落 PerfFileLog(用户盯控制台,免去掏 Files 里的日志)。
/// 文件级自由函数 → 实例方法与 escaping 通知闭包都能裸调,不需要 self(仿 pinConnectionPortrait)。
fileprivate func plog(_ s: String) { print(s); PerfFileLog.shared.line(s) }

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
    private var uwGotFirst = false
    private var mainGotFirst = false
    private(set) var running = false

    // 调用方(按钮)已用 vm.stopCameraForProbe 的 completion 保证 app 相机 teardown 落地才调这里;再留 0.3s 小余量兜硬件释放延迟
    func startBaseline() { queue.asyncAfter(deadline: .now() + 0.3) { self._start(dual: false) } }
    func startDual()     { queue.asyncAfter(deadline: .now() + 0.3) { self._start(dual: true) } }

    private func _start(dual: Bool) {
        guard !running else { return }
        // 修复2:计量器互斥——探针启动即停基线计量表(app 相机将被停,计量表继续打=假数污染日志)
        if LensLoadMeter.shared.running {
            plog("⚠️ 互斥断言: 基线计量表在跑 → 强制停(探针启动,其后的基线行为假数)")
            LensLoadMeter.shared.stop()
        }
        mode = dual ? "双流" : "基线单流"
        UIDevice.current.isBatteryMonitoringEnabled = true
        uwGotFirst = false; mainGotFirst = false
        let ok = dual ? setupDual() : setupSingle()
        guard ok else { plog("Q3 \(mode): setup 失败,退出"); LensProbeStatus.shared.set("🔬 Q3 \(mode) setup 失败"); return }
        uwFrames = 0; lastTick = CACurrentMediaTime(); running = true
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume(); timer = t
        plog("════ Q3 \(mode) start(超广角感知 + \(dual ? "主摄显示流" : "无显示流"))════")
        LensProbeStatus.shared.set("🔬 Q3 \(mode) 启动…等首帧")
    }

    private func setupSingle() -> Bool {
        guard let uw = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) else {
            plog("Q3 基线: 无超广角设备"); return false
        }
        single.beginConfiguration(); single.sessionPreset = .inputPriority
        guard let i = try? AVCaptureDeviceInput(device: uw), single.canAddInput(i) else {
            plog("Q3 基线: addInput 失败"); single.commitConfiguration(); return false
        }
        single.addInput(i)
        uwOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        uwOutput.alwaysDiscardsLateVideoFrames = true
        uwOutput.setSampleBufferDelegate(self, queue: queue)
        if single.canAddOutput(uwOutput) { single.addOutput(uwOutput) }
        observe(single)
        single.commitConfiguration(); single.startRunning()
        plog("Q3 基线: 配置完成(ultrawide 单流),isRunning=\(single.isRunning)")
        return true
    }

    private func setupDual() -> Bool {
        guard AVCaptureMultiCamSession.isMultiCamSupported,
              let uw = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back),
              let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            plog("Q3 双流: 前置条件不满足(multiCam/uw/wide)"); return false
        }
        let s = AVCaptureMultiCamSession(); multiSession = s
        s.beginConfiguration()
        // 超广角感知流
        guard let ui = try? AVCaptureDeviceInput(device: uw), s.canAddInput(ui) else {
            plog("Q3 双流: uw addInput 失败"); s.commitConfiguration(); return false
        }
        s.addInputWithNoConnections(ui)
        setMultiCamFormat(uw, "超广角")   // 关键:独立设备必须选 isMultiCamSupported 格式,否则不出帧
        uwOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        uwOutput.alwaysDiscardsLateVideoFrames = true
        uwOutput.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddOutput(uwOutput) else {
            plog("Q3 双流: uwOutput canAddOutput=false"); s.commitConfiguration(); return false
        }
        s.addOutputWithNoConnections(uwOutput)
        guard let up = ui.ports(for: .video, sourceDeviceType: .builtInUltraWideCamera, sourceDevicePosition: .back).first else {
            plog("Q3 双流: uw 无 video port"); s.commitConfiguration(); return false
        }
        let uc = AVCaptureConnection(inputPorts: [up], output: uwOutput)
        if s.canAddConnection(uc) { s.addConnection(uc); pinConnectionPortrait(uc) }
        else { plog("Q3 双流: ⚠️ 超广角连接 canAddConnection=false(多摄组合不支持?)") }
        // 主摄显示流(仅收帧,模拟显示)
        if let wi = try? AVCaptureDeviceInput(device: wide), s.canAddInput(wi) {
            s.addInputWithNoConnections(wi)
            setMultiCamFormat(wide, "广角")
            mainOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            mainOutput.alwaysDiscardsLateVideoFrames = true
            mainOutput.setSampleBufferDelegate(self, queue: queue)
            if s.canAddOutput(mainOutput) {
                s.addOutputWithNoConnections(mainOutput)
                if let wp = wi.ports(for: .video, sourceDeviceType: .builtInWideAngleCamera, sourceDevicePosition: .back).first {
                    let wc = AVCaptureConnection(inputPorts: [wp], output: mainOutput)
                    if s.canAddConnection(wc) { s.addConnection(wc); pinConnectionPortrait(wc) }
                    else { plog("Q3 双流: ⚠️ 主摄连接 canAddConnection=false") }
                }
            }
        } else {
            plog("Q3 双流: 主摄 addInput 失败(仅超广角单流继续)")
        }
        observe(s)
        s.commitConfiguration()

        // ═══ 埋点1:MultiCam 配置合法性(commit 之后、startRunning 之前)═══
        // 判读:hardwareCost >1.0 = 硬件预算超限,会话 isRunning=true 但不投帧(正是 FPS=0 无首帧症状)
        logMCCost(s, "初始配置(≈1080p60×2)")
        if s.hardwareCost > 1.0 {
            setFrameRate(wide, 30, "主摄")                      // 降档B:仅降主摄帧率(超广角感知保 60)
            logMCCost(s, "降档B(主摄30fps)")
        }
        if s.hardwareCost > 1.0 {
            setMultiCamFormat(uw, "超广角", targetW: 1280)      // 降档C:双设备 720p30
            setMultiCamFormat(wide, "广角", targetW: 1280)
            setFrameRate(uw, 30, "超广角"); setFrameRate(wide, 30, "主摄")
            logMCCost(s, "降档C(双设备720p30)")
        }
        plog(String(format: "Q3 双流·埋点1 判读: 最终 hardwareCost=%.2f → %@",
                    s.hardwareCost,
                    s.hardwareCost > 1.0 ? "仍>1.0 预算超限,预期不投帧(OPEN-1 关键证据)"
                                         : "≤1.0 预算内,本行之后的配置即「能跑的最省配置」"))

        // ═══ 埋点2:连线是否建起来(同一位置)═══
        var cds: [String] = []
        for (i, c) in s.connections.enumerated() {
            let ports = c.inputPorts.map { p in
                "\(p.sourceDeviceType?.rawValue ?? "?")·\(p.mediaType.rawValue)"
            }.joined(separator: "+")
            cds.append("#\(i)[\(ports)] enabled=\(c.isEnabled) active=\(c.isActive)")
        }
        plog("Q3 双流·埋点2: connections=\(s.connections.count) " + (cds.isEmpty ? "(零连接!)" : cds.joined(separator: " | ")))

        s.startRunning()
        plog("Q3 双流: startRunning 后 isRunning=\(s.isRunning) connActive=[\(s.connections.map { $0.isActive ? "Y" : "N" }.joined(separator: ","))]")
        return true
    }

    /// 埋点1:MultiCam 预算三元组(hardwareCost/systemPressureCost/运行时 isMultiCamSupported)
    private func logMCCost(_ s: AVCaptureMultiCamSession, _ stage: String) {
        plog(String(format: "Q3 双流·埋点1 %@: hardwareCost=%.2f systemPressureCost=%.2f isMultiCamSupported(运行时)=%@",
                    stage, s.hardwareCost, s.systemPressureCost,
                    AVCaptureMultiCamSession.isMultiCamSupported ? "Y" : "N"))
    }

    /// 埋点1 降档用:锁帧率(须在 activeFormat 支持范围内;30 在 60max 格式内合法)
    private func setFrameRate(_ dev: AVCaptureDevice, _ fps: Int32, _ label: String) {
        do {
            try dev.lockForConfiguration()
            let d = CMTimeMake(value: 1, timescale: fps)
            dev.activeVideoMinFrameDuration = d
            dev.activeVideoMaxFrameDuration = d
            dev.unlockForConfiguration()
            plog("Q3 双流: \(label) 锁 \(fps)fps")
        } catch { plog("Q3 双流: \(label) 锁 \(fps)fps 失败 \(error)") }
    }

    /// 多摄独立设备:activeFormat 必须是 isMultiCamSupported 的,否则会话跑但无帧。选最接近 targetW 宽的一档(默认 1920;埋点1 降档传 1280)。
    private func setMultiCamFormat(_ dev: AVCaptureDevice, _ label: String, targetW: Int = 1920) {
        let cands = dev.formats.filter { $0.isMultiCamSupported }
        func w(_ f: AVCaptureDevice.Format) -> Int { Int(CMVideoFormatDescriptionGetDimensions(f.formatDescription).width) }
        guard let fmt = cands.min(by: { abs(w($0) - targetW) < abs(w($1) - targetW) }) else {
            plog("Q3 双流: \(label) 无 isMultiCamSupported 格式!"); return
        }
        do {
            try dev.lockForConfiguration(); dev.activeFormat = fmt; dev.unlockForConfiguration()
            let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            plog("Q3 双流: \(label) 选多摄格式 \(d.width)x\(d.height)(目标宽\(targetW))")
        } catch {
            plog("Q3 双流: \(label) lockForConfiguration 失败 \(error)")
        }
    }

    private var obsTokens: [NSObjectProtocol] = []

    /// 埋点3+修复1:中断(reason+时间戳)/RuntimeError(NSError.code)/中断结束→尝试恢复,失败自动停探针还相机。
    /// 时间戳=CACurrentMediaTime(单调秒),便于把 Zc 手动切 App 的中断从证据里剔干净。
    /// block observer 必须存 token 移除(removeObserver(self) 对 block 无效→重复 start 叠观察者,日志重复行)。
    private func observe(_ s: AVCaptureSession) {
        let nc = NotificationCenter.default
        obsTokens.append(nc.addObserver(forName: .AVCaptureSessionWasInterrupted, object: s, queue: nil) { note in
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int).map { String($0) } ?? "?"
            plog(String(format: "Q3 ⚠️ 会话被中断 t=%.3f reason=%@(1=后台 2=被其他client占用 3=多前台App 4=系统压力)", CACurrentMediaTime(), reason))
            LensProbeStatus.shared.set("🔬 Q3 会话中断 reason=\(reason)")
        })
        obsTokens.append(nc.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: s, queue: nil) { [weak self] _ in
            plog(String(format: "Q3 会话中断结束 t=%.3f → 尝试恢复 startRunning", CACurrentMediaTime()))
            guard let self = self else { return }
            self.queue.async {
                guard self.running else { return }
                if !s.isRunning { s.startRunning() }
                if s.isRunning {
                    plog("Q3 ✅ 中断恢复成功 isRunning=true")
                    LensProbeStatus.shared.set("🔬 Q3 中断恢复,继续")
                } else {
                    plog("Q3 ❌❌ 中断恢复失败(isRunning=false)→ 自动停探针,还相机给 app")
                    LensProbeStatus.shared.set("🔬 Q3 恢复失败,已自动还相机")
                    self.stop { LensProbeStatus.shared.restoreCameraHook?() }
                }
            }
        })
        obsTokens.append(nc.addObserver(forName: .AVCaptureSessionRuntimeError, object: s, queue: nil) { note in
            let e = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            plog(String(format: "Q3 ❌ RuntimeError t=%.3f code=%d domain=%@ %@", CACurrentMediaTime(), e?.code ?? 0, e?.domain ?? "?", e?.localizedDescription ?? "?"))
        })
    }

    /// 刀A:completion = 反向有序恢复——探针 session 确认释放后(主线程)才放行调用方 vm.start()。
    /// 未在跑也必须回调,否则「停探针+恢复相机」链在这里断掉,相机回不来。
    func stop(_ completion: (() -> Void)? = nil) {
        queue.async {
            guard self.running else {
                if let c = completion { DispatchQueue.main.async(execute: c) }
                return
            }
            self.timer?.cancel(); self.timer = nil
            self.obsTokens.forEach { NotificationCenter.default.removeObserver($0) }   // block token 正确移除
            self.obsTokens.removeAll()
            if self.single.isRunning { self.single.stopRunning() }
            self.single.inputs.forEach { self.single.removeInput($0) }
            self.single.outputs.forEach { self.single.removeOutput($0) }
            self.uwOutput.setSampleBufferDelegate(nil, queue: nil)     // 刀A:delegate 置 nil(下次 start 由 setup 重挂)
            self.mainOutput.setSampleBufferDelegate(nil, queue: nil)
            if self.multiSession?.isRunning == true { self.multiSession?.stopRunning() }
            self.multiSession = nil
            self.running = false
            plog("════ Q3 \(self.mode) stop → 探针session已释放 isRunning=\(self.single.isRunning) → 允许恢复 app 相机 ════")
            LensProbeStatus.shared.clear()
            if let c = completion { DispatchQueue.main.async(execute: c) }
        }
    }

    // 感知流:每帧跑 pose = 模拟真实感知负载(超广角流)
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard running else { return }
        if output === uwOutput, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            if !uwGotFirst { uwGotFirst = true; plog("Q3 ✅ 超广角首帧到达") }
            let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
            _ = try? handler.perform([poseReq])
            uwFrames += 1
        } else if output === mainOutput {
            if !mainGotFirst { mainGotFirst = true; plog("Q3 ✅ 主摄显示流首帧到达") }
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let fps = Double(uwFrames) / max(0.001, now - lastTick)
        uwFrames = 0; lastTick = now
        let tn: String = { switch ProcessInfo.processInfo.thermalState {
            case .nominal: return "nominal"; case .fair: return "fair"
            case .serious: return "serious"; case .critical: return "critical"; @unknown default: return "?" } }()
        let msg = String(format: "Q3 %@ FPS=%.0f thermal=%@ battery=%.0f%%",
                         mode, fps, tn, UIDevice.current.batteryLevel * 100)
        plog(msg)
        LensProbeStatus.shared.set("🔬 " + msg)   // 屏上 HUD
    }
}
#endif
