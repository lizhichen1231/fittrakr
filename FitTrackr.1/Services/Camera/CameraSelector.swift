import CoreGraphics
import Foundation

enum CameraType {
    case wide
    case telephoto
}

struct CameraSelection {
    let camera: CameraType
    let digitalCrop: CGFloat
}

class CameraSelector {
    private var deviceInfo: DeviceCameraInfo { DeviceCameraInfo.shared }

    var telephotoZoom: CGFloat { deviceInfo.telephotoZoom }

    // 使用 isTelephotoUsable 而非 hasTelephoto（检查 ≤3x 限制）
    var canUseTelephoto: Bool { deviceInfo.isTelephotoUsable }

    // 切换到长焦的最小缩放倍数
    var minZoomForTelephoto: CGFloat = 2.0

    func select(equivalentZoom: CGFloat, personCenter: CGPoint) -> CameraSelection {
        // 如果长焦不可用（没有或超过3x），直接用广角
        guard canUseTelephoto else {
            return CameraSelection(camera: .wide, digitalCrop: max(1.0, equivalentZoom))
        }

        // 安全区计算：长焦视野在广角中的覆盖范围
        let coverage = 1.0 / telephotoZoom
        let baseMargin = (1.0 - coverage) / 2
        let safetyPadding = min(0.05, coverage * 0.3)
        let effectiveMargin = min(baseMargin + safetyPadding, 0.48)

        let isInSafeZone =
            personCenter.x >= effectiveMargin && personCenter.x <= (1 - effectiveMargin) &&
            personCenter.y >= effectiveMargin && personCenter.y <= (1 - effectiveMargin)

        // 当 zoom >= 阈值 且人在安全区时，切换到长焦
        let shouldUseTelephoto = equivalentZoom >= minZoomForTelephoto && isInSafeZone

        if shouldUseTelephoto {
            let digitalCrop = max(1.0, equivalentZoom / telephotoZoom)
            return CameraSelection(camera: .telephoto, digitalCrop: digitalCrop)
        } else {
            return CameraSelection(camera: .wide, digitalCrop: max(1.0, equivalentZoom))
        }
    }

    func convertToTelephoto(_ pointInWide: CGPoint) -> CGPoint {
        let coverage = 1.0 / telephotoZoom
        let margin = (1.0 - coverage) / 2
        return CGPoint(
            x: (pointInWide.x - margin) / coverage,
            y: (pointInWide.y - margin) / coverage
        )
    }

    func isInTelephotoView(_ pointInWide: CGPoint) -> Bool {
        guard canUseTelephoto else { return false }
        let coverage = 1.0 / telephotoZoom
        let margin = (1.0 - coverage) / 2
        return pointInWide.x >= margin && pointInWide.x <= (1 - margin) &&
               pointInWide.y >= margin && pointInWide.y <= (1 - margin)
    }
}
