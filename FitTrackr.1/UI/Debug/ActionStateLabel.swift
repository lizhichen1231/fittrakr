// ActionStateLabel.swift
// [A] 状态标签区：显示动作状态、景别、状态机状态

import SwiftUI

#if DEBUG

struct ActionStateLabel: View {
    let data: DebugData

    @State private var isTransitioning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 第一个标签：当前动作状态
            actionStateTag

            // 第二个标签：当前景别
            shotTypeTag

            // 第三个标签：状态机状态
            stateMachineTag
        }
        .onChange(of: data.rawActionState) { _ in
            withAnimation(.easeInOut(duration: 0.15)) {
                isTransitioning = data.rawActionState != data.actionState
            }
        }
    }

    // MARK: - 动作状态标签

    private var actionStateTag: some View {
        HStack(spacing: 6) {
            Text(actionEmoji)
            Text(actionName)
            Text("\(Int(data.actionConfidence * 100))%")
                .foregroundColor(.white.opacity(0.7))
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(DebugColors.color(for: data.actionState))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isTransitioning ? Color.white : Color.clear, lineWidth: 2)
                .opacity(isTransitioning ? 1 : 0)
        )
        .animation(.easeInOut(duration: 0.3), value: data.actionState)
    }

    // MARK: - 景别标签

    private var shotTypeTag: some View {
        HStack(spacing: 6) {
            Text(shotEmoji)

            if data.stateMachineState == "Transitioning" {
                Text("\(shotName(data.shotType)) → \(shotName(data.targetShotType))")
                Text(String(format: "%.1fx→%.1fx", zoomForShot(data.shotType), zoomForShot(data.targetShotType)))
                    .foregroundColor(.white.opacity(0.7))
            } else {
                Text(shotName(data.shotType))
                Text(String(format: "%.2fx", data.currentZoom))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(DebugColors.labelBackground)
        .cornerRadius(8)
    }

    // MARK: - 状态机标签

    private var stateMachineTag: some View {
        HStack(spacing: 4) {
            Image(systemName: "gearshape")
                .font(.system(size: 9))

            Text(data.stateMachineState)

            if data.stateMachineState == "Transitioning" {
                Text("\(Int(data.transitionProgress * 100))%")
            } else if data.stateMachineState == "Holding" {
                Text(String(format: "%.1fs", data.timeSinceLastSwitch))
            }
        }
        .font(.system(size: 9, weight: .regular, design: .monospaced))
        .foregroundColor(.gray)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.6))
        .cornerRadius(6)
    }

    // MARK: - 辅助属性

    private var actionEmoji: String {
        switch data.actionState {
        case .talkingHead: return "🎤"
        case .fullBody: return "🏃"
        case .upperBody: return "💪"
        case .showAndTell: return "👋"
        case .idle: return "😶"
        }
    }

    private var actionName: String {
        switch data.actionState {
        case .talkingHead: return "Talking Head"
        case .fullBody: return "Full Body"
        case .upperBody: return "Upper Body"
        case .showAndTell: return "Show & Tell"
        case .idle: return "Idle"
        }
    }

    private var shotEmoji: String {
        switch data.shotType {
        case .closeUp: return "📷"
        case .medium: return "🎬"
        case .wide: return "🏠"
        case .detail: return "🔍"
        }
    }

    private func shotName(_ type: ShotType) -> String {
        switch type {
        case .closeUp: return "Close-up"
        case .medium: return "Medium"
        case .wide: return "Wide"
        case .detail: return "Detail"
        }
    }

    private func zoomForShot(_ type: ShotType) -> CGFloat {
        switch type {
        case .closeUp: return 1.8
        case .medium: return 1.4
        case .wide: return 1.0
        case .detail: return 2.2
        }
    }
}

#endif
