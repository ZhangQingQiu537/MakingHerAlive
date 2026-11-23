import Foundation

/// 她的"手"：本地只读工具 + 工具调用循环（2026-10-29 重做）
///
/// 之前我用正则从他的话里抠文件名 —— 那是我替她理解，换个说法就废。
/// 现在改成：把三个工具交给她，**由模型自己决定要不要用、用哪个、参数填什么**。
///
/// 权限（不可绕过）：
///   · 只读，不写不删不覆盖
///   · 只能碰 文稿 / 桌面 / 下载 / 阿岚工作区
///   · 单次最多 3 轮工具调用，防止死循环
enum ToolLoop {

    struct Call {
        let id: String
        let name: String
        let args: [String: Any]
    }

    /// 2026-11-21：她自己的搜索预算（每轮最多 2 次、总时长 20s）
    private static var searchCount = 0
    private static var searchDeadline = Date()

    struct Result {
        var context: String     // 工具查到的内容（拼成一段，交给正式那轮流式用）
        var used: [String]      // 用过哪些工具（给日志/界面提示）
        var images: [String] = []   // 画出来的作品（本地 png 路径），直接贴进聊天
    }

    // MARK: - 工具定义（给模型看）

    static let schemas: [[String: Any]] = [
        ["type": "function", "function": [
            "name": "list_dir",
            "description": "列出他电脑上某个目录里的文件。只能看 文稿/桌面/下载/阿岚工作区。",
            "parameters": ["type": "object", "properties": [
                "dir": ["type": "string", "description": "目录名，如 Documents、Desktop、Downloads、阿岚工作区"]
            ], "required": ["dir"]]
        ]],
        ["type": "function", "function": [
            "name": "read_file",
            "description": "读一份文件的正文（只读）。支持 .docx/.txt/.md/.csv/.json。他提到某篇东西时用它。",
            "parameters": ["type": "object", "properties": [
                "name": ["type": "string", "description": "文件名或它的一部分，如 随笔2"]
            ], "required": ["name"]]
        ]],
        ["type": "function", "function": [
            "name": "write_file",
            "description": "把你写的东西存成一个文件（放在作品区，不会覆盖他原有的文件）。写文字、写想法、写说明时用。",
            "parameters": ["type": "object", "properties": [
                "name": ["type": "string", "description": "文件叫什么，如 展签草稿"],
                "content": ["type": "string", "description": "正文"]
            ], "required": ["name", "content"]]
        ]],
        // ⏸ 2026-11-07：画图暂缓（他看不出必要性）。代码保留在 case 里，工具不再注册。
        ["type": "function", "function": [
            "name": "read_webpage",
            "description": "打开一个网页看正文。搜到的摘要不够、想确认细节时用它。只读，不改任何东西。",
            "parameters": ["type": "object", "properties": [
                "url": ["type": "string", "description": "完整网址，必须 http/https"]
            ], "required": ["url"]]
        ]],
        ["type": "function", "function": [
            "name": "search_web",
            "description": "上网搜公开资料。聊到你不了解的作品/人物/事件，或想核实一条信息时用它。一轮最多两次；还查不到就直说记不清，不许编。",
            "parameters": ["type": "object", "properties": [
                "query": ["type": "string", "description": "搜索词，越具体越好，比如 肖骏 不正常飞船 专辑"]
            ], "required": ["query"]]
        ]],
        ["type": "function", "function": [
            "name": "read_diary",
            "description": "翻你自己的日记（你每天晚上写的）。想确认某天发生过什么、或你自己当时怎么想的，就用它。只查你自己的，不要念给他听。",
            "parameters": ["type": "object", "properties": [
                "date": ["type": "string", "description": "哪一天，格式 2026-10-28；不填就返回最近三天"],
                "keyword": ["type": "string", "description": "想找的词，比如 面试、房租"]
            ]]
        ]],
        // ⏸ 2026-11-07：run_task 不再注册（DSH 派活已停用）
        ["type": "function", "function": [
            "name": "search_files",
            "description": "按关键词找他电脑里的文件，返回匹配的路径。",
            "parameters": ["type": "object", "properties": [
                "keyword": ["type": "string", "description": "关键词，如 随笔、周报"]
            ], "required": ["keyword"]]
        ]],
    ]

    // MARK: - 执行

    private static func roots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Documents", "Desktop", "Downloads", "阿岚工作区"]
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func resolveDir(_ name: String) -> URL? {
        let n = name.replacingOccurrences(of: "~/", with: "").lowercased()
        let map = ["documents": "Documents", "文稿": "Documents", "文档": "Documents",
                   "desktop": "Desktop", "桌面": "Desktop",
                   "downloads": "Downloads", "下载": "Downloads",
                   "阿岚工作区": "阿岚工作区", "工作区": "阿岚工作区"]
        guard let folder = map[n] ?? map.first(where: { n.contains($0.key) })?.value else { return nil }
        return roots().first { $0.lastPathComponent == folder }
    }

    static func run(_ c: Call) async -> String {
        switch c.name {
        case "list_dir":
            let d = (c.args["dir"] as? String) ?? "Documents"
            guard let url = resolveDir(d) else { return "没有这个目录（只能看 文稿/桌面/下载/工作区）" }
            let items = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            let shown = items.filter { !$0.hasPrefix(".") }.prefix(40)
            return shown.isEmpty ? "（空目录）" : "（他自己电脑上的 \(url.lastPathComponent)）\n" + shown.joined(separator: "\n")
        case "read_file":
            let name = (c.args["name"] as? String) ?? ""
            if let dir = resolveDir(name) {          // 他可能把目录名当文件名给了
                let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                return "「\(name)」是个目录，里面有：\n" + items.filter { !$0.hasPrefix(".") }
                    .prefix(40).joined(separator: "\n") + "\n（要读哪一份，用 read_file 再叫我一次）"
            }
            guard let url = FileScout.locate(name), let body = FileScout.read(url) else {
                // 自己补救一轮：按关键词搜一遍，把候选给它
                var hits: [String] = []
                for r in roots() {
                    if let e = FileManager.default.enumerator(at: r, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) {
                        // ⚠️ 2026-11-09 修 D-15：async 上下文里 `for case let ... in` 迭代
                        //    非 Sendable 的 DirectoryEnumerator 在 Swift 6 是 error。
                        //    改用 nextObject() 手动取，语义一样。
                        while let u = e.nextObject() as? URL {
                            if u.lastPathComponent.contains(name) {
                                hits.append(u.path); if hits.count >= 8 { break }
                            }
                        }
                    }
                    if hits.count >= 8 { break }
                }
                return hits.isEmpty ? "没找到「\(name)」" : "没直接找到「\(name)」，相近的有：\n" + hits.joined(separator: "\n")
            }
            return "（这是他自己电脑里的文件，不是你够不着的东西）\n【\(url.lastPathComponent)】\n" + String(body.prefix(20_000))
        case "search_files":
            let kw = (c.args["keyword"] as? String) ?? ""
            var hits: [String] = []
            for r in roots() {
                guard let e = FileManager.default.enumerator(at: r, includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles]) else { continue }
                // 同上（D-15）
                while let u = e.nextObject() as? URL {
                    if u.lastPathComponent.contains(kw) {
                        hits.append(u.path); if hits.count >= 12 { break }
                    }
                }
                if hits.count >= 12 { break }
            }
            return hits.isEmpty ? "没找到含「\(kw)」的文件" : hits.joined(separator: "\n")
        case "write_file":
            let name = ((c.args["name"] as? String) ?? "未命名").trimmingCharacters(in: .whitespaces)
            let body = (c.args["content"] as? String) ?? ""
            guard !body.isEmpty else { return "内容是空的，没写" }
            return writeWork(name: name, body: body)
        case "search_web":
            let q = ((c.args["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return "搜索词是空的" }
            if Date() > searchDeadline { return "（这一轮查得够久了，先用手上这些说，别再搜）" }
            if searchCount >= 2 { return "（已经查过两次了，够用了；再缺就直说记不清）" }
            searchCount += 1
            AppLog.add("  [她查] 搜索：\(q)（本轮第 \(searchCount) 次）")
            guard let r = await WebSearchService.searchFacts(query: q) else {
                return "没搜到（可能本来就没有公开信息）。别编，照实说。"
            }
            var out = "查到的资料：\n" + r.facts
            if !r.urls.isEmpty {
                out += "\n\n来源页（想细看可以用 read_webpage 打开）：\n" + r.urls.prefix(2).joined(separator: "\n")
            }
            return out
        case "read_webpage":
            let u = (c.args["url"] as? String) ?? ""
            if let page = await WebSearchService.fetchPage(url: u) {
                return page
            }
            return "这页打不开（可能是站点不让抓）。"
        case "read_diary":
            let date = (c.args["date"] as? String) ?? ""
            let kw = (c.args["keyword"] as? String) ?? ""
            return readDiary(date: date, keyword: kw)
        case "run_task":
            // ⏸ 2026-11-07：DSH 派活已停用（旧资产清理）。留着 case 只为兼容旧调用。
            return "这个我办不到——我没有后台跑任务的能力。"
        case "draw_image":
            let prompt = (c.args["prompt"] as? String) ?? ""
            guard !prompt.isEmpty else { return "没说要画什么" }
            return await drawWork(prompt: prompt)
        default:
            return "没有这个工具"
        }
    }

    // MARK: - 她自己的日记（2026-10-30 补，设计 §12 要求）

    private static func readDiary(date: String, keyword: String) -> String {
        let dir = DiaryStore.dir
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return "日记还没写呢。"
        }
        var mds = files.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if !date.isEmpty {
            mds = mds.filter { $0.deletingPathExtension().lastPathComponent == date }
        } else {
            mds = Array(mds.suffix(3))          // 不指定就最近三天
        }
        guard !mds.isEmpty else { return "那几天没写。" }

        var out: [String] = []
        for u in mds {
            guard let t = try? String(contentsOf: u, encoding: .utf8) else { continue }
            let day = u.deletingPathExtension().lastPathComponent
            if keyword.isEmpty {
                out.append("〔\(day)〕\n" + String(t.prefix(1200)))
            } else if t.contains(keyword) {
                out.append("〔\(day)〕\n" + String(t.prefix(1200)))
            }
        }
        return out.isEmpty ? "没找到含「\(keyword)」的日子。" : out.joined(separator: "\n\n")
    }

    // MARK: - 重活（隐形 DSH，2026-10-29 v3）

    /// 把活交给 DSH，等它跑完，把结果当"她查到/做完了"还给她。
    /// ⚠️ 不出任务卡、不出按钮：设计 v3 定的是"零工单"。这里只回一段话。
    private static func runTask(goal: String) async -> String {
        let t = DSHTaskCenter.shared.submit(title: String(goal.prefix(14)), task: goal, auth: .none)
        let deadline = Date().addingTimeInterval(180)
        var lastStatus = t.status
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let cur = DSHTaskCenter.shared.task(id: t.id) else { continue }
            lastStatus = cur.status
            switch cur.status {
            case "done":
                let body = ([cur.summary] + cur.detail).filter { !$0.isEmpty }.joined(separator: "\n")
                let files = cur.artifacts.isEmpty ? "" : "\n产物：\(cur.artifacts.joined(separator: "、"))"
                return "弄完了：\n\(body.isEmpty ? "（没有更多细节）" : body)\(files)"
            case "failed", "timeout", "refused", "cancelled":
                let why = cur.summary.isEmpty ? "没成" : cur.summary
                return "没弄成：\(why)"
            case "waiting_permission":
                return "这一步要动他的网或者要授权，我先停在这儿了。你得问一句再继续。"
            default:
                continue
            }
        }
        return "还在弄（\(lastStatus)），已经跑了三分钟。你可以先跟他说一声，别让他干等。"
    }

    // MARK: - 作品（2026-10-29 v3：她是设计者，产出算作品）

    /// 给界面用（拼图片绝对路径）
    static var workDirForUI: URL { workDir }

    /// 2026-11-07 审查 D-06：作品信息走这里传，不再往回复正文里塞 ⟦作品:…⟧
    /// （标记会被模型复述、路径带 | 会被截断、多条只处理第一条）
    static var pendingWork: (path: String, name: String)?

    private static var workDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let d = home.appendingPathComponent("阿岚工作区/作品", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// 写一份作品（永不覆盖原件）
    private static func writeWork(name: String, body: String) -> String {
        var fileName = name.replacingOccurrences(of: "/", with: "-")
        if !fileName.contains(".") { fileName += ".md" }
        var url = workDir.appendingPathComponent("\(stamp())-\(fileName)")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = workDir.appendingPathComponent("\(stamp())-\(i)-\(fileName)"); i += 1
        }
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            // 2026-11-07 作品位：写完的东西算"她的作品"，记一张卡（topic=我的作品）
            var card = MemoryCard()
            card.topic = "我的作品"
            card.time = ISO8601DateFormatter().string(from: Date())
            card.event = "我写了《\(fileName.replacingOccurrences(of: ".md", with: ""))》，存进作品里了"
            card.tags = ["作品", "我写的"]
            card.atIndex = CardStore.shared.cards.count
            _ = CardStore.shared.append(card)
            pendingWork = (url.path, fileName)
            return "已存好：\(url.lastPathComponent)（\(body.count) 字）。可以跟他说「写完了，给你看」。"
        } catch {
            return "没写成：\(error.localizedDescription.prefix(40))"
        }
    }

    /// 从 secrets.json 取密钥（和 App 其他地方一致）
    private static func secret(_ name: String) -> String? {
        let p = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/阿岚/secrets.json")
        guard let d = try? Data(contentsOf: p),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o[name] as? String
    }

    /// 画一张（ARK，一天一张）
    private static var quotaURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("阿岚工作区/.draw-quota.json")
    }

    /// 每天最多画几张（他同意 3 张，够看也够省）
    private static let dailyQuota = 1

    private static func drawQuotaLeft() -> Int {
        guard let d = try? Data(contentsOf: quotaURL),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              (o["date"] as? String) == stamp() else { return 1 }
        return max(0, dailyQuota - ((o["count"] as? Int) ?? 0))
    }

    private static func bumpQuota() {
        var n = 1
        if let d = try? Data(contentsOf: quotaURL),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           (o["date"] as? String) == stamp() { n = (o["count"] as? Int ?? 0) + 1 }
        let obj: [String: Any] = ["date": stamp(), "count": n]
        if let d = try? JSONSerialization.data(withJSONObject: obj) { try? d.write(to: quotaURL) }
    }

    private static func drawWork(prompt: String) async -> String {
        guard drawQuotaLeft() > 0 else {
            return "今天画不出来了（超出今日额度）。你就说今天手生了，明天给他画。"
        }
        guard let key = secret("volcano-ark-key"), !key.isEmpty else {
            return "画不了（没有画图的能力配置）"
        }
        let url = URL(string: "https://ark.cn-beijing.volces.com/api/v3/images/generations")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // ⚠️ 2026-10-29：她不是摄影师。默认出写实照片一眼假，必须锁手绘质感。
        let style = "手绘作品：铅笔或炭笔速写打底，少量淡彩晕染，纸面纹理清晰，笔触可见，"
            + "构图略松散、有留白，像一个人在本子上随手画的，不要写实照片，不要摄影感，"
            + "不要 3D 渲染，不要过度精致。画面内容："
        let payload: [String: Any] = ["model": "doubao-seedream-5-0-pro-260628",
                                      "prompt": style + prompt, "size": "1024x1024",
                                      "response_format": "url", "watermark": false]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = o["data"] as? [[String: Any]],
                  let u = arr.first?["url"] as? String,
                  let imgURL = URL(string: u) else {
                return "画失败了（返回里没有图）"
            }
            let (imgData, _) = try await URLSession.shared.data(from: imgURL)
            // ⚠️ 2026-10-30 修（审查 §5.4）：ARK 回的是 JPEG，却存成 .png，
            //    上传 QQ / 按扩展名处理会踩坑。按文件头判真实格式。
            let isJPEG = imgData.starts(with: [0xFF, 0xD8, 0xFF])
            let ext = isJPEG ? "jpg" : "png"
            let f = DateFormatter(); f.dateFormat = "HHmmss"
            let file = workDir.appendingPathComponent("\(stamp())-\(f.string(from: Date())).\(ext)")
            try imgData.write(to: file)
            bumpQuota()
            return "画好了：\(file.lastPathComponent)。跟他说一声，图已经贴上去了。"
        } catch {
            return "画失败了：\(error.localizedDescription.prefix(40))"
        }
    }

    // MARK: - 循环

    /// 在正式回答之前，先让模型决定要不要动手。用过工具就把结果拼进 messages。
    static func preflight(_ messages: [LLMMessage], maxRounds: Int = 3) async -> Result {
        var msgs = messages
        searchCount = 0
        searchDeadline = Date().addingTimeInterval(20)
        var used: [String] = []
        var context: [String] = []
        var images: [String] = []
        for _ in 0..<maxRounds {
            guard let turn = try? await DeepSeekClient.generateWithTools(messages: msgs,
                                                                        tools: schemas) else { break }
            guard !turn.calls.isEmpty else { break }
            msgs.append(LLMMessage(role: "assistant", content: turn.content))
            for c in turn.calls {
                let out = await run(c)
                if c.name == "draw_image", out.hasPrefix("画好了：") {
                    let fname = String(out.dropFirst(4).prefix { $0 != "。" })
                    let url = workDir.appendingPathComponent(fname)
                    if FileManager.default.fileExists(atPath: url.path) { images.append(url.path) }
                }
                used.append(c.name)
                context.append("〔\(c.name)〕\n\(out)")
                msgs.append(LLMMessage(role: "tool", content: out, toolCallId: c.id))
            }
        }
        // ⚠️ 不把 tool 消息带进流式请求：DeepSeek 的流式接口对 tool_call_id 校验很严，
        //    带过去就是 422。改成一段普通文本，交给正式那轮当"你查到的资料"。
        return Result(context: context.joined(separator: "\n\n"), used: used, images: images)
    }
}
