import AVFoundation

struct CameraInfo {
    let device: AVCaptureDevice
    let type: AVCaptureDevice.DeviceType
    let zoomFactor: CGFloat
}

class DeviceCameraInfo {
    static let shared = DeviceCameraInfo()

    private(set) var ultraWide: CameraInfo?
    private(set) var wide: CameraInfo?
    private(set) var telephoto: CameraInfo?

    var hasUltraWide: Bool { ultraWide != nil }
    var hasWide: Bool { wide != nil }
    var hasTelephoto: Bool { telephoto != nil }

    var ultraWideZoom: CGFloat { ultraWide?.zoomFactor ?? 0.5 }
    var wideZoom: CGFloat { wide?.zoomFactor ?? 1.0 }
    var telephotoZoom: CGFloat { telephoto?.zoomFactor ?? 2.0 }

    // 最大允许的长焦倍率（超过此值的长焦不使用）
    static let maxAllowedTelephotoZoom: CGFloat = 3.0

    // 长焦是否在可用范围内（≤ 3x）
    var isTelephotoUsable: Bool {
        hasTelephoto && telephotoZoom <= Self.maxAllowedTelephotoZoom
    }

    var isMultiCamSupported: Bool { AVCaptureMultiCamSession.isMultiCamSupported }

    // 多摄可用条件：系统支持 + 有长焦 + 长焦 ≤ 3x
    var canUseMultiCam: Bool { isMultiCamSupported && isTelephotoUsable }

    private init() { detectCameras() }

    private func detectCameras() {
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInUltraWideCamera,
            .builtInWideAngleCamera,
            .builtInTelephotoCamera
        ]

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .back
        )

        print("📷 [DeviceInfo] 发现 \(discovery.devices.count) 个镜头:")
        for device in discovery.devices {
            let zoom = getEquivalentZoom(for: device)
            let info = CameraInfo(device: device, type: device.deviceType, zoomFactor: zoom)
            print("📷   - \(device.localizedName) | type=\(device.deviceType.rawValue) | zoom=\(zoom)x")

            switch device.deviceType {
            case .builtInUltraWideCamera:
                ultraWide = info
            case .builtInWideAngleCamera:
                wide = info
            case .builtInTelephotoCamera:
                telephoto = info
            default:
                break
            }
        }

        print("📷 设备镜头: 超广=\(hasUltraWide), 广角=\(hasWide), 长焦=\(hasTelephoto)(\(telephotoZoom)x)")
        if hasTelephoto && !isTelephotoUsable {
            print("📷 ⚠️ 长焦 \(telephotoZoom)x 超过限制 \(Self.maxAllowedTelephotoZoom)x，不启用多摄")
        }
        print("📷 多摄支持: isMultiCamSupported=\(isMultiCamSupported), isTelephotoUsable=\(isTelephotoUsable), canUseMultiCam=\(canUseMultiCam)")
    }

    private func getEquivalentZoom(for device: AVCaptureDevice) -> CGFloat {
        switch device.deviceType {
        case .builtInUltraWideCamera:
            return 0.5
        case .builtInWideAngleCamera:
            return 1.0
        case .builtInTelephotoCamera:
            return getTelephotoZoom(device)
        default:
            return 1.0
        }
    }

    private func getTelephotoZoom(_ device: AVCaptureDevice) -> CGFloat {
        // 尝试从虚拟设备获取切换点
        if let triple = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back),
           let factors = triple.virtualDeviceSwitchOverVideoZoomFactors as? [NSNumber],
           let last = factors.last {
            return CGFloat(truncating: last)
        }

        if let dual = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back),
           let factors = dual.virtualDeviceSwitchOverVideoZoomFactors as? [NSNumber],
           let first = factors.first {
            return CGFloat(truncating: first)
        }

        // 兜底
        return 2.0
    }

    func coverageRect(for zoom: CGFloat) -> CGRect {
        let size = 1.0 / zoom
        let margin = (1.0 - size) / 2
        return CGRect(x: margin, y: margin, width: size, height: size)
    }
}
