// DebugControlBar.swift
// [E] 控制区：debug 开关按钮

import SwiftUI

#if DEBUG

struct DebugControlBar: View {
    @Binding var showAll: Bool
    @Binding var showSkeleton: Bool
    @Binding var showBoxes: Bool
    @Binding var showPanel: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Debug 总开关
            DebugToggleButton(
                icon: showAll ? "eye" : "eye.slash",
                isActive: showAll
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showAll.toggle()
                }
            }

            if showAll {
                // 骨骼点开关
                DebugToggleButton(
                    icon: "figure.stand",
                    isActive: showSkeleton
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSkeleton.toggle()
                    }
                }

                // Box 开关
                DebugToggleButton(
                    icon: "rectangle.dashed",
                    isActive: showBoxes
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showBoxes.toggle()
                    }
                }

                // 数据面板开关
                DebugToggleButton(
                    icon: "chart.bar",
                    isActive: showPanel
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showPanel.toggle()
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.6))
        .cornerRadius(20)
    }
}

// MARK: - 单个开关按钮

struct DebugToggleButton: View {
    let icon: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isActive ? .white : .gray)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(isActive ? Color.white.opacity(0.2) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }
}

#endif
