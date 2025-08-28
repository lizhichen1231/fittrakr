// SkeletonAddon.swift  — 覆盖整个文件
import SwiftUI
import Vision
import AVFoundation
import CoreGraphics
import QuartzCore

/// 骨架增量接入（内嵌 Vision，去除对 pose.process 的依赖）
final class SkeletonAddon {
    static let shared = SkeletonAddon()

    // 对外发布：裁剪后画面单位线段（左上原点）
    final class Store: ObservableObject {
        @Published var segments: [(CGPoint, CGPoint)] = []
    }
    let store = Store()

    // 配置
    var maxPoseFPS: Double = 15          // 软限频
    var minJointConfidence: Float = 0.2  // 最低置信度
    var mirrorX: Bool = false            // 前置镜像预览可设为 true
    var disableROI: Bool = false         // 调试用：强制不用 ROI

    private var lastTick: CFTimeInterval = 0

    /// 主入口（每帧可调用；内部自行限频）
    func process(pixelBuffer: CVPixelBuffer,
                 orientation _: CGImagePropertyOrientation, // 保留旧签名，内部固定 .up
                 pts: CMTime,
                 follow: FollowResult) {

        // 限频
        let now = CACurrentMediaTime()
        if now - lastTick < 1.0 / maxPoseFPS { return }
        lastTick = now

        // —— 计算 Vision ROI（BL 归一化） —— //
        let W = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let H = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        var roiBL: CGRect? = nil   // BL 原点、整帧归一化 ROI
        if !disableROI, let sb = follow.stableBox, sb.width > 2, sb.height > 2 {
            // stableBox: 传感器 TL 像素 → 转为 Vision 期望的 BL 归一化
            roiBL = CGRect(
                x: sb.minX / max(W, 1),
                y: 1.0 - ((sb.minY + sb.height) / max(H, 1)),
                width: sb.width / max(W, 1),
                height: sb.height / max(H, 1)
            ).standardized
        }

        // —— 异步跑 Vision 人体骨架 —— //
        let request = VNDetectHumanBodyPoseRequest()
        if let r = roiBL { request.regionOfInterest = r }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try handler.perform([request])
                guard let obs = request.results?.first,
                      let body = try? obs.recognizedPoints(.all) else {
                    DispatchQueue.main.async { self.store.segments = [] }
                    return
                }

                // —— 将点映射到【裁剪后画面】的 [0,1] 单位坐标（左上原点） —— //
                let crop   = follow.cropRect
                let sensor = follow.sensorSize
                let sW = max(sensor.width, 1)
                let sH = max(sensor.height, 1)
                let cropN_TL = CGRect(x: crop.minX / sW, y: crop.minY / sH,
                                      width: crop.width / sW, height: crop.height / sH)

                @inline(__always)
                func mapToCrop(_ rp: VNRecognizedPoint) -> CGPoint? {
                    // 1) 若使用了 ROI：把 (ROI 内归一化) → (整帧 BL 归一化)
                    var pBL = rp.location
                    if let r = roiBL {
                        pBL.x = r.minX + pBL.x * r.width
                        pBL.y = r.minY + pBL.y * r.height
                    }
                    // 2) BL → TL，并按需镜像 X
                    var xTL = pBL.x
                    if mirrorX { xTL = 1 - xTL }
                    let pTL = CGPoint(x: xTL, y: 1 - pBL.y)
                    // 3) 传感器 TL 单位 → 裁剪后单位
                    let x = (pTL.x - cropN_TL.minX) / max(cropN_TL.width, 1e-6)
                    let y = (pTL.y - cropN_TL.minY) / max(cropN_TL.height, 1e-6)
                    guard x.isFinite, y.isFinite, x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
                    return CGPoint(x: x, y: y)
                }

                // —— 线段拓扑（稳定且简单） —— //
                let pairs: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
                    (.leftShoulder, .rightShoulder),
                    (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
                    (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
                    (.leftHip, .rightHip),
                    (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
                    (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
                    (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
                    (.nose, .leftEye), (.leftEye, .leftEar),
                    (.nose, .rightEye), (.rightEye, .rightEar)
                ]

                var segs: [(CGPoint, CGPoint)] = []
                for (a, b) in pairs {
                    if let pa = body[a], pa.confidence >= self.minJointConfidence,
                       let pb = body[b], pb.confidence >= self.minJointConfidence,
                       let A = mapToCrop(pa), let B = mapToCrop(pb) {
                        segs.append((A, B))
                    }
                }

                DispatchQueue.main.async { self.store.segments = segs }
            } catch {
                DispatchQueue.main.async { self.store.segments = [] }
            }
        }
    }
}

/// SwiftUI 覆盖层（放在预览之上）
struct SkeletonDebugOverlayView: View {
    @ObservedObject private var store = SkeletonAddon.shared.store

    var body: some View {
        GeometryReader { _ in
            Canvas { ctx, size in
                guard !store.segments.isEmpty else { return }
                var path = Path()
                for (a, b) in store.segments {
                    path.move(to: CGPoint(x: a.x * size.width, y: a.y * size.height))
                    path.addLine(to: CGPoint(x: b.x * size.width, y: b.y * size.height))
                }
                ctx.stroke(
                    path,
                    with: .color(.green),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .blendMode(.plusLighter)
        }
    }
}

