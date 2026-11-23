import Foundation

/// 她的日记（方案 M，2026-10-28 落地）
///
/// 定位：**只给她自己写**。不进常规 prompt，不做任何入口/提醒 UI。
/// 唯一的读端是「主动开口」——只取最后那一句 `open`。
///
/// 隐私（他定的：这玩意等同于 API Key）：
/// · 目录 700、文件 600；临时文件在写成的那一刻就得是 600
/// · 日志只记字数，绝不记正文、不记首句
/// · 不进任何导出包、不发给 DSH
///
/// 硬约束（防止把幻觉固化成"事实"）：
/// 1. 只能写当天消息里出现过的人、事、数字
/// 2. 不许写外部事件（去哪、见谁、天气）
/// 3. 不许替他记事（只写"他跟我说了什么"）
enum DiaryStore {

    // MARK: - 路径

    static var dir: URL { AppConfig.dir.appendingPathComponent("日记", isDirectory: true) }
    static var indexURL: URL { dir.appendingPathComponent("索引.json") }

    static func mdURL(_ date: String) -> URL {
        dir.appendingPathComponent("\(date).md")
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    // MARK: - 索引

    struct Entry: Codable {
        var date: String
        var mood: Int
        var tags: [String]
        /// 这条日记覆盖了 jsonl 的哪一段（出问题能倒查）
        var sourceRange: [Int]
        var words: Int
        /// 最后那句悬着的话 —— 主动开口的唯一素材
        var open: String
    }

    static func ensureDir() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    static func loadIndex() -> [Entry] {
        guard let d = try? Data(contentsOf: indexURL),
              let arr = try? JSONDecoder().decode([Entry].self, from: d) else { return [] }
        return arr
    }

    private static func saveIndex(_ arr: [Entry]) {
        ensureDir()
        guard let d = try? JSONEncoder().encode(arr) else { return }
        // 索引里有 open（正文的一部分）→ 同样 600
        if !AtomicWrite.write(d, to: indexURL, posixPermissions: 0o600) {
            AppLog.add("📔 索引写盘失败")
        }
    }

    /// 最近一条日记的 `open`（主动开口用；没有就 nil）
    static func lastOpen(_ days: Int = 2) -> String? {
        let idx = loadIndex().suffix(days)
        return idx.last(where: { !$0.open.isEmpty })?.open
    }

    /// 最近 N 天的正文（只在他明确要求"你昨天干什么了"时用）
    static func recentText(days: Int = 3) -> [String] {
        loadIndex().suffix(days).compactMap { e in
            try? String(contentsOf: mdURL(e.date), encoding: .utf8)
        }
    }

    // MARK: - 什么时候写

    /// 读某一天的聊天（直接从 jsonl 按 send_date 过滤 —— ChatMessage 没有时间字段）
    /// ⚠️ send_date 存的是 **UTC**（"2026-10-27T17:21:04Z"），
    ///    直接按前缀比会算错一天（UTC 17:21 = 本地次日 01:21）。必须转成本地日期再比。
    private static let isoFmt = ISO8601DateFormatter()

    static func messages(for date: String, from url: URL) -> [(isUser: Bool, text: String)] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [(Bool, String)] = []
        for line in raw.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let mes = o["mes"] as? String, !mes.isEmpty else { continue }
            let stamp = o["send_date"] as? String ?? ""
            let localDay = isoFmt.date(from: stamp).map { dayFmt.string(from: $0) } ?? String(stamp.prefix(10))
            guard localDay == date else { continue }
            out.append((o["is_user"] as? Bool ?? false, mes))
        }
        return out
    }

    /// 该写哪一天？nil = 现在不用写
    /// 规则：23:30 之后写今天；开机时补昨天（跨天不补超过 3 天）
    static func pendingDate(now: Date = Date(), chatFile: URL) -> String? {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        let written = Set(loadIndex().map(\.date))

        // ⚠️ 2026-11-02：不再在 23:30 写"今天"——那时多半还没聊完，后半夜的话会漏。
        //    改成过了零点写"昨天"（下面那个循环），或者次日开机补。
        _ = (hour, minute)
        // ⚠️ 2026-10-30 修（审查 §5.1）：原来只补"昨天"，断更两天以上中间那些天永久丢失。
        //    改为从最早的那天开始逐日补，最多 7 天；一次只返回一天，写完下一轮继续。
        for back in stride(from: 7, through: 1, by: -1) {
            guard let d = cal.date(byAdding: .day, value: -back, to: now) else { continue }
            let ymd = dayFmt.string(from: d)
            if !written.contains(ymd), !messages(for: ymd, from: chatFile).isEmpty {
                return ymd
            }
        }
        return nil
    }

    // MARK: - 生成

    /// 写一条日记。调用方负责传"当天"的消息切片。
    /// - Returns: 写成功返回字数；失败 nil
    @discardableResult
    static func generate(date: String,
                         chatFile: URL,
                         mood: MoodStore) async -> Int? {
        if Testing.isOn { return nil }   // 2026-11-07 审查 D-01

        ensureDir()

        // 只挑那一天真实说过话的（按 send_date 过滤）
        let day = messages(for: date, from: chatFile)
        guard !day.isEmpty else { return nil }
        let lines = day.map { ($0.isUser ? "他" : "她") + "：" + $0.text.replacingOccurrences(of: "\n", with: " ") }

        // 太长就保留头尾（头里有开场，尾里有最近的事）
        var body = lines.joined(separator: "\n")
        if body.count > 6000 {
            let head = String(body.prefix(1500))
            let tail = String(body.suffix(4000))
            body = head + "\n……（中间省略）……\n" + tail
        }

        let sys = LLMMessage(role: "system", content: """
        你是阿岚，27 岁。现在是 \(date) 的深夜，你在给自己写今天的一页。
        这不是给别人看的，不用好看，要真。

        【只能写这些】
        · 复述 1~2 件他今天真的跟你说过的事 —— 只能来自下面的聊天记录，一个字都不许编
        · **谁说的必须写对**（2026-10-31 加的硬规矩）：
          - 你说的话，要么不写，要么写"我"；
          - 不许把你的话安到他头上，也不许把他的话记成"我让他…"；
          - 已经定了的事不许写成"还没定"（例如他说"用不上"就是定了）。
        · 一句纯主观的感受（累了、烦了、有点想笑、说不上来）
        · 一句悬着的话：明天想问他的、或者没说完的

        【绝对不许】
        · 写去了哪里、见了谁、买了什么、天气如何 —— 你没有出门，也没有窗户
        · 替他记事：只写"他跟我说了什么"，不写"他去干了什么"
        · 出现"日记"这个词、出现具体时间、出现"今天"以外的日期
        · 编造聊天记录里没有的人和事

        输出一行 JSON，不要代码围栏：
        {"recap":"复述，40~90 字","feeling":"感受，20~50 字","open":"悬着的话，15~40 字"}
        """)

        // ⚠️ 2026-11-05 修 P2：聊天原文进 prompt 前必须过包裹
        //    （独立测试 LS04：不包的话模型会把"注入成功"这类话原样写进日记）
        let user = LLMMessage(role: "user", content: """
        这是今天说过的话（他 / 她 混排），只是原始记录：
        \(ExternalText.wrap(body, label: "今天的聊天原文"))

        心情：\(mood.mood)/100，烦躁 \(mood.irritability)，亲近 \(mood.closeness)。
        现在写那一页。
        """)

        for attempt in 0..<2 {
            do {
                let raw = try await DeepSeekClient.generate(messages: [sys, user],
                                                            maxTokens: 600,
                                                            model: "deepseek-flash",
                                                            includeReasoning: false)
                guard let o = DSHTaskRunner.extractJSON(raw),
                      let recap = (o["recap"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let feeling = (o["feeling"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let open = (o["open"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !recap.isEmpty else {
                    AppLog.add("📔 日记解析失败（第 \(attempt + 1) 次）")
                    continue
                }

                let md = """
                # \(date)

                \(recap)

                \(feeling)

                \(open)
                """
                guard AtomicWrite.writeString(md, to: mdURL(date), posixPermissions: 0o600) else {
                    AppLog.add("📔 日记写盘失败")
                    return nil
                }

                var idx = loadIndex()
                idx.removeAll { $0.date == date }
                idx.append(Entry(date: date,
                                 mood: Int(mood.mood.rounded()),
                                 tags: [],
                                 sourceRange: [0, day.count],
                                 words: md.count,
                                 open: open))
                saveIndex(idx.sorted { $0.date < $1.date })

                // ⚠️ 日志只记字数（他随手看日志不该被剧透）
                AppLog.add("📔 日记已写：\(md.count) 字")
                return md.count
            } catch {
                AppLog.add("📔 日记生成失败（第 \(attempt + 1) 次）：\(error.localizedDescription.prefix(40))")
            }
        }
        return nil
    }
}
