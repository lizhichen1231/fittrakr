// video_to_heightratio.swift —— 离线从视频提取 heightRatio 序列（macOS 命令行，绕开 Pod）
//
// 用法：
//   自检（强烈先跑）：swift video_to_heightratio.swift <video> <out.csv> --probe-only
//      → 只处理到第一帧有检测为止，把「喂给 Vision 之前摆正后的画面 + 检测框」存成 <out.csv>.probe.png，
//        并打印 旋转/朝向/尺寸/bbox/heightRatio，供肉眼确认「人正立、框套在人身上、rect.height 是身高方向」。
//   全量提取：       swift video_to_heightratio.swift <video> <out.csv>
//      → 逐帧写 CSV：frame,timestamp_s,heightRatio,confidence,heightRatioRaw,boxFound
//
// 口径与 App 内 PersonTracker.detectHumanRectFallback 完全一致：
//   VNDetectHumanRectanglesRequest(upperBodyOnly=false) → toSensor(含 Y 翻转) → 多框选择(就近/最大面积)
//   → 与 App fitness 预设相同参数的 SimpleKalman(x,y,w,h) 平滑 → heightRatio = 平滑框高 / 画面高。
// 关键差异：离线读文件的 CVPixelBuffer 是「横躺」的原始帧，不应用旋转；
//   必须按 video track 的 preferredTransform 把画面摆正（给 VNImageRequestHandler 传对应 orientation），
//   否则检测的是横躺的人、rect.height 量到的是宽度方向，整条 heightRatio 物理意义反掉。

import Foundation
import AVFoundation
import Vision
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

// ===== 与 App 内 PersonTracker / PanEngine 完全一致的滤波/选择（fitness 预设）=====

final class SimpleKalmanFilter {
    private var x: CGFloat = 0
    private var p: CGFloat = 1
    private let q: CGFloat
    private let r: CGFloat
    init(processNoise: CGFloat, measurementNoise: CGFloat) { q = processNoise; r = measurementNoise }
    func update(_ z: CGFloat) -> CGFloat {
        let xPred = x; let pPred = p + q
        let k = pPred / (pPred + r)
        x = xPred + k * (z - xPred); p = (1 - k) * pPred
        return x
    }
    func reset(_ v: CGFloat) { x = v; p = 1 }
    func softReset(_ v: CGFloat, _ blend: CGFloat) { x = x * (1 - blend) + v * blend; p = min(p + 0.1, 1.0) }
}

func iouRect(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let inter = a.intersection(b); if inter.isNull { return 0 }
    let i = inter.width * inter.height
    let u = a.width * a.height + b.width * b.height - i
    return u > 0 ? i / u : 0
}
func lerpc(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

var kX: SimpleKalmanFilter?, kY: SimpleKalmanFilter?, kW: SimpleKalmanFilter?, kH: SimpleKalmanFilter?
func setupKalman() {
    // fitness 预设：processNoise=0.0002, measurementNoise=0.12；W/H 用 *0.3 / *1.2
    let pn: CGFloat = 0.0002, mn: CGFloat = 0.12
    kX = SimpleKalmanFilter(processNoise: pn, measurementNoise: mn)
    kY = SimpleKalmanFilter(processNoise: pn, measurementNoise: mn)
    kW = SimpleKalmanFilter(processNoise: pn * 0.3, measurementNoise: mn * 1.2)
    kH = SimpleKalmanFilter(processNoise: pn * 0.3, measurementNoise: mn * 1.2)
}

var rawBox: CGRect?   // 上一帧平滑后框（= App process() 的 rawBox）

func applyKalman(_ rawRect: CGRect) -> CGRect {
    if kX == nil { setupKalman() }
    let smoothed: CGRect
    if let last = rawBox {
        let iou = iouRect(rawRect, last)
        if iou > 0.05 {
            let sx = kX!.update(rawRect.midX), sy = kY!.update(rawRect.midY)
            let sw = kW!.update(rawRect.width), sh = kH!.update(rawRect.height)
            smoothed = CGRect(x: sx - sw / 2, y: sy - sh / 2, width: sw, height: sh)
        } else {
            let blend = max(0.05, min(0.2, iou * 4))
            kX?.softReset(rawRect.midX, blend); kY?.softReset(rawRect.midY, blend)
            kW?.softReset(rawRect.width, blend); kH?.softReset(rawRect.height, blend)
            smoothed = CGRect(x: lerpc(last.midX, rawRect.midX, blend) - rawRect.width / 2,
                              y: lerpc(last.midY, rawRect.midY, blend) - rawRect.height / 2,
                              width: lerpc(last.width, rawRect.width, blend),
                              height: lerpc(last.height, rawRect.height, blend))
        }
    } else {
        kX?.reset(rawRect.midX); kY?.reset(rawRect.midY); kW?.reset(rawRect.width); kH?.reset(rawRect.height)
        smoothed = rawRect
    }
    return smoothed
}

// ===== 旋转：preferredTransform → CGImagePropertyOrientation =====
func orientationFromTransform(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
    if abs(t.b - 1) < 0.01 && abs(t.c + 1) < 0.01 { return .right }   // 竖屏（顺时针转 90° 摆正）
    if abs(t.b + 1) < 0.01 && abs(t.c - 1) < 0.01 { return .left }    // 竖屏倒置
    if abs(t.a + 1) < 0.01 && abs(t.d + 1) < 0.01 { return .down }    // 横屏 180°
    return .up                                                        // 横屏正常
}
func isQuarterTurn(_ o: CGImagePropertyOrientation) -> Bool {
    o == .left || o == .right || o == .leftMirrored || o == .rightMirrored
}

func writePNG(_ cg: CGImage, _ url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
}

let ciCtx = CIContext()

/// 渲染「摆正后喂给 Vision 的画面 + 检测框」用于自检
func renderProbe(_ pb: CVPixelBuffer, _ orientation: CGImagePropertyOrientation, _ bbox: CGRect?, _ url: URL) {
    let ci = CIImage(cvPixelBuffer: pb).oriented(orientation)   // 摆正
    guard let base = ciCtx.createCGImage(ci, from: ci.extent) else { return }
    let W = base.width, H = base.height
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.draw(base, in: CGRect(x: 0, y: 0, width: W, height: H))
    if let b = bbox {
        // Vision 归一化（摆正空间，原点左下）→ CGContext 默认也是左下原点，直接乘即可
        ctx.setStrokeColor(red: 1, green: 0.1, blue: 0.1, alpha: 1)
        ctx.setLineWidth(CGFloat(max(4, W / 200)))
        ctx.stroke(CGRect(x: b.minX * CGFloat(W), y: b.minY * CGFloat(H),
                          width: b.width * CGFloat(W), height: b.height * CGFloat(H)))
    }
    if let out = ctx.makeImage() { writePNG(out, url) }
}

// ===== 参数 =====
let args = CommandLine.arguments
func die(_ m: String) -> Never { FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(2) }
guard args.count >= 3 else { die("用法: swift video_to_heightratio.swift <video> <out.csv> [--probe-only]") }
let videoURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let probeOnly = args.contains("--probe-only")
let probePNG = URL(fileURLWithPath: args[2] + ".probe.png")

// ===== 载入 track + 旋转/尺寸（async load，避免弃用同步属性）=====
let asset = AVURLAsset(url: videoURL)
var track: AVAssetTrack?
var transform = CGAffineTransform.identity
var natural = CGSize.zero
do {
    let sem = DispatchSemaphore(value: 0)
    Task {
        track = try? await asset.loadTracks(withMediaType: .video).first
        if let tr = track, let v = try? await tr.load(.preferredTransform, .naturalSize) {
            transform = v.0; natural = v.1
        }
        sem.signal()
    }
    sem.wait()
}
guard let vtrack = track else { die("❌ 视频里没有视频轨道: \(videoURL.path)") }
let orientation = orientationFromTransform(transform)

print("📹 视频: \(videoURL.lastPathComponent)")
print("   naturalSize(编码) = \(Int(natural.width))×\(Int(natural.height))")
print("   preferredTransform = [a:\(transform.a) b:\(transform.b) c:\(transform.c) d:\(transform.d)]")
print("   → 选用 orientation = \(orientation)  (.right/.left = 竖屏需旋转；.up = 横屏不转)")

// ===== AVAssetReader 逐帧 =====
guard let reader = try? AVAssetReader(asset: asset) else { die("❌ 无法创建 AVAssetReader") }
let trackOut = AVAssetReaderTrackOutput(track: vtrack,
    outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
trackOut.alwaysCopiesSampleData = false
reader.add(trackOut)
reader.startReading()

let req = VNDetectHumanRectanglesRequest()
req.upperBodyOnly = false

var csv = "frame,timestamp_s,heightRatio,confidence,heightRatioRaw,boxFound\n"
var frame = 0
var detectedCount = 0
var firstProbeDone = false
var lastOrientedDims = (w: 0, h: 0)

while reader.status == .reading, let sb = trackOut.copyNextSampleBuffer() {
    guard let pb = CMSampleBufferGetImageBuffer(sb) else { frame += 1; continue }
    let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
    let bw = CGFloat(CVPixelBufferGetWidth(pb)), bh = CGFloat(CVPixelBufferGetHeight(pb))
    let ow = isQuarterTurn(orientation) ? bh : bw   // 摆正后宽
    let oh = isQuarterTurn(orientation) ? bw : bh   // 摆正后高
    lastOrientedDims = (Int(ow), Int(oh))

    let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: orientation, options: [:])
    var hr: CGFloat?, hrRaw: CGFloat?, conf: Float = 0, found = false
    var selBBoxNorm: CGRect?
    if (try? handler.perform([req])) != nil, let list = req.results, !list.isEmpty {
        func toSensor(_ r: CGRect) -> CGRect {       // 与 App 一致：含 Y 翻转
            CGRect(x: r.minX * ow, y: (1 - r.maxY) * oh, width: r.width * ow, height: r.height * oh)
        }
        let cands = list.map { (toSensor($0.boundingBox), CGFloat($0.confidence), $0.boundingBox) }
        let sel: (CGRect, CGFloat, CGRect)
        if let last = rawBox {
            sel = cands.min { hypot($0.0.midX - last.midX, $0.0.midY - last.midY)
                            < hypot($1.0.midX - last.midX, $1.0.midY - last.midY) }!
        } else {
            sel = cands.max { ($0.0.width * $0.0.height) < ($1.0.width * $1.0.height) }!
        }
        let smoothed = applyKalman(sel.0)
        rawBox = smoothed
        hr = smoothed.height / oh           // = App: lastHeightRatio = rect.height / sensorH
        hrRaw = sel.2.height                 // 原始 Vision 归一化高度（摆正空间）
        conf = Float(sel.1)
        selBBoxNorm = sel.2
        found = true
        detectedCount += 1
    }

    // —— 自检：第一帧有检测就 dump 摆正画面 + 框 ——
    if !firstProbeDone && found {
        renderProbe(pb, orientation, selBBoxNorm, probePNG)
        firstProbeDone = true
        print("🔎 自检帧 #\(frame) t=\(String(format: "%.3f", pts))s")
        print("   摆正后画面 = \(Int(ow))×\(Int(oh))  (高>宽 即竖直)")
        print("   选中 bbox(归一化, 摆正空间) = x\(String(format: "%.3f", selBBoxNorm!.minX)) y\(String(format: "%.3f", selBBoxNorm!.minY)) w\(String(format: "%.3f", selBBoxNorm!.width)) h\(String(format: "%.3f", selBBoxNorm!.height))")
        print("   heightRatio(原始)=\(String(format: "%.3f", Double(hrRaw!)))  heightRatio(Kalman)=\(String(format: "%.3f", Double(hr!)))  conf=\(String(format: "%.2f", Double(conf)))")
        print("   📸 已存自检图: \(probePNG.path)")
        if probeOnly { print("   (--probe-only：肉眼确认人正立、红框套在人身上、框是竖高方向后，再跑全量)"); break }
    }

    if !probeOnly {
        if found {
            csv += String(format: "%d,%.4f,%.5f,%.3f,%.5f,1\n", frame, pts, Double(hr!), Double(conf), Double(hrRaw!))
        } else {
            csv += String(format: "%d,%.4f,,,,0\n", frame, pts)
        }
    }
    frame += 1
}

if !firstProbeDone {
    print("⚠️ 前 \(frame) 帧均无人体检测。可能旋转选错或视频无人。orientedDims=\(lastOrientedDims)")
}

if !probeOnly {
    do { try csv.write(to: outURL, atomically: true, encoding: .utf8) }
    catch { die("❌ 写 CSV 失败: \(error)") }
    print("✅ 全量提取完成：\(frame) 帧，其中 \(detectedCount) 帧有检测 → \(outURL.path)")
    print("   自检图: \(probePNG.path)")
}
