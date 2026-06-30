import AVFoundation
import QuartzCore
import CoreImage

/// 本地视频帧源:用 `AVAssetReader` 逐帧解码,把每帧当作 `CVPixelBuffer` 吐给 tracking。
/// 这样在没有摄像头的 iOS 模拟器里也能把预先录好的视频灌进 pipeline 跑 tracking。
///
/// - `realtime == true`:按视频自身的 PTS 节流,模拟真实帧率(给人眼审查 overlay 用)。
/// - `realtime == false`:全速解码、不睡眠,尽快跑完(给自动化测试用)。
/// - `loop == true`:播放到结尾后从头重播(交互回放默认开启,免去"播完黑屏"状态)。
///
/// 解码用 `AVAssetReaderVideoCompositionOutput` + `AVMutableVideoComposition(propertiesOf:)`,
/// 会把视频轨道自带的旋转(竖屏视频常见的 90° transform)烘焙进输出,得到**直立**的帧,
/// 与实时摄像头路径(连接里设了 `.portrait`)保持一致,保证 Vision 人体检测能正常工作。
/// 像素格式用 BGRA,和 `CameraEngine` 的 `videoSettings` 一致。
final class VideoFileSource: FrameSource {

    var onFrame: ((CVPixelBuffer, CVPixelBuffer?, CMTime) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?   // 视频回放不产音频
    var onFinished: (() -> Void)?

    private let url: URL
    private let realtime: Bool
    private let loop: Bool
    private let queue = DispatchQueue(label: "video.file.source", qos: .userInitiated)

    /// 仅在 realtime 时生效:CPU 跟不上时丢掉「已经迟到」的帧,让播放跟住真实墙钟时间
    /// (类似实时摄像头的 alwaysDiscardsLateVideoFrames)。可在播放中随时切换。
    /// false 时逐帧不丢、慢放(看得全,适合逐帧审查);模拟器上 Vision 慢,默认建议开。
    var dropLateFrames: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _dropLate }
        set { lock.lock(); _dropLate = newValue; lock.unlock() }
    }

    // 跨线程状态(main 写 / bg 读循环),用同一把锁保护避免数据竞争。
    private let lock = NSLock()
    private var _running = false
    private var _dropLate = false
    private var isRunning: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _running }
        set { lock.lock(); _running = newValue; lock.unlock() }
    }

    // 视频名义帧间隔(秒),用作丢帧的「迟到」判定容差。bg 队列内读写。
    private var frameInterval: Double = 1.0 / 30.0

    // —— 假长焦合成(仅 readLoop 的 bg 队列访问,单线程,无需加锁)——
    // 工作/输出色彩空间与 TrackingController.ciContext 逐字一致(deviceRGB),
    // 保证假长焦相对广角不产生色偏/gamma 差、切镜瞬间无接缝。CIContext 单例复用,不每帧 new。
    private let deviceRGB = CGColorSpaceCreateDeviceRGB()
    private lazy var ciContext = CIContext(options: [
        .workingColorSpace: deviceRGB,
        .outputColorSpace:  deviceRGB
    ])
    // 假长焦输出缓冲池(单例复用,尺寸=广角帧尺寸)
    private var telePoolRef: CVPixelBufferPool?
    private var telePoolW = 0
    private var telePoolH = 0
    private var loggedTeleOnce = false

    init(url: URL, realtime: Bool = true, loop: Bool = false, dropLateFrames: Bool = false) {
        self.url = url
        self.realtime = realtime
        self.loop = loop
        self._dropLate = dropLateFrames
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        queue.async { [weak self] in self?.readLoop() }
    }

    func stop() {
        isRunning = false
    }

    // MARK: - 解码循环(在 queue 上跑)

    private func makeReaderOutput() -> (AVAssetReader, AVAssetReaderOutput)? {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = asset.tracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }

        if videoTrack.nominalFrameRate > 0 {
            frameInterval = 1.0 / Double(videoTrack.nominalFrameRate)
        }

        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        // 优先用 video composition 输出:自动应用轨道 transform → 直立帧。
        let compOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack],
                                                             videoSettings: settings)
        compOutput.alwaysCopiesSampleData = false
        compOutput.videoComposition = AVMutableVideoComposition(propertiesOf: asset)

        if reader.canAdd(compOutput) {
            reader.add(compOutput)
            guard reader.startReading() else { return nil }
            return (reader, compOutput)
        }

        // 兜底:普通 track 输出(不应用 transform,极少数情况)。
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: settings)
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else { return nil }
        reader.add(trackOutput)
        guard reader.startReading() else { return nil }
        return (reader, trackOutput)
    }

    private func readLoop() {
        repeat {
            guard let (reader, output) = makeReaderOutput() else {
                finish()   // 打不开 → 当作结束,免得上层卡住
                return
            }

            var basePTS: Double?
            var baseWall: Double = 0

            // 每帧用 autoreleasepool 包住:拉流的 CMSampleBuffer(每帧一整张 BGRA,~MB 级)
            // 和 CoreImage 渲染的临时对象都是 autorelease 的;readLoop 这个 block 在 loop
            // 播放下长期不返回,不主动排干就会一路堆积 → 真机 OOM 被 jetsam 杀掉(播完闪退)。
            while isRunning && reader.status == .reading {
                let keepGoing = autoreleasepool { () -> Bool in
                    guard let sample = output.copyNextSampleBuffer() else { return false }   // EOF → 退出本轮
                    guard let pb = CMSampleBufferGetImageBuffer(sample) else { return true }  // 坏帧 → 跳过

                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)

                    if realtime {
                        let ptsSec = pts.seconds
                        if basePTS == nil { basePTS = ptsSec; baseWall = CACurrentMediaTime() }
                        let target = baseWall + (ptsSec - basePTS!)   // 该帧应出现的墙钟时刻
                        let wait = target - CACurrentMediaTime()
                        if wait > 0 {
                            Thread.sleep(forTimeInterval: wait)        // 太早 → 等到点再吐
                        } else if dropLateFrames && -wait > frameInterval * 0.5 {
                            // 太迟(落后超过半帧)→ 丢这帧:sample 随本 pool 立即释放,继续下一帧
                            return true
                        }
                    }

                    if !isRunning { return false }   // 节流期间被 stop()
                    // 合成「假长焦」一路:中心裁广角 + 上采样回广角同尺寸,补齐相机的双路输出,
                    // 让 process 拿到完整一对、切镜能触发。设备无可用长焦时返回 nil(行为同前)。
                    let tele = makeFakeTelephoto(from: pb)
                    // 同步调用:tracking 在本闭包内消费完(渲染出 CGImage 副本),
                    // 返回后 sample 才释放,故 pb/tele 在使用期间始终有效。
                    onFrame?(pb, tele, pts)
                    return true
                }
                if !keepGoing { break }
            }

            reader.cancelReading()
        } while isRunning && loop

        finish()
    }

    /// 收尾。跑到这里时若 isRunning 仍为 true,说明是自然播完(EOF 且未 loop),
    /// 而非被 stop() 打断——只有自然播完才回调 onFinished。
    private func finish() {
        let natural = isRunning
        isRunning = false
        if natural {
            DispatchQueue.main.async { [weak self] in self?.onFinished?() }
        }
    }

    // MARK: - 假长焦合成(strangler-fig:只在本层伪装相机的第二路,不碰 tracking/zoom)

    /// 用广角帧合成一路「假长焦」:按 `DeviceCameraInfo.coverageRect` 中心裁剪(= live 切镜
    /// 假设的同一几何,不在此独立重算 1/telephotoZoom),再上采样回广角同尺寸。
    /// 仅当设备长焦可用时合成(与 `CameraSelector` 同一道门);否则返回 nil(维持原行为)。
    /// 输出 BGRA、与广角同尺寸(teleSensorW == sensorW)、由调用方用同一 pts 一起喂 onFrame。
    private func makeFakeTelephoto(from wide: CVPixelBuffer) -> CVPixelBuffer? {
        let info = DeviceCameraInfo.shared
        guard info.isTelephotoUsable else { return nil }   // 设备无可用长焦 → 不合成(同 CameraSelector 门)
        let telephotoZoom = info.telephotoZoom
        guard telephotoZoom > 1.0 else { return nil }

        let W = CVPixelBufferGetWidth(wide)
        let H = CVPixelBufferGetHeight(wide)
        guard W > 0, H > 0 else { return nil }

        // 中心裁剪矩形复用现成真值:与 CameraSelector.convertToTelephoto / computeFinalCropRect
        // 的几何完全一致(coverage = 1/telephotoZoom 的居中方形,归一化),避免 AR/有效区漂移。
        let cov = info.coverageRect(for: telephotoZoom)
        let cropX = cov.minX * CGFloat(W)
        let cropY = cov.minY * CGFloat(H)
        let cropW = cov.width  * CGFloat(W)
        let cropH = cov.height * CGFloat(H)
        guard cropW >= 1, cropH >= 1 else { return nil }

        if !loggedTeleOnce {
            loggedTeleOnce = true
            print("📷 [VideoFileSource] 合成假长焦: telephotoZoom=\(String(format: "%.2f", telephotoZoom))x " +
                  "coverage=\(String(format: "%.3f", cov.width)) crop=\(Int(cropW))x\(Int(cropH)) → \(W)x\(H)")
        }

        // 整段裁剪+上采样包在 autoreleasepool 里(别破坏上一刀的内存修复);
        // 返回的 buffer 来自 pool(Create 规则,调用方持有),不随 pool 排干释放。
        return autoreleasepool { () -> CVPixelBuffer? in
            // 中心裁剪 + 等比上采样回 W×H(scale = 1/coverage = telephotoZoom)
            let src = CIImage(cvPixelBuffer: wide)
            let cropped = src.cropped(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH))
            let moved = cropped.transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))
            let scaled = moved.transformed(by: CGAffineTransform(scaleX: CGFloat(W) / cropW,
                                                                 y: CGFloat(H) / cropH))

            guard let pool = telePool(width: W, height: H) else { return nil }
            var out: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess,
                  let outBuf = out else { return nil }

            // 颜色一致:输出 buffer 标 deviceRGB,且用 deviceRGB 渲染——与 TrackingController 的
            // 工作/输出空间一致,下游 CIImage(cvPixelBuffer:) 读回同一空间 → 无色偏、切镜无缝。
            CVBufferSetAttachment(outBuf, kCVImageBufferCGColorSpaceKey, deviceRGB, .shouldPropagate)
            ciContext.render(scaled, to: outBuf,
                             bounds: CGRect(x: 0, y: 0, width: W, height: H),
                             colorSpace: deviceRGB)
            return outBuf
        }
    }

    /// 假长焦输出缓冲池(单例复用;尺寸变化时重建——同一段视频内不会变)。IOSurface 支持以便
    /// CIContext 高效渲染、且下游 CIImage 可直接包裹。
    private func telePool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let p = telePoolRef, telePoolW == width, telePoolH == height { return p }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess,
              let p = pool else { return nil }
        telePoolRef = p; telePoolW = width; telePoolH = height
        return p
    }
}
