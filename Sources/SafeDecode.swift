import Foundation

/// 读 JSON 的统一入口：**解码失败不再静默回空**
///
/// 背景（2026-11-05 独立测试 P3）：全项目没有 SafeDecode，卡片/记忆/情绪的 load
/// 都是 `try?` + 默认值 —— 文件一坏就当成"空数据"，下一次 save 把损坏前的数据冲掉。
/// 2026-10-02 那次数据全丢就是这个模式。
///
/// 现在的行为：
/// 1. 解码失败 → 写日志（带文件名与错误）
/// 2. 把原文件复制到 `数据快照/损坏-<label>-<时间>.json`
/// 3. 才返回 nil（调用方回默认值，但损坏件已经留住了）
enum SafeDecode {

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Companion", isDirectory: true)
    }

    static var snapshotDir: URL {
        supportDir.appendingPathComponent("数据快照", isDirectory: true)
    }

    /// 解一份 JSON；失败时留证据再返回 nil
    static func load<T: Decodable>(_ type: T.Type, from url: URL, label: String) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            AppLog.add("⚠️ \(label) 解码失败：\(error.localizedDescription)")
            quarantine(data, label: label)
            return nil
        }
    }

    /// 把损坏的原文件另存一份，绝不覆盖
    static func quarantine(_ data: Data, label: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "损坏-\(label)-\(f.string(from: Date())).json"
        do {
            try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
            try data.write(to: snapshotDir.appendingPathComponent(name), options: .atomic)
            AppLog.add("🗂 损坏文件已留档：数据快照/\(name)")
        } catch {
            AppLog.add("⚠️ 损坏文件留档失败：\(error.localizedDescription)")
        }
    }
}
