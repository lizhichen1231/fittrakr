
import AVFoundation

/// 类似苹果相机的两档感觉：
/// - normal：低延迟标准防抖（.standard）
/// - slightlyDelayed：更稳，允许一点延迟（优先 .cinematic，不支持则退回 .auto/.standard）
public enum AppleCamFeel { case normal, slightlyDelayed }

public struct AppleStabilizer {
    public init() {}

    /// 预览阶段应用“相机感受”的稳定参数
    public func applyPreview(feel: AppleCamFeel, to connection: AVCaptureConnection) {
        guard connection.isVideoStabilizationSupported else { return }
        switch feel {
        case .normal:
            // 低延迟标准防抖
            if connection.preferredVideoStabilizationMode != .standard {
                connection.preferredVideoStabilizationMode = .standard
            }
        case .slightlyDelayed:
            // 更稳一点：尽量上 .cinematic；不支持则让系统自动挑选
            if #available(iOS 13.0, *) {
                connection.preferredVideoStabilizationMode = .cinematic
            } else {
                connection.preferredVideoStabilizationMode = .auto
            }
        }
    }

    /// 录制阶段：尽量给到更好的稳定（可比预览更“稳”）
    public func applyRecordingBest(to connection: AVCaptureConnection) {
        guard connection.isVideoStabilizationSupported else { return }
        // 先尝试 extended，其次 cinematic，最后 standard
        if #available(iOS 13.0, *) {
            connection.preferredVideoStabilizationMode = .cinematicExtended
        } else {
            connection.preferredVideoStabilizationMode = .cinematic
        }
        // 注意：最终生效模式以 connection.activeVideoStabilizationMode 为准，
        // 不支持的情况下系统会降级到可用模式（可能是 .off/.standard）
    }

    /// 关闭系统防抖
    public func turnOff(on connection: AVCaptureConnection) {
        guard connection.isVideoStabilizationSupported else { return }
        if connection.preferredVideoStabilizationMode != .off {
            connection.preferredVideoStabilizationMode = .off
        }
    }
}

