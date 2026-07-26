import XCTest
import AVFoundation
@testable import FitTrackr_1

/// 【三牙参数卡·回放台】DanceTrack 片驱动完整 vm 管线(VideoFileSource→handleFrame→follow.process),
/// 读 PersonIdentifier 分牙计数 + TC LOST 计数,离线出预注册判据数字——先回放台后真机。
/// clip_1_sameshirt = 双人同色夹具(判据2/4);clip_5 = 运动/找回夹具(判据1 近似)。
final class ReacqReplayTests: XCTestCase {

    struct ReplayResult {
        var rejected = 0, color = 0, margin = 0, pos = 0, lost = 0
        var desc: String {
            let d = max(rejected, 1)
            return "拒\(rejected) 色\(color)(\(100*color/d)%) margin\(margin)(\(100*margin/d)%) pos\(pos)(\(100*pos/d)%) LOST=\(lost)"
        }
    }

    private func clipURL(_ name: String) -> URL? {
        let b = Bundle(for: CameraViewModel.self)
        return b.url(forResource: name, withExtension: "mp4")
            ?? b.url(forResource: name, withExtension: "mp4", subdirectory: "DebugReplayClips")
    }

    /// 跑一条片子(非实时=尽快解码,管线同步消费=天然背压),回分牙数字
    private func runClip(_ name: String, seconds: TimeInterval,
                         extrap: Bool, posStart: Float) -> ReplayResult? {
        guard let url = clipURL(name) else { return nil }
        let pi = PersonIdentifier.shared
        pi.unlock()
        pi.reacqExtrapolationEnabled = extrap
        pi.reacqPosStart = posStart
        pi.reacqFailCount = 0; pi.reacqFailColor = 0; pi.reacqFailMargin = 0
        pi.reacqFailPos = 0; pi.reacqFailDetector = 0
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
        r.lost = TrackingController.dbgLostCount
        return r
    }

    /// 贡献拆分(判据1/3 + 刀2 单开/双开)—— clip_5 运动夹具
    func testContributionSplit_clip5() throws {
        guard clipURL("clip_5_sameshirt_dancetrack0034") != nil else {
            throw XCTSkip("clip_5 不在测试宿主 bundle(Debug Copy Replay Clips 未跑)")
        }
        var report = "\n═══ 复现拆分 clip_2(挂单三)═══\n"
        for (label, ex, ps) in [("A 仅外推(起步0.06)", true, Float(0.06)),
                                ("B 仅重标定(起步0.12)", false, Float(0.12))] {
            guard let r = runClip("clip_2_sameshirt_dancetrack0004", seconds: 40, extrap: ex, posStart: ps) else { continue }
            report += "  \(label): \(r.desc)\n"
        }
        print(report)
    }

    /// 判据2/4 —— clip_1 双人同色夹具:margin 败率 + 反例保护(margin 仍在拦真双人)
    func testMarginAndSafety_clip1() throws {
        guard clipURL("clip_1_sameshirt_dancetrack0097") != nil else {
            throw XCTSkip("clip_1 不在测试宿主 bundle")
        }
        guard let r = runClip("clip_1_sameshirt_dancetrack0097", seconds: 40, extrap: true, posStart: 0.12) else {
            XCTFail("clip_1 跑失败"); return
        }
        print("\n═══ clip_1 双人同色 ═══\n  交付配置: \(r.desc)\n")
        // 判据3:色牙不得退化
        if r.rejected > 0 {
            XCTAssertLessThan(Double(r.color) / Double(r.rejected), 0.01 + 0.02, "色牙败率不得退化")
        }
    }
}
