#if DEBUG
// 【掉帧卡·附带】本文件依赖 DEBUG-only 埋点(dbg*/assocTrace),Release test 构建整体剔除
import XCTest
import AVFoundation
@testable import FitTrackr_1

/// 【三牙参数卡·回放台】DanceTrack 片驱动完整 vm 管线(VideoFileSource→handleFrame→follow.process),
/// 读 PersonIdentifier 分牙计数 + TC LOST 计数,离线出预注册判据数字——先回放台后真机。
/// clip_1_sameshirt = 双人同色夹具(判据2/4);clip_5 = 运动/找回夹具(判据1 近似)。
final class ReacqReplayTests: XCTestCase {

    struct ReplayResult {
        var rejected = 0, color = 0, margin = 0, pos = 0, lost = 0, dupMerged = 0
        var desc: String {
            let d = max(rejected, 1)
            return "拒\(rejected) 色\(color)(\(100*color/d)%) margin\(margin)(\(100*margin/d)%) pos\(pos)(\(100*pos/d)%) 同人去重=\(dupMerged) LOST=\(lost)"
        }
    }

    private func clipURL(_ name: String) -> URL? {
        let b = Bundle(for: CameraViewModel.self)
        return b.url(forResource: name, withExtension: "mp4")
            ?? b.url(forResource: name, withExtension: "mp4", subdirectory: "DebugReplayClips")
    }

    /// 跑一条片子(非实时=尽快解码,管线同步消费=天然背压),回分牙数字
    private func runClip(_ name: String, seconds: TimeInterval) -> ReplayResult? {
        guard let url = clipURL(name) else { return nil }
        let pi = PersonIdentifier.shared
        pi.unlock()
        pi.reacqFailCount = 0; pi.reacqFailColor = 0; pi.reacqFailMargin = 0
        pi.reacqFailPos = 0; pi.reacqFailDetector = 0; pi.reacqDupMerged = 0
        TrackingController.dbgLostCount = 0

        let vm = CameraViewModel(source: VideoFileSource(url: url, realtime: false, loop: false))
        vm.updateOutputSize(for: CGSize(width: 390, height: 844))
        vm.start()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        vm.stop()
        var r = ReplayResult()
        r.rejected = pi.reacqFailCount; r.color = pi.reacqFailColor
        r.margin = pi.reacqFailMargin; r.pos = pi.reacqFailPos
        r.dupMerged = pi.reacqDupMerged
        r.lost = TrackingController.dbgLostCount
        return r
    }

    /// 交付配置回归 —— clip_5 运动/找回夹具(判据1 近似 + 判据3)
    func testDeliveryConfig_clip5() throws {
        guard clipURL("clip_5_sameshirt_dancetrack0034") != nil else {
            throw XCTSkip("clip_5 不在测试宿主 bundle(Debug Copy Replay Clips 未跑)")
        }
        guard let r = runClip("clip_5_sameshirt_dancetrack0034", seconds: 40) else {
            XCTFail("clip_5 跑失败"); return
        }
        print("\n═══ clip_5 交付配置(A 仅外推·起步0.06)═══\n  \(r.desc)\n")
        // 交付配置基线:A 拆分轮 拒9/pos0/LOST0(单轮方差告警下的量级锚)
        XCTAssertEqual(r.lost, 0, "clip_5 交付配置不应出现 LOST")
    }

    /// 判据2/4 —— clip_1 双人同色夹具:margin 败率 + 反例保护(margin 仍在拦真双人)
    func testMarginAndSafety_clip1() throws {
        guard clipURL("clip_1_sameshirt_dancetrack0097") != nil else {
            throw XCTSkip("clip_1 不在测试宿主 bundle")
        }
        guard let r = runClip("clip_1_sameshirt_dancetrack0097", seconds: 40) else {
            XCTFail("clip_1 跑失败"); return
        }
        print("\n═══ clip_1 双人同色 ═══\n  交付配置: \(r.desc)\n")
        // 判据3:色牙不得退化
        if r.rejected > 0 {
            XCTAssertLessThan(Double(r.color) / Double(r.rejected), 0.01 + 0.02, "色牙败率不得退化")
        }
    }
}

#endif
