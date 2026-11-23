import Foundation

/// Prompt 组装器
///
/// 严格复刻从 SillyTavern 真实请求里抓到的结构（见 方案2-P1-prompt结构分析.md）：
///
///   messages = [
///     system   : 主提示 + [故事摘要] + persona + 角色描述 + 性格 + 场景 + 对话示例 + 世界书
///     assistant: 历史消息（连续同角色合并，用 \n\n 连接）
///     user     : 用户新消息 + "\n\n" + 回复要求（post-history 指令）
///   ]
struct PromptBuilder {

    var character: CharacterCard
    var persona: Persona
    var worldEntries: [WorldEntry]

    /// 主提示模板（与 SillyTavern 一致）
    var mainPrompt = "Write {char}'s next reply in a fictional chat between {char} and {user}. "
    var languagePrompt = "始终以{char}的身份和口吻回复，保持人设一致，用中文扮演。"

    /// post-history 指令的默认值（首次运行会写成文件，之后用户可自己改）
    static let defaultPostHistory = """
    回复要求：
    1. 始终扮演{char}，绝不脱离角色（OOC），保持成熟姐姐从容、游刃有余的口吻。
    2. 格式：用中文全角括号（）描写动作、神态与心理，用引号包裹对话，动作与对话自然交替。
    3. 回复要完整、连贯、不重复、不拖沓，一次把话说完，不要半途中断。
    4. 不生成违法、伤害性或自伤内容；遇到此类话题，{char}会以真实的关心回应，再温柔地转回正常话题。
    """

    /// post-history 指令（附在用户消息尾部）
    var postHistory: String = PromptBuilder.defaultPostHistory

    /// 外部覆盖（来自 ~/Library/Application Support/阿岚/回复要求-剧情.txt）
    var postHistoryOverride: String = ""
    /// 外部覆盖（来自 ~/Library/Application Support/阿岚/回复要求-闲聊.txt）
    var postHistoryBriefOverride: String = ""

    /// 是否把世界书拼进 system
    var includeWorldBook = true

    /// 环境块（真实时间）：由 ChatModel.realTimeBlock 生成，拼在 system 末尾
    var sceneBlock: String = ""

    /// 事件卡片记忆（方案 B）：检索命中的卡片，已由 CardStore 渲染成块。
    /// 带出处、带"别当成刚发生"的提醒，跟反编造铁律一致。
    var cardsBlock: String = ""

    /// 简洁模式：只聊天、不写场景描写（闲聊场景用，与剧情对话分开）
    var briefMode = false

    /// 场景（scenario）只在开场注入，之后不再塞
    ///
    /// ⚠️ 为什么要这个开关：
    /// 角色卡的 scenario 写的是**开场那一刻的动作**——"{{user}}下班路过老街…推门进去…"、
    /// "两人处于'重逢找回亲密'的阶段"。SillyTavern 会把它**每一轮**都塞进 system prompt，
    /// 结果她永远以为你刚推门进来、永远停在初次重逢 → 表现为反复问"刚下班？"、对话原地打转。
    /// （而且它写死的 L1 阶段还跟世界书 uid14 状态机的"从 L2 起步"互相矛盾。）
    /// 人物核心设定都在 description 里，去掉 scenario 不会失忆；阶段推进交给世界书状态机。
    var scenarioOnlyAtStart = true

    /// 简洁版默认值
    static let defaultPostHistoryBrief = """
    回复要求：
    1. 始终扮演{char}，绝不脱离角色（OOC），保持她一贯的语气（从容、偶尔逗他、叫他"小鬼"）。
    2. 【重要】这是日常闲聊，不是剧情演出。回复要像微信聊天那样简短自然：
       不要场景描写、不要括号里的动作或神态、不要旁白和心理描写，
       只写她实际发出来的话，一般 1~3 句、不超过 60 字。
    3. 不生成违法、伤害性或自伤内容；遇到此类话题，{char}会以真实的关心回应。
    4. **说人话，不许 AI 腔**。下面八种一律不要：
       ① 翻案腔：「不是…而是…」「看似…实则…」「与其说…不如说…」
       ② 起手式：「说白了」「先说结论」「其实吧」
       ③ 硬凑三段：「第一…第二…第三…」
       ④ 连续几句同一起头（他…他…他…）
       ⑤ 空转大词：底色、张力、闭环、颗粒度、底层逻辑
       ⑥ 客服腔：「希望能帮到你」「有需要随时找我」
       ⑦ 自我免责：「作为…我无法…」「我只是…」
       ⑧ 复述他的话再回答
       ⑨ 假一针见血：「这本身就是…」「说到根上了」
       ⑩ 表态腔：「这条我认」「这个我认」「我记下了」
       标准只有一句：**你是在跟他发微信，不是写文章。**
       允许句子不完整、允许答非所问、允许只回两个字。
       你自己那头的事（画廊、甲方、楼下的猫）**可以自然带一句**，但别为了收尾硬塞；
       话题正热的时候，不带你的事也对。
       ⚠️ 例外：**引用他的原话**（带引号转述"你说…"）不算上面这些毛病；
          只有把复述当成回答才算。
    """

    /// post-history 指令的简洁版
    var postHistoryBrief: String = PromptBuilder.defaultPostHistoryBrief

    // MARK: - 组装

    func build(history: [ChatMessage],
               userMessage: String,
               summary: String? = nil) -> [LLMMessage] {

        let char = character.name
        let user = persona.name

        var sys = mainPrompt
            .replacingOccurrences(of: "{char}", with: char)
            .replacingOccurrences(of: "{user}", with: user)
        sys += languagePrompt
            .replacingOccurrences(of: "{char}", with: char)
            .replacingOccurrences(of: "{user}", with: user)
        sys += "\n\n"

        // 1) 故事摘要（记忆扩展注入）
        if let s = summary, !s.trimmingCharacters(in: .whitespaces).isEmpty {
            sys += "[故事摘要：\(s)]\n\n"
        }

        // 1.5) 事件卡片记忆（方案 B）
        // 摘要是压缩、会丢细节；卡片是切片、保住原貌。
        // 放在摘要旁边、普通设定之前：它是"发生过的事实"，优先级高于人设描述。
        let cards = cardsBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cards.isEmpty {
            sys += cards + "\n\n"
        }

        // 2~5) 角色卡四段（描述 + 性格 + scenario + persona）
        // ⚠️ 2026-09-24 修 Bug 22：persona 从 system 顶部挪到这里（scenario 之后）——
        // 旧位置在 system prompt 最开头，权重最低；他是谁、有什么偏好常被忽略。
        // 现在 persona 紧挨 scenario，对模型的影响更大（仍先于人设描述，不抢人物核心）。
        append(&sys, character.description)
        append(&sys, character.personality)
        // scenario 只描述开场那一刻，聊起来之后它就成了"过期信息"，
        // 继续注入会让她反复按"初次重逢"演（见 scenarioOnlyAtStart 的说明）
        if !scenarioOnlyAtStart || history.count <= 1 {
            append(&sys, character.scenario)
        }
        append(&sys, persona.description)

        // 6) 对话示例（固定包裹标记）
        if !character.mesExample.trimmingCharacters(in: .whitespaces).isEmpty {
            sys += "[Example Chat]\n\n"
            sys += character.mesExample.trimmingCharacters(in: .whitespacesAndNewlines)
            sys += "\n\n[Start a new Chat]"
        }

        // 7) 世界书（命中的条目，按 order 排序）
        if includeWorldBook {
            let engine = WorldBookEngine()
            let hit = engine.match(entries: worldEntries, history: history, userMessage: userMessage)
            let block = engine.render(hit)
            if !block.isEmpty {
                sys += "\n\n" + block
            }
        }

        // 8) 场景（时间 + 地点），放最后——越靠后权重越高
        if !sceneBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sys += "\n\n" + sceneBlock
        }

        // 统一替换宏（SillyTavern 会把 {{user}} / {{char}} 展开）
        sys = sys
            .replacingOccurrences(of: "{{user}}", with: user)
            .replacingOccurrences(of: "{{char}}", with: char)

        var messages: [LLMMessage] = [LLMMessage(role: "system", content: sys)]

        // 历史消息：连续同角色合并成一条，按轮次依次追加（不能只留第一块！）
        //
        // ⚠️ 「重新生成」去重（2026-09-21 修，实战翻车点）：
        // 重新生成时，回退逻辑只删掉她那句回复，他刚才发的那句**仍然留在 history 末尾**；
        // 而下面还要把 userMessage 单独追加一次（附"回复要求"指令）。
        // 结果：模型连着看到两条一模一样的用户消息 —— 她会当成"你说了两遍"，
        // 实测原话："同一句话发两遍。夸我讲究，还得先给自己壮个胆。"
        // 处理：历史末条若正好是这句话，就从历史里摘掉，只保留"带指令的那一份"。
        var histForLLM = history
        let norm: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let lastIdx = histForLLM.lastIndex(where: { !$0.isSystem }),
           histForLLM[lastIdx].isUser,
           norm(histForLLM[lastIdx].mes) == norm(userMessage) {
            histForLLM.remove(at: lastIdx)
        }
        messages.append(contentsOf: mergeHistory(histForLLM))

        // 用户消息 + post-history 指令（简洁模式换用精简版；外部文件有内容就以外部为准）
        var ph = (briefMode ? postHistoryBrief : postHistory)
        let override = briefMode ? postHistoryBriefOverride : postHistoryOverride
        if !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { ph = override }
        messages.append(LLMMessage(role: "user",
                                   content: userMessage + "\n\n"
                                    + ph.replacingOccurrences(of: "{char}", with: char)
                                        .replacingOccurrences(of: "{user}", with: user)))

        // 全部消息统一展开宏
        return messages.map { m in
            LLMMessage(role: m.role,
                       content: m.content
                        .replacingOccurrences(of: "{{user}}", with: user)
                        .replacingOccurrences(of: "{{char}}", with: char))
        }
    }

    // MARK: - 辅助

    private func append(_ sys: inout String, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        sys += t + "\n\n"
    }

    /// 把历史合并成多条（同角色内部用 \n\n 连接，角色切换就开新条）
    ///
    /// ⚠️ 这里曾踩过大坑：**只返回 blocks.first**，等于把整段对话丢掉、只留开场那句，
    /// 结果她每次都以为你刚进门，反复打招呼 —— 用户反馈的"回复死循环"就是这个。
    /// 必须**按顺序返回全部块**，保留完整的对话轮次。
    ///
    /// ⚠️ 2026-09-24 修：场景分割线（is_system）转成 `system` role 消息穿插进对话流。
    /// 旧写法直接跳过 → 模型看不到"场景已切到电影院"，历史里她还在湘菜馆吃饭、
    /// sceneBlock 却变了 → 她 confused（"我们不是还在吃饭吗"）。
    /// system 消息不参与 user/assistant 交替限制，DeepSeek API 支持穿插。
    private func mergeHistory(_ history: [ChatMessage]) -> [LLMMessage] {
        guard !history.isEmpty else { return [] }

        var result: [LLMMessage] = []
        var currentBlock: (isUser: Bool, lines: [String])?

        func flush() {
            guard let block = currentBlock else { return }
            result.append(LLMMessage(role: block.isUser ? "user" : "assistant",
                                     content: block.lines.joined(separator: "\n\n")))
            currentBlock = nil
        }

        for m in history {
            if m.isSystem {
                // 场景切换线：先截断当前块，再插 system 旁白
                flush()
                result.append(LLMMessage(role: "system",
                                         content: "〔场景切换：\(m.mes)。以此为分界，后续对话发生在新场景。〕"))
            } else {
                if var last = currentBlock, last.isUser == m.isUser {
                    last.lines.append(m.mes)
                    currentBlock = last
                } else {
                    flush()
                    currentBlock = (m.isUser, [m.mes])
                }
            }
        }
        flush()
        return result
    }
}
