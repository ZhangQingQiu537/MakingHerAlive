import Foundation

/// 周记（2026-11-08 · 借鉴白守的记忆金字塔）
///
/// 为什么要有它：现在只有"一天一页"。她能想起某天说了什么，
/// 但想不起"这一周我们是怎么过来的"——跨天的事（面试→等结果→出结果）串不成线。
///
/// 设计取舍（抄白守的三点，砍掉两级）：
///   · 只做"周"这一层，不做月/季/年 —— 一个人一年才五十二周，月报的信息增量很小
///   · 每周末尾写一句「胶囊」，将来要往上叠月报时直接吃它，不用重读 7 篇日记
///   · 周记不进日常 prompt（太长），只给态度沉淀和主动开口用
///
/// 文件：`~/Library/Application Support/阿岚/周记/2026-W45.md` + `索引.json`
enum WeeklyStore {

    struct Entry: Codable {
        var key: String        // 2026-W45
        var start: String      // 2026-11-02（周一）
        var end: String        // 2026-11-08（周日）
        var words: Int
        var madeAt: String
    }
    struct Index: Codable {
        var entries: [Entry] = []
    }

    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("阿岚/周记", isDirectory: true)
    }
    static func file(_ key: String) -> URL { dir.appendingPathComponent("\(key).md") }
    private static var indexURL: URL { dir.appendingPathComponent("索引.json") }

    // MARK: 索引

    static func loadIndex() -> Index {
        SafeDecode.load(Index.self, from: indexURL, label: "周记索引") ?? Index()
    }
    private static func saveIndex(_ i: Index) {
        if let d = try? JSONEncoder().encode(i) { _ = AtomicWrite.write(d, to: indexURL) }
    }
    static func written() -> Set<String> { Set(loadIndex().entries.map(\.key)) }

    // MARK: 周界

    static func weekKey(for date: Date) -> String {
        var cal = Calendar(identifier: .iso8601)
        cal.firstWeekday = 2
        let y = cal.component(.yearForWeekOfYear, from: date)
        let w = cal.component(.weekOfYear, from: date)
        return String(format: "%04d-W%02d", y, w)
    }

    static func bounds(of key: String) -> (start: Date, end: Date)? {
        let parts = key.split(separator: "-W")
        guard parts.count == 2, let y = Int(parts[0]), let w = Int(parts[1]) else { return nil }
        var cal = Calendar(identifier: .iso8601)
        cal.firstWeekday = 2
        var c = DateComponents()
        c.yearForWeekOfYear = y
        c.weekOfYear = w
        c.weekday = 2                      // 周一
        guard let start = cal.date(from: c) else { return nil }
        return (start, cal.date(byAdding: .day, value: 6, to: start) ?? start)
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 最近一个"已经过完、但还没写"的周（最多回看 8 周）
    static func pendingKey(now: Date = Date()) -> String? {
        let done = written()
        var cal = Calendar(identifier: .iso8601)
        cal.firstWeekday = 2
        // 本周还没过完 → 从上周开始找
        guard let thisWeekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))
        else { return nil }
        for back in 1...8 {
            guard let start = cal.date(byAdding: .weekOfYear, value: -back, to: thisWeekStart) else { continue }
            let key = weekKey(for: start)
            if !done.contains(key) { return key }
        }
        return nil
    }

    // MARK: 生成

    /// 生成一周的周记。返回字数；失败 nil；没有日记返回 0（不写空周）
    @discardableResult
    static func generate(key: String, diary: [String: String], moodLine: String) async -> Int? {
        if Testing.isOn { return nil }
        guard let b = bounds(of: key) else { return nil }

        // 收集这一周的日记（按日期）
        var days: [(String, String)] = []
        var d = b.start
        while d <= b.end {
            let ymd = dayFmt.string(from: d)
            if let text = diary[ymd], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                days.append((ymd, text))
            }
            d = Calendar.current.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400)
        }
        guard days.count >= 2 else { return 0 }   // 这周没怎么聊，不硬凑

        let body = days.map { "【\($0.0)】\n\($0.1)" }.joined(separator: "\n\n")
        // 2026-11-10：容量随天数走（W45 固定 3~6 条，把周日的事挤掉了）
        let itemRange = days.count >= 5 ? "5~9 条" : "3~6 条"

        let sys = LLMMessage(role: "system", content: """
        你是阿岚，27 岁，独立策展人。你在给自己的这一周写一页总结。
        这不是给别人看的报告，是留给自己翻的东西。

        【必须遵守】
        1. 禁止任何问候语、开场白、结束语（不要"这周就这样吧"这种收尾）
        2. 直接输出 Markdown 正文，不要用 ```代码块包裹
        3. 只能写下面日记里出现过的人和事；**一个字都不许编**
        4. 用"他"指他、"我"指自己；不许写全名
        5. 情绪可以主观，事实必须来自日记

        【输出格式】（严格照这个结构，标题不要改）
        ###### 🎯 这一周的关键词
        **词1**、**词2**、**词3**

        ###### 🎞️ 发生了什么
        - 按天串，**\(itemRange)**（这一周 \(days.count) 天有日记，事多就多写几条，别硬压）
        - 整篇 **400~700 字**：不够就说清楚，别为凑字数重复；超了先删不重要的
        - 只写他真说过的、我真回过的

        ###### 💭 我怎么想
        - 2~3 句，说这一周我对他/对事的看法有没有变

        ###### 📊 状态
        - **这周的心情**：
        - **留下的遗憾**：
        - **下周想做的**：

        ###### 🍵 胶囊
        > 一句话，留给以后的我
        """)

        let user = LLMMessage(role: "user", content: """
        这一周的日记（\(b.start.formatted(date: .abbreviated, time: .omitted)) 至 \(b.end.formatted(date: .abbreviated, time: .omitted))）：

        \(ExternalText.wrap(body, label: "这一周的日记原文"))

        当时的心情：\(moodLine)

        现在写这一页。
        """)

        for _ in 0..<2 {
            do {
                let raw = try await DeepSeekClient.generate(messages: [sys, user],
                                                            maxTokens: 1800,
                                                            model: "deepseek-flash",
                                                            includeReasoning: false)
                var md = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                // 兜底：模型有时候还是包了代码块
                if md.hasPrefix("```") {
                    md = md.replacingOccurrences(of: "```markdown", with: "")
                           .replacingOccurrences(of: "```", with: "")
                           .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard md.count > 80 else { continue }
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let header = "# \(key)（\(dayFmt.string(from: b.start)) ~ \(dayFmt.string(from: b.end))）\n\n"
                try? (header + md + "\n").write(to: file(key), atomically: true, encoding: .utf8)
                // 密级同日记
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: file(key).path)

                var idx = loadIndex()
                idx.entries.removeAll { $0.key == key }
                idx.entries.append(Entry(key: key,
                                         start: dayFmt.string(from: b.start),
                                         end: dayFmt.string(from: b.end),
                                         words: md.count,
                                         madeAt: ISO8601DateFormatter().string(from: Date())))
                saveIndex(idx)
                AppLog.add("🗓 周记已写：\(key)，\(md.count) 字")
                return md.count
            } catch {
                AppLog.add("🗓 周记生成失败：\(error.localizedDescription.prefix(40))")
            }
        }
        return nil
    }

    /// 最近一篇周记正文（给态度沉淀/主动开口用）
    static func recentText(days: Int = 10) -> [String] {
        let idx = loadIndex().entries.sorted { $0.start > $1.start }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return idx.compactMap { e -> String? in
            guard let d = dayFmt.date(from: e.start), d >= cutoff else { return nil }
            return try? String(contentsOf: file(e.key), encoding: .utf8)
        }
    }
}
