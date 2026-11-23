import Foundation
import CryptoKit

/// 火山 TTS 音频缓存（Batch B T1，2026-09-24 上线）
///
/// 同一段台词 + 同一音色 + 同一资源 合成过的 mp3 **不再二次请求火山**——
/// 火山配额贵、延迟明显（即便走 Python 桥也要 1.1s），缓存命中直接走本地，~10ms 出音频。
///
/// **缓存键不含 API Key**：换 Key 后旧缓存自然作废（hash 变了），但实际命中时 hash 不变 → 仍可用。
/// 这是**有意设计**：换 Key 不应让缓存全失效；调用方应当验证 Key 没失效后再信任旧 mp3。
///
/// LRU 上限 200 个（超了删最老的）；不在这里做磁盘限额——磁盘够大，真占满了再加。
enum VoiceCache {

    /// 缓存目录
    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("voice", isDirectory: true)
    }

    /// 上限（命中后超出则删最老的）
    static let cap = 200

    /// sha256(text + speaker + resource + format) → "<hash>.<ext>"
    /// ⭐ 2026-09-24 加 format 进 key：mp3 和 pcm 字节不通用，不能互相冒充。
    /// 老缓存（key 不含 format）会自动 miss，自然淘汰。
    static func key(_ text: String, speaker: String, resource: String, format: String) -> String {
        let raw = "\(text)\u{1F}\(speaker)\u{1F}\(resource)\u{1F}\(format)"
        let h = SHA256.hash(data: Data(raw.utf8))
        let ext = format == "pcm" ? "pcm" : "mp3"
        return h.map { String(format: "%02x", $0) }.joined() + "." + ext
    }

    static func url(for fileName: String) -> URL {
        dir.appendingPathComponent(fileName)
    }

    /// 命中则返回 Data；没命中返回 nil（不写盘——写盘由 put 决定）
    static func get(_ text: String, speaker: String, resource: String, format: String) -> Data? {
        let fn = key(text, speaker: speaker, resource: resource, format: format)
        let u = url(for: fn)
        guard let d = try? Data(contentsOf: u) else { return nil }
        // 命中：更新 mtime（LRU 标记）
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
        return d
    }

    /// 写入缓存；自动 LRU 截断
    @discardableResult
    static func put(_ data: Data, _ text: String, speaker: String, resource: String, format: String) -> Bool {
        let fn = key(text, speaker: speaker, resource: resource, format: format)
        let u = url(for: fn)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try data.write(to: u, options: .atomic)
        } catch {
            return false
        }
        enforceLRU()
        return true
    }

    /// 超 cap 时按 mtime 删最老的
    private static func enforceLRU() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard names.count > cap else { return }
        let infos: [(name: String, mtime: Date)] = names.compactMap { n in
            let p = dir.appendingPathComponent(n)
            guard let a = try? FileManager.default.attributesOfItem(atPath: p.path),
                  let m = a[.modificationDate] as? Date else { return nil }
            return (n, m)
        }
        // 按 mtime 升序（最老的在前）
        let sorted = infos.sorted { $0.mtime < $1.mtime }
        let toDelete = sorted.prefix(sorted.count - cap)
        for it in toDelete {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(it.name))
        }
    }

    /// 清空缓存（控制台"清缓存"按钮可调）
    static func clear() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 当前缓存文件数（调试/控制台显示用）
    static var count: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).count
    }

    /// 缓存总大小（字节）
    static var sizeBytes: Int64 {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.reduce(0) { acc, n in
            let p = dir.appendingPathComponent(n)
            let s = (try? FileManager.default.attributesOfItem(atPath: p.path)[.size] as? Int64) ?? 0
            return acc + s
        }
    }
}