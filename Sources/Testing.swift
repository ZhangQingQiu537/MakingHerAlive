import Foundation

/// 测试模式（2026-11-07 · 审查 D-01 修）
///
/// 为什么要有它：压测她的回答时，不想让这段对话污染记忆。
/// 之前只挡住"抽卡 / 日记 / 摘要"三处，**还有十几条写入路径在跑**：
/// 作品卡、态度沉淀、联网知识卡、开机补抽……关掉测试模式后还会把这些补抽一遍。
///
/// 现在统一成一处开关：**所有会落成长期记忆的写入，都先问这里**。
/// 文件：`~/Library/Application Support/阿岚/测试模式.json`（由控制台切）
enum Testing {

    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("测试模式.json")
    }

    /// 每 5 秒最多读一次盘（body 里不读，但写入端可能在主线程被频繁调用）
    private static var cached: (value: Bool, at: Date) = (false, .distantPast)
    private static let lock = NSLock()

    static var isOn: Bool {
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(cached.at) < 5 { return cached.value }
        var v = false
        if let d = try? Data(contentsOf: file),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            v = (o["on"] as? Bool) ?? false
        }
        cached = (v, Date())
        return v
    }
}
