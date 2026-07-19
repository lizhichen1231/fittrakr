import AVFoundation
import UIKit

#if DEBUG
/// 【镜头切换查勘 #2 · Q2 探针】—— 纯读,只查不改,用完即撤(分支 probe/lens-recon)。
/// 读 .builtInDualWideCamera 的:构成子镜头 / virtualDeviceSwitchOverVideoZoomFactors(切换点 S)/
/// zoom 范围 / ≈1080p60 format / GDC 语义(超广角段是否校正)。
/// ⚠️ 不建 session、不切逻辑;只 new 一个 device 对象读属性再丢。输出进 console + PerfFileLog(脱机可取)。
enum LensReconProbe {
    static func dumpDualWide() {
        var L: [String] = ["════ LENS-RECON #2 · Q2(dualWide 切换点)════"]

        var s = utsname(); uname(&s)
        let machine = withUnsafeBytes(of: &s.machine) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
        L.append("device=\(machine) iOS=\(UIDevice.current.systemVersion) MultiCamSupported=\(AVCaptureMultiCamSession.isMultiCamSupported)")

        guard let dw = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) else {
            L.append("dualWide=❌ 不可用 → 设计降级路径生效(纯超广角数字裁剪=现状),整套切换旁路。")
            flush(L); return
        }
        L.append("dualWide=✅ \(dw.localizedName)")

        // 构成子镜头(应为 超广角 + 主摄)+ 各自 zoom 基准
        let parts = dw.constituentDevices
        L.append("构成子镜头=\(parts.map { $0.deviceType.rawValue })")
        for p in parts {
            L.append(String(format: "  · %@  zoom[%.2f…%.2f]  GDC支持=%@",
                            p.deviceType.rawValue, p.minAvailableVideoZoomFactor, p.maxAvailableVideoZoomFactor,
                            p.isGeometricDistortionCorrectionSupported ? "Y" : "N"))
        }

        // ★核心:切换点 S(dualWide 的 ultrawide→wide 交叉;注意不是 triple 的 tele 8x)
        if let f = dw.virtualDeviceSwitchOverVideoZoomFactors as? [NSNumber], !f.isEmpty {
            L.append("★switchOverZoomFactors(S)=\(f.map { $0.doubleValue })  ← 参数表换算基准")
        } else {
            L.append("★switchOverZoomFactors=(none!)")
        }
        L.append(String(format: "dualWide 整体 zoom[%.2f…%.2f]  当前 videoZoomFactor=%.3f",
                        dw.minAvailableVideoZoomFactor, dw.maxAvailableVideoZoomFactor, dw.videoZoomFactor))

        // GDC 语义:dualWide 整体是否支持/开着 GDC(超广角段畸变校正)
        L.append("dualWide GDC 支持=\(dw.isGeometricDistortionCorrectionSupported) 当前开=\(dw.isGeometricDistortionCorrectionSupported ? dw.isGeometricDistortionCorrectionEnabled : false)")

        // ≈1080p60 format(注意 multiCam-only 标记,Q3 双流用)
        if let best = dw.formats.filter({ $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 59 } })
            .min(by: { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return abs(Int(da.width)*Int(da.height) - 1920*1080) < abs(Int(db.width)*Int(db.height) - 1920*1080)
            }) {
            let d = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
            let fps = best.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            L.append("≈1080p60 format=\(d.width)x\(d.height)@\(Int(fps)) multiCam支持=\(best.isMultiCamSupported ? "Y" : "N")")
        }
        flush(L)
    }

    private static func flush(_ L: [String]) {
        let text = L.joined(separator: "\n")
        print(text)
        PerfFileLog.shared.line(text)
    }
}
#endif
