import Foundation

/// 直连 DeepSeek（脱离 SillyTavern 代理的第一步）。
///
/// DeepSeek 是 OpenAI 兼容协议：`POST https://api.deepseek.com/chat/completions`。
/// payload 与走 ST 代理时**保持一致**（include_reasoning / reasoning_effort 原样透传），
/// 这样切换直连后她的行为不变。
///
/// ⚠️ 模型名映射：ST 里的 `deepseek-v4-flash` 是别名，DeepSeek 官方模型只有
///    `deepseek-flash` 和 `deepseek-v4-pro`（2026-09-23 实测 /models 确认）。
enum DeepSeekClient {

    /// ⚠️ 2026-10-28：允许用环境变量改接口地址（只给测试用）。
    /// 之前是 `static let` 写死，导致 Kimi 那套 SSE 测试根本连不到本地 mock，
    /// 拿到的是真接口的 401 —— 三条断言"通过"其实是假通过。
    static var endpoint: String {
        if let o = ProcessInfo.processInfo.environment["NRY_LLM_ENDPOINT"], !o.isEmpty {
            return o
        }
        return "https://api.deepseek.com/chat/completions"
    }

    /// ST 配置名 → DeepSeek 官方模型名
    static func directModel(_ configured: String) -> String {
        configured.contains("pro") ? "deepseek-v4-pro" : "deepseek-flash"
    }

    private static func makeRequest(messages: [LLMMessage], maxTokens: Int,
                                    model: String, includeReasoning: Bool,
                                    stream: Bool, timeout: TimeInterval,
                                    /// 本轮指定的思考投入，nil = 用全局配置（STClient.shared.reasoningEffort）
                                    reasoningEffort: String? = nil) throws -> URLRequest {
        guard let key = KeychainStore.loadKey(), !key.isEmpty else {
            throw STError.http(-1, "DeepSeek Key 未配置（Keychain 里没有）")
        }
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var p: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "max_tokens": maxTokens,
            "temperature": 1.0,
            "stream": stream,
        ]
        if includeReasoning {
            p["include_reasoning"] = true
            // 本轮指定的思考投入优先（自适应：注入大时降 low），否则用全局配置
            let effort = reasoningEffort ?? STClient.shared.reasoningEffort
            if !effort.isEmpty {
                p["reasoning_effort"] = effort
            }
        } else {
            // ⚠️ DeepSeek 官方 API 不认 include_reasoning: false（2026-09-24 实测）
            // 只传 false 会被忽略，思考照常跑 → maxTokens=500 时思考吃光额度 → 正文为空
            // 真正禁用思考要传 thinking: {type: "disabled"}
            p["thinking"] = ["type": "disabled"]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: p)
        return req
    }

    // MARK: - 非流式

    /// 一次生成的完整结果（正文 + 思考原文）
    ///
    /// ⭐ 2026-09-25：调试"模型为什么这么判"必须拿到 reasoning_content，
    /// 原来的 `generate` 只回正文，思考过程全丢了。
    struct LLMResult {
        var content: String = ""
        var reasoning: String = ""
    }

    static func generate(messages: [LLMMessage], maxTokens: Int = 8192,
                         model: String = "deepseek-flash",
                         includeReasoning: Bool = true) async throws -> String {
        try await generateFull(messages: messages, maxTokens: maxTokens, model: model,
                               includeReasoning: includeReasoning).content
    }

    /// 同 generate，但连思考原文一起返回
    static func generateFull(messages: [LLMMessage], maxTokens: Int = 8192,
                             model: String = "deepseek-flash",
                             includeReasoning: Bool = true) async throws -> LLMResult {
        let req = try makeRequest(messages: messages, maxTokens: maxTokens, model: model,
                                  includeReasoning: includeReasoning, stream: false, timeout: 180)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw STError.http(code, String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any] else {
            throw STError.badResponse
        }
        var r = LLMResult()
        r.content = ((msg["content"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // DeepSeek 官方字段：message.reasoning_content（include_reasoning=true 时才有）
        r.reasoning = (msg["reasoning_content"] as? String) ?? ""
        return r
    }

    // MARK: - 流式（SSE 解析与 STClient.generateStream 同构）

    /// ⚠️ 2026-10-28 修 H-03（审查报告）：直连模式以前没有把 URLSessionTask 暴露出去，
    /// 「停止」按钮调 `STClient.cancelCurrentStream()` 时 `streamTask` 是 nil ——
    /// 网络流照跑，取消后还能把整段回复落盘。这里留一个当前流句柄供取消。
    ///
    /// ⚠️ 注意：锁只能在**同步函数**里用。直接在 async 上下文里 `lock()/unlock()`
    /// 会触发 Swift 6 的 "unavailable from asynchronous contexts" 警告，所以包成小盒子。
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        func set(_ t: URLSessionTask?) { lock.lock(); task = t; lock.unlock() }
        func get() -> URLSessionTask? { lock.lock(); defer { lock.unlock() }; return task }
    }
    private static let taskBox = TaskBox()

    static func cancelCurrent() {
        taskBox.get()?.cancel()
    }

    static func generateStream(messages: [LLMMessage],
                               maxTokens: Int = 8192,
                               model: String = "deepseek-flash",
                               includeReasoning: Bool = true,
                      firstContentTimeout: TimeInterval = 0,
                      onDelta: @escaping @MainActor (String) -> Void,
                      /// 思考片段回调（reasoning_content）。传了就会逐段回调，
                      /// 用来把"她为什么这么说"留进诊断日志；不传就完全没开销。
                      onReasoning: (@MainActor (String) -> Void)? = nil,
                      /// ⚠️ 2026-10-28 修 M-01（审查报告）：流结束时的完成状态。
                      /// 以前不管流是正常结束、被 max_tokens 截断、还是半路断网，
                      /// 都当成功交付 —— 截断的句子就这么发给他了。
                      /// 现在回调一个完成标记：stop / length / eof（没收到 [DONE]）
                      onFinish: (@MainActor (String) -> Void)? = nil) async throws {
        let req = try makeRequest(messages: messages, maxTokens: maxTokens, model: model,
                                  includeReasoning: includeReasoning, stream: true, timeout: 300)
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        // 登记当前流，供「停止」取消；退出时无论成功失败都清掉
        Self.taskBox.set(bytes.task)
        defer { Self.taskBox.set(nil) }
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw STError.http(code, "DeepSeek 流式请求失败")
        }

        var sawDone = false
        var finishReason = ""
        var badChunks = 0     // 解析不了的 SSE 块（真正损坏，不是"没有 delta"的心跳）

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
        defer { watchdog?.cancel() }

        do {
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let jsonStr = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if jsonStr == "[DONE]" { sawDone = true; continue }
                if jsonStr.isEmpty { continue }
                guard let data = jsonStr.data(using: .utf8) else { badChunks += 1; continue }
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    badChunks += 1      // 坏块：记下来，别静默当成正常结束
                    continue
                }
                // 有的服务商会在末尾发一个只带 usage、没有 delta 的块 —— 那是正常的
                guard let choices = obj["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any] else { continue }
                // 完成原因（最后一条 delta 里带）：stop / length / content_filter …
                if let fr = choices.first?["finish_reason"] as? String, !fr.isEmpty {
                    finishReason = fr
                }
                // 思考原文（reasoning_content）与正文（content）是两个独立字段，
                // 同一段 delta 一般只有其一，这里分开取、互不影响。
                if let rp = delta["reasoning_content"] as? String, !rp.isEmpty {
                    if let cb = onReasoning { await cb(rp) }
                }
                guard let piece = delta["content"] as? String, !piece.isEmpty else { continue }
                flag.gotContent = true
                await onDelta(piece)
            }
        } catch {
            if flag.timedOut { throw STError.firstTokenTimeout }
            throw error
        }
        if flag.timedOut { throw STError.firstTokenTimeout }

        // 收尾：告诉调用方这次到底说完没有
        let verdict: String
        if badChunks > 0 {
            verdict = "badchunk"             // 流里有坏块 → 这条不能当完整
        } else if !finishReason.isEmpty {
            verdict = finishReason           // "stop" = 正常；"length" = 被截断
        } else {
            verdict = sawDone ? "stop" : "eof"   // 连 [DONE] 都没有 = 半路断了
        }
        if let cb = onFinish { await cb(verdict) }
        // 没正常结束就抛出去：调用方据此保留半截正文 + 给"重试"，而不是当成完整回复落库
        if verdict != "stop" {
            throw STError.incomplete(verdict)
        }
    }

    /// 带工具的非流式一轮（2026-10-29）
    /// 返回：模型说的话 + 它想调的工具有哪些。**不流式** —— 工具轮本来就看不到字。
    static func generateWithTools(messages: [LLMMessage], tools: [[String: Any]],
                                  model: String = "deepseek-flash",
                                  maxTokens: Int = 800) async throws
        -> (content: String, calls: [ToolLoop.Call]) {
        guard let key = KeychainStore.loadKey(), !key.isEmpty else {
            throw STError.http(-1, "DeepSeek Key 未配置")
        }
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let msgs: [[String: Any]] = messages.map { m in
            if m.role == "tool" {
                return ["role": "tool", "content": m.content, "tool_call_id": m.toolCallId ?? ""]
            }
            return ["role": m.role, "content": m.content]
        }
        let payload: [String: Any] = ["model": model, "messages": msgs,
                                      "tools": tools, "tool_choice": "auto",
                                      "max_tokens": maxTokens, "stream": false]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw STError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, "工具轮失败")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any] else {
            throw STError.badResponse
        }
        let content = (msg["content"] as? String) ?? ""
        var calls: [ToolLoop.Call] = []
        if let tc = msg["tool_calls"] as? [[String: Any]] {
            for c in tc {
                let id = (c["id"] as? String) ?? UUID().uuidString
                guard let fn = c["function"] as? [String: Any],
                      let name = fn["name"] as? String else { continue }
                var args: [String: Any] = [:]
                if let a = fn["arguments"] as? String,
                   let d = a.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    args = o
                }
                calls.append(ToolLoop.Call(id: id, name: name, args: args))
            }
        }
        return (content, calls)
    }

}
