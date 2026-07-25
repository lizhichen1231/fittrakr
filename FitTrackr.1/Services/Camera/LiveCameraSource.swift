import AVFoundation

/// 实时摄像头帧源:把现有 `CameraEngine`(AVCaptureSession 那一套)原样包起来,
/// 作为它的 delegate,把帧/音频转发到 FrameSource 的闭包上。
///
/// 行为与改造前完全一致——包括原本写在 `CameraViewModel.start()` 里的
/// `useUltraWideWithGDC(true)`,这里把它收进 `start()`,使「实时摄像头专属」的
/// 配置封装在实时源内部,不泄漏到与帧源无关的上层。
final class LiveCameraSource: NSObject, FrameSource {

    var onFrame: ((CVPixelBuffer, CVPixelBuffer?, CMTime) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onFinished: (() -> Void)?   // 摄像头不会自然结束,始终不触发

    private let camera = CameraEngine()

    override init() {
        super.init()
        camera.delegate = self
    }

    func start() {
        camera.useUltraWideWithGDC(true)   // 原 CameraViewModel.start() 中的实时专属配置
        camera.start()
    }

    func stop() {
        camera.stop()
    }

    #if DEBUG
    /// 【查勘#2 探针专用】停 app 相机并等 teardown 完成再回调(给探针一个干净释放的摄像头)。
    func stopForProbe(_ completion: @escaping () -> Void) {
        camera.stopForProbe(completion)
    }
    #endif
}

extension LiveCameraSource: CameraEngineDelegate {
    func cameraEngine(_ engine: CameraEngine,
                      didOutputWideFrame wideFrame: CVPixelBuffer,
                      telephotoFrame: CVPixelBuffer?,
                      pts: CMTime) {
        onFrame?(wideFrame, telephotoFrame, pts)
    }

    func cameraEngine(_ engine: CameraEngine,
                      didOutputAudio sampleBuffer: CMSampleBuffer) {
        onAudio?(sampleBuffer)
    }
}
