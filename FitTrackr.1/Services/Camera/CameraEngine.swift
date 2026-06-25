import AVFoundation
import UIKit

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
        // 方向通知在主线程开启
        DispatchQueue.main.async {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(self.handleOrientationChange),
                                                   name: UIDevice.orientationDidChangeNotification,
                                                   object: nil)
        }
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
        DispatchQueue.main.async {
            NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
    }

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

        // 方向 + 稳定 + 镜像（先设置，用 portrait 避免旋转问题）
        if let conn = videoOutput.connection(with: .video) {
            sysStabilizer.applyPreview(feel: .normal, to: conn)
            if conn.isVideoMirroringSupported { conn.isVideoMirrored = usingFront }
            if conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
        }

        session.commitConfiguration()

        // 格式选择放到 commitConfiguration 之后，单独处理
        _ = setPreferredFrameRate(60)
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

    // MARK: - Orientation

    private func currentVideoOrientation() -> AVCaptureVideoOrientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft:        return .landscapeRight
        case .landscapeRight:       return .landscapeLeft
        case .portraitUpsideDown:   return .portraitUpsideDown
        default:                    return .portrait
        }
    }

    @objc private func handleOrientationChange() {
        // 暂时禁用方向变化，避免 ProRes Raw 旋转崩溃
    }
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
            deviceTypes: [.builtInUltraWideCamera, .builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )
        guard let device =
                discovery.devices.first(where: { $0.deviceType == .builtInUltraWideCamera }) ??
                discovery.devices.first(where: { $0.deviceType == .builtInTripleCamera || $0.deviceType == .builtInDualWideCamera }) ??
                discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
        else {
            print("⚠️ 没找到后置相机"); return
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

            if device.deviceType == .builtInUltraWideCamera {
                device.videoZoomFactor = max(1.0, device.minAvailableVideoZoomFactor)
            } else {
                device.videoZoomFactor = max(0.5, device.minAvailableVideoZoomFactor)
            }

            device.unlockForConfiguration()
        } catch {
            print("⚠️ 锁定设备失败：\(error)")
        }

        let gdc = device.isGeometricDistortionCorrectionSupported ? device.isGeometricDistortionCorrectionEnabled : false
        print("✅ Using: \(device.localizedName) | type=\(device.deviceType.rawValue) | zoom=\(device.videoZoomFactor) | GDC=\(gdc)")
    }
}
