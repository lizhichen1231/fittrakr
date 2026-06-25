// TrackingOverlay.swift
// [C] 画面叠加层：bounding box + 骨骼点 + 构图参考线

import SwiftUI

#if DEBUG

struct TrackingOverlay: View {
    let data: DebugData
    let showBoxes: Bool
    let showSkeleton: Bool
    let viewSize: CGSize

    // 骨骼连接定义
    private let skeletonConnections: [(String, String)] = [
        // 躯干
        ("left_shoulder_1", "right_shoulder_1"),
        ("left_shoulder_1", "left_hip_1"),
        ("right_shoulder_1", "right_hip_1"),
        ("left_hip_1", "right_hip_1"),
        // 左臂
        ("left_shoulder_1", "left_elbow_1"),
        ("left_elbow_1", "left_wrist_1"),
        // 右臂
        ("right_shoulder_1", "right_elbow_1"),
        ("right_elbow_1", "right_wrist_1"),
        // 左腿
        ("left_hip_1", "left_knee_1"),
        ("left_knee_1", "left_ankle_1"),
        // 右腿
        ("right_hip_1", "right_knee_1"),
        ("right_knee_1", "right_ankle_1"),
    ]

    var body: some View {
        Canvas { context, size in
            // 1. 三分法网格线
            drawGrid(context: context, size: size)

            // 2. Bounding boxes
            if showBoxes {
                if let rawBox = data.rawBox {
                    drawBox(context: context, box: rawBox, size: size,
                           color: DebugColors.rawBoxColor, isDashed: true, lineWidth: 1)
                }
                if let stableBox = data.stableBox {
                    drawBox(context: context, box: stableBox, size: size,
                           color: DebugColors.stableBoxColor, isDashed: false, lineWidth: 2)
                }
            }

            // 3. 骨骼点和连线
            if showSkeleton, let positions = data.jointPositions {
                drawSkeleton(context: context, positions: positions,
                            confidences: data.jointConfidences, size: size)
            }

            // 4. 构图中心点
            drawFramingCrosses(context: context, size: size)
        }
    }

    // MARK: - 绘制三分法网格

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        var path = Path()

        // 垂直线
        for i in 1...2 {
            let x = size.width * CGFloat(i) / 3
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }

        // 水平线
        for i in 1...2 {
            let y = size.height * CGFloat(i) / 3
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }

        context.stroke(path, with: .color(DebugColors.gridLineColor), lineWidth: 0.5)
    }

    // MARK: - 绘制 Bounding Box

    private func drawBox(context: GraphicsContext, box: CGRect, size: CGSize,
                        color: Color, isDashed: Bool, lineWidth: CGFloat) {
        // 坐标转换：Vision (左下原点) → SwiftUI (左上原点)
        let screenRect = CGRect(
            x: box.minX * size.width,
            y: (1 - box.maxY) * size.height,
            width: box.width * size.width,
            height: box.height * size.height
        )

        var path = Path()
        path.addRect(screenRect)

        if isDashed {
            let style = StrokeStyle(lineWidth: lineWidth, dash: [5, 3])
            context.stroke(path, with: .color(color), style: style)
        } else {
            context.stroke(path, with: .color(color), lineWidth: lineWidth)
        }
    }

    // MARK: - 绘制骨骼点

    private func drawSkeleton(context: GraphicsContext, positions: [String: CGPoint],
                             confidences: [String: CGFloat]?, size: CGSize) {
        // 绘制连线
        for (from, to) in skeletonConnections {
            if let fromPos = positions[from], let toPos = positions[to] {
                let fromScreen = toScreen(fromPos, size: size)
                let toScreen = toScreen(toPos, size: size)

                var path = Path()
                path.move(to: fromScreen)
                path.addLine(to: toScreen)

                context.stroke(path, with: .color(DebugColors.skeletonLineColor), lineWidth: 1)
            }
        }

        // 绘制关节点
        for (name, pos) in positions {
            let screenPos = toScreen(pos, size: size)
            let confidence = confidences?[name] ?? 0.5

            // 根据置信度选择颜色
            let color: Color = confidence > 0.7 ? .green : (confidence > 0.3 ? .yellow : .red)

            let radius: CGFloat = 3
            let rect = CGRect(x: screenPos.x - radius, y: screenPos.y - radius,
                             width: radius * 2, height: radius * 2)

            context.fill(Path(ellipseIn: rect), with: .color(color))
        }
    }

    // MARK: - 绘制构图中心点

    private func drawFramingCrosses(context: GraphicsContext, size: CGSize) {
        // 画面中心（黄色）
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        drawCross(context: context, at: center, size: 12, color: DebugColors.centerCrossColor)

        // 目标中心（含偏移，红色）
        if data.framingOffset != .zero {
            let targetCenter = CGPoint(
                x: size.width / 2 + data.framingOffset.x * size.width,
                y: size.height / 2 - data.framingOffset.y * size.height // Y 轴翻转
            )
            drawCross(context: context, at: targetCenter, size: 12, color: DebugColors.targetCrossColor)

            // 连接线
            var path = Path()
            path.move(to: center)
            path.addLine(to: targetCenter)
            let style = StrokeStyle(lineWidth: 1, dash: [3, 2])
            context.stroke(path, with: .color(Color.white.opacity(0.5)), style: style)
        }
    }

    private func drawCross(context: GraphicsContext, at point: CGPoint, size: CGFloat, color: Color) {
        var path = Path()
        path.move(to: CGPoint(x: point.x - size/2, y: point.y))
        path.addLine(to: CGPoint(x: point.x + size/2, y: point.y))
        path.move(to: CGPoint(x: point.x, y: point.y - size/2))
        path.addLine(to: CGPoint(x: point.x, y: point.y + size/2))

        context.stroke(path, with: .color(color), lineWidth: 2)
    }

    // MARK: - 坐标转换

    private func toScreen(_ point: CGPoint, size: CGSize) -> CGPoint {
        // Vision 坐标系：左下原点，Y 向上
        // SwiftUI 坐标系：左上原点，Y 向下
        return CGPoint(
            x: point.x * size.width,
            y: (1 - point.y) * size.height
        )
    }
}

#endif
