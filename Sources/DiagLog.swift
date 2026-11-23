import Foundation

/// 判断依据日志：阶段为什么变、情绪为什么这么判
///
/// 写在 `~/Library/Application Support/阿岚/诊断日志.json`，控制台里能翻。
///
/// ⚠️ 为什么需要它（2026-09-25 用户原话：「麻了，不知道哪儿说错话了掉阶段了」）：
/// 阶段机制已删除（2026-10-26），这条只作为历史说明保留。
/// 原来两者都只在运行日志里留一行，而运行日志**会轮转**、且**不带"是哪句话触发的"**，
/// 于是用户只看到"怎么突然 L2 了"，完全没法回溯。
/// 现在每次变更都把「时间 / 从哪到哪 / 原因 / 触发那句话」存下来。
struct DiagEvent: Codable, Identifiable, Hashable {
    /// HH:mm:ss（当天内够用，控制台里最关心"刚才那一下"）
    var at: String = ""
    /// "stage" = 阶段变更；"mood" = 情绪判定
    var kind: String = ""
    /// 阶段："L3"；情绪：上一段的情绪（可为空）
    var from: String = ""
    /// 阶段："L2"；情绪："smile"
    var to: String = ""
    /// 阶段："检测降级（连续 3 次判 L2）" / "三振出局（说好去电影院，他却去了画廊）"
    /// 情绪：命中的关键词，如「啧」；没命中时写"（无命中 → 落 calm）"
    var reason: String = ""
    /// 触发那句话（他说的，或她刚回的那句）
    var trigger: String = ""

    var id: String { "\(at)|\(kind)|\(to)|\(reason)|\(trigger.prefix(12))" }

    var isDrop: Bool {
        guard kind == "stage" else { return false }
        let a = Int(from.replacingOccurrences(of: "L", with: "")) ?? 0
        let b = Int(to.replacingOccurrences(of: "L", with: "")) ?? 0
        return b < a
    }
}

/// 一次 LLM 调用的**完整思考过程**（调试用）
///
/// ⚠️ 为什么单独记一份（2026-09-25）：用户要的不只是"阶段变了"，而是
/// **"模型凭什么这么判"** —— 那就必须把 reasoning_content（思考原文）留下来。
/// 运行日志只记一行结论，且会轮转，所以思考过程单独存这里。
struct ThinkEvent: Codable, Identifiable, Hashable {
    var at: String = ""
    /// 用途："阶段检测" / "主对话" / "事件抽卡" / "记忆摘要" / "联网判断" / "地点检测"
    var task: String = ""
    /// 耗时（秒）
    var seconds: Double = 0
    /// 模型输入的提示词（截断保存，太长只留前 400 字）
    var prompt: String = ""
    /// ⭐ 思考过程原文（reasoning_content）
    var reasoning: String = ""
    /// 最终输出
    var output: String = ""

    var id: String { "\(at)|\(task)|\(output.prefix(16))" }
}

struct DiagLog: Codable {
    /// 阶段变更（最近的在前）
    var stageEvents: [DiagEvent] = []
    /// 情绪判定（最近的在前）
    var moodEvents: [DiagEvent] = []
    /// 模型思考全流程（最近的在前）
    var thinkEvents: [ThinkEvent] = []

    static let stageCap = 40
    static let moodCap = 60
    static let thinkCap = 30

    // MARK: - 路径

    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("诊断日志.json")
    }

    // MARK: - 读写

    static func load() -> DiagLog {
        guard let d = try? Data(contentsOf: file),
              let l = try? JSONDecoder().decode(DiagLog.self, from: d) else { return DiagLog() }
        return l
    }

    func save() {
        let dir = DiagLog.file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(self).write(to: DiagLog.file)
    }

    // MARK: - 记录

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f
    }()

    /// 记一条（自动截断到上限，最近的在前）
    static func record(_ ev: DiagEvent) {
        var log = load()
        var e = ev
        if e.at.isEmpty { e.at = fmt.string(from: Date()) }
        // 同样内容短时间内重复（比如连续几轮同一个情绪）就不再堆了
        switch e.kind {
        case "stage":
            if let first = log.stageEvents.first,
               first.to == e.to, first.reason == e.reason { return }
            log.stageEvents.insert(e, at: 0)
            log.stageEvents = Array(log.stageEvents.prefix(Self.stageCap))
        default:
            if let first = log.moodEvents.first,
               first.to == e.to, first.reason == e.reason { return }
            log.moodEvents.insert(e, at: 0)
            log.moodEvents = Array(log.moodEvents.prefix(Self.moodCap))
        }
        log.save()
    }

    /// 记一次完整思考（调试用：看模型到底怎么想的）
    static func recordThink(_ ev: ThinkEvent) {
        var log = load()
        var e = ev
        if e.at.isEmpty { e.at = fmt.string(from: Date()) }
        // ⚠️ 截断上限别设太小：2026-09-25 设成 3000 时，阶段检测的思考（约 5k~8k 字）
        // 被砍掉一半，用户在控制台看到的就是"话说到一半没了"（还以为是模型被截断了）。
        // 12000 能完整装下 medium 档绝大多数思考，30 条 × 12k ≈ 360KB，可读。
        e.reasoning = String(e.reasoning.prefix(12000))
        log.thinkEvents.insert(e, at: 0)
        log.thinkEvents = Array(log.thinkEvents.prefix(Self.thinkCap))
        log.save()
    }

    /// 触发句太长会撑爆界面，统一截一下
    static func clip(_ s: String, _ n: Int = 60) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return t.count > n ? String(t.prefix(n)) + "…" : t
    }
}
