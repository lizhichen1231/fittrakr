import XCTest
import AVFoundation
import CoreMedia
@testable import FitTrackr_1

/// 验证 VideoFileSource 能在模拟器里(无摄像头)把本地视频解码成 CVPixelBuffer 逐帧吐出。
/// 这是「capture 解耦」的核心:只要它能吐帧,tracking pipeline 在模拟器里就能跑。
///
/// 注意:与 ZoomControllerTests 一样,本测试目前**无法在本机直接 run**——
/// 测试 bundle 链接 MediaPipeTasksCommon 的静态库时缺少 zlib(`-lz`),
/// 是 CocoaPods 配置遗留问题,与本测试代码无关(App target 本身可正常构建/运行)。
/// 解码机制已用独立 swift 脚本在本环境验证通过(同仓库 scripts/ 的验证惯例)。
/// 待测试 target 的链接修复后,本测试即可执行。
final class VideoFileSourceTests: XCTestCase {

    /// 生成一段合成竖屏视频(N 帧:黑底 + 横向移动的白块),返回临时文件 URL。
    private func makeSyntheticVideo(frames: Int = 30,
                                    size: CGSize = CGSize(width: 720, height: 1280),
                                    fps: Int32 = 30) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("synthetic_\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: attrs)
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            guard let pool = adaptor.pixelBufferPool else { XCTFail("无 pixelBufferPool"); break }
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
            guard let pb = pbOut else { XCTFail("无法创建像素缓冲"); break }

            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                                width: Int(size.width), height: Int(size.height),
                                bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
            ctx?.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx?.fill(CGRect(origin: .zero, size: size))
            let x = CGFloat(i) / CGFloat(frames) * (size.width - 100)
            ctx?.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx?.fill(CGRect(x: x, y: size.height / 2 - 50, width: 100, height: 100))
            CVPixelBufferUnlockBaseAddress(pb, [])

            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        let done = XCTestExpectation(description: "finishWriting")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(writer.status, .completed,
                       "写测试视频失败: \(String(describing: writer.error))")
        return url
    }

    /// 全速(realtime:false)解码:应吐出接近 30 帧,且尺寸正确(直立)。
    func testEmitsFramesFullSpeed() throws {
        let url = try makeSyntheticVideo(frames: 30)
        let source = VideoFileSource(url: url, realtime: false, loop: false)

        let finished = XCTestExpectation(description: "onFinished")
        var count = 0
        var firstDims: (Int, Int)?
        source.onFrame = { pb, tele, _ in
            count += 1
            if firstDims == nil { firstDims = (CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb)) }
            XCTAssertNil(tele, "视频源不应有长焦帧")
        }
        source.onFinished = { finished.fulfill() }
        source.start()
        wait(for: [finished], timeout: 15)

        XCTAssertGreaterThan(count, 20, "应解码出接近 30 帧,实际 \(count)")
        XCTAssertEqual(firstDims?.0, 720, "宽应为 720(直立)")
        XCTAssertEqual(firstDims?.1, 1280, "高应为 1280(直立)")
    }

    /// stop() 能及时中断解码循环。
    func testStopHalts() throws {
        let url = try makeSyntheticVideo(frames: 120)
        let source = VideoFileSource(url: url, realtime: true, loop: true)
        var count = 0
        source.onFrame = { _, _, _ in count += 1 }
        source.start()

        let exp = expectation(description: "got some frames")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            source.stop()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        let afterStop = count
        // 停止后再等一会,确认不再持续吐帧(loop 不会无限继续)。
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertLessThanOrEqual(count - afterStop, 2, "stop() 后应基本停住")
        XCTAssertGreaterThan(afterStop, 0, "停止前应至少解码出几帧")
    }
}
