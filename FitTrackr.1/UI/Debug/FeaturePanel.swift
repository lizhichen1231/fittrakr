// FeaturePanel.swift
// [B] 数据面板：显示 ActionClassifier 的四个特征值

import SwiftUI

#if DEBUG

struct FeaturePanel: View {
    let data: DebugData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 标题
            HStack {
                Image(systemName: "chart.bar")
                    .font(.system(size: 10))
                Text("Features")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .foregroundColor(.white.opacity(0.8))

            Divider()
                .background(Color.white.opacity(0.2))

            // 特征值
            FeatureRow(
                name: "Motion",
                value: data.overallMotion,
                maxValue: 0.1,
                warningThreshold: 0.03,
                dangerThreshold: 0.06,
                format: "%.3f"
            )

            FeatureRow(
                name: "U/L Ratio",
                value: min(data.upperLowerRatio, 10),
                maxValue: 10,
                warningThreshold: 3,
                dangerThreshold: 7,
                format: "%.2f"
            )

            FeatureRow(
                name: "Hand Ext",
                value: min(data.handExtension, 3),
                maxValue: 3,
                warningThreshold: 1.5,
                dangerThreshold: 2.5,
                format: "%.2f",
                specialColor: data.handExtension > 1.5 ? DebugColors.showAndTell : nil
            )

            // 手部中心（布尔值）
            HStack {
                Text("Hand Ctr")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 60, alignment: .leading)

                Circle()
                    .fill(data.handInCenter ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)

                Text(data.handInCenter ? "Yes" : "No")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))

                Spacer()
            }

            Divider()
                .background(Color.white.opacity(0.2))

            // 底部信息行
            HStack {
                Text("FPS:")
                    .foregroundColor(.white.opacity(0.6))
                Text(String(format: "%.0f", data.fps))
                    .foregroundColor(.white)

                Spacer()

                Text("Zoom:")
                    .foregroundColor(.white.opacity(0.6))
                Text(String(format: "%.2fx", data.currentZoom))
                    .foregroundColor(.cyan)
            }
            .font(.system(size: 9, design: .monospaced))

            HStack {
                Text("Conf:")
                    .foregroundColor(.white.opacity(0.6))
                Text(String(format: "%.0f%%", data.confidence * 100))
                    .foregroundColor(confidenceColor)

                Spacer()

                Text(data.zoomMode == .intelligent ? "🎬 Smart" : "📐 Fixed")
                    .font(.system(size: 8))
            }
            .font(.system(size: 9, design: .monospaced))
        }
        .padding(10)
        .frame(width: 160)
        .background(DebugColors.panelBackground)
        .cornerRadius(10)
    }

    private var confidenceColor: Color {
        if data.confidence >= 0.8 { return .green }
        if data.confidence >= 0.5 { return .yellow }
        return .red
    }
}

// MARK: - 特征值行

struct FeatureRow: View {
    let name: String
    let value: CGFloat
    let maxValue: CGFloat
    let warningThreshold: CGFloat
    let dangerThreshold: CGFloat
    let format: String
    var specialColor: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            // 名称
            Text(name)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 60, alignment: .leading)

            // 进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // 背景
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 4)

                    // 进度
                    RoundedRectangle(cornerRadius: 2)
                        .fill(progressColor)
                        .frame(width: min(geo.size.width, geo.size.width * (value / maxValue)), height: 4)
                }
            }
            .frame(width: 50, height: 4)

            // 数值
            Text(String(format: format, value))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(progressColor)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private var progressColor: Color {
        if let special = specialColor { return special }
        if value >= dangerThreshold { return DebugColors.dangerValue }
        if value >= warningThreshold { return DebugColors.warningValue }
        return DebugColors.normalValue
    }
}

#endif
