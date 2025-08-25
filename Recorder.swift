
import AVFoundation
import Photos
import CoreImage

protocol Recorder {
    var isRecording: Bool { get }
    func start(size: CGSize)
    func appendVideo(ciImage: CIImage, at pts: CMTime)
    func appendAudio(_ sampleBuffer: CMSampleBuffer)
    func stopAndSave(_ completion: @escaping (Bool)->Void)
}

final class AVWriterRecorder: NSObject, Recorder, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var writer: AVAssetWriter?
    private var vInput: AVAssetWriterInput?
    private var aInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?

    private let ciContext = CIContext(options: [
        .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
        .outputColorSpace : CGColorSpaceCreateDeviceRGB()
    ])

    private(set) var isRecording = false

    // 统一时间刻度 & 记录输出尺寸（兜底创建 PB 用）
    private let timescale: Int32 = 600
    private var outputSize: CGSize = .zero

    // 真实时间戳基准
    private var videoBasePTS: CMTime? = nil
    private var audioBasePTS: CMTime? = nil

    func start(size: CGSize) {
        stopAndSave { _ in }

        outputSize = size

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("auto_reframe_\(Int(Date().timeIntervalSince1970)).mp4")

        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }

        // Video
        let vSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(size.width*size.height)*5,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vIn.expectsMediaDataInRealTime = true

        // 给 adaptor 明确像素缓冲属性，便于尽快创建 pool
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let adp = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn,
                                                       sourcePixelBufferAttributes: attrs)

        // Audio
        let aSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100,
            AVEncoderBitRateKey: 96000
        ]
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
        aIn.expectsMediaDataInRealTime = true

        if w.canAdd(vIn) { w.add(vIn) }
        if w.canAdd(aIn) { w.add(aIn) }
        guard w.startWriting() else { return }
        w.startSession(atSourceTime: .zero)

        writer = w
        vInput = vIn
        aInput = aIn
        adaptor = adp
        isRecording = true
        videoBasePTS = nil
        audioBasePTS = nil
    }

    func appendVideo(ciImage: CIImage, at pts: CMTime) {
        guard isRecording, let vInput = vInput, let adaptor = adaptor else { return }
        guard vInput.isReadyForMoreMediaData else { return }

        // 以首帧为零的相对时间，消除“快进感”
        if videoBasePTS == nil { videoBasePTS = pts }
        var relPTS = CMTimeSubtract(pts, videoBasePTS!)
        relPTS = CMTimeConvertScale(relPTS, timescale: timescale, method: .default)

        // --- 获取像素缓冲：优先用 adaptor 的 pool；没有就兜底创建 ---
        var pb: CVPixelBuffer? = nil
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        } else {
            // pool 还没准备好（常见于刚开始的前几帧）→ 兜底创建一次性 PB
            let w = max(2, Int(outputSize.width))
            let h = max(2, Int(outputSize.height))
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: w,
                kCVPixelBufferHeightKey: h,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ]
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                attrs as CFDictionary, &pb)
        }
        guard let pixelBuffer = pb else { return } // 若失败就跳过这一帧，避免崩溃

        // --- 渲染到像素缓冲 ---
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)

        if let cgImage = ciContext.createCGImage(ciImage,
                                                 from: ciImage.extent.isEmpty ? rect : ciImage.extent),
           let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer),
                                   width: width,
                                   height: height,
                                   bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                               CGBitmapInfo.byteOrder32Little.rawValue) {

            // 背景清为黑，避免边缘随机像素
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(rect)

            // 保持宽高比绘制
            let iw = CGFloat(cgImage.width), ih = CGFloat(cgImage.height)
            let s  = min(CGFloat(width)/iw, CGFloat(height)/ih)
            let dw = iw*s, dh = ih*s
            let dx = (CGFloat(width)  - dw)/2
            let dy = (CGFloat(height) - dh)/2
            context.draw(cgImage, in: CGRect(x: dx, y: dy, width: dw, height: dh))
        } else {
            // 兜底：填充黑帧
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(base, 0, CVPixelBufferGetDataSize(pixelBuffer))
            }
        }

        _ = adaptor.append(pixelBuffer, withPresentationTime: relPTS)
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording, let aInput = aInput, aInput.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if audioBasePTS == nil { audioBasePTS = pts }
        let base = audioBasePTS ?? pts

        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count)
        for i in 0..<infos.count {
            infos[i].presentationTimeStamp = CMTimeSubtract(infos[i].presentationTimeStamp, base)
            if infos[i].decodeTimeStamp != .invalid {
                infos[i].decodeTimeStamp = CMTimeSubtract(infos[i].decodeTimeStamp, base)
            }
        }
        var adj: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                              sampleBuffer: sampleBuffer,
                                              sampleTimingEntryCount: count,
                                              sampleTimingArray: &infos,
                                              sampleBufferOut: &adj)
        if let adj = adj { aInput.append(adj) }
    }

    func stopAndSave(_ completion: @escaping (Bool)->Void) {
        guard isRecording, let writer = writer else { completion(false); return }
        isRecording = false
        vInput?.markAsFinished()
        aInput?.markAsFinished()
        writer.finishWriting {
            let url = writer.outputURL
            PHPhotoLibrary.requestAuthorization { s in
                guard s == .authorized || s == .limited else {
                    DispatchQueue.main.async { completion(false) }; return
                }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }) { ok, _ in
                    DispatchQueue.main.async { completion(ok) }
                }
            }
            self.writer = nil; self.vInput = nil; self.aInput = nil; self.adaptor = nil
        }
    }
}
