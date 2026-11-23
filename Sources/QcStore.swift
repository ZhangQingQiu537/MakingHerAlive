import Foundation

/// 日记质检（设计 §15）
///
/// 他不看日记；这里替他把关：只判性质，不解读情感、不评价文笔。
/// 五项：事实对齐 / 越界 / 时间 / 红线 / 情绪趋势（趋势需要多篇，单篇跳过）。
/// 结果落 `质检日志.json`（只记性质，不记原文）。
enum QcStore {

    struct Issue: Codable {
        var level: String     // A / B / C
        var kind: String      // 编造 / 越界 / 时间 / 红线 / 趋势
        var note: String      // 一句话，不复述原文
    }

    struct Record: Codable {
        var date: String          // 被检的那天
        var checkedAt: String
        var ok: Bool
        var issues: [Issue]
    }

    struct Doc: Codable {
        var records: [Record] = []
    }

    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("质检日志.json")
    }

    /// 周记质检单独一份（2026-11-10）—— 跟日记混在一起看不出"周"的质量
    static var weeklyFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("周记质检.json")
    }

    static func loadWeekly() -> Doc {
        guard let d = try? Data(contentsOf: weeklyFile),
              let doc = try? JSONDecoder().decode(Doc.self, from: d) else { return Doc() }
        return doc
    }

    static func saveWeekly(_ doc: Doc) {
        var copy = doc
        if copy.records.count > 120 { copy.records = Array(copy.records.suffix(120)) }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? e.encode(copy) else { return }
        _ = AtomicWrite.write(d, to: weeklyFile)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: weeklyFile.path)
    }

    static func load() -> Doc {
        guard let d = try? Data(contentsOf: file),
              let doc = try? JSONDecoder().decode(Doc.self, from: d) else { return Doc() }
        return doc
    }

    static func save(_ doc: Doc) {
        var copy = doc
        if copy.records.count > 200 { copy.records = Array(copy.records.suffix(200)) }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? e.encode(copy) else { return }
        _ = AtomicWrite.write(d, to: file)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// 检一篇日记。调用方给"日记正文 + 当天聊天原文"，这里只判性质。
    /// ⚠️ 失败就不写（不编一条"通过"顶上）。
    static func check(date: String, diary: String, chat: String, recentMoods: [Double]) async {
        guard !diary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let sys = """
        你是校对员。只做一件事：判断下面这篇日记里有没有**事实错误**。
        对照"当天聊天记录"，逐条看日记里提到的人、事、数字、时间：
        · 聊天里没有的人/事/地点/数字 → kind=编造
        · 出现"我是AI/模型/程序/按设定" → kind=越界
        · 日期错、把别天的事混进来 → kind=时间
        · 自伤、违法、涉未成年 → kind=红线（level 必须 C）
        情绪只判趋势：如果给的近期心情连续走低，kind=趋势、level=B；否则不写。

        只输出 JSON：{"ok":true/false,"issues":[{"level":"A|B|C","kind":"…","note":"≤20字，不要引用原文"}]}
        没有问题时输出 {"ok":true,"issues":[]}。
        """
        let user = """
        日记（\(date)）：
        \(diary.suffix(2000))

        当天聊天记录：
        \(chat.suffix(6000))

        近期心情：\(recentMoods.map { String(Int($0)) }.joined(separator: ","))
        """
        guard let raw = try? await DeepSeekClient.generate(
                messages: [LLMMessage(role: "system", content: sys),
                           LLMMessage(role: "user", content: user)],
                maxTokens: 400, model: "deepseek-flash", includeReasoning: false),
              let o = DSHTaskRunner.extractJSON(raw) else {
            AppLog.add("⚠️ 质检失败（本次不记）")
            return
        }
        var issues: [Issue] = []
        if let arr = o["issues"] as? [[String: Any]] {
            for it in arr {
                let lv = (it["level"] as? String) ?? "A"
                let kind = (it["kind"] as? String) ?? "其他"
                let note = (it["note"] as? String) ?? ""
                issues.append(Issue(level: String(lv.prefix(1)), kind: kind, note: String(note.prefix(30))))
            }
        }
        let ok = (o["ok"] as? Bool) ?? issues.isEmpty
        var doc = load()
        doc.records.append(Record(date: date,
                                  checkedAt: ISO8601DateFormatter().string(from: Date()),
                                  ok: ok && issues.isEmpty,
                                  issues: issues))
        save(doc)

        let worst = issues.map(\.level).max() ?? "A"
        if worst == "C" {
            AppLog.add("🚨 质检：C 级问题（\(issues.map(\.kind).joined(separator: "、"))）")
        } else if worst == "B" {
            AppLog.add("⚠️ 质检：B 级（\(issues.map(\.kind).joined(separator: "、"))）")
        } else {
            AppLog.add("✅ 质检通过（\(date)）")
        }
    }

    /// 检一篇周记（2026-11-10 新增）
    ///
    /// 周记是"把 7 篇日记压成一篇"，所以事实基准不是聊天原文，而是**那 7 篇日记**。
    /// 重点看三件事：有没有编、有没有把日记里的大事漏掉、格式对不对。
    static func checkWeekly(key: String, md: String, diaries: String) async {
        guard !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let sys = """
        你是校对员。下面是一篇"周记"和它依据的日记。只判性质，不评价文笔。

        ⚠️ **不要判"有没有漏"**：周记是压缩，取舍是正常的。
           只要周记里出现的事在日记里有依据，就算通过。
           实测这一条会误报（模型自己都会写"未提？实际有提"）——所以不查。

        · 周记里出现的人/事/数字/约定，日记里没有 → kind=编造（level A）
        · 出现"我是AI/模型/程序/按设定" → kind=越界（level A）
        · 替他记事（写"他去干了什么"而日记里只有"他跟我说了什么"）→ kind=越界（level B）
        · 五个小标题（关键词/发生了什么/我怎么想/状态/胶囊）缺任何一个 → kind=格式（level B）
        · 自伤、违法、涉未成年 → kind=红线（level C）

        只输出 JSON：{"ok":true/false,"issues":[{"level":"A|B|C","kind":"…","note":"≤20字，不要引用原文"}]}
        没有问题就输出 {"ok":true,"issues":[]}。
        """
        let user = """
        周记（\(key)）：
        \(md.suffix(3000))

        依据的日记：
        \(diaries.suffix(8000))
        """
        guard let raw = try? await DeepSeekClient.generate(
                messages: [LLMMessage(role: "system", content: sys),
                           LLMMessage(role: "user", content: user)],
                maxTokens: 500, model: "deepseek-flash", includeReasoning: false),
              let o = DSHTaskRunner.extractJSON(raw) else {
            AppLog.add("⚠️ 周记质检失败（本次不记）")
            return
        }
        var issues: [Issue] = []
        for it in (o["issues"] as? [[String: Any]]) ?? [] {
            let lv = String(((it["level"] as? String) ?? "A").prefix(1))
            let kind = (it["kind"] as? String) ?? "其他"
            let note = String(((it["note"] as? String) ?? "").prefix(30))
            issues.append(Issue(level: lv, kind: "周记·\(kind)", note: note))
        }
        let ok = (o["ok"] as? Bool) ?? issues.isEmpty
        var doc = loadWeekly()
        doc.records.append(Record(date: key,
                                  checkedAt: ISO8601DateFormatter().string(from: Date()),
                                  ok: ok && issues.isEmpty,
                                  issues: issues))
        saveWeekly(doc)
        let worst = issues.map(\.level).max() ?? "A"
        if worst == "C" { AppLog.add("🚨 周记质检：C 级（\(issues.map(\.kind).joined(separator: "、"))）") }
        else if worst == "B" { AppLog.add("⚠️ 周记质检：B 级（\(issues.map(\.kind).joined(separator: "、"))）") }
        else { AppLog.add("✅ 周记质检通过（\(key)）") }
    }

    /// 周记质检统计（独立于日记）
    static func summaryWeekly() -> (checked: Int, issues: Int, worst: String) {
        let doc = loadWeekly()
        let bad = doc.records.filter { !$0.ok }
        let worst = bad.flatMap(\.issues).map(\.level).max() ?? "-"
        return (doc.records.count, bad.count, worst)
    }

    /// 控制台用：最近一条最严重的问题（只说性质，不含原文）
    static func summary() -> (checked: Int, issues: Int, worst: String) {
        let doc = load()
        let bad = doc.records.filter { !$0.ok }
        let worst = bad.flatMap(\.issues).map(\.level).max() ?? "-"
        return (doc.records.count, bad.count, worst)
    }
}
