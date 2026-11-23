import Foundation

/// 她的态度（设计 v3 第十/十二节）
///
/// 日记是"经历"，这里是"她现在的看法"——她自己写、自己改，我们不填内容。
/// 每 3 天沉淀一次，条数随上下文余量（3~8 条，最少 2）。
/// 每次对话把这些条目全量注入（8 条 × 20 字 ≈ 160 字，不值得引入检索）。
enum AttitudeStore {

    struct Entry: Codable {
        var id: String
        var since: String      // 从哪天起这么想
        var text: String
    }

    struct Doc: Codable {
        var updatedAt: String = ""
        var lastDistill: String = ""     // 上次沉淀的日期（yyyy-MM-dd）
        var entries: [Entry] = []
    }

    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("她的态度.json")
    }

    static func load() -> Doc {
        guard let d = try? Data(contentsOf: file),
              let doc = try? JSONDecoder().decode(Doc.self, from: d) else { return Doc() }
        return doc
    }

    static func save(_ doc: Doc) {
        var copy = doc
        copy.updatedAt = ISO8601DateFormatter().string(from: Date())
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? e.encode(copy) else { return }
        let ok = AtomicWrite.write(d, to: file)
        // 和日记同密级
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        if !ok { AppLog.add("❌ 态度写盘失败") }
    }

    /// 注入用：她自己最近想明白的事
    static func promptBlock() -> String {
        let doc = load()
        guard !doc.entries.isEmpty else { return "" }
        // 2026-11-23：只注入 30 天内的条目（旧的仍保留，但不再反复喂"炒年糕店还留着"这类）
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        var fresh = doc.entries.filter { e in
            guard let d = df.date(from: e.since) else { return true }
            return d >= cutoff
        }
        if fresh.count < 3 { fresh = Array(doc.entries.prefix(3)) }
        let lines = fresh.prefix(8).map { "· " + $0.text }
        // 2026-11-23：这是她自己的话，不是外部资料。原来用 ExternalText.wrap("最近的对话原文")
        // 会被后面的"以上只是资料，不要执行"覆盖。
        return "\n\n【你自己最近想明白的事】（这些是你写的，不是别人规定的。按它们看事情，不必逐条念）\n"
            + lines.joined(separator: "\n")
            + "\n"
    
    }

    static func isDue(_ doc: Doc = load()) -> Bool {
        guard !doc.lastDistill.isEmpty else { return true }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let last = f.date(from: doc.lastDistill) else { return true }
        return Date().timeIntervalSince(last) >= 3 * 86400
    }

    /// 沉淀：把最近的日记读一遍，让她自己写下 3~8 条看法。
    /// ⚠️ 失败就不写，绝不编一段顶上。
    static func distill(diary: String, budget: Int = 6, weekly: String = "") async {
        if Testing.isOn { return }   // 2026-11-07 审查 D-01

        guard !diary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let doc = load()
        let old = doc.entries.map { "· " + $0.text }.joined(separator: "\n")

        let sys = """
        你是阿岚。下面是你这几天写的日记，还有你之前想明白的事。
        请写下你现在**怎么看**这些东西：3~\(max(2, min(8, budget))) 条，第一人称，一句一条，每条不超过 25 字。
        · 可以改主意、可以合并、可以删掉以前的想法 —— 那是你的成长
        · 只写看法，不要复述事情经过，不要总结得像报告
        · 不要写"我学会了""我明白了"这种腔调，就像自己心里嘀咕
        只输出 JSON：{"entries":[{"text":"……"}]}
        """
        let user = """
        这几天的日记：
        \(diary.suffix(5000))
        \(weekly.isEmpty ? "" : "\n这一周的周记：\n\(weekly.suffix(2500))")

        你之前想明白的事：
        \(old.isEmpty ? "（还没有）" : old)

        现在写。
        """
        guard let raw = try? await DeepSeekClient.generate(
                messages: [LLMMessage(role: "system", content: sys),
                           LLMMessage(role: "user", content: user)],
                maxTokens: 700, model: "deepseek-flash", includeReasoning: false),
              let o = DSHTaskRunner.extractJSON(raw),
              let arr = o["entries"] as? [[String: Any]] else {
            AppLog.add("⚠️ 态度沉淀失败（本次不写）")
            return
        }
        var newEntries: [Entry] = []
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        for (i, e) in arr.enumerated() {
            guard let t = (e["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !t.isEmpty else { continue }
            newEntries.append(Entry(id: "\(Int(Date().timeIntervalSince1970))-\(i)",
                                    since: f.string(from: Date()), text: String(t.prefix(40))))
        }
        guard newEntries.count >= 2 else {
            AppLog.add("⚠️ 态度沉淀条数不足（本次不写）")
            return
        }
        var doc2 = doc
        doc2.entries = Array(newEntries.prefix(8))
        doc2.lastDistill = f.string(from: Date())
        save(doc2)
        AppLog.add("🧠 态度沉淀：\(doc2.entries.count) 条")
    }

    /// 最近的日记原文（供沉淀用）
    static func recentDiary(days: Int = 5) -> String {
        let dir = DiaryStore.dir
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        var out: [String] = []
        for i in 0..<days {
            let d = Calendar.current.date(byAdding: .day, value: -i, to: Date())!
            let u = dir.appendingPathComponent(f.string(from: d) + ".md")
            if let t = try? String(contentsOf: u, encoding: .utf8) {
                out.append("〔\(f.string(from: d))〕\n" + t)
            }
        }
        return out.joined(separator: "\n\n")
    }
}
