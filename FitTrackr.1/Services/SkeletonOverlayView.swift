import UIKit
import AVFoundation
import Vision

// 轻量平滑器：对屏幕坐标做 EMA，减少视觉抖动
final class PoseSmoother {
    var alpha: CGFloat = 0.35 // 0~1，越小越稳
    private var last: [String: CGPoint] = [:]
    func reset() { last.removeAll() }
    func apply(name: String, point: CGPoint) -> CGPoint {
        if let p = last[name] {
            let q = CGPoint(x: p.x + (point.x - p.x) * alpha,
                            y: p.y + (point.y - p.y) * alpha)
            last[name] = q; return q
        } else { last[name] = point; return point }
    }
}

/// 覆盖层：把 Vision 的人体+手部关键点画在预览上（基于 CAShapeLayer）
final class SkeletonOverlayView: UIView {
    // 由外部注入（预览层知道实际裁切/镜像/旋转）
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    // 置信度门槛（避免“飞线”）
    var minConfLine: Float = 0.35
    var minConfDot:  Float = 0.25

    // 画线/点的图层（合并为 4 个，避免成百上千个图层）
    private let bodyLines = CAShapeLayer()
    private let bodyDots  = CAShapeLayer()
    private let handLines = CAShapeLayer()
    private let handDots  = CAShapeLayer()

    private let smoother = PoseSmoother()

    // 人体连线（19 点常见拓扑）
    private let bodyChains: [[VNHumanBodyPoseObservation.JointName]] = [
        [.leftShoulder, .leftElbow, .leftWrist],
        [.rightShoulder, .rightElbow, .rightWrist],
        [.leftHip, .leftKnee, .leftAnkle],
        [.rightHip, .rightKnee, .rightAnkle],
        [.leftShoulder, .neck, .rightShoulder],
        [.leftHip, .rightHip],
        [.neck, .nose],
        [.nose, .leftEye, .leftEar],
        [.nose, .rightEye, .rightEar],
        [.leftShoulder, .leftHip],
        [.rightShoulder, .rightHip]
    ]

    // 手部连线
    private let handChains: [[VNHumanHandPoseObservation.JointName]] = [
        [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip],
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for l in [bodyLines, handLines] {
            l.strokeColor = UIColor.systemBlue.withAlphaComponent(0.9).cgColor
            l.fillColor = UIColor.clear.cgColor
            l.lineWidth = 2
            layer.addSublayer(l)
        }
        // 手部用绿色
        handLines.strokeColor = UIColor.systemGreen.withAlphaComponent(0.9).cgColor

        bodyDots.fillColor = UIColor.systemBlue.cgColor
        handDots.fillColor = UIColor.systemGreen.cgColor
        layer.addSublayer(bodyDots)
        layer.addSublayer(handDots)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 显示/更新骨架（在主线程调用）
    /// - Parameters:
    ///   - bodies: 体骨架（字典：JointName->Point）
    ///   - hands: 手骨架（同上）
    func render(bodies: [[VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]],
                hands:  [[VNHumanHandPoseObservation.JointName: VNRecognizedPoint]]) {
        assert(Thread.isMainThread, "render must be called on main thread")
        guard let layer = previewLayer else { return }

        // 组合路径（一次性赋值，避免大量小对象）
        let bLines = UIBezierPath()
        let bDots  = UIBezierPath()
        let hLines = UIBezierPath()
        let hDots  = UIBezierPath()

        CATransaction.begin()
        CATransaction.setDisableActions(true) // 禁止隐式动画，避免“抖一下”

        // —— 人体 —— //
        for dict in bodies {
            for chain in bodyChains {
                var lastPt: CGPoint? = nil
                for name in chain {
                    guard let rp = dict[name], rp.confidence >= minConfLine else { lastPt = nil; continue }
                    let p = toScreenPoint(rp.location, layer: layer)
                    let s = smoother.apply(name: "body.\(name.rawValue)", point: p)
                    if let a = lastPt { bLines.move(to: a); bLines.addLine(to: s) }
                    lastPt = s
                }
            }
            // 点：用关节名作为 key，连续帧才有记忆
            for (name, rp) in dict where rp.confidence >= minConfDot {
                let p = toScreenPoint(rp.location, layer: layer)
                let s = smoother.apply(name: "body.dot.\(name.rawValue)", point: p)
                bDots.append(UIBezierPath(ovalIn: CGRect(x: s.x-3, y: s.y-3, width: 6, height: 6)))
            }
        }

        // —— 手部 —— //
        for dict in hands {
            for chain in handChains {
                var lastPt: CGPoint? = nil
                for name in chain {
                    guard let rp = dict[name], rp.confidence >= minConfLine else { lastPt = nil; continue }
                    let p = toScreenPoint(rp.location, layer: layer)
                    let s = smoother.apply(name: "hand.\(name.rawValue)", point: p)
                    if let a = lastPt { hLines.move(to: a); hLines.addLine(to: s) }
                    lastPt = s
                }
            }
            // 点：同理使用关节名作 key
            for (name, rp) in dict where rp.confidence >= minConfDot {
                let p = toScreenPoint(rp.location, layer: layer)
                let s = smoother.apply(name: "hand.dot.\(name.rawValue)", point: p)
                hDots.append(UIBezierPath(ovalIn: CGRect(x: s.x-3, y: s.y-3, width: 6, height: 6)))
            }
        }

        bodyLines.path = bLines.cgPath
        bodyDots.path  = bDots.cgPath
        handLines.path = hLines.cgPath
        handDots.path  = hDots.cgPath

        CATransaction.commit()
    }

    private func toScreenPoint(_ norm: CGPoint, layer: AVCaptureVideoPreviewLayer) -> CGPoint {
        // Vision: (x, y) 图像坐标，左下为 (0,0)
        // AVCaptureDevicePoint: (x, y) 左上为 (0,0)；因此需要翻转 y
        let devicePoint = CGPoint(x: norm.x, y: 1 - norm.y)
        return layer.layerPointConverted(fromCaptureDevicePoint: devicePoint)
    }
}

