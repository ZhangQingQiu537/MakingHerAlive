import Foundation

/// 核心档案（2026-11-07 · 记忆系统第一层）
///
/// 为什么要有它：现在的记忆全靠"检索命中"—— 今天没命中"他在考试"，她就不知道；
/// 明天没命中"猫哥"，她就问"这是谁"。**有些事必须一直摆在眼前，不能靠运气想起来。**
///
/// 对应业界做法（Letta 的 core memory / Mem0 的 user profile）：
/// 几百字、每轮注入、永不检索丢失。
///
/// 文件：`~/Library/Application Support/阿岚/核心档案.json`
/// 结构：{"sections":[{"title":"他","lines":["26 岁，上海，做产品","对花粉过敏"]}]}
/// 他在控制台/文本编辑器里改，改完 App 下一轮自动读新内容。
enum CoreProfile {

    struct Section: Codable {
        var title: String
        var lines: [String]
    }
    struct Doc: Codable {
        var sections: [Section] = []
    }

    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("核心档案.json")
    }

    static func load() -> Doc {
        SafeDecode.load(Doc.self, from: file, label: "核心档案") ?? Doc()
    }

    static func save(_ d: Doc) {
        if let data = try? JSONEncoder().encode(d) { _ = AtomicWrite.write(data, to: file) }
    }

    /// 注入给模型的块（空档案返回 ""）
    static func block() -> String {
        let d = load()
        let parts = d.sections.compactMap { s -> String? in
            let lines = s.lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !lines.isEmpty else { return nil }
            return "【\(s.title)】\n" + lines.map { "· " + $0 }.joined(separator: "\n")
        }
        guard !parts.isEmpty else { return "" }
        // 2026-11-23（2A）：档案超过 30 天就提醒自己"可能过期"，别当铁律
        var stale = ""
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let m = attrs[.modificationDate] as? Date {
            let days = Int(Date().timeIntervalSince(m) / 86400)
            if days >= 30 { stale = "（这份档案是 \(days) 天前记的，有些事可能变了；拿不准就问他）\n" }
        }
        return """

        【关于他、关于我们 —— 这些你一直知道，不用问、不用确认】
        \(stale)
        \(parts.joined(separator: "\n"))
        · 上面对话里没提到时，也当作你知道；不要问"你是做什么的""我们怎么认识的"。
        · 这些不是"设定"，是你和他相处里记住的事。
        """
    }

    /// 首次运行播种（只在文件不存在时写一次，之后由他自己改）
    static func seedIfNeeded() {
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        let d = Doc(sections: [
            Section(title: "他", lines: [
                "26 岁，上海，做产品",
                "对花粉过敏"
            ]),
            Section(title: "他在忙的事", lines: [
                "工作：在一家公司做产品，最近在赶一个上线",
                "周末偶尔帮朋友的店看半天店"
            ]),
            Section(title: "我们", lines: [
                "我有一份自己的事在做；手上的方案改到第八版，对方还没回音",
                "楼下有只橘猫，他起名叫猫哥"
            ])
        ])
        save(d)
    }
}
