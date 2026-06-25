// ShotIndicatorBar.swift
// [D] 景别指示条：显示所有景别和当前位置

import SwiftUI

#if DEBUG

struct ShotIndicatorBar: View {
    let data: DebugData

    // 景别对应的 zoom 值（用于定位）
    private let shotZooms: [(ShotType, CGFloat)] = [
        (.wide, 1.0),
        (.medium, 1.4),
        (.closeUp, 1.8),
        (.detail, 2.2)
    ]

    private let barWidth: CGFloat = 200
    private let indicatorSize: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 景别名称
            HStack(spacing: 0) {
                ForEach(shotZooms, id: \.0) { shot, zoom in
                    Text(shortName(shot))
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(data.shotType == shot ? .white : .gray)
                        .frame(width: barWidth / CGFloat(shotZooms.count))
                }
            }

            // 进度条
            ZStack(alignment: .leading) {
                // 背景条
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.gray.opacity(0.4))
                    .frame(width: barWidth, height: 3)

                // 景别标记点
                HStack(spacing: 0) {
                    ForEach(0..<shotZooms.count, id: \.self) { index in
                        Circle()
                            .fill(data.shotType == shotZooms[index].0 ? .white : .gray)
                            .frame(width: 5, height: 5)

                        if index < shotZooms.count - 1 {
                            Spacer()
                        }
                    }
                }
                .frame(width: barWidth)

                // 目标位置指示器（空心圆）
                if data.stateMachineState == "Transitioning" {
                    Circle()
                        .stroke(Color.white.opacity(0.5), lineWidth: 1)
                        .frame(width: indicatorSize, height: indicatorSize)
                        .offset(x: zoomToOffset(zoomForShot(data.targetShotType)) - indicatorSize / 2)
                }

                // 当前位置指示器（实心圆）
                Circle()
                    .fill(Color.white)
                    .frame(width: indicatorSize, height: indicatorSize)
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                    .offset(x: zoomToOffset(data.currentZoom) - indicatorSize / 2)
                    .animation(.easeOut(duration: 0.2), value: data.currentZoom)
            }
            .frame(height: indicatorSize)

            // 当前 zoom 数值
            Text(String(format: "%.2fx", data.currentZoom))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.7))
        .cornerRadius(8)
    }

    // MARK: - 辅助方法

    private func shortName(_ shot: ShotType) -> String {
        switch shot {
        case .wide: return "Wide"
        case .medium: return "Med"
        case .closeUp: return "Close"
        case .detail: return "Detail"
        }
    }

    private func zoomForShot(_ shot: ShotType) -> CGFloat {
        switch shot {
        case .wide: return 1.0
        case .medium: return 1.4
        case .closeUp: return 1.8
        case .detail: return 2.2
        }
    }

    private func zoomToOffset(_ zoom: CGFloat) -> CGFloat {
        // 将 zoom 值映射到条的位置
        let minZoom: CGFloat = 1.0
        let maxZoom: CGFloat = 2.2
        let normalizedZoom = (zoom - minZoom) / (maxZoom - minZoom)
        return normalizedZoom * barWidth
    }
}

#endif
