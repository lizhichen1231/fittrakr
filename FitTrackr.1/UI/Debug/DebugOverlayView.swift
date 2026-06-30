// DebugOverlayView.swift
// 主 Debug Overlay View，组合所有子组件
// 覆盖追踪 + 动作分类 + 景别决策全链路的调试信息

import SwiftUI

#if DEBUG

struct DebugOverlayView: View {
    let data: DebugData?

    // 控制开关状态:showAll 改由外部共享开关(vm.showDebugOverlay,默认关)驱动;子开关仍局部
    @Binding var showAll: Bool
    @State private var showSkeleton: Bool = true
    @State private var showBoxes: Bool = true
    @State private var showPanel: Bool = true

    var body: some View {
        GeometryReader { geo in
            let safeData = data ?? DebugData.empty

            ZStack {
                // [C] 画面叠加层（全屏）
                if showAll {
                    TrackingOverlay(
                        data: safeData,
                        showBoxes: showBoxes,
                        showSkeleton: showSkeleton,
                        viewSize: geo.size
                    )
                }

                // [A] 状态标签区（左上角）
                if showAll {
                    VStack {
                        HStack {
                            ActionStateLabel(data: safeData)
                                .padding(.leading, 12)
                                .padding(.top, 12)

                            Spacer()
                        }
                        Spacer()
                    }
                }

                // [B] 数据面板（右上角）
                if showAll && showPanel {
                    VStack {
                        HStack {
                            Spacer()
                            FeaturePanel(data: safeData)
                                .padding(.trailing, 12)
                                .padding(.top, 12)
                        }
                        Spacer()
                    }
                }

                // 底部区域
                VStack {
                    Spacer()

                    HStack(alignment: .bottom) {
                        // [D] 景别指示条（底部左侧）
                        if showAll {
                            ShotIndicatorBar(data: safeData)
                                .padding(.leading, 12)
                        }

                        Spacer()

                        // [E] 控制区（底部右侧）
                        DebugControlBar(
                            showAll: $showAll,
                            showSkeleton: $showSkeleton,
                            showBoxes: $showBoxes,
                            showPanel: $showPanel
                        )
                        .padding(.trailing, 12)
                    }
                    .padding(.bottom, 80) // 避免和底部 Tab 栏重叠
                }
            }
        }
        .allowsHitTesting(true)
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black.edgesIgnoringSafeArea(.all)

        DebugOverlayView(
            data: DebugData(
                rawBox: CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.6),
                stableBox: CGRect(x: 0.32, y: 0.22, width: 0.36, height: 0.56),
                confidence: 0.92,
                currentZoom: 1.65,
                fps: 28,
                actionState: .talkingHead,
                rawActionState: .upperBody,
                actionConfidence: 0.78,
                overallMotion: 0.015,
                upperLowerRatio: 2.5,
                handExtension: 0.9,
                handInCenter: false,
                shotType: .closeUp,
                targetShotType: .medium,
                stateMachineState: "Transitioning",
                transitionProgress: 0.45,
                timeSinceLastSwitch: 2.3,
                framingOffset: CGPoint(x: 0, y: -0.08),
                jointPositions: [
                    "nose_1": CGPoint(x: 0.5, y: 0.85),
                    "left_shoulder_1": CGPoint(x: 0.4, y: 0.7),
                    "right_shoulder_1": CGPoint(x: 0.6, y: 0.7),
                    "left_hip_1": CGPoint(x: 0.42, y: 0.45),
                    "right_hip_1": CGPoint(x: 0.58, y: 0.45),
                    "left_wrist_1": CGPoint(x: 0.3, y: 0.55),
                    "right_wrist_1": CGPoint(x: 0.7, y: 0.55)
                ],
                jointConfidences: [
                    "nose_1": 0.95,
                    "left_shoulder_1": 0.88,
                    "right_shoulder_1": 0.9,
                    "left_hip_1": 0.85,
                    "right_hip_1": 0.82,
                    "left_wrist_1": 0.75,
                    "right_wrist_1": 0.78
                ],
                zoomMode: .intelligent
            ),
            showAll: .constant(true)
        )
    }
}

#endif
