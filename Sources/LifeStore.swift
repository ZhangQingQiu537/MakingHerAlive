import Foundation

/// 她自己的生活（2026-11-10）
///
/// 为什么要有它：以前模型没有"今天发生了什么"的输入，只能拿工作填，
/// 于是她一天到晚都在改方案。这里每天给她 2~3 条**已经定好的**生活事件。
///
/// 硬约束（防编造）：
///   · 只能从固定池里取（画廊 / 老街 / 猫 / 四个固定的人）
///   · 不许出现新人名、新城市、新机构、政治、灾难、名人
///   · 每天至少 1 条生活侧（非工作），最多 3 条
///   · 每条一天只用一次；7 天内不重复
///
/// 落盘：`~/Library/Application Support/阿岚/她的生活.json`
enum LifeStore {

    struct Item: Codable {
        var kind: String     // work / life / mood
        var text: String
        var used: Bool = false
    }
    struct Day: Codable {
        var date: String
        var items: [Item]
    }
    struct Doc: Codable {
        var days: [String: Day] = [:]
    }

    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("她的生活.json")
    }

    private static var generating = Set<String>()

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    // MARK: 读写

    static func load() -> Doc {
        guard let d = try? Data(contentsOf: file),
              let doc = try? JSONDecoder().decode(Doc.self, from: d) else { return Doc() }
        return doc
    }

    static func save(_ doc: Doc) {
        var copy = doc
        // 只留最近 8 天
        let keep = Set((0..<8).compactMap { i -> String? in
            guard let d = Calendar.current.date(byAdding: .day, value: -i, to: Date()) else { return nil }
            return dayFmt.string(from: d)
        })
        copy.days = copy.days.filter { keep.contains($0.key) }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(copy) else { return }
        _ = AtomicWrite.write(data, to: file)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // MARK: 取用

    /// 今天还没用的一条（优先生活侧）。取到就标 used。
    static func takeOne() -> String? {
        var doc = load()
        let today = dayFmt.string(from: Date())
        guard var day = doc.days[today], !day.items.isEmpty else { return nil }
        // 优先生活侧，其次工作侧，最后心情
        let order = ["life", "work", "mood"]
        for k in order {
            if let i = day.items.firstIndex(where: { $0.kind == k && !$0.used }) {
                day.items[i].used = true
                doc.days[today] = day
                save(doc)
                return day.items[i].text
            }
        }
        // 2026-11-23：三条都用过之后不再"消失"，而是回退到最后一条。
        //   原来第 4 轮起【你今天】直接空掉，她当天后半段没有任何自己的生活。
        if let last = day.items.last(where: { $0.kind == "life" }) ?? day.items.last {
            return "（今天早些时候）" + last.text
        }
        return nil
    }

    /// 今天已用的全部（日记/周记只能引用这些）
    static func usedToday() -> [String] {
        let doc = load()
        let today = dayFmt.string(from: Date())
        return (doc.days[today]?.items ?? []).filter(\.used).map(\.text)
    }

    static func todayLine() -> String {
        let doc = load()
        let today = dayFmt.string(from: Date())
        let items = doc.days[today]?.items ?? []
        return items.map { "· \($0.text)" }.joined(separator: "\n")
    }

    /// 从模型输出里抠出 JSON 数组（容忍 ```json 包裹）
    /// ⚠️ 2026-11-10 22:49 崩过一次：原来用 range(of:) 的 upperBound 去切字符串，
    ///    遇到不配对/顺序错乱的括号会踩到 String 索引断言（EXC_BREAKPOINT）。
    ///    现在只用 firstIndex / lastIndex，并先确认顺序。
    private static func parseArray(_ raw: String) -> [[String: Any]]? {
        guard let a = raw.firstIndex(of: "["), let b = raw.lastIndex(of: "]"), a < b else { return nil }
        let t = String(raw[a...b])
        guard let d = t.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return nil }
        return arr
    }

    // MARK: 生成

    /// 今天还没有生活就生成一份。返回是否新生成。
    @discardableResult
    static func ensureToday() async -> Bool {
        if Testing.isOn { return false }
        let today = dayFmt.string(from: Date())
        var doc = load()
        if let d = doc.days[today], !d.items.isEmpty { return false }
        // 防并发（开机 + tick 同时进来会生成两份）
        if generating.contains(today) { return false }
        generating.insert(today)
        defer { generating.remove(today) }

        // 近 7 天说过的事，避免重复
        var recent: [String] = []
        for (k, v) in doc.days where k != today { recent += v.items.map(\.text) }
        recent = Array(recent.suffix(12))

        let weekday = Calendar.current.component(.weekday, from: Date())  // 1=周日
        let isWeekend = (weekday == 1 || weekday == 7)

        let sys = """
        你在给"阿岚"安排**今天**的生活。她 27 岁，在老街开一家没挂牌的小画廊。

        【只能从这些里取材】
        · 地方：画廊、老街、菜市场、五金店、家（阳台、厨房）、材料市场
        · 人（固定四个，不许新增）：阿岚（大学同学，做媒体）、老周（五金店）、
          小陈（实习生，毛躁）、一个一年来两次的老客户（每次都要砍价）
        · 东西：画框、梯子、咖啡机、旧画、绿萝、伞、膏药、猫

        【绝对不许】
        · 新人名、新城市、新机构、政治、灾难、名人、突发事件
        · 写成小说或场景描写；只要一句陈述
        · **不许出现星期几、明天、昨天、后天**——一律写"今天"或不写时间
          （例：写"上午给旧画换框"，不写"周三上午给旧画换框"）
        · 重复下面"最近说过"的内容

        【今天】
        星期\(weekday)，\(isWeekend ? "周末（画廊照常开门，人少、节奏慢）" : "工作日")。

        【输出】
        三行 JSON 数组，不要代码块：
        [{"kind":"work","text":"…"},{"kind":"life","text":"…"},{"kind":"mood","text":"…"}]
        · work：画廊/甲方/布展/装框 之类，一句 15~30 字
        · life：生活侧，必须有具体东西（猫、菜、伞、绿萝、老周、阿岚），一句 15~30 字
        · mood：一句纯情绪，10~20 字，不许带事件
        """

        let user = recent.isEmpty ? "最近没说过什么。" : "最近说过（不要重复）：\n" + recent.joined(separator: "\n")

        for _ in 0..<2 {
            do {
                let raw = try await DeepSeekClient.generate(
                    messages: [LLMMessage(role: "system", content: sys),
                               LLMMessage(role: "user", content: user)],
                    maxTokens: 800, model: "deepseek-flash", includeReasoning: false)
                guard let arr = parseArray(raw) else { continue }
                var items: [Item] = []
                for it in arr {
                    let k = (it["kind"] as? String) ?? ""
                    let t = ((it["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard ["work", "life", "mood"].contains(k), t.count >= 6, t.count <= 60 else { continue }
                    items.append(Item(kind: k, text: t))
                }
                guard !items.isEmpty else { continue }
                // 2026-11-23：没有 life 时直接替换掉最后一条，而不是 append 后被 prefix(3) 切掉
                if !items.contains(where: { $0.kind == "life" }) {
                    let filler = Item(kind: "life", text: "楼下的猫又来蹭饭，蹲在门口不走")
                    if items.count >= 3 { items[2] = filler } else { items.append(filler) }
                }
                doc.days[today] = Day(date: today, items: Array(items.prefix(3)))
                save(doc)
                AppLog.add("🌤 她的生活已生成：\(items.prefix(3).map(\.text).joined(separator: " / "))")
                return true
            } catch {
                AppLog.add("🌤 生活生成失败：\(error.localizedDescription.prefix(30))")
            }
        }
        return false
    }
}
