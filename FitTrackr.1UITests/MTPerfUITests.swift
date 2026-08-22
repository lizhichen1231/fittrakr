// 【新 UI·掉帧排查】三场景性能测量(真机 Release 跑)。
// XCTHitchMetric = Instruments Core Animation hitch 的测试化(ms of hitch per s,0=满帧)。
// 场景:① 素材库堆叠甩动 ② 网格滚动→底栏收拢 ③ 进入相机转场。
// 手势用归一化坐标(无障碍 id 未布线,新 UI 预览期)。

import XCTest

@available(iOS 26.0, *)
final class MTPerfUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchNewUI() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MT_NEW_UI"] = "1"
        app.launch()
        sleep(3)   // 主题图/卡图网络加载 + 首帧稳定
        return app
    }

    private func pt(_ app: XCUIApplication, _ x: Double, _ y: Double) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    // ① 堆叠甩动:横向快甩 4 次(往复)
    func testDeckFling() throws {
        let app = launchNewUI()
        let opts = XCTMeasureOptions(); opts.iterationCount = 3
        measure(metrics: [XCTHitchMetric(application: app)], options: opts) {
            for _ in 0..<2 {
                pt(app, 0.7, 0.5).press(forDuration: 0.04, thenDragTo: pt(app, 0.15, 0.5),
                                        withVelocity: 2200, thenHoldForDuration: 0.05)
                usleep(700_000)
                pt(app, 0.3, 0.5).press(forDuration: 0.04, thenDragTo: pt(app, 0.85, 0.5),
                                        withVelocity: 2200, thenHoldForDuration: 0.05)
                usleep(700_000)
            }
        }
    }

    // ② 网格滚动 → 底栏收拢(k 随 scrollY 连续变化)
    func testGridScrollBarCollapse() throws {
        let app = launchNewUI()
        // 先进网格
        pt(app, 0.5, 0.7).press(forDuration: 0.04, thenDragTo: pt(app, 0.5, 0.25),
                                withVelocity: 1800, thenHoldForDuration: 0.05)
        sleep(1)
        let opts = XCTMeasureOptions(); opts.iterationCount = 3
        measure(metrics: [XCTHitchMetric(application: app)], options: opts) {
            for _ in 0..<2 {
                pt(app, 0.5, 0.62).press(forDuration: 0.04, thenDragTo: pt(app, 0.5, 0.34),
                                         withVelocity: 1400, thenHoldForDuration: 0.05)
                usleep(500_000)
                pt(app, 0.5, 0.34).press(forDuration: 0.04, thenDragTo: pt(app, 0.5, 0.62),
                                         withVelocity: 1400, thenHoldForDuration: 0.05)
                usleep(500_000)
            }
        }
    }

    // ③ 进入相机转场(快门 → 返回,往复)
    func testCaptureTransition() throws {
        let app = launchNewUI()
        let opts = XCTMeasureOptions(); opts.iterationCount = 3
        measure(metrics: [XCTHitchMetric(application: app)], options: opts) {
            pt(app, 0.5, 0.916).tap()      // 快门(bottom 80pt)
            usleep(900_000)
            pt(app, 0.118, 0.906).tap()    // 返回 chevron
            usleep(900_000)
        }
    }

    // xctrace attach 用:非测量,循环三场景 30s 供 Time Profiler 抓栈
    func testProfileLoop() throws {
        let app = launchNewUI()
        for _ in 0..<3 {
            pt(app, 0.7, 0.5).press(forDuration: 0.04, thenDragTo: pt(app, 0.15, 0.5),
                                    withVelocity: 2200, thenHoldForDuration: 0.05)
            usleep(600_000)
            pt(app, 0.5, 0.7).press(forDuration: 0.04, thenDragTo: pt(app, 0.5, 0.25),
                                    withVelocity: 1800, thenHoldForDuration: 0.05)
            usleep(400_000)
            pt(app, 0.5, 0.5).press(forDuration: 0.04, thenDragTo: pt(app, 0.5, 0.75),
                                    withVelocity: 1400, thenHoldForDuration: 0.05)
            usleep(400_000)
            // 回堆叠
            pt(app, 0.5, 0.4).press(forDuration: 0.04, thenDragTo: pt(app, 0.5, 0.8),
                                    withVelocity: 1800, thenHoldForDuration: 0.05)
            usleep(400_000)
            pt(app, 0.5, 0.916).tap()
            usleep(800_000)
            pt(app, 0.118, 0.906).tap()
            usleep(800_000)
        }
    }
}
