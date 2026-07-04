import Foundation

/// FPS 修复卡 ②b:每帧级调试日志的统一 verbosity 闸。
///
/// 问题:锁定热路径每帧 6–9 条 print 直灌 stdout,连 LLDB 时单条 ms 级 → 拖慢帧线程;
/// 且 PROBE 原来是无条件 print,Release 也每帧打。
/// 方案:把这些「每帧 spam」收编到一个闸后面,**默认静默**(live 高帧率不被 print I/O 拖)。
///  - 回放期(ReplayLogger 用 dup2 接管 stdout 并解析 PROBE/REJECT/STATE/SHADOW… 计数)→ 自动放行,
///    保证 SUMMARY 不断;
///  - 手动开 `verbose` → 放行(现场深挖用);
///  - Release:整体 no-op(连字符串都不构造),顺带把 Release 的每帧 PROBE 也省掉。
///
/// 关键:参数用 `@autoclosure` → 闸关/Release 时**连字符串都不构造**(String(format:)/插值成本一并省)。
///
/// 只收编「每帧必打」的诊断行;事件级日志(STATE 迁移、REACQ-FAIL、GATE-MISS、SHADOW-FALLBACK、
/// OUTLIER 等,低频、多为排障关键)保持裸 print 常打。
enum DebugLog {
    #if DEBUG
    /// 手动总闸,默认关。live 静默 = 快;要现场看每帧细节时置 true。
    static var verbose = false
    #endif

    /// 每帧级 spam 日志:仅在 verbose 或回放期才真打(且此时才构造字符串)。Release 为 no-op。
    @inline(__always)
    static func frame(_ message: @autoclosure () -> String) {
        #if DEBUG
        if verbose || ReplayLogger.shared.active {
            print(message())
        }
        #endif
    }
}
