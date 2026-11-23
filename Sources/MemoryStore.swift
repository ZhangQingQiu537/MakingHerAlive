import Foundation

/// 长期记忆（摘要）
///
/// 存在 `~/Library/Application Support/阿岚/记忆.json`。
/// 目的：聊天越攒越长时，把较早的对话压成一段摘要，
/// 这样既不会撑爆上下文，她也不会"忘了前几天说过什么"。
struct MemoryStore: Codable {

    /// 摘要正文
    var summary: String = ""
    /// 已经摘要到第几条（数组下标，之前的都不再进 prompt）
    var summarizedUpTo: Int = 0

    /// 未摘要的消息数达到这个数就触发一次压缩
    static let triggerAt = 30
    /// 无论如何都完整保留最近这么多条
    static let recentKeep = 20

    var isEmpty: Bool { summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: - 读写

    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("记忆.json")
    }

    static func load() -> MemoryStore {
        guard let m = SafeDecode.load(MemoryStore.self, from: MemoryStore.file, label: "摘要") else { return MemoryStore() }
        var fixed = m
        // ⚠️ 2026-10-28 修 M-10：负数下标会让 `history[start..<cut]` 直接崩（数组越界）。
        //    调用方只做了 min(count)，没挡负数 —— 手改/损坏的 JSON 就能让 App 一说话就闪退。
        if fixed.summarizedUpTo < 0 { fixed.summarizedUpTo = 0 }
        return fixed
    }

    func save() {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(self) else { return }
        // 2026-09-24 改用 AtomicWrite（Bug 12）：摘要一旦损坏就回不来，
        // 写半路进程被杀 → 文件残缺 → 下次 load 失败 → 摘要全清零。
        if !AtomicWrite.write(data, to: MemoryStore.file) {
            AppLog.add("❌ 摘要写盘失败：\(MemoryStore.file.path)")
        }
    }
}
