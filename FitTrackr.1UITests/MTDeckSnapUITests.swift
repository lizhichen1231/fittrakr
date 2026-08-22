// 【卡组物理·UIScrollView】三断言:快甩前进 ≥2 张且停整卡 / 慢拖 40 回弹原卡 / 拖半停 1s 吸附最近卡。
// 吸附位与 app 内 deckSnapX 同式:卡宽 = min(0.60×屏高×9/16, 屏宽−48),minX = (屏宽−卡宽)/2。

import XCTest

final class MTDeckSnapUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MT_NEW_UI"] = "1"
        app.launch()
        sleep(3)
        return app
    }
    private func expectedMinX(_ app: XCUIApplication) -> CGFloat {
        let f = app.frame
        let cardW = min(0.60 * f.height * 9.0 / 16.0, f.width - 48)
        return (f.width - cardW) / 2
    }
    private func topIndex(_ app: XCUIApplication) -> Int {
        let top = app.descendants(matching: .any)["deck.card.top"]
        XCTAssertTrue(top.waitForExistence(timeout: 3), "顶层卡不存在")
        return Int(top.label) ?? -1
    }
    private func assertSnapped(_ app: XCUIApplication, _ label: String) {
        let top = app.descendants(matching: .any)["deck.card.top"]
        XCTAssertTrue(top.waitForExistence(timeout: 3), "\(label) 顶层卡不存在")
        let minX = top.frame.minX
        let exp = expectedMinX(app)
        XCTAssertLessThanOrEqual(abs(minX - exp), 1.0, "\(label) 未吸附整卡:minX=\(minX) 期望=\(exp)")
    }
    private func drag(_ app: XCUIApplication, dx: CGFloat, velocity: XCUIGestureVelocity, hold: TimeInterval) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.45))
        let end = start.withOffset(CGVector(dx: dx, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: hold)
    }

    /// ① 快甩一次:惯性前进 ≥2 张,且最终停在整张卡
    func testFastFlingAdvancesTwoPlus() throws {
        let app = launch()
        let before = topIndex(app)
        drag(app, dx: -320, velocity: 5000, hold: 0)
        sleep(2)   // 等系统减速自然结束
        let after = topIndex(app)
        let n = 12
        let adv = ((after - before) % n + n) % n
        XCTAssertGreaterThanOrEqual(adv, 2, "快甩仅前进 \(adv) 张(\(before)→\(after))")
        assertSnapped(app, "快甩")
    }

    /// ② 慢拖 40pt 松手:回弹到原卡
    func testSlowDrag40Rebounds() throws {
        let app = launch()
        let before = topIndex(app)
        drag(app, dx: -40, velocity: 200, hold: 0.1)
        usleep(1_200_000)
        XCTAssertEqual(topIndex(app), before, "慢拖 40pt 应回弹原卡")
        assertSnapped(app, "慢拖40")
    }

    /// ③ 拖到一半停 1 秒松手:吸附最近卡
    func testDragHalfHoldSnapsNearest() throws {
        let app = launch()
        let before = topIndex(app)
        drag(app, dx: -200, velocity: 600, hold: 1.0)   // ≈0.66 page → 最近 = 下一张
        usleep(1_200_000)
        let after = topIndex(app)
        let n = 12
        let adv = ((after - before) % n + n) % n
        XCTAssertEqual(adv, 1, "拖半停 1s 应吸附最近(下一张),实际前进 \(adv)")
        assertSnapped(app, "拖停松")
    }
}
