import AVFoundation

/// 抽象「会吐帧的东西」。把 tracking 的输入和帧的来源解耦:
/// 真机摄像头(LiveCameraSource)和本地视频回放(VideoFileSource)都实现它,
/// tracking 入口(CameraViewModel)只依赖这个协议,不再直接依赖 AVCaptureSession。
///
/// 签名刻意对齐现有链路:帧是 `CVPixelBuffer`(+ 可选长焦帧)+ `CMTime` 时间戳,
/// 这样 `TrackingController.process(wideFrame:telephotoFrame:pts:)` 一行都不用改。
protocol FrameSource: AnyObject {
    /// 每来一帧回调一次。wide=广角/主帧,telephoto=长焦帧(仅多摄实时有,其余为 nil)。
    var onFrame: ((_ wide: CVPixelBuffer, _ telephoto: CVPixelBuffer?, _ pts: CMTime) -> Void)? { get set }

    /// 音频帧(仅实时摄像头有;视频回放可不实现)。
    var onAudio: ((CMSampleBuffer) -> Void)? { get set }

    /// 帧源自然结束(视频播放到结尾且未开启 loop)。摄像头源不会触发。
    var onFinished: (() -> Void)? { get set }

    func start()
    func stop()
}
