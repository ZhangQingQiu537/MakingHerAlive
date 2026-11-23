import Foundation

/// 世界书匹配引擎
///
/// 复刻 SillyTavern 的核心规则（只做我们实际用得到的子集）：
/// - constant 条目：无条件注入（如好感度状态机）
/// - 关键词条目：扫描最近 N 条消息，命中 keys 才注入
/// - 按 order 升序排列
///
/// 说明：我们只有 15 条世界书，规则不复杂，先做够用的子集，
/// 后续用"与网页版输出对比"来校准。
struct WorldBookEngine {

    /// 扫描深度：最近多少条消息参与关键词匹配
    var scanDepth: Int = 2

    func match(entries: [WorldEntry], history: [ChatMessage], userMessage: String) -> [WorldEntry] {
        // 参与匹配的文本 = 最近 scanDepth 条历史 + 当前用户输入
        let recent = history.suffix(scanDepth).map { $0.mes }
        let haystack = (recent + [userMessage]).joined(separator: "\n").lowercased()

        var hit: [WorldEntry] = []
        for e in entries {
            if e.disable == true { continue }

            if e.constant {
                hit.append(e)
                continue
            }

            // 关键词命中（任一 key 出现在文本里即算命中）
            let matched = e.key.contains { key in
                let k = key.trimmingCharacters(in: .whitespaces)
                return !k.isEmpty && haystack.contains(k.lowercased())
            }
            if matched { hit.append(e) }
        }

        // 按 order 升序
        return hit.sorted { $0.order < $1.order }
    }

    /// 把命中的条目拼成一段文本
    func render(_ entries: [WorldEntry]) -> String {
        entries
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
