import Foundation
import QuartzCore

#if DEBUG
/// FPS 修复卡 ②a:实况性能日志的**异步串行文件 sink** + **脱机采集通道**。
///
/// 目的:脱离 Xcode(不连调试器)独立启动跑,把 perfHUD 的 `⏱` 性能行(FPS/rect/tot)
/// 落到 `Documents/PerfLogs/live_<时间戳>.log` —— 配合 Info.plist 的
/// UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace,Files app 直接取,
/// 供**凉机脱机**的 FPS 归因(分刀贡献表)。
///
/// 设计要点:
///  - 写操作全部派到**串行队列**(async),不阻塞相机/跟踪帧线程(这是 perf 正确性要求,
///    也是 ②a 相对"直接 print"的收益之一:断开帧线程与日志 I/O 的耦合)。
///  - 只提供一个 sink `line(_:)`;②b 收编每帧 print 时**复用同一 sink**,本刀先只接性能行。
///  - 与 `ReplayLogger` 无冲突:ReplayLogger 用 `dup2` 重定向 stdout(仅回放期);
///    本类写自己的独立文件、从不碰 stdout。回放时两者各写各的文件,互不干扰。
final class PerfFileLog {
    static let shared = PerfFileLog()
    private init() {}

    private let queue = DispatchQueue(label: "com.fittrackr.perflog", qos: .utility)
    private var handle: FileHandle?
    private var opened = false
    private var pendingTag = ""

    /// HUD 可读:当前日志文件路径(脱机时也能在屏幕上看到落到哪)。
    private(set) static var currentPath = ""

    /// 追加一行(异步、串行保序、不阻塞调用线程)。首次调用惰性建文件。
    func line(_ s: String) {
        let stamp = CACurrentMediaTime()
        queue.async { [weak self] in
            guard let self = self else { return }
            if !self.opened { self.openOnQueue() }
            guard let h = self.handle else { return }
            let row = String(format: "%.3f %@\n", stamp, s)
            if let d = row.data(using: .utf8) { h.write(d) }
        }
    }

    /// 手动滚动一个新文件。每次凉机脱机测量前调一次(带刀号 tag),分刀日志各自独立、便于归因。
    func startNewSession(tag: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            try? self.handle?.close()
            self.handle = nil
            self.opened = false
            self.pendingTag = tag
            self.openOnQueue()
        }
    }

    // 仅在串行队列上调用:建目录 + 建文件 + 打开句柄。
    private func openOnQueue() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PerfLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let name = pendingTag.isEmpty ? "live_\(stamp).log" : "live_\(pendingTag)_\(stamp).log"
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        handle?.write("════ PERF LOG \(name) ════\n".data(using: .utf8)!)
        PerfFileLog.currentPath = url.path
        opened = true
        print("📄 PerfLog → \(url.path)")   // 连 Xcode 时可见;脱机时靠 Files app 取
    }
}
#endif
