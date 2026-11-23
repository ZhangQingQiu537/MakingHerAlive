import Foundation

/// "这句话需不需要她真的动手"—— 由模型判断，不再靠关键词表（2026-10-29）
///
/// 之前 `agentKeywordHit` 是一张写死的表（"帮我/整理一下/弄一下"…）：
/// 命中就派活、不命中就永远学不会。她要是有独立判断，这一步就不能是字符串匹配。
///
/// 设计要点：
/// · 用便宜模型（deepseek-flash）+ 关思考 + 200 tokens，0.3~0.6 秒，与回复并行不阻塞
/// · **默认沉默**：拿不准就不开口。宁可少帮一次，也不要做成"要我帮你弄吗"复读机
/// · 只认"不查/不看就办不成"的事；情绪、抱怨、回忆、闲聊一律不派
/// · 判定理由写进日志，方便他调口径
enum TaskIntentJudge {

    struct Verdict {
        let need: Bool
        let what: String     // 要做的事，一句话
        let why: String      // 为什么这么判（给他看）
    }

    private static let system = """
    你在判断：下面这句话，**需不需要真的动手去做一件事**（读文件、查资料、整理材料、写东西、跑程序）。

    只认"不查不看就办不成"的：
      · 要 → "帮我把桌面那份周报汇总成表格"、"查一下某高校今年的复试线"、"把这段录音转成文字"
      · 不要 → "我今天累死了"、"这报告真烦"、"你还记得我面试吗"、"随便聊聊"
      · 不要 → 只是表达情绪、抱怨、回忆、问她的看法、开玩笑
      · **拿不准 → 不要**

    只输出一行 JSON，不要解释：
    {"need": true/false, "what": "要做的事（≤20字，不需要就空字符串）", "why": "≤15字理由"}
    """

    static func judge(_ text: String, recent: [String]) async -> Verdict? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 4 else { return nil }

        let ctx = recent.suffix(4).joined(separator: "\n")
        let user = """
        最近几轮（供参考，判断只看最后一句）：
        \(ctx.isEmpty ? "（无）" : ctx)

        最后一句：
        \(t)
        """
        guard let raw = try? await DeepSeekClient.generate(
                messages: [LLMMessage(role: "system", content: system),
                           LLMMessage(role: "user", content: user)],
                maxTokens: 200, model: "deepseek-flash", includeReasoning: false),
              let o = DSHTaskRunner.extractJSON(raw) else { return nil }

        let need = (o["need"] as? Bool) ?? (o["need"] as? String == "true")
        let what = (o["what"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let why = (o["why"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Verdict(need: need, what: what, why: why)
    }
}
