#if DEBUG
// 【掉帧卡·附带】本文件依赖 DEBUG-only 埋点(dbg*/assocTrace),Release test 构建整体剔除
import XCTest
import AVFoundation
@testable import FitTrackr_1

/// 【方案A·步四】纯关联跟踪基线:压住自动锁(零身份介入),整片走未锁定路径
/// (detectHumanRectCandidate 最近邻 + applyKalmanSmoothing IoU 门控),
/// 逐帧 trace(box/IoU/blend/conf/候选数)写 Documents/AssocTrace/<clip>.csv,
/// Mac 端 devicectl 拉回,对 DanceTrack GT(居中裁+fps30 映射)离线判 ID switch。
/// 片选:clip_3(0005,4人明暗混搭≈异色端)+ clip_2(0004,4人全白撞衫=最难端);
/// 关联算法色盲(中心距+IoU,不进衣色),衣色只影响对账不影响被测行为。
final class AssocBaselineTests: XCTestCase {

    private func clipURL(_ name: String) -> URL? {
        let b = Bundle(for: CameraViewModel.self)
        return b.url(forResource: name, withExtension: "mp4")
            ?? b.url(forResource: name, withExtension: "mp4", subdirectory: "DebugReplayClips")
    }

    private func runAssocTrace(_ name: String, seconds: TimeInterval) throws {
        guard clipURL(name) != nil, let url = clipURL(name) else {
            throw XCTSkip("\(name) 不在测试宿主 bundle")
        }
        PersonIdentifier.autoLockSuppressed = true
        PersonIdentifier.shared.unlock()
        TrackingController.assocTrace.removeAll()
        TrackingController.assocTraceEnabled = true
        defer { TrackingController.assocTraceEnabled = false }

        let vm = CameraViewModel(source: VideoFileSource(url: url, realtime: false, loop: false))
        vm.updateOutputSize(for: CGSize(width: 390, height: 844))
        vm.start()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        vm.stop()

        let rows = TrackingController.assocTrace
        var csv = "f,minX,minY,w,h,iou,blend,conf,cands\n"
        for r in rows {
            csv += String(format: "%d,%.1f,%.1f,%.1f,%.1f,%.4f,%.4f,%.3f,%d\n",
                          r.f, r.box.minX, r.box.minY, r.box.width, r.box.height,
                          r.iou, r.blend, r.conf, r.cands)
        }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AssocTrace", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("\(name).csv")
        try csv.data(using: .utf8)!.write(to: out)

        // 现场速报:低IoU 事件(≤0.05 = 软混合被触发,ID switch 的候选时刻)+ 断链(帧号跳变>1 = 无检测帧)
        let lowIoU = rows.filter { $0.iou >= 0 && $0.iou <= 0.05 }.count
        var gapEvents = 0, maxGap = 0
        for i in 1..<max(rows.count, 1) where rows[i].f - rows[i-1].f > 1 {
            gapEvents += 1; maxGap = max(maxGap, rows[i].f - rows[i-1].f - 1)
        }
        print("═══ ASSOC-BASELINE \(name) ═══ 帧=\(rows.count) 低IoU(≤0.05)=\(lowIoU) 断链段=\(gapEvents)(最长\(maxGap)帧) → \(out.path)")
        XCTAssertGreaterThan(rows.count, 100, "trace 近乎空:关联链没跑起来(检查压锁/片源)")
        XCTAssertFalse(PersonIdentifier.shared.isLocked, "基线期间不允许发生锁定")
    }

    func testAssocBaseline_clip3_0005() throws {
        try runAssocTrace("clip_3_sameshirt_dancetrack0005", seconds: 75)
    }

    func testAssocBaseline_clip2_0004() throws {
        try runAssocTrace("clip_2_sameshirt_dancetrack0004", seconds: 75)
    }
}

#endif
