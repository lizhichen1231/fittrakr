import AVFoundation

protocol MultiCamDelegate: AnyObject {
    func multiCam(_ manager: MultiCamManager, didOutputWide frame: CVPixelBuffer, timestamp: CMTime)
    func multiCam(_ manager: MultiCamManager, didOutputTelephoto frame: CVPixelBuffer, timestamp: CMTime)
}

class MultiCamManager: NSObject {

    weak var delegate: MultiCamDelegate?

    private var multiSession: AVCaptureMultiCamSession?
    private var singleSession: AVCaptureSession?

    private var wideDevice: AVCaptureDevice?
    private var telephotoDevice: AVCaptureDevice?

    private var wideOutput: AVCaptureVideoDataOutput?
    private var telephotoOutput: AVCaptureVideoDataOutput?

    private let wideQueue = DispatchQueue(label: "wide.camera", qos: .userInteractive)
    private let teleQueue = DispatchQueue(label: "tele.camera", qos: .userInteractive)

    private var deviceInfo: DeviceCameraInfo { DeviceCameraInfo.shared }

    var isMultiCamSupported: Bool { deviceInfo.isMultiCamSupported }
    var hasTelephoto: Bool { deviceInfo.hasTelephoto }
    var telephotoZoom: CGFloat { deviceInfo.telephotoZoom }
    var canUseMultiCam: Bool { deviceInfo.canUseMultiCam }

    private(set) var latestWideFrame: CVPixelBuffer?
    private(set) var latestTelephotoFrame: CVPixelBuffer?
    private(set) var wideTimestamp: CMTime = .zero
    private(set) var telephotoTimestamp: CMTime = .zero

    enum Mode { case single, multi }
    private(set) var mode: Mode = .single

    func setup() -> Bool {
        if canUseMultiCam {
            mode = .multi
            return setupMultiCam()
        } else {
            mode = .single
            return setupSingleCam()
        }
    }

    private func setupMultiCam() -> Bool {
        print("📷 [MultiCam] setupMultiCam() 开始")

        multiSession = AVCaptureMultiCamSession()
        guard let session = multiSession else {
            print("📷 ❌ 创建 AVCaptureMultiCamSession 失败")
            return false
        }

        session.beginConfiguration()

        // 广角
        guard let wide = deviceInfo.wide?.device else {
            print("📷 ❌ 找不到广角镜头，回退单摄")
            session.commitConfiguration()
            return setupSingleCam()
        }
        wideDevice = wide
        print("📷 [MultiCam] 广角设备: \(wide.localizedName)")

        do {
            let wideInput = try AVCaptureDeviceInput(device: wide)
            guard session.canAddInput(wideInput) else {
                print("📷 ❌ 无法添加广角输入")
                return false
            }
            session.addInputWithNoConnections(wideInput)

            wideOutput = AVCaptureVideoDataOutput()
            wideOutput?.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            wideOutput?.alwaysDiscardsLateVideoFrames = true
            wideOutput?.setSampleBufferDelegate(self, queue: wideQueue)
            guard session.canAddOutput(wideOutput!) else {
                print("📷 ❌ 无法添加广角输出")
                return false
            }
            session.addOutputWithNoConnections(wideOutput!)

            guard let port = wideInput.ports(for: .video, sourceDeviceType: .builtInWideAngleCamera, sourceDevicePosition: .back).first else {
                print("📷 ❌ 找不到广角端口")
                return false
            }
            let connection = AVCaptureConnection(inputPorts: [port], output: wideOutput!)
            guard session.canAddConnection(connection) else {
                print("📷 ❌ 无法添加广角连接")
                return false
            }
            session.addConnection(connection)
            connection.videoOrientation = .portrait
            print("📷 ✅ 广角设置完成")
        } catch {
            print("📷 ❌ 广角设置失败: \(error)")
            return false
        }

        // 长焦
        if let tele = deviceInfo.telephoto?.device {
            telephotoDevice = tele
            print("📷 [MultiCam] 长焦设备: \(tele.localizedName)")

            do {
                let teleInput = try AVCaptureDeviceInput(device: tele)
                guard session.canAddInput(teleInput) else {
                    print("📷 ⚠️ 无法添加长焦输入，仅使用广角")
                    session.commitConfiguration()
                    return true
                }
                session.addInputWithNoConnections(teleInput)

                telephotoOutput = AVCaptureVideoDataOutput()
                telephotoOutput?.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                telephotoOutput?.alwaysDiscardsLateVideoFrames = true
                telephotoOutput?.setSampleBufferDelegate(self, queue: teleQueue)
                guard session.canAddOutput(telephotoOutput!) else {
                    print("📷 ⚠️ 无法添加长焦输出")
                    return true
                }
                session.addOutputWithNoConnections(telephotoOutput!)

                guard let port = teleInput.ports(for: .video, sourceDeviceType: .builtInTelephotoCamera, sourceDevicePosition: .back).first else {
                    print("📷 ⚠️ 找不到长焦端口")
                    return true
                }
                let connection = AVCaptureConnection(inputPorts: [port], output: telephotoOutput!)
                guard session.canAddConnection(connection) else {
                    print("📷 ⚠️ 无法添加长焦连接")
                    return true
                }
                session.addConnection(connection)
                connection.videoOrientation = .portrait
                print("📷 ✅ 长焦设置完成")
            } catch {
                print("📷 ⚠️ 长焦设置失败: \(error)")
            }
        } else {
            print("📷 ⚠️ 没有检测到长焦镜头")
        }

        session.commitConfiguration()
        print("📷 ✅ 多摄设置成功: 广角 + 长焦(\(telephotoZoom)x)")
        return true
    }

    private func setupSingleCam() -> Bool {
        singleSession = AVCaptureSession()
        guard let session = singleSession else { return false }

        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        guard let device = deviceInfo.wide?.device ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return false
        }
        wideDevice = device

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return false }
            session.addInput(input)

            wideOutput = AVCaptureVideoDataOutput()
            wideOutput?.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            wideOutput?.alwaysDiscardsLateVideoFrames = true
            wideOutput?.setSampleBufferDelegate(self, queue: wideQueue)
            guard session.canAddOutput(wideOutput!) else { return false }
            session.addOutput(wideOutput!)

            if let conn = wideOutput?.connection(with: .video) {
                conn.videoOrientation = .portrait
            }
        } catch {
            print("❌ 单摄设置失败: \(error)")
            return false
        }

        session.commitConfiguration()
        print("✅ 单摄设置成功")
        return true
    }

    func start() {
        if mode == .multi {
            multiSession?.startRunning()
        } else {
            singleSession?.startRunning()
        }
    }

    func stop() {
        if mode == .multi {
            multiSession?.stopRunning()
        } else {
            singleSession?.stopRunning()
        }
    }

    var session: AVCaptureSession? {
        mode == .multi ? multiSession : singleSession
    }

    // 供 CameraEngine 一次性 dump 多摄两路设备的实际配置
    func dumpConfig(_ describe: (AVCaptureDevice, String) -> Void) {
        if let w = wideDevice { describe(w, "multicam-wide") } else { print("📸 (无广角设备)") }
        if let t = telephotoDevice { describe(t, "multicam-tele") } else { print("📸 (无长焦设备/未启用第二路)") }
    }
}

extension MultiCamManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if output == wideOutput {
            latestWideFrame = pixelBuffer
            wideTimestamp = timestamp
            delegate?.multiCam(self, didOutputWide: pixelBuffer, timestamp: timestamp)
        } else if output == telephotoOutput {
            latestTelephotoFrame = pixelBuffer
            telephotoTimestamp = timestamp
            delegate?.multiCam(self, didOutputTelephoto: pixelBuffer, timestamp: timestamp)
        }
    }
}
