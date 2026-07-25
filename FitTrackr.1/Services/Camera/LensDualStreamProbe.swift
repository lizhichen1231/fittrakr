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
    private var mainFrames = 0   // 帧率口径卡:显示流也计数,tick 两路分开报(产出表的实测 FPS 列)
    private var uwDev: AVCaptureDevice?      // 判决卡·三/四:遍历重配 + 运行时压力读取用
    private var mainDev: AVCaptureDevice?
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
        uwFrames = 0; mainFrames = 0; lastTick = CACurrentMediaTime(); running = true
        if dual {
            // 判决卡·三:双流 = 阶梯全遍历模式。不开 5s tick(它清帧计数,会污染每档的 10s 测量窗),
            // 计量与采样全部由 runRung 的「3s 稳定 + 10s 测量」窗自管。
            rungPassed = []; rungResults = []
            plog("════ Q3 双流·阶梯全遍历 start(A→B→C[→D],每档 3s稳定+10s测量,不因达标提前退出)════")
            LensProbeStatus.shared.setRun(mode: "Q3阶梯A", firstFrame: false, fps: nil)
            runRung(0)
        } else {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 5, repeating: 5)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume(); timer = t
            plog("════ Q3 基线单流 start(超广角感知,无显示流)════")
            LensProbeStatus.shared.setRun(mode: "Q3基线单流", firstFrame: false, fps: nil)
        }
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
        uwDev = uw   // 判决卡·四:tick 读运行时压力用
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
        uwDev = uw; mainDev = wide   // 判决卡·三:遍历重配用
        observe(s)
        s.commitConfiguration()

        // ═══ 埋点1(基点):commit 之后、startRunning 之前读一次预算——阶梯逐档的 cost 由 runRung 记 ═══
        logMCCost(s, "初始(启动前,A档配置)")

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

    // ═══ 判决卡·三:阶梯全遍历(强制走完全部档位,不因达标提前退出)═══
    private struct RungSpec { let name: String; let uwW: Int; let uwFPS: Double; let mainW: Int; let mainFPS: Double }
    private let rungs: [RungSpec] = [
        RungSpec(name: "A 1080p60×2",         uwW: 1920, uwFPS: 60, mainW: 1920, mainFPS: 60),
        RungSpec(name: "B 1080p60+主摄30",     uwW: 1920, uwFPS: 60, mainW: 1920, mainFPS: 30),
        RungSpec(name: "C 720p30×2",          uwW: 1280, uwFPS: 30, mainW: 1280, mainFPS: 30),
        RungSpec(name: "D 720p60+主摄720p30",  uwW: 1280, uwFPS: 60, mainW: 1280, mainFPS: 30),   // 仅 B/C 均未过双门时追加
    ]
    private var rungPassed: [Bool] = []      // 按执行序:A=0 B=1 C=2 (D=3)
    private var rungResults: [String] = []

    /// 逐档:重配 format/帧率 → 读双预算+双门判读 → 3s 稳定 → 10s 测量窗(帧计数)→ 档位行 → 下一档
    private func runRung(_ idx: Int) {
        guard running, let s = multiSession, let uw = uwDev, let wide = mainDev else { return }
        if idx == 3 {   // D 档条件:B、C 都没过双门才追加(判决卡·三)
            let bPass = rungPassed.count > 1 && rungPassed[1]
            let cPass = rungPassed.count > 2 && rungPassed[2]
            if bPass || cPass { plog("Q3 阶梯: D 跳过(B 或 C 已过双门)"); finishLadder(); return }
            plog("Q3 阶梯: B/C 均未过双门 → 追加 D")
        }
        guard idx < rungs.count else { finishLadder(); return }
        let r = rungs[idx]
        plog("Q3 阶梯 ▶ \(r.name) 配置中…")
        let uwDesc = setMultiCamFormat(uw, "超广角", targetW: r.uwW, targetFPS: r.uwFPS) ?? "?"
        let mainDesc = setMultiCamFormat(wide, "广角", targetW: r.mainW, targetFPS: r.mainFPS) ?? "?"
        logMCCost(s, r.name)
        plog(gateLine(s, r.name))
        let pass = gatePass(s)
        rungPassed.append(pass)
        let hw = s.hardwareCost, sp = s.systemPressureCost
        LensProbeStatus.shared.setRun(mode: "Q3阶梯\(r.name)", firstFrame: uwGotFirst, fps: nil)
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in            // 3s 稳定(丢弃)
            guard let self = self, self.running else { return }
            self.uwFrames = 0; self.mainFrames = 0
            let t0 = CACurrentMediaTime()
            self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in  // 10s 测量窗
                guard let self = self, self.running else { return }
                let dt = max(0.001, CACurrentMediaTime() - t0)
                let f = Double(self.uwFrames) / dt, mf = Double(self.mainFrames) / dt
                let line = String(format: "Q3 阶梯 ✔ %@: uw=%@ main=%@ hwCost=%.2f spCost=%.2f 实测FPS=%.0f(感知)/%.0f(显示) %@",
                                  r.name, uwDesc, mainDesc, hw, sp, f, mf, pass ? "双门过" : "双门未过")
                plog(line)
                self.rungResults.append(line)
                LensProbeStatus.shared.setRun(mode: "Q3阶梯\(r.name)", firstFrame: self.uwGotFirst, fps: f)
                self.runRung(idx + 1)
            }
        }
    }

    /// 遍历完成:汇总表逐行落 log → 停探针 session(相机仍黑,按⏹恢复)→ 事件行提示
    private func finishLadder() {
        plog("════ Q3 阶梯遍历完成(\(rungResults.count) 档)══ 汇总 ══")
        rungResults.forEach { plog("  " + $0) }
        stop {
            LensProbeStatus.shared.set("🔬 Q3 阶梯遍历完成(\(self.rungResults.count)档),数据在 PerfLog,按⏹恢复相机")
        }
    }

    /// 双门(判决卡·二):两个预算都 ≤1.0 才算过——hwCost 管硬件带宽,spCost 管持续压力(超了=掉帧/发热不可持续)
    private func gatePass(_ s: AVCaptureMultiCamSession) -> Bool {
        s.hardwareCost <= 1.0 && s.systemPressureCost <= 1.0
    }

    /// 双门判读行:两个数并排,各自达标与否 + 总判
    private func gateLine(_ s: AVCaptureMultiCamSession, _ stage: String) -> String {
        let hw = s.hardwareCost, sp = s.systemPressureCost
        return String(format: "Q3 双流·双门判读 %@: hardwareCost=%.2f(%@) systemPressureCost=%.2f(%@) → %@",
                      stage, hw, hw <= 1.0 ? "达标" : "超限", sp, sp <= 1.0 ? "达标" : "超限",
                      (hw <= 1.0 && sp <= 1.0) ? "双门通过,可持续" : "未过双门,不可持续")
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

    /// 多摄独立设备:activeFormat 必须是 isMultiCamSupported 的,否则会话跑但无帧。
    /// 帧率口径卡·二.2:优先「支持 targetFPS 且宽最接近 targetW」的多摄档,并**显式锁 targetFPS**
    /// (旧版只按宽度过滤+主路径从不锁帧率 → 默认档 30fps = FPS=30 的成因)。
    /// 无 targetFPS 多摄档时如实报「硬件不提供」,退回宽度最近档,锁到该档 maxFPS。
    /// 二.1 实读:选完打印该 format 的 videoSupportedFrameRateRanges + activeVideoMin/MaxFrameDuration 实际值。
    @discardableResult
    private func setMultiCamFormat(_ dev: AVCaptureDevice, _ label: String, targetW: Int = 1920, targetFPS: Double = 60) -> String? {
        let mc = dev.formats.filter { $0.isMultiCamSupported }
        func w(_ f: AVCaptureDevice.Format) -> Int { Int(CMVideoFormatDescriptionGetDimensions(f.formatDescription).width) }
        func maxFPS(_ f: AVCaptureDevice.Format) -> Double { f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0 }
        let withFPS = mc.filter { maxFPS($0) >= targetFPS }
        if withFPS.isEmpty {
            plog("Q3 双流: \(label) ⚠️ 硬件不提供 \(Int(targetFPS))fps 的多摄档(isMultiCamSupported 共\(mc.count)档,各档maxFPS=[\(mc.map { String(format: "%.0f", maxFPS($0)) }.joined(separator: ","))])")
        }
        let cands = withFPS.isEmpty ? mc : withFPS
        guard let fmt = cands.min(by: { abs(w($0) - targetW) < abs(w($1) - targetW) }) else {
            plog("Q3 双流: \(label) 无 isMultiCamSupported 格式!"); return nil
        }
        do {
            try dev.lockForConfiguration()
            dev.activeFormat = fmt
            let lockFPS = min(targetFPS, maxFPS(fmt))                 // 显式锁帧率(两路同口径)
            let dur = CMTimeMake(value: 1, timescale: Int32(lockFPS))
            dev.activeVideoMinFrameDuration = dur
            dev.activeVideoMaxFrameDuration = dur
            dev.unlockForConfiguration()
            let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let ranges = fmt.videoSupportedFrameRateRanges.map { String(format: "%.0f-%.0f", $0.minFrameRate, $0.maxFrameRate) }.joined(separator: "/")
            func fpsOf(_ t: CMTime) -> Double { t.value > 0 ? Double(t.timescale) / Double(t.value) : 0 }
            plog(String(format: "Q3 双流: %@ 选多摄格式 %dx%d ranges=%@ 实锁=%.0f/%.0f fps(目标 宽%d@%.0f)",
                        label, d.width, d.height, ranges,
                        fpsOf(dev.activeVideoMinFrameDuration), fpsOf(dev.activeVideoMaxFrameDuration),
                        targetW, targetFPS))
            // 档位记录列:所选分辨率 + 实锁帧率(判决卡·三)
            return String(format: "%dx%d@锁%.0f", d.width, d.height, fpsOf(dev.activeVideoMaxFrameDuration))
        } catch {
            plog("Q3 双流: \(label) lockForConfiguration 失败 \(error)"); return nil
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
            self.uwDev = nil; self.mainDev = nil
            self.running = false
            plog("════ Q3 \(self.mode) stop → 探针session已释放 isRunning=\(self.single.isRunning) → 允许恢复 app 相机 ════")
            LensProbeStatus.shared.clear()
            LensProbeStatus.shared.clearRun()   // 常驻行熄灭 = 探针不再接管相机
            if let c = completion { DispatchQueue.main.async(execute: c) }
        }
    }

    // 感知流:每帧跑 pose = 模拟真实感知负载(超广角流)
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard running else { return }
        if output === uwOutput, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            if !uwGotFirst {
                uwGotFirst = true; plog("Q3 ✅ 超广角首帧到达")
                LensProbeStatus.shared.setRun(mode: "Q3\(mode)", firstFrame: true, fps: nil)   // 常驻行:首帧翻✅
            }
            let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
            _ = try? handler.perform([poseReq])
            uwFrames += 1
        } else if output === mainOutput {
            if !mainGotFirst { mainGotFirst = true; plog("Q3 ✅ 主摄显示流首帧到达") }
            mainFrames += 1
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = max(0.001, now - lastTick)
        let fps = Double(uwFrames) / dt
        let mfps = Double(mainFrames) / dt
        uwFrames = 0; mainFrames = 0; lastTick = now
        let tn: String = { switch ProcessInfo.processInfo.thermalState {
            case .nominal: return "nominal"; case .fair: return "fair"
            case .serious: return "serious"; case .critical: return "critical"; @unknown default: return "?" } }()
        // 帧率口径:双流两路分开报(感知/显示),与基线同口径对比
        let msg = mode == "双流"
            ? String(format: "Q3 %@ FPS=%.0f(感知)/%.0f(显示) thermal=%@ battery=%.0f%%", mode, fps, mfps, tn, UIDevice.current.batteryLevel * 100)
            : String(format: "Q3 %@ FPS=%.0f thermal=%@ battery=%.0f%%", mode, fps, tn, UIDevice.current.batteryLevel * 100)
        plog(msg)
        LensProbeStatus.shared.setRun(mode: "Q3\(mode)", firstFrame: uwGotFirst, fps: fps)   // 常驻行:FPS 每 5s 刷
        LensProbeStatus.shared.set("🔬 " + msg)   // 事件行:完整采样(含 thermal/battery)
    }
}
#endif
