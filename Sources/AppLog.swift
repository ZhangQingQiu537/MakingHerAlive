import Foundation

/// 运行日志
///
/// 写在 `~/Library/Application Support/阿岚/运行日志.txt`，
/// 控制台里能看到每轮的耗时、附加调用、错误——方便排查"为什么这么慢"。
///
/// ⚠️ 2026-09-24 改用 LogRotation（Batch B P2-3）：超 1MB 自动归档为 `运行日志.txt.1`，
/// 旧策略是超 500 行就丢最早的——会丢关键时刻的报错；现在按字节轮转更可靠。
enum AppLog {

    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("运行日志.txt")
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    static func add(_ msg: String) {
        let line = "[\(fmt.string(from: Date()))] \(msg)\n"
        LogRotation.append(line, to: file)
    }

    /// 耗时格式化：3.42s
    static func secs(_ from: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(from))
    }
}
