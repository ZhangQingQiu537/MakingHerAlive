import Foundation

/// 对接 SillyTavern 服务端（复用它的存储 + LLM 代理）
///
/// 关键点（P0 摸清的）：
/// - HTTP Basic 认证
/// - CSRF：先用 cookiejar 请求 /csrf-token（会拿到 session cookie），
///   之后每个请求都要带 X-CSRF-Token **并且带着那个 cookie**
final class STClient {

    static let shared = STClient()

    private let base = ProcessInfo.processInfo.environment["ST_BASE"] ?? "http://127.0.0.1:8000"
    /// 旧 SillyTavern 代理的 Basic Auth：用 ST_BASIC_AUTH="user:pass" 传入；不传就不带这个头
    private let auth: String = {
        guard let raw = ProcessInfo.processInfo.environment["ST_BASIC_AUTH"], !raw.isEmpty else { return "" }
        return "Basic " + Data(raw.utf8).base64EncodedString()
    }()

    private var session: URLSession!
    private var csrfToken: String?

    /// 思考投入 low / medium / high（空 = 不指定）。
    /// 实测：同一个 prompt，medium 的思考量约是默认的一半，low 约 1/5，且都更快出正文。
    var reasoningEffort: String = "medium"

    /// 正在跑的流式请求（"停止"按钮用它中断）
    private var streamTask: URLSessionTask?

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpShouldSetCookies = true
        // ⭐ 禁用 URLSession 的钥匙串凭据存储：
        // Authorization 头是我们手动设置的，不需要 URLSession 管密码。
        // 不禁用的话，它会把 127.0.0.1 的 Basic Auth 密码存进钥匙串，
        // 而每次构建重签后 macOS 都会弹"想要使用机密信息"的授权框（用户实测遇到过）。
        cfg.urlCredentialStorage = nil
        session = URLSession(configuration: cfg)
    }

    // MARK: - 基础请求

    private func request(_ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 180) async throws -> Data {
        guard let url = URL(string: base + path) else { throw STError.badURL }

        if csrfToken == nil { try await fetchToken() }

        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        if !auth.isEmpty { req.setValue(auth, forHTTPHeaderField: "Authorization") }
        if let t = csrfToken { req.setValue(t, forHTTPHeaderField: "X-CSRF-Token") }
        if let b = body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: b)
        } else {
            req.httpMethod = "GET"
        }

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw STError.http(code, String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }
        return data
    }

    private func fetchToken() async throws {
        guard let url = URL(string: base + "/csrf-token") else { throw STError.badURL }
        var req = URLRequest(url: url)
        if !auth.isEmpty { req.setValue(auth, forHTTPHeaderField: "Authorization") }
        let (data, _) = try await session.data(for: req)
        struct Tok: Decodable { let token: String }
        csrfToken = try JSONDecoder().decode(Tok.self, from: data).token
    }

    // MARK: - 业务

    /// 拉角色卡
    func characters() async throws -> [CharacterCard] {
        let d = try await request("/api/characters/all", body: [:])
        return try JSONDecoder().decode([CharacterCard].self, from: d)
    }

    /// 把当前阶段写进世界书 uid14（"当前从L2起步" → "当前从L3起步"）
    /// 这样状态机才是真的在演进，而不是每轮都从头判断
    ///
    /// 2026-09-24 重构：委托给 WorldBookService（Bug 6 修）—— 主 App 与控制台都走这个入口。
    /// useDirect=false 分支已删（ST 已归档，控制台用 Backend.saveStage）。
    @discardableResult

    /// 拉世界书
    func worldBook(name: String) async throws -> WorldBook {
        let d = try await request("/api/worldinfo/get", body: ["name": name])
        return try JSONDecoder().decode(WorldBook.self, from: d)
    }

    /// 拉聊天记录
    func chat(avatar: String, file: String) async throws -> [ChatMessage] {
        // ⭐ useDirect 下不走 ST API（A1 切割后 node 服务可能根本没起），直接读本地文件。
        // 这同时让"控制台手改了聊天文件 → 下一轮立刻生效"在直连模式也成立。
        if AppConfig.load().useDirect {
            return readLocalChat(avatar: avatar, file: file)
        }
        let d = try await request("/api/chats/get", body: ["avatar_url": avatar, "file_name": file])
        // 接口会返回一个 metadata 对象 + 若干消息，这里只取有 mes 的
        let raw = try JSONSerialization.jsonObject(with: d) as? [[String: Any]] ?? []
        var out: [ChatMessage] = []
        for o in raw {
            guard let mes = o["mes"] as? String else { continue }
            let name = o["name"] as? String ?? ""
            let isUser = o["is_user"] as? Bool ?? false
            let isSystem = o["is_system"] as? Bool ?? false
            out.append(ChatMessage(name: name, isUser: isUser, mes: mes, isSystem: isSystem))
        }
        return out
    }

    /// 拉**指定** persona 的描述（按 key 取，不读网页版"当前选中"的那张）
    ///
    /// 这是 App 与网页版隔离的关键：网页版切 persona 不会影响 App。
    func personaDescription(key: String) async throws -> String {
        let d = try await request("/api/settings/get", body: [:])
        guard let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "" }
        var s = obj["settings"]
        if let str = s as? String { s = try JSONSerialization.jsonObject(with: Data(str.utf8)) }
        guard let settings = s as? [String: Any],
              let pu = settings["power_user"] as? [String: Any],
              let dict = pu["persona_descriptions"] as? [String: Any],
              let entry = dict[key] as? [String: Any] else { return "" }
        return entry["description"] as? String ?? ""
    }

    /// 把新消息追加到 App 自己的 chat 文件（与网页版互不干扰）
    ///
    /// ⚠️ 2026-09-24 加并发锁（Bug 3）：后台摘要、问候脚本可能并发写同一个 jsonl，
    /// 没有锁会让一行写一半（"{\\"name\\":" 写到一半被切）—— 加 NSLock 全局串行化。
    @discardableResult
    func appendToChat(avatar: String, file: String, name: String, isUser: Bool,
                      mes: String, isSystem: Bool = false,
                      reasoning: String = "", imageFile: String = "",
                      workPath: String = "", workName: String = "") -> Bool {
        return STClient.chatFileLock.withLock {
            let url = chatFileURL(avatar: avatar, file: file)
            let df = ISO8601DateFormatter()
            let obj: [String: Any] = [
                "name": name,
                "is_user": isUser,
                "is_system": isSystem,
                "send_date": df.string(from: Date()),
                "mes": mes,
                // ⭐ 思考原文跟着消息一起落盘（extra 是 SillyTavern 的自定义字段位）
                "extra": ["reasoning": reasoning, "image": imageFile,
                          "workPath": workPath, "workName": workName],
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  let line = String(data: data, encoding: .utf8) else { return false }
            let text = line + "\n"
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    // 文件不存在：先写 metadata 行
                    let meta: [String: Any] = [
                        "chat_metadata": ["integrity": UUID().uuidString, "tainted": false],
                        "user_name": "unused",
                        "character_name": name,
                    ]
                    if let md = try? JSONSerialization.data(withJSONObject: meta),
                       let ms = String(data: md, encoding: .utf8) {
                        try (ms + "\n").write(to: url, atomically: true, encoding: .utf8)
                    }
                }
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                h.seekToEndOfFile()
                try h.write(contentsOf: Data(text.utf8))
                return true
            } catch {
                print("[chat] 写入失败: \(error)")
                return false
            }
        }
    }

    /// 重写整个聊天文件（编辑消息 / 重新生成时用：先回退、再重写）
    @discardableResult
    func rewriteChat(avatar: String, file: String, messages: [ChatMessage]) -> Bool {
        return STClient.chatFileLock.withLock {
            let url = chatFileURL(avatar: avatar, file: file)
            let df = ISO8601DateFormatter()

            var lines: [String] = []
            // 保留原有的 metadata 行（避免破坏 SillyTavern 的解析）
            var oldLines: [[String: Any]] = []
            var unparsed: [String] = []
            let oldText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for (li, l) in oldText.split(separator: "\n").enumerated() {
                let raw = String(l)
                if li == 0, raw.contains("chat_metadata") { continue }
                if let d = l.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   o["mes"] != nil {
                    oldLines.append(o)
                } else if !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                    // ⚠️ 2026-10-28 修 H-06：解析不了的行**原样留着**。
                    //    以前重写会把它永久删掉（用户的半行消息就这么没了）。
                    unparsed.append(raw)
                }
            }
            if let first = oldText.split(separator: "\n").first,
               first.contains("chat_metadata") {
                lines.append(String(first))
            } else {
                let meta: [String: Any] = [
                    "character_name": "unused",
                    "chat_metadata": ["integrity": UUID().uuidString, "tainted": false],
                    "user_name": "unused",
                ]
                if let md = try? JSONSerialization.data(withJSONObject: meta),
                   let ms = String(data: md, encoding: .utf8) {
                    lines.append(ms)
                }
            }
            // ⚠️ 2026-10-28 修 L-03（审查报告）：重写时原来一律用"现在"当 send_date、
            //    并且丢掉 extra 里的未知字段（2020 年的消息会被改成今天）。
            //    现在：内容没变的消息沿用原来的时间和 extra，只更新 reasoning。
            for (i, m) in messages.enumerated() {
                // ⚠️ 2026-10-28 修 L-03：以**旧对象为底**再覆盖，这样 custom 之类的
                //    未知顶层字段、原 send_date、extra 里的其他键都不会被抹掉。
                var obj: [String: Any] = [:]
                if i < oldLines.count,
                   let om = oldLines[i]["mes"] as? String, om == m.mes,
                   (oldLines[i]["is_user"] as? Bool ?? false) == m.isUser {
                    obj = oldLines[i]
                }
                obj["name"] = m.name
                obj["is_system"] = m.isSystem      // ⚠️ 原来硬编码 false，分割线会变普通消息
                obj["is_user"] = m.isUser
                if obj["send_date"] == nil { obj["send_date"] = df.string(from: Date()) }
                obj["mes"] = m.mes
                var extra = (obj["extra"] as? [String: Any]) ?? [:]
                extra["reasoning"] = m.reasoning
                if !m.imagePath.isEmpty { extra["image"] = m.imagePath }
                if !m.workPath.isEmpty { extra["workPath"] = m.workPath; extra["workName"] = m.workName }
                obj["extra"] = extra
                if let d = try? JSONSerialization.data(withJSONObject: obj),
                   let s = String(data: d, encoding: .utf8) {
                    lines.append(s)
                }
            }
            // 坏行原样带回（放在末尾，不参与对话，但绝不丢）
            lines.append(contentsOf: unparsed)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try lines.joined(separator: "\n").appending("\n")
                    .write(to: url, atomically: true, encoding: .utf8)
                return true
            } catch {
                print("[chat] 重写失败: \(error)")
                return false
            }
        }
    }

    /// 文件 IO 串行锁（Bug 3）：appendToChat + rewriteChat 共用，
    /// 避免后台摘要、问候脚本并发写同一个 jsonl 时把一行切半。
    /// 用 NSLock 是因为 FileHandle 内部不线程安全，要纯阻塞互斥。
    private static let chatFileLock = NSLock()

    /// 聊天文件路径（useDirect 时走自有目录）
    func chatFileURL(avatar: String, file: String) -> URL {
        URL(fileURLWithPath: chatBase)
            .appendingPathComponent(avatar.replacingOccurrences(of: ".png", with: ""))
            .appendingPathComponent("\(file).jsonl")
    }

    /// useDirect 模式下直接读本地聊天文件（不走 API）
    func readLocalChat(avatar: String, file: String) -> [ChatMessage] {
        let url = chatFileURL(avatar: avatar, file: file)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [ChatMessage] = []
        var bad: [String] = []
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let mes = o["mes"] as? String else {
                // ⚠️ 2026-10-28 修 H-06（审查报告）：坏行以前**静默跳过**，
                //    下一次编辑/重新生成触发 rewriteChat 就把这行永久抹掉了。
                //    现在：坏行原样另存一份（.未识别-*），既不进对话，也绝不会丢。
                let t = String(line)
                if !t.contains("chat_metadata") { bad.append(t) }
                continue
            }
            out.append(ChatMessage(name: o["name"] as? String ?? "",
                                   isUser: o["is_user"] as? Bool ?? false,
                                   mes: mes,
                                   isSystem: o["is_system"] as? Bool ?? false,
                                   reasoning: Self.reasoningFrom(o),
                                   imagePath: Self.imageFrom(o),
                                   workPath: Self.workFrom(o, "workPath"),
                                   workName: Self.workFrom(o, "workName"),
                                   sentAt: (o["send_date"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }))
        }
        if !bad.isEmpty {
            let side = url.path + ".未识别-\(Self.dayStamp()).txt"
            let block = bad.joined(separator: "\n") + "\n"
            if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: side)) {
                defer { try? h.close() }
                h.seekToEndOfFile()
                try? h.write(contentsOf: Data(block.utf8))
            } else {
                try? block.write(toFile: side, atomically: true, encoding: .utf8)
            }
            AppLog.add("⚠️ 聊天记录里有 \(bad.count) 行解析失败，已另存到 \(URL(fileURLWithPath: side).lastPathComponent)")
        }
        return out
    }

    private static func dayStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f.string(from: Date())
    }

    /// 从 jsonl 一行的 extra 里取思考原文（旧数据没有这个字段 → 空串）
    private static func workFrom(_ o: [String: Any], _ key: String) -> String {
        ((o["extra"] as? [String: Any])?[key] as? String) ?? ""
    }

    private static func imageFrom(_ o: [String: Any]) -> String {
        ((o["extra"] as? [String: Any])?["image"] as? String) ?? ""
    }

    private static func reasoningFrom(_ o: [String: Any]) -> String {
        ((o["extra"] as? [String: Any])?["reasoning"] as? String) ?? ""
    }

    /// 中断当前流式请求（"停止"按钮）
    func cancelCurrentStream() {
        streamTask?.cancel()
        // ⚠️ 2026-10-28 修 H-03：直连模式下 `streamTask` 从来没被赋值（上面那行是 ST 代理路径的），
        //    所以要单独取消 DeepSeek 那条流，否则点了停止网络还在跑、回复还会落盘。
        DeepSeekClient.cancelCurrent()
    }

    /// SillyTavern 根目录（App 与它共用同一份数据文件）
    var stRoot: String {
        // 可选：兼容读取旧的 SillyTavern 数据。没装/没有就退回本机默认目录。
        ProcessInfo.processInfo.environment["ST_ROOT"]
            ?? NSString(string: "~/SillyTavern").expandingTildeInPath
    }

    /// ⭐ 聊天记录根目录（脱离 ST 的关键切换）：
    /// useDirect=true → 自有 `~/Library/Application Support/阿岚/聊天/`；
    /// false → ST 的 `data/default-user/chats/`。
    /// 两边目录结构一致（都是 `<chatAvatar>/<file>.jsonl`），切换不需要搬格式。
    var chatBase: String {
        if AppConfig.load().useDirect {
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Companion", isDirectory: true)
                .appendingPathComponent("聊天", isDirectory: true)
                .path
        }
        return URL(fileURLWithPath: stRoot)
            .appendingPathComponent("data/default-user/chats").path
    }

    // MARK: - 头像路径（useDirect 走 App 侧自有资产目录）
    // 历史版本：拼 stRoot —— 已删（Bug 2）。ST 目录已归档为只读。
    // 现在：useDirect 时 App 自有 `资产/` 里没有 PNG（角色卡现在是 JSON），
    // 这两个方法在 useDirect 路径里**不会调到**（Main.swift 走 loadLocalAssets）。
    // 留它们是为了 useDirect=false 路径将来万一回退时仍能编译 —— 用 fatalError 防误用。
    func characterAvatarPath(_ name: String) -> String {
        if AppConfig.load().useDirect {
            // 2026-10-29：她的头像终于有了 —— 资产/头像.png 存在就用它，否则回退占位
            let av = AppConfig.dir.appendingPathComponent("资产/头像.png")
            if FileManager.default.fileExists(atPath: av.path) { return av.path }
            return AppConfig.dir.appendingPathComponent("资产/no-png-placeholder").path
        }
        // useDirect=false 已废弃（ST 已归档），保留 fallback 不报错
        return "/dev/null"
    }

    func userAvatarPath(key: String) -> String {
        if AppConfig.load().useDirect {
            return AppConfig.dir.appendingPathComponent("资产/no-png-placeholder").path
        }
        return "/dev/null"
    }

    /// 调 LLM（走 SillyTavern 的代理，不用自己管 Key）
    /// ⭐ useDirect=true 时直连 DeepSeek（脱离 ST），行为不变（payload 同构）
    /// 同 generate，但连思考原文一起返回（调试"模型为什么这么判"用）
    ///
    /// ⭐ 2026-09-25 新增。走 ST 代理时思考原文可能拿不到（看代理是否透传），
    /// App 现在是直连模式（useDirect=true），所以主路径一定能拿到。
    func generateFull(messages: [LLMMessage], maxTokens: Int = 8192,
                      model: String = "deepseek-v4-flash",
                      includeReasoning: Bool = true) async throws -> DeepSeekClient.LLMResult {
        if AppConfig.load().useDirect {
            return try await DeepSeekClient.generateFull(
                messages: messages, maxTokens: maxTokens,
                model: DeepSeekClient.directModel(model),
                includeReasoning: includeReasoning)
        }
        let d = try await request("/api/backends/chat-completions/generate",
                                  body: payload(messages, maxTokens, model: model,
                                                includeReasoning: includeReasoning, stream: false))
        guard let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any] else {
            throw STError.badResponse
        }
        var r = DeepSeekClient.LLMResult()
        r.content = ((msg["content"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        r.reasoning = (msg["reasoning_content"] as? String) ?? ""
        return r
    }

    func generate(messages: [LLMMessage], maxTokens: Int = 8192,
                  model: String = "deepseek-v4-flash",
                  includeReasoning: Bool = true) async throws -> String {
        if AppConfig.load().useDirect {
            return try await DeepSeekClient.generate(
                messages: messages, maxTokens: maxTokens,
                model: DeepSeekClient.directModel(model),
                includeReasoning: includeReasoning)
        }
        let d = try await request("/api/backends/chat-completions/generate",
                                  body: payload(messages, maxTokens, model: model,
                                                includeReasoning: includeReasoning, stream: false))
        guard let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw STError.badResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 流式生成：每收到一段就回调（用于逐字显示，避免"干等"）
    ///
    /// - firstContentTimeout: 超过这么多秒还**一直在思考、正文一个字没出**，就主动切断，
    ///   并抛 `STError.firstTokenTimeout` —— 调用方据此改用"直接说"（不思考）重说一遍。
    ///   专治间歇性长思考（同一句话有时 3 秒、有时 60 秒）。0 = 不设保护。
    func generateStream(messages: [LLMMessage],
                        maxTokens: Int = 8192,
                        model: String = "deepseek-v4-flash",
                        includeReasoning: Bool = true,
                        firstContentTimeout: TimeInterval = 0,
                        onDelta: @escaping @MainActor (String) -> Void,
                        onReasoning: (@MainActor (String) -> Void)? = nil,
                        onFinish: (@MainActor (String) -> Void)? = nil) async throws {
        if AppConfig.load().useDirect {
            try await DeepSeekClient.generateStream(
                messages: messages, maxTokens: maxTokens,
                model: DeepSeekClient.directModel(model),
                includeReasoning: includeReasoning,
                firstContentTimeout: firstContentTimeout,
                onDelta: onDelta, onReasoning: onReasoning, onFinish: onFinish)
            return
        }
        if onReasoning != nil { AppLog.add("  （走 ST 代理时拿不到思考原文）") }
        if csrfToken == nil { try await fetchToken() }

        guard let url = URL(string: base + "/api/backends/chat-completions/generate") else {
            throw STError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        if !auth.isEmpty { req.setValue(auth, forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = csrfToken { req.setValue(t, forHTTPHeaderField: "X-CSRF-Token") }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload(messages, maxTokens, model: model, includeReasoning: includeReasoning, stream: true))

        let (bytes, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw STError.http(code, "流式请求失败")
        }
        streamTask = bytes.task

        // 看门狗：只盯"正文"，思考再多也不算数
        let flag = StreamFlag()
        var watchdog: Task<Void, Never>? = nil
        if firstContentTimeout > 0 {
            let task = bytes.task
            watchdog = Task {
                try? await Task.sleep(nanoseconds: UInt64(firstContentTimeout * 1_000_000_000))
                if !Task.isCancelled && !flag.gotContent {
                    flag.timedOut = true
                    task.cancel()
                }
            }
        }
        defer {
            watchdog?.cancel()
            streamTask = nil
        }

        do {
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let jsonStr = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if jsonStr.isEmpty || jsonStr == "[DONE]" { continue }
                guard let data = jsonStr.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = obj["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let piece = delta["content"] as? String, !piece.isEmpty else { continue }
                flag.gotContent = true
                await onDelta(piece)
            }
        } catch {
            if flag.timedOut { throw STError.firstTokenTimeout }
            throw error
        }
        if flag.timedOut { throw STError.firstTokenTimeout }
    }

    private func payload(_ messages: [LLMMessage], _ maxTokens: Int,
                        model: String, includeReasoning: Bool, stream: Bool) -> [String: Any] {
        var p: [String: Any] = [
            "chat_completion_source": "deepseek",
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "max_tokens": maxTokens,
            "temperature": 1.0,
            "stream": stream,
            // ⚠️ 思考开关（SillyTavern 代理认的是这个字段，不是 thinking）
            // 实测：true → 返回 reasoning_content、语气明显更像她；
            //      false → 1~2 秒出字，但会跳出角色变成"帮你列选项"的助手腔。
            "include_reasoning": includeReasoning,
        ]
        // 思考投入档位：SillyTavern 会把它转发给 DeepSeek（仅在开思考时生效）。
        // 实测同一个 prompt：默认 → 思考 435~917 字；medium → 91~549；low → 72~157。
        if includeReasoning, !reasoningEffort.isEmpty {
            p["reasoning_effort"] = reasoningEffort
        }
        return p
    }
}

/// 流式生成的共享标志（主流程与看门狗线程都会碰，只读写简单 Bool）
/// ⚠️ 2026-10-28 修 R-05：这两个标志被**两个线程**读写 ——
/// 看门狗 Task 写 `timedOut`、读 `gotContent`；流循环相反。裸 Bool 在多线程下没有可见性保证，
/// 极端情况会「正文早就来了还被判超时」。加锁，代价可以忽略。
final class StreamFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _gotContent = false
    private var _timedOut = false

    var gotContent: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _gotContent }
        set { lock.lock(); _gotContent = newValue; lock.unlock() }
    }
    var timedOut: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _timedOut }
        set { lock.lock(); _timedOut = newValue; lock.unlock() }
    }
}

enum STError: LocalizedError {
    case badURL
    case http(Int, String)
    case badResponse
    /// 思考太久、正文一个字没出，已被看门狗切断
    case firstTokenTimeout
    /// ⚠️ 2026-10-28 修 M-01：流结束了但没说完（被截断 / 半路断连）
    case incomplete(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "地址无效"
        case .http(let c, let b): return "HTTP \(c): \(b)"
        case .badResponse: return "响应格式异常"
        case .firstTokenTimeout: return "她想了太久，已自动打断"
        case .incomplete(let why): return "这条没说完（\(why)）"
        }
    }
}
