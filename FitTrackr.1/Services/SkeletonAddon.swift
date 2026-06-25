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

    // 线程安全的髋部数据（供 FollowEngine 从任意线程读取）
    private let hipLock = NSLock()
    private var _hipCenter: CGPoint? = nil
    private var _hipConfidence: Float = 0

    /// 线程安全地获取髋部中心
    func getHipData() -> (center: CGPoint?, confidence: Float) {
        hipLock.lock()
        let result = (_hipCenter, _hipConfidence)
        hipLock.unlock()
        return result
    }

    /// 内部更新髋部数据
    private func setHipData(center: CGPoint?, confidence: Float) {
        hipLock.lock()
        _hipCenter = center
        _hipConfidence = confidence
        hipLock.unlock()
    }

    // 配置
    var maxPoseFPS: Double = 15          // 软限频
    var minJointConfidence: Float = 0.2  // 最低置信度
    var mirrorX: Bool = false            // 前置镜像预览可设为 true
    var disableROI: Bool = false         // 调试用：强制不用 ROI

    private var lastTick: CFTimeInterval = 0

    /// 主入口（每帧可调用；内部自行限频）。
    /// 传入 `pose`（复用主检测结果）时**不再自己跑 Vision**，仅做坐标映射（去重）；
    /// 不传时回退到自检（保留 ROI + 限频），保证兼容。
    func process(pixelBuffer: CVPixelBuffer,
                 orientation _: CGImagePropertyOrientation, // 保留旧签名，内部固定 .up
                 pts: CMTime,
                 follow: FollowResult,
                 pose: VNHumanBodyPoseObservation? = nil) {

        // 限频
        let now = CACurrentMediaTime()
        if now - lastTick < 1.0 / maxPoseFPS { return }
        lastTick = now

        // —— 复用主检测 pose：去重，不再跑 Vision，只做映射（整帧归一化，无 ROI）——
        if let pose = pose {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self, let body = try? pose.recognizedPoints(.all) else {
                    self?.setHipData(center: nil, confidence: 0)
                    DispatchQueue.main.async { self?.store.segments = [] }
                    return
                }
                self.emit(body: body, roiBL: nil, follow: follow)
            }
            return
        }

        // —— 兜底：未拿到主 pose 时自检（保留 ROI）——
        let W = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let H = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        var roiBL: CGRect? = nil
        if !disableROI, let sb = follow.stableBox, sb.width > 2, sb.height > 2 {
            roiBL = CGRect(
                x: sb.minX / max(W, 1),
                y: 1.0 - ((sb.minY + sb.height) / max(H, 1)),
                width: sb.width / max(W, 1),
                height: sb.height / max(H, 1)
            ).standardized
        }
        let request = VNDetectHumanBodyPoseRequest()
        if let r = roiBL { request.regionOfInterest = r }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try handler.perform([request])
                guard let obs = request.results?.first,
                      let body = try? obs.recognizedPoints(.all) else {
                    self.setHipData(center: nil, confidence: 0)
                    DispatchQueue.main.async { self.store.segments = [] }
                    return
                }
                self.emit(body: body, roiBL: roiBL, follow: follow)
            } catch {
                self.setHipData(center: nil, confidence: 0)
                DispatchQueue.main.async { self.store.segments = [] }
            }
        }
    }

    /// 把骨骼点映射到【裁剪后画面】单位坐标 + 更新髋部数据 + 发布线段（两条路径共用）
    private func emit(body: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
                      roiBL: CGRect?,
                      follow: FollowResult) {
        let crop   = follow.cropRect
        let sensor = follow.sensorSize
        let sW = max(sensor.width, 1)
        let sH = max(sensor.height, 1)
        let cropN_TL = CGRect(x: crop.minX / sW, y: crop.minY / sH,
                              width: crop.width / sW, height: crop.height / sH)

        func mapToCrop(_ rp: VNRecognizedPoint) -> CGPoint? {
            var pBL = rp.location
            if let r = roiBL {
                pBL.x = r.minX + pBL.x * r.width
                pBL.y = r.minY + pBL.y * r.height
            }
            var xTL = pBL.x
            if mirrorX { xTL = 1 - xTL }
            let pTL = CGPoint(x: xTL, y: 1 - pBL.y)
            let x = (pTL.x - cropN_TL.minX) / max(cropN_TL.width, 1e-6)
            let y = (pTL.y - cropN_TL.minY) / max(cropN_TL.height, 1e-6)
            guard x.isFinite, y.isFinite, x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
            return CGPoint(x: x, y: y)
        }

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

        var hipCenter: CGPoint? = nil
        var hipConf: Float = 0
        if let leftHip = body[.leftHip], let rightHip = body[.rightHip] {
            let minConf = min(leftHip.confidence, rightHip.confidence)
            if minConf >= self.minJointConfidence {
                var lhBL = leftHip.location
                var rhBL = rightHip.location
                if let r = roiBL {
                    lhBL.x = r.minX + lhBL.x * r.width
                    lhBL.y = r.minY + lhBL.y * r.height
                    rhBL.x = r.minX + rhBL.x * r.width
                    rhBL.y = r.minY + rhBL.y * r.height
                }
                let lhTL = CGPoint(x: lhBL.x, y: 1 - lhBL.y)
                let rhTL = CGPoint(x: rhBL.x, y: 1 - rhBL.y)
                hipCenter = CGPoint(x: (lhTL.x + rhTL.x) / 2, y: (lhTL.y + rhTL.y) / 2)
                hipConf = minConf
            }
        }

        self.setHipData(center: hipCenter, confidence: hipConf)
        DispatchQueue.main.async { self.store.segments = segs }
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

