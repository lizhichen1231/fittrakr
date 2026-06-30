// DebugColors.swift
// Debug Overlay 颜色常量定义

import SwiftUI

#if DEBUG

// MARK: - Debug 颜色常量

enum DebugColors {
    // 动作状态颜色
    static let talkingHead = Color(hex: 0x4A90D9)   // 蓝色
    static let fullBody = Color(hex: 0x50C878)      // 绿色
    static let upperBody = Color(hex: 0xFF9500)     // 橙色
    static let showAndTell = Color(hex: 0xAF52DE)   // 紫色
    static let idle = Color(hex: 0x8E8E93)          // 灰色

    // 景别颜色
    static let closeUp = Color(hex: 0x4A90D9)       // 蓝色
    static let medium = Color(hex: 0x00CED1)        // 青色
    static let wide = Color(hex: 0x50C878)          // 绿色
    static let detail = Color(hex: 0xAF52DE)        // 紫色

    // 进度条颜色
    static let normalValue = Color.white
    static let warningValue = Color.yellow
    static let dangerValue = Color.red

    // 背景颜色
    static let panelBackground = Color.black.opacity(0.8)
    static let labelBackground = Color.black.opacity(0.85)

    // 叠加层颜色
    static let rawBoxColor = Color.yellow
    static let stableBoxColor = Color.green
    static let skeletonLineColor = Color.white.opacity(0.6)
    static let gridLineColor = Color.white.opacity(0.15)
    static let centerCrossColor = Color.yellow
    static let targetCrossColor = Color.red

    // 获取动作状态对应的颜色
    static func color(for actionState: ActionState) -> Color {
        switch actionState {
        case .talkingHead: return talkingHead
        case .fullBody: return fullBody
        case .upperBody: return upperBody
        case .showAndTell: return showAndTell
        case .idle: return idle
        }
    }

    // 获取景别对应的颜色
    static func color(for shotType: ShotType) -> Color {
        switch shotType {
        case .closeUp: return closeUp
        case .medium: return medium
        case .wide: return wide
        case .detail: return detail
        }
    }
}

// MARK: - Color Hex Extension

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

#endif
