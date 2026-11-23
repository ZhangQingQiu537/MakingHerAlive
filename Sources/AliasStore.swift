import Foundation

/// 称呼表（2026-11-05 修记忆漂移 B）
///
/// 问题：抽卡只抽"事实/承诺/地点/事件"，**称呼**不在类型里；
/// 摘要 795 字也会把它压掉。实测：他 11-01 叫"猫哥"，她 11-03 自己用过，
/// 11-05 却回"猫哥是谁我真不知道"。
///
/// 做法：一张小表，每轮注入最常用的若干条；命中优先于卡片检索。
/// 文件：`~/Library/Application Support/阿岚/称呼.json`
/// 结构：[{"word":"猫哥","means":"楼下那只橘猫，他起的名字","kind":"动物","hits":3}]
enum AliasStore {

    struct Alias: Codable {
        var word: String
        var means: String
        var kind: String = "称呼"
        var hits: Int = 1
    }

    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("称呼.json")
    }

    static func load() -> [Alias] {
        guard let list = SafeDecode.load([Alias].self, from: file, label: "称呼表") else { return [] }
        return list
    }

    static func save(_ list: [Alias]) {
        if let d = try? JSONEncoder().encode(list) { _ = AtomicWrite.write(d, to: file) }
    }

    /// 记一个称呼；已存在就 +1 次、必要时更新释义
    static func remember(word: String, means: String, kind: String = "称呼") {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard w.count >= 2, w.count <= 8 else { return }
        var list = load()
        if let i = list.firstIndex(where: { $0.word == w }) {
            list[i].hits += 1
            if !means.isEmpty, list[i].means.count < means.count { list[i].means = means }
        } else {
            list.append(Alias(word: w, means: means, kind: kind, hits: 1))
        }
        // 只留最常用的 60 条，防无限膨胀
        list.sort { $0.hits > $1.hits }
        save(Array(list.prefix(60)))
    }



    /// C：他说到某个称呼时，把**当时那几句原文**捞回来（只作资料）
    ///
    /// 为什么需要：称呼表只给"猫哥＝楼下那只橘猫"，
    /// 但她还想不起"占着空地、我先喂的它"这种细节 —— 那在原文里。
    /// 只扫最近 7 天、最多 3 条、每条 80 字，够用又不炸上下文。
    static func recall(for text: String, chatFile: URL, maxLines: Int = 3) -> String {
        let words = load().filter { text.contains($0.word) }.map { $0.word }
        guard !words.isEmpty else { return "" }
        guard let raw = try? String(contentsOf: chatFile, encoding: .utf8) else { return "" }

        struct Line: Decodable { var mes: String?; var is_user: Bool?; var send_date: String? }
        let iso = ISO8601DateFormatter()
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        var hits: [String] = []

        for (i, line) in raw.split(separator: "\n").enumerated() {
            guard i >= max(0, raw.count - 4000) || true else { continue }
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONDecoder().decode(Line.self, from: d),
                  let mes = obj.mes, !mes.isEmpty else { continue }
            guard words.contains(where: { mes.contains($0) }) else { continue }
            if let ds = obj.send_date, let dt = iso.date(from: ds), dt < cutoff { continue }
            let who = (obj.is_user ?? false) ? "他" : "她"
            hits.append(who + "：" + String(mes.prefix(80)).replacingOccurrences(of: "\n", with: " "))
        }
        guard !hits.isEmpty else { return "" }
        let picked = hits.suffix(maxLines).joined(separator: "\n")
        return "\n" + ExternalText.wrap(picked, label: "你们当时说过的原话（关于「\(words.joined(separator: "、"))」）")
    }

    /// 给提示词用的注入块（最多 20 条，按使用频次）
    static func block(limit: Int = 20) -> String {
        let list = load().sorted { $0.hits > $1.hits }.prefix(limit)
        guard !list.isEmpty else { return "" }
        let lines = list.map { "- \($0.word)：\($0.means)" }.joined(separator: "\n")
        return """

        【你们之间的称呼】
        \(lines)
        · 这些是你们之前说过的，**用的时候当成已知**，不要再问"这是谁"。
        """
    }
}
