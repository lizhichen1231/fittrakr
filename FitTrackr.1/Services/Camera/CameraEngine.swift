import AVFoundation
import UIKit

/// 竖屏硬钉:把 capture connection 的旋转固定为 portrait,**永不跟随设备物理朝向**。
/// iOS 17+ 用 videoRotationAngle=90(portrait);videoOrientation 在 iOS 17+ 已废弃,且部分格式下
/// 根本不 pin → 连接回落到跟随设备 = 正是「横过来画面转 90°」的根因。iOS 16 回退 videoOrientation=.portrait。
/// 镜像(isVideoMirrored)与本函数无关,各调用点自理。所有 videoDataOutput connection 都必须过这一道。
func pinConnectionPortrait(_ connection: AVCaptureConnection) {
    var how = "none(两路都不支持!)"
    if #available(iOS 17.0, *), connection.isVideoRotationAngleSupported(90) {
        connection.videoRotationAngle = 90   // 90° = 竖屏(传感器横向原生 → 转正)
        how = "videoRotationAngle=90 → 实读=\(connection.videoRotationAngle)"
    } else if connection.isVideoOrientationSupported {
        connection.videoOrientation = .portrait
        how = "videoOrientation=.portrait(废弃兜底,iOS17 可能不 pin→跟设备转)"
    }
    #if DEBUG
    let sup90: Bool = { if #available(iOS 17.0, *) { return connection.isVideoRotationAngleSupported(90) }; return false }()
    let msg = "🔒 pinPortrait → \(how) | 支持90=\(sup90)"
    print(msg)
    PerfFileLog.shared.line(msg)
    #endif
}

protocol CameraEngineDelegate: AnyObject {
    func cameraEngine(_ engine: CameraEngine,
                      didOutputWideFrame: CVPixelBuffer,
                      telephotoFrame: CVPixelBuffer?,
                      pts: CMTime)
    func cameraEngine(_ engine: CameraEngine,
                      didOutputAudio sampleBuffer: CMSampleBuffer)
}

 class CameraEngine: NSObject {

    // Core
    private let session = AVCaptureSession()
    var captureSession: AVCaptureSession {
        multiCamManager?.session ?? session
    }

    // 多摄管理器
    private var multiCamManager: MultiCamManager?
    private(set) var isMultiCamActive: Bool = false

    // I/O
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    // Queues
    private let sessionQueue = DispatchQueue(label: "cam.session") // 所有会话相关放同一串行队列
    private let videoQueue   = DispatchQueue(label: "cam.video", qos: .userInteractive)
    private let audioQueue   = DispatchQueue(label: "cam.audio")

    weak var delegate: CameraEngineDelegate?

    // State
    private var configured = false
    private(set) var usingFront = false

    // Stabilizer（见 AppleStabilizer.swift）
    private let sysStabilizer = AppleStabilizer()

    override init() { super.init() }

    // MARK: - Lifecycle

    func start() {
        #if DEBUG
        // 埋点卡三:形态标注首行——从执行器常量实导,避免不同形态数据混比(文案不写死)。
        PerfFileLog.shared.line(String(format: "🏷 形态=缓推不对称(W%.1f/U%.1f,0=瞬切) 执行器=setLensDeviceZoom白名单 贴边带=%.2f 出门驻=%.2f 前置驻=%.1f",
                                       CameraEngine.lensRampRateToWide, CameraEngine.lensRampRateToUW,
                                       LensArbiter.edgeBandBuffer, LensArbiter.exitDwellSec,
                                       LensArbiter.Params().dwellSec))
        LensReconProbe.dumpDualWide()   // 【查勘#2 Q2 探针】用完即撤(probe/lens-recon)
        #endif
        // 任务零:全应用锁死竖屏——已删设备方向通知订阅(采集层 connection 一次性设死 .portrait,不再跟随旋转)
        sessionQueue.async {
            if !self.configured { self.configureSession() }
            if self.isMultiCamActive {
                self.multiCamManager?.start()
            } else {
                self.session.startRunning()
            }
            self.dumpCaptureConfig()   // 一次性:打印实际捕获配置(format maxFPS vs 当前锁的 fps)
        }
    }

    // 【方案B·刀1 能力分层】Tier 1 = dualWide 虚拟设备(zoom 锁 1.0 → 物理恒 UW,行为冻结);
    // Tier 0 = 无 dualWide 或强制开关 → 现状超广角+数字裁剪,一行不改。
    // forceTier0:验收开关(TunerSheet DEBUG 按钮切,重启相机生效)——本刀要求 Tier 0 可切换验证。
    static var forceTier0 = false

    // 【刀3 影子模式】仲裁输入的采集侧事实(useUltraWideWithGDC 每次选定设备后更新;只读)
    static var currentTier1 = false                    // 本次选定是否 dualWide(Tier 1)
    static var lastSelectedDeviceZoom: CGFloat = 1.0   // 当前设备 zoom(执行器写入时同步更新)

    // 【刀4 执行放行】仲裁指令 → 设备 zoom 的唯一合法通道。
    // TrackingController 经此静态钩子调 setLensDeviceZoom(useUltraWideWithGDC 装配)。
    static var lensZoomExecutor: ((CGFloat, String) -> Void)?
    private var activeVideoDevice: AVCaptureDevice?    // useUltraWideWithGDC 选定的设备
    private var sanctionedDeviceZoom: CGFloat = 1.0    // 白名单目标:守卫只放行等于它的写入

    /// 除数/测量归一的每帧实读通道(useUltraWideWithGDC 装配;TrackingController 每帧读)。
    /// 【终审回落】缓推机制已撤(lensRampRate 一并删,不留死常量);瞬切下本通道在跳变检出帧
    /// 读到阶跃 → 帧入口重映射自动退化为一步式(k=2 单次),正是回落条款要的形态。
    static var liveDeviceZoomReader: (() -> CGFloat)?

    /// 【PTS对齐卡·三】PTS→host 钟换算(采集时刻查除数用)。会话带音频 → synchronizationClock
    /// 不能假设与 host 同源,CMSyncConvertTime 做 API 级精确映射(零经验标定)。nil=交接期/非实时源。
    static var captureTimeConverter: ((CMTime) -> Double)?

    /// 刀4:唯一合法设备 zoom 写入口(仲裁指令专用)。写前更新白名单 → KVO 守卫放行;其余写入照拦。
    // 【单人收口卡·一】回缓推:闪回双向出现,归因除数时延——瞬切下错位=全步长(2×,必可见);
    // 缓推下每帧 k≈1.03,帧入口 readback+逐帧微重映射(帧序修正后)吸收到不可见量级。
    // 【掉帧缓解+收尾卡·三】速率决策落定:不对称——toWide 0.7(首破感知阈 <1%,钳位帧全档为 0);
    // toUW 2.0(降速只买更长钳位冻结,0.5 档达 2.1s)。掉帧与速率无关(指纹跨四档),不影响本决策。
    // 面板选择器绑 toWide 档(1.0 vs 0.7 交替复验用);toUW 固定。0 = 瞬切(后备形态,直写)。
    static var lensRampRateToWide: Float = 0.7
    static var lensRampRateToUW: Float = 2.0

    func setLensDeviceZoom(_ z: CGFloat, reason: String) {
        sessionQueue.async {
            guard let dev = self.activeVideoDevice else {
                print("🎯 LENS-EXEC 失败: 无活跃设备(reason=\(reason))"); return
            }
            self.sanctionedDeviceZoom = z
            do {
                try dev.lockForConfiguration()
                let rate = z > dev.videoZoomFactor ? CameraEngine.lensRampRateToWide
                                                    : CameraEngine.lensRampRateToUW
                if rate > 0 {
                    dev.ramp(toVideoZoomFactor: z, withRate: rate)
                } else {
                    dev.videoZoomFactor = z
                }
                dev.unlockForConfiguration()
            } catch {
                print("🎯 LENS-EXEC 失败: lockForConfiguration \(error)(reason=\(reason))"); return
            }
            let rateUsed = z > 1.5 ? CameraEngine.lensRampRateToWide : CameraEngine.lensRampRateToUW
            let form = rateUsed > 0 ? String(format: "缓推(rate %.1f/s)", rateUsed) : "瞬切"
            let msg = "🎯 LENS-EXEC \(form)→\(String(format: "%.2f", z)) 实读起点=\(String(format: "%.2f", dev.videoZoomFactor)) reason=\(reason)"
            print(msg)
            #if DEBUG
            PerfFileLog.shared.line(msg)
            #endif
        }
    }

    // 【刀1收口→刀4 白名单化】KVO 守卫:只放行「等于 sanctionedDeviceZoom(setLensDeviceZoom 刚批准的值)」
    // 的写入;其余任何来源写设备 zoom → 断言(DEBUG 爆)+ log + 拦回白名单值。旁路写入依旧无路可走。
    // 探针交接(stopForProbe)时解除;vm.start() 重新武装。
    private var zoomGuardObs: NSKeyValueObservation?
    private func armZoomGuard(_ dev: AVCaptureDevice) {
        zoomGuardObs?.invalidate()
        zoomGuardObs = dev.observe(\.videoZoomFactor, options: [.new]) { [weak self] d, _ in
            let z = d.videoZoomFactor
            let allowed = self?.sanctionedDeviceZoom ?? 1.0
            guard abs(z - allowed) > 0.001 else { return }
            // 缓推兼容:ramp 期间中间值放行(系统在朝白名单目标插值);终值仍受精确校验——
            // 野 ramp 到非白名单目标,ramp 结束后首个事件/写入即被拦回。
            if d.isRampingVideoZoom { return }
            let msg = "❌ zoom守卫断言: device.videoZoomFactor 被写成 \(String(format: "%.2f", z)),白名单=\(String(format: "%.2f", allowed))(仅 setLensDeviceZoom 合法)→ 拦回"
            print(msg)
            #if DEBUG
            PerfFileLog.shared.line(msg)   // PerfFileLog 是 DEBUG-only 类,裸调会破 Release 构建
            #endif
            assertionFailure(msg)   // DEBUG 当场爆定位写入方;Release 只拦回
            self?.sessionQueue.async {
                if (try? d.lockForConfiguration()) != nil { d.videoZoomFactor = allowed; d.unlockForConfiguration() }
            }
        }
    }

    // 一次性 dump 实际捕获配置(session 启动后调一次,非每帧)。同时写静态量供 HUD 读。
    static var lastCaptureConfig = ""
    func dumpCaptureConfig() {
        func fpsOf(_ t: CMTime) -> Double { (t.value > 0 && t.timescale > 0) ? Double(t.timescale) / Double(t.value) : 0 }
        var lines: [String] = []
        func describe(_ dev: AVCaptureDevice, _ label: String) {
            let f = dev.activeFormat
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let maxFR = f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            lines.append(String(format: "%@ %dx%d fmtMax=%.0f 锁=%.0f/%.0f",
                                label, dims.width, dims.height, maxFR,
                                fpsOf(dev.activeVideoMinFrameDuration), fpsOf(dev.activeVideoMaxFrameDuration)))
        }
        if isMultiCamActive {
            lines.append("MULTICAM 双路(无60锁)")
            multiCamManager?.dumpConfig(describe)
        } else {
            lines.append("SINGLE preset=\(session.sessionPreset.rawValue)")
            for input in session.inputs {
                if let di = input as? AVCaptureDeviceInput, di.device.hasMediaType(.video) { describe(di.device, "wide") }
            }
        }
        let text = lines.joined(separator: " | ")
        CameraEngine.lastCaptureConfig = text
        print("📸 捕获配置: " + text)
    }

    func stop() {
        sessionQueue.async {
            if self.isMultiCamActive {
                self.multiCamManager?.stop()
            } else {
                self.session.stopRunning()
            }
        }
        // 任务零:已删设备方向通知退订(不再订阅方向)
    }

    #if DEBUG
    /// 【查勘#2 探针专用·probe/lens-recon】彻底停采集并**移除输入释放摄像头设备**,teardown 落地后回调(主线程)。
    /// 为什么不用普通 stop():stop() 只 stopRunning(),硬件释放有延迟且输入仍占设备 → 探针紧接着开自己的 session
    /// 抢同一后置摄像头会撞 FigCaptureSourceRemote err=-17281 硬 assert(整个 app 被杀)。移除输入强制释放 + 用
    /// completion 精确等到干净再放探针,替代不可靠的固定延时。configured=false → 恢复相机时 start() 会重新配置。
    func stopForProbe(_ completion: @escaping () -> Void) {
        sessionQueue.async {
            if self.isMultiCamActive {
                self.multiCamManager?.stop()
            } else {
                self.session.stopRunning()
                self.session.beginConfiguration()
                self.session.inputs.forEach { self.session.removeInput($0) }
                self.session.outputs.forEach { self.session.removeOutput($0) }
                self.session.commitConfiguration()
                // 刀A:delegate 置 nil——不留任何指向 app 管线的回调,交接干净
                self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
                self.audioOutput.setSampleBufferDelegate(nil, queue: nil)
            }
            self.configured = false
            // 刀1收口:交接时解除 zoom 钳死——探针(Q4 ramp)是合法的设备 zoom 使用方;vm.start() 重新武装
            self.zoomGuardObs?.invalidate(); self.zoomGuardObs = nil
            // 刀4:执行通道随交接下线(防探针期间误执行);vm.start() 重装配
            CameraEngine.lensZoomExecutor = nil
            CameraEngine.captureTimeConverter = nil
            CameraEngine.liveDeviceZoomReader = nil
            self.activeVideoDevice = nil
            self.sanctionedDeviceZoom = 1.0
            // 刀A:确认 isRunning=false 落日志——这行必须出现在探针「配置完成」之前,是有序交接的凭证
            let msg = "🔁 探针交接: app相机已停 isRunning=\(self.session.isRunning) inputs=\(self.session.inputs.count) outputs=\(self.session.outputs.count) delegate=nil → \(self.session.isRunning ? "⚠️ 仍在运行,交接失败!" : "已释放,允许探针接管")"
            print(msg); PerfFileLog.shared.line(msg)
            DispatchQueue.main.async { completion() }
        }
    }
    #endif

    deinit { NotificationCenter.default.removeObserver(self) }

    // 录制阶段切换稳定：开启 -> 更稳；关闭 -> 恢复预览低延迟
    func setStabilizationForRecording(_ on: Bool) {
        sessionQueue.async {
            guard let conn = self.videoOutput.connection(with: .video),
                  conn.isVideoStabilizationSupported else { return }
            if on {
                self.sysStabilizer.applyRecordingBest(to: conn)   // cinematic / extended（设备支持时）
            } else {
                self.sysStabilizer.turnOff(on: conn)
                self.sysStabilizer.applyPreview(feel: .normal, to: conn) // 低延迟 standard
            }
        }
    }

    // MARK: - Session setup (on sessionQueue)

    private func configureSession() {
        configured = true

        // 调试：打印多摄检测结果
        let info = DeviceCameraInfo.shared
        print("📷 [MultiCam诊断] canUseMultiCam=\(info.canUseMultiCam)")
        print("📷 [MultiCam诊断] isMultiCamSupported=\(info.isMultiCamSupported)")
        print("📷 [MultiCam诊断] hasTelephoto=\(info.hasTelephoto), zoom=\(info.telephotoZoom)x")

        // 尝试多摄模式
        if info.canUseMultiCam {
            let manager = MultiCamManager()
            manager.delegate = self
            print("📷 [MultiCam诊断] 尝试 setup()...")
            if manager.setup() {
                multiCamManager = manager
                isMultiCamActive = true

                // 音频需要单独添加到多摄 session
                if let multiSession = manager.session {
                    multiSession.beginConfiguration()
                    if let mic = AVCaptureDevice.default(for: .audio),
                       let micInput = try? AVCaptureDeviceInput(device: mic),
                       multiSession.canAddInput(micInput) {
                        multiSession.addInput(micInput)
                    }
                    if multiSession.canAddOutput(audioOutput) {
                        multiSession.addOutput(audioOutput)
                    }
                    audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
                    multiSession.commitConfiguration()
                }

                print("📷 ✅ CameraEngine: 多摄模式已启用 (广角 + \(info.telephotoZoom)x长焦)")
                return
            } else {
                print("📷 ❌ MultiCamManager.setup() 失败，回退单摄")
            }
        } else {
            if info.hasTelephoto && !info.isTelephotoUsable {
                print("📷 ℹ️ 长焦 \(info.telephotoZoom)x 超限，使用广角+数码裁切模式")
            } else if !info.hasTelephoto {
                print("📷 ℹ️ 设备无长焦镜头，使用广角+数码裁切模式")
            } else {
                print("📷 ⚠️ 多摄不可用，使用单摄模式")
            }
        }

        // 回退到单摄模式
        isMultiCamActive = false
        configureSingleCamSession()
    }

    private func configureSingleCamSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        // 选相机：优先后置
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        let back  = discovery.devices.first { $0.position == .back }
        let front = discovery.devices.first { $0.position == .front }
        let camera = back ?? front
        usingFront = (camera?.position == .front)

        // Video input
        if let cam = camera,
           let input = try? AVCaptureDeviceInput(device: cam),
           session.canAddInput(input) {
            session.addInput(input)
            // 连续 AF/AE
            if (try? cam.lockForConfiguration()) != nil {
                if cam.isFocusModeSupported(.continuousAutoFocus)       { cam.focusMode = .continuousAutoFocus }
                if cam.isExposureModeSupported(.continuousAutoExposure) { cam.exposureMode = .continuousAutoExposure }
                cam.unlockForConfiguration()
            }
        }

        // Audio input
        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        // Video output
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)

        // Audio output
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)

        // 稳定 + 镜像(竖屏 pin 挪到最终格式敲定之后,见下)
        if let conn = videoOutput.connection(with: .video) {
            sysStabilizer.applyPreview(feel: .normal, to: conn)
            if conn.isVideoMirroringSupported { conn.isVideoMirrored = usingFront }
        }

        session.commitConfiguration()

        // 格式选择放到 commitConfiguration 之后，单独处理
        _ = setPreferredFrameRate(60)

        // 竖屏硬钉:**必须在 setPreferredFrameRate(最终 1080p60 格式)之后** —— 否则对临时格式
        // isVideoRotationAngleSupported(90) 可能 false → 掉废弃 videoOrientation 兜底 → iOS17 跟设备转(横屏 bug 真凶)。
        if let conn = videoOutput.connection(with: .video) {
            pinConnectionPortrait(conn)
        }
    }

    // 设置期望帧率（在 sessionQueue 调用）
    @discardableResult
    func setPreferredFrameRate(_ fps: Int) -> Bool {
        guard let device = (session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }
            .first { $0.hasMediaType(.video) }) else { return false }

        // 选一个既支持该 fps、又分辨率≈1080p 的 format(不再取最大/4K——4K 处理太慢把帧率拖到 ~32)
        // 过滤掉 ProRes Raw / Bayer 等不支持旋转的格式
        let matched = device.formats.filter { format in
            let supportsFrameRate = format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= Double(fps) && Double(fps) <= $0.maxFrameRate
            }

            let desc = format.formatDescription
            let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)

            let safeFormats: [FourCharCode] = [
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelFormatType_32BGRA,
                kCVPixelFormatType_32ARGB,
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            ]

            let isSafeFormat = safeFormats.contains(mediaSubType)

            return supportsFrameRate && isSafeFormat
        }.sorted { f1, f2 in
            // 取「面积最接近 1080p(1920×1080)」的 60 帧 format,而不是最大的(4K)
            let target = 1920 * 1080
            let d1 = CMVideoFormatDescriptionGetDimensions(f1.formatDescription)
            let d2 = CMVideoFormatDescriptionGetDimensions(f2.formatDescription)
            let a1 = Int(d1.width) * Int(d1.height)
            let a2 = Int(d2.width) * Int(d2.height)
            return abs(a1 - target) < abs(a2 - target)
        }

        guard let targetFormat = matched.first else { return false }

        do {
            try device.lockForConfiguration()
            device.activeFormat = targetFormat
            let duration = CMTimeMake(value: 1, timescale: Int32(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            return true
        } catch {
            return false
        }
    }

    // 任务零:已删 currentVideoOrientation()(读 UIDevice.orientation,死代码,从未被调用)
    //         + handleOrientationChange()(空 no-op stub)。采集层 connection 一次性设死 .portrait。
}

// MARK: - 单摄 Delegates
extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            delegate?.cameraEngine(self, didOutputWideFrame: pb, telephotoFrame: nil, pts: pts)
        } else if output === audioOutput {
            delegate?.cameraEngine(self, didOutputAudio: sampleBuffer)
        }
    }
}

// MARK: - 多摄 Delegates
extension CameraEngine: MultiCamDelegate {
    func multiCam(_ manager: MultiCamManager, didOutputWide frame: CVPixelBuffer, timestamp: CMTime) {
        delegate?.cameraEngine(self, didOutputWideFrame: frame, telephotoFrame: manager.latestTelephotoFrame, pts: timestamp)
    }

    func multiCam(_ manager: MultiCamManager, didOutputTelephoto frame: CVPixelBuffer, timestamp: CMTime) {
        // 长焦帧在广角回调中通过 latestTelephotoFrame 获取，无需单独处理
    }
}

// MARK: - Ultra Wide + GDC
extension CameraEngine {

    /// 切到 0.5x（Ultra Wide/等效）并尽量开启系统几何畸变矫正（GDC）
    func useUltraWideWithGDC(_ enable: Bool = true) {
        // 多摄模式下不需要切换，已经独立使用广角
        guard !isMultiCamActive else {
            print("📷 多摄模式，跳过 Ultra Wide 切换")
            return
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInDualWideCamera, .builtInUltraWideCamera, .builtInTripleCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )
        // 【方案B·刀1 能力分层】Tier 1:优先 dualWide 虚拟设备(物理切换后续由它托管;本刀 zoom 锁 1.0 = 恒 UW,行为冻结)。
        // Tier 0:无 dualWide 或 forceTier0 → 现状链(超广角优先)原样。
        let dualWide = discovery.devices.first(where: { $0.deviceType == .builtInDualWideCamera })
        let tier1 = (dualWide != nil) && !CameraEngine.forceTier0
        guard let device: AVCaptureDevice = tier1 ? dualWide :
                (discovery.devices.first(where: { $0.deviceType == .builtInUltraWideCamera }) ??
                 discovery.devices.first(where: { $0.deviceType == .builtInTripleCamera }) ??
                 discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera }))
        else {
            print("⚠️ 没找到后置相机"); return
        }
        print("📷 刀1 能力分层: \(tier1 ? "Tier 1(dualWide 虚拟设备,zoom=1.0 物理恒UW)" : "Tier 0(超广角数字裁剪=现状)") forceTier0=\(CameraEngine.forceTier0) dualWide存在=\(dualWide != nil)")
        CameraEngine.currentTier1 = tier1              // 刀3:影子仲裁读
        CameraEngine.lastSelectedDeviceZoom = 1.0      // 起始 1.0(执行器写入时更新)
        // 刀4:装配执行通道 + 白名单归位(设备重选=回到 1.0 基态)
        activeVideoDevice = device
        sanctionedDeviceZoom = 1.0
        CameraEngine.lensZoomExecutor = { [weak self] z, r in self?.setLensDeviceZoom(z, reason: r) }
        // 【闪动修】除数逐帧实读通道:缓推期间裁剪/测量归一必须贴着光学实际值走,不能用目标值
        CameraEngine.liveDeviceZoomReader = { [weak device] in device?.videoZoomFactor ?? 1.0 }
        // 【PTS对齐卡·三】采集时刻换算器:帧 PTS(会话同步钟)→ host 秒(CACurrentMediaTime 同源)
        CameraEngine.captureTimeConverter = { [weak self] pts in
            guard let s = self?.session, let sync = s.synchronizationClock else {
                return CACurrentMediaTime()   // 无同步钟(异常):回落"现在" = 旧行为
            }
            return CMTimeGetSeconds(CMSyncConvertTime(pts, from: sync, to: CMClockGetHostTimeClock()))
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs {
            if let di = input as? AVCaptureDeviceInput, di.device.hasMediaType(.video) {
                session.removeInput(di)
            }
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
        } catch {
            print("⚠️ 创建视频输入失败：\(error)")
            return
        }

        do {
            try device.lockForConfiguration()

            if device.isGeometricDistortionCorrectionSupported {
                device.isGeometricDistortionCorrectionEnabled = enable
            }

            if device.deviceType == .builtInDualWideCamera {
                // 刀1:dualWide zoom 硬锁 1.0 = 物理恒 UW(S=2.0 切换点远在上方,虚拟设备不会切镜头)。
                // 全工程唯一动设备 zoom 的地方就是本函数(已核),数字裁剪 zoom 在下游 renderCrop,与此无关。
                device.videoZoomFactor = 1.0
            } else if device.deviceType == .builtInUltraWideCamera {
                device.videoZoomFactor = max(1.0, device.minAvailableVideoZoomFactor)
            } else {
                device.videoZoomFactor = max(0.5, device.minAvailableVideoZoomFactor)
            }

            device.unlockForConfiguration()
        } catch {
            print("⚠️ 锁定设备失败：\(error)")
        }

        // 刀1:运行时切 Tier(强制开关翻转后 stop→start)走到这里时 session 已 configured,
        // configureSession 不会再跑 → 新设备的 1080p60 格式锁在这补(冷启动路径不变:configureSession 里那次生效)。
        if configured { _ = setPreferredFrameRate(60) }

        // 刀1收口:钳死武装(格式敲定之后——格式变更会把 zoom 重置回 1.0,先钳会误报)
        armZoomGuard(device)

        let gdc = device.isGeometricDistortionCorrectionSupported ? device.isGeometricDistortionCorrectionEnabled : false
        print("✅ Using: \(device.localizedName) | type=\(device.deviceType.rawValue) | zoom=\(device.videoZoomFactor) | GDC=\(gdc)")

        // 横屏真凶:超广角切换 removeInput/addInput 后是**新连接,从未 pin** → 跟设备转。这里补钉竖屏(与单摄同一道)。
        if let conn = videoOutput.connection(with: .video) {
            pinConnectionPortrait(conn)
        }
    }
}
