import Foundation

/// App 自己的配置（与网页版完全隔离）
///
/// 存 `~/Library/Application Support/阿岚/config.json`，
/// 网页版怎么改都不影响这里。
struct AppConfig: Codable {

    /// 固定使用的用户 persona（key = SillyTavern 的头像文件名）
    /// 注意：是**指定的这一张**，不是网页版"当前选中的那张"
    var personaKey: String = ""
    var personaName: String = "小林"

    /// 使用哪张角色卡（填角色名，可切换）
    ///   "阿岚"        → 剧情版（绑世界书，含 L1-L4 状态机、画廊与母亲那条暗线）
    ///   "阿岚（闲聊）" → 闲聊版（不绑世界书，纯陪聊，不推进剧情）
    var characterName: String = "阿岚"

    /// 聊天记录存在哪个目录（**与角色卡解耦**，切换角色卡不会丢历史）
    var chatDir: String = "阿岚"

    /// App 专属的聊天文件名（与网页版的"闲聊"分开）
    var chatFile: String = "原生"

    /// 简洁模式：只聊天、不写场景描写（App 默认开启，与网页版主对话分开）
    var briefMode: Bool = true

    /// 界面模式：`chat` = 对话气泡；`galgame` = 恋爱游戏（全屏背景 + 立绘 + 对话框）
    ///
    /// ⚠️ 两个界面**共用同一个 ChatModel**，所以切换只是换渲染层：
    /// 不中断流式输出、不丢记忆/场景/阶段。这里只记住"上次用哪个"。
    var uiMode: String = "chat"

    var model: String = "deepseek-v4-flash"

    /// ⭐ 2026-10-26：外挂任务开关（说"帮我…"时是否派给 DSH）
    /// 可空 —— 老配置文件没有这个键也能解码
    var agentTasksEnabled: Bool? = nil

    /// ⭐ 2026-10-26：她会不会主动开口（空闲 3h + 19:00-22:30 + 每天 1 条）
    var proactiveEnabled: Bool? = nil

    /// ⚠️ 思考与正文**共用**这个额度（DeepSeek 的实际行为）—— 这是"正文被吃光"的根源。
    /// 实测（2026-09-25，同一道难题）：8192 → 思考吃满 8192、正文 0 字、finish=length；
    ///   32768 → 思考 27419、正文 2638 字、finish=stop。
    /// 用户明确「输出质量最重要，思考久没关系」→ 现在给到 **65536**：
    /// 让思考跑得完，正文仍有余量。实测 API 到 131072 都接受，这里留一倍安全余量。
    /// 注意这只是**上限**，正常轮次实际思考只有几十~几百 token，不会因此变慢。
    var maxTokens: Int = 65536
    var temperature: Double = 1.0

    /// 思考能力（开＝她先想再说，语气自然；代价是慢 5~10 秒）
    var includeReasoning: Bool = true

    /// 思考投入档位：low / medium / high（空 = 不指定、用模型默认）
    /// 实测同一道难题：medium 思考 27419 token / 145s，low 11311 token / 65s。
    /// ⚠️ 用户 2026-09-25 定：**保持 medium 不动**——宁可多等，也要输出质量。
    var reasoningEffort: String = "medium"

    /// 「思考超时」保护：这么久还没吐出第一个正文，就自动切断、改用"直接说"重说一遍。
    /// ⚠️ 2026-09-25 从 35s 提到 **150s**：实测 medium 档复杂轮次思考要 145 秒才出正文，
    ///   原来 35 秒就把思考切断了 —— 等于白等 35 秒再降级重来，用户感知就是"被吃光"。
    ///   既然质量优先、思考久可以接受，保护网就该退到真正异常（卡死）才触发。
    /// 0 = 关闭保护。
    var thinkingTimeout: Double = 150

    /// ⭐ 脱离 SillyTavern：true = LLM 直连 DeepSeek（Key 在 Keychain）、数据走自有存储；
    /// false = 维持现状走 ST 代理。切换可逆，出问题改回 false 即可。
    /// ⚠️ 2026-10-28 修 H-01（审查报告）：默认值必须是 true。
    ///    原来默认 false，而没有 config.json 的全新安装会走进"网页版路径已废弃"分支，
    ///    boot 直接失败（ready=false）——新装打不开。
    var useDirect: Bool = true

    // MARK: - 她的声音（TTS）
    // 决定（2026-09-23）：A2 火山引擎；B 用用户自己设计的定制音色（做好后填 voiceId）；
    // C2 只有剧情模式发声；E 微信场景不发声。

    /// TTS 总开关（界面顶栏可切）。默认关。
    var voiceEnabled: Bool = false
    /// 引擎：`builtin`（macOS 内置，先顶用）/ `volcano`（火山引擎，等用户音色 ID）
    var voiceEngine: String = "builtin"
    /// 联网搜索总开关（博查）：识别《作品名》+ 自主判断，默认开
    var webSearchEnabled: Bool = true
    /// 火山音色 ID（用户在火山引擎音色设计做好后给我，填这里）
    var voiceId: String = ""
    /// 火山语音应用 APP ID（数值，语音应用详情页；2026-09-23 实测 token 已认证通过，就差它）
    var volcanoAppId: String = ""
    /// ⭐ 新版控制台的 **API Key**（控制台>API Key管理 创建）—— v3 WebSocket API 用这个。
    /// 与旧的 Access Token 是两种东西；填了这个就优先用新版鉴权。
    var volcanoApiKey: String = ""
    /// 资源 ID：seed-tts-2.0（语音合成2.0）/ seed-icl-2.0（声音复刻，S_ 开头的音色走这个）
    var volcanoResourceId: String = "seed-tts-2.0"

    /// TTS 音频格式：`mp3`（默认，文件模式）/ `pcm`（流式模式，首字延迟 ~400ms）
    ///
    /// ⭐ 2026-09-24 PCM 流式：火山按合成进度切片 EV_TTS_RESPONSE 帧，mp3 模式下一帧近完整，
    /// 优化空间小；pcm 模式每帧是裸 float32 字节，Swift 端可以 scheduleBuffer 排队播放。
    /// 切换后会**自动清空 VoiceCache**（mp3/pcm 字节不通用）。
    var voiceFormat: String = "pcm"

    // MARK: - 读写

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Companion", isDirectory: true)
    }

    static var fileURL: URL { dir.appendingPathComponent("config.json") }

    // MARK: - 编解码

    init() {}

    enum CodingKeys: String, CodingKey {
        case personaKey, personaName, characterName, chatDir, chatFile, briefMode, uiMode
        case model, maxTokens, temperature, includeReasoning, reasoningEffort, thinkingTimeout
        case useDirect
        case voiceEnabled, voiceEngine, voiceId
        case volcanoAppId
        case volcanoApiKey, volcanoResourceId
        case voiceFormat
        case webSearchEnabled
        // ⚠️ 2026-10-28 修 M-08（审查报告）：这两个开关以前**根本不在 CodingKeys 里**，
        //    所以 config.json 里写 false 也读不进来（恒 nil），调用处 `?? true` 又把 nil 当开。
        //    → 用户关不掉主动开口 / 派活。
        case agentTasksEnabled, proactiveEnabled
    }

    /// ⚠️ 容错解码：老配置文件里没有新加的字段。
    /// 用合成的 Codable 实现时，**缺一个字段就整份解码失败** → 用户的配置会悄悄全部回到默认值。
    /// 所以这里逐字段 decodeIfPresent，缺谁补谁的默认值。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        // try? 与可选值会自动展平，直接 ?? 兜底
        func get<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: k)) ?? fallback
        }
        personaKey = get(.personaKey, d.personaKey)
        personaName = get(.personaName, d.personaName)
        characterName = get(.characterName, d.characterName)
        chatDir = get(.chatDir, d.chatDir)
        chatFile = get(.chatFile, d.chatFile)
        briefMode = get(.briefMode, d.briefMode)
        uiMode = get(.uiMode, d.uiMode)
        model = get(.model, d.model)
        maxTokens = get(.maxTokens, d.maxTokens)
        temperature = get(.temperature, d.temperature)
        includeReasoning = get(.includeReasoning, d.includeReasoning)
        reasoningEffort = get(.reasoningEffort, d.reasoningEffort)
        thinkingTimeout = get(.thinkingTimeout, d.thinkingTimeout)
        useDirect = get(.useDirect, d.useDirect)
        voiceEnabled = get(.voiceEnabled, d.voiceEnabled)
        voiceEngine = get(.voiceEngine, d.voiceEngine)
        voiceId = get(.voiceId, d.voiceId)
        volcanoAppId = get(.volcanoAppId, d.volcanoAppId)
        volcanoApiKey = get(.volcanoApiKey, d.volcanoApiKey)
        volcanoResourceId = get(.volcanoResourceId, d.volcanoResourceId)
        voiceFormat = get(.voiceFormat, d.voiceFormat)
        webSearchEnabled = get(.webSearchEnabled, d.webSearchEnabled)
        agentTasksEnabled = get(.agentTasksEnabled, d.agentTasksEnabled)
        proactiveEnabled = get(.proactiveEnabled, d.proactiveEnabled)
    }

    // MARK: 「回复要求」外部文件（用户可在控制台里直接改，不用改代码）

    static var replyBriefURL: URL { dir.appendingPathComponent("回复要求-闲聊.txt") }
    static var replyStoryURL: URL { dir.appendingPathComponent("回复要求-剧情.txt") }

    /// 首次运行把默认文案写成文件；已存在就不动（用户改过的要保留）
    static func ensureReplyRuleFiles(brief: String, story: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: replyBriefURL.path) {
            try? brief.write(to: replyBriefURL, atomically: true, encoding: .utf8)
        }
        if !FileManager.default.fileExists(atPath: replyStoryURL.path) {
            try? story.write(to: replyStoryURL, atomically: true, encoding: .utf8)
        }
    }

    static func loadReplyRule(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func load() -> AppConfig {
        guard let d = try? Data(contentsOf: fileURL),
              let c = try? JSONDecoder().decode(AppConfig.self, from: d) else {
            return AppConfig()
        }
        return c
    }

    /// ⚠️ **必须保留未知字段**（2026-09-24 修 Bug 9）：
    /// 这份 config.json 是主 App 与控制台共用的，控制台字段可能未来比主 App 多。
    /// JSONEncoder 全量编码会清掉所有 AppConfig 没声明的字段 —— 比如将来控制台加了 `consoleOnly`，
    /// App 一启动一保存，控制台的字段就被静默吞掉。**两端不对称**就是设计陷阱。
    /// 正确做法：先读原文件成字典，只覆盖认识的键（与控制台 Backend.save 一致）。
    func save() {
        try? FileManager.default.createDirectory(at: AppConfig.dir, withIntermediateDirectories: true)
        var dict: [String: Any]
        if let d = try? Data(contentsOf: AppConfig.fileURL),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            dict = o
        } else {
            dict = [:]
        }
        dict["personaKey"] = personaKey
        dict["personaName"] = personaName
        dict["characterName"] = characterName
        dict["chatDir"] = chatDir
        dict["chatFile"] = chatFile
        dict["briefMode"] = briefMode
        dict["uiMode"] = uiMode
        dict["model"] = model
        dict["maxTokens"] = maxTokens
        dict["temperature"] = temperature
        dict["includeReasoning"] = includeReasoning
        dict["reasoningEffort"] = reasoningEffort
        dict["thinkingTimeout"] = thinkingTimeout
        dict["useDirect"] = useDirect
        dict["voiceEnabled"] = voiceEnabled
        dict["voiceEngine"] = voiceEngine
        dict["voiceId"] = voiceId
        dict["volcanoAppId"] = volcanoAppId
        dict["volcanoApiKey"] = volcanoApiKey
        dict["volcanoResourceId"] = volcanoResourceId
        dict["voiceFormat"] = voiceFormat
        dict["webSearchEnabled"] = webSearchEnabled
        // 只有用户明确设过才写回去，避免把 nil 变成 true 覆盖掉控制台的值
        if let v = agentTasksEnabled { dict["agentTasksEnabled"] = v }
        if let v = proactiveEnabled { dict["proactiveEnabled"] = v }
        guard let e = try? JSONSerialization.data(withJSONObject: dict,
                                                  options: [.prettyPrinted, .sortedKeys]) else { return }
        try? e.write(to: AppConfig.fileURL)
    }
}
