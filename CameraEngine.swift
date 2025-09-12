import AVFoundation
import UIKit

protocol CameraEngineDelegate: AnyObject {
    func cameraEngine(_ engine: CameraEngine,
                      didOutputVideo pixelBuffer: CVPixelBuffer,
                      pts: CMTime)
    func cameraEngine(_ engine: CameraEngine,
                      didOutputAudio sampleBuffer: CMSampleBuffer)
}

 class CameraEngine: NSObject {

    // Core
    private let session = AVCaptureSession()
    var captureSession: AVCaptureSession { session }

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
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { self.session.stopRunning() }
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
                // ⚠️ HDR 全部交给系统自动管理：不再手动触碰 videoHDR 相关属性
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

        // 方向跟随 + 预览低延迟 standard 稳定；前置可镜像
        if let conn = videoOutput.connection(with: .video) {
            if conn.isVideoOrientationSupported { conn.videoOrientation = currentVideoOrientation() }
            sysStabilizer.applyPreview(feel: .normal, to: conn) // 低延迟（类似系统相机预览）
            if conn.isVideoMirroringSupported { conn.isVideoMirrored = usingFront }
        }

        // Audio output
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)

        // 默认尝试 60fps（best-effort）
        _ = setPreferredFrameRate(60)

        session.commitConfiguration()
    }

    // 设置期望帧率（在 sessionQueue 调用）
    @discardableResult
    func setPreferredFrameRate(_ fps: Int) -> Bool {
        guard let device = (session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }
            .first { $0.hasMediaType(.video) }) else { return false }

        // 选一个既支持该 fps，又分辨率尽量高的 format
        let matched = device.formats.filter { format in
            format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= Double(fps) && Double(fps) <= $0.maxFrameRate
            }
        }.sorted { f1, f2 in
            let d1 = CMVideoFormatDescriptionGetDimensions(f1.formatDescription)
            let d2 = CMVideoFormatDescriptionGetDimensions(f2.formatDescription)
            return (d1.width * d1.height) > (d2.width * d2.height)
        }

        guard let targetFormat = matched.first else { return false }

        do {
            try device.lockForConfiguration()
            device.activeFormat = targetFormat
            let duration = CMTimeMake(value: 1, timescale: Int32(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            // ❌ 不再手动设置 videoHDR（避免 API 差异 / 运行时限制）
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
        sessionQueue.async {
            guard let conn = self.videoOutput.connection(with: .video),
                  conn.isVideoOrientationSupported else { return }
            conn.videoOrientation = self.currentVideoOrientation()
        }
    }
}

// MARK: - Delegates
extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            delegate?.cameraEngine(self, didOutputVideo: pb, pts: pts)
        } else if output === audioOutput {
            delegate?.cameraEngine(self, didOutputAudio: sampleBuffer)
        }
    }
}


extension CameraEngine {

    /// 切到 0.5x（Ultra Wide/等效）并尽量开启系统几何畸变矫正（GDC）
    func useUltraWideWithGDC(_ enable: Bool = true) {
        // 1) 找后置相机：优先物理 Ultra Wide；其次双/三摄虚拟设备（能到 0.5x）
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

        // 2) 重新配置 session 的视频输入
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // 移除旧视频输入
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

        // 3) 锁定设备做 GDC / 变焦设置
        do {
            try device.lockForConfiguration()

            // 系统几何畸变矫正（GDC）
            if device.isGeometricDistortionCorrectionSupported {
                device.isGeometricDistortionCorrectionEnabled = enable
            }

            // Ultra Wide 物理镜头用 1.0x；虚拟设备取最小可用（≈0.5x）
            if device.deviceType == .builtInUltraWideCamera {
                device.videoZoomFactor = max(1.0, device.minAvailableVideoZoomFactor)
            } else {
                device.videoZoomFactor = max(0.5, device.minAvailableVideoZoomFactor)
            }

            device.unlockForConfiguration()
        } catch {
            print("⚠️ 锁定设备失败：\(error)")
        }

        // 4) 调试输出（方便你确认已经生效）
        let gdc = device.isGeometricDistortionCorrectionSupported ? device.isGeometricDistortionCorrectionEnabled : false
        print("✅ Using: \(device.localizedName) | type=\(device.deviceType.rawValue) | zoom=\(device.videoZoomFactor) | GDC=\(gdc)")
    }
}
