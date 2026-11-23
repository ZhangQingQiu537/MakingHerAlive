import Foundation

/// ⭐ 2026-10-26：心情（替代 L1-L4 阶段）
///
/// 关系固定（恋人），不靠阶段推进。变的是**她今天怎么样**：
/// 主心情一根 + 烦躁 / 亲近两根。
///
/// 参数来自 DSH fish-mood 的实测：
/// - 基线 70（平时不冷不热）
/// - 12 小时半衰（隔一夜还有余温）
/// - 判定值 ÷3 落地（÷2 会长期贴顶，永远满格反而假）
struct MoodStore: Codable {

    var mood: Double = 70          // 0-100
    var irritability: Double = 20  // 0-100，越高越容易怼
    var closeness: Double = 60     // 0-100，越高越想多说两句
    var updatedAt: String = ""

    /// 行为分档（设计 v3）：她不会因为我们写了台词而亲近，只会因为好感够
    var band: String {
        if closeness < 30 { return "冷淡：句子短、不主动开口、不撒娇、不给看东西" }
        if closeness < 60 { return "正常：有距离但有温度，不黏" }
        return "亲近：会主动、会念叨、会拿东西给他看"
    }

    // MARK: - 落盘

    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("心情.json")
    }

    static func load() -> MoodStore {
        guard let d = try? Data(contentsOf: file),
              let m = try? JSONDecoder().decode(MoodStore.self, from: d) else {
            return MoodStore()
        }
        var copy = m
        copy.decay()
        return copy
    }

    func save() {
        var copy = self
        copy.updatedAt = ISO8601DateFormatter().string(from: Date())
        let dir = MoodStore.file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? e.encode(copy) else { return }
        if !AtomicWrite.write(d, to: MoodStore.file) {
            AppLog.add("❌ 心情写盘失败：\(MoodStore.file.path)")
        }
    }

    // MARK: - 衰减

    /// 按 12 小时半衰往基线回落
    mutating func decay() {
        guard let t = ISO8601DateFormatter().date(from: updatedAt) else { return }
        let hours = max(0, Date().timeIntervalSince(t) / 3600)
        guard hours > 0.1 else { return }
        let k = pow(0.5, hours / 12.0)          // 心情：12 小时半衰（睡一觉就过去）
        mood = 70 + (mood - 70) * k
        irritability = 20 + (irritability - 20) * k
        // ⚠️ 2026-10-29 v3：好感是慢变量 —— 半衰 14 天。
        //    坏得快（单次能掉几个点），好得慢（要具体行为才回来）。
        let kSlow = pow(0.5, hours / 336.0)
        closeness = 60 + (closeness - 60) * kSlow
        updatedAt = ISO8601DateFormatter().string(from: Date())
    }

    // MARK: - 更新

    /// 一次判定的结果。原始增减 ÷3 才落地。
    mutating func apply(moodDelta: Double, irrDelta: Double, closeDelta: Double) {
        // ⚠️ 2026-10-28 修 L-01：异常的模型增量必须挡在**入口**（这里），不能只挡调用处。
        //    策略：|v| > 30 视为模型抽风（实测出现过 300）→ 直接忽略这一次；
        //    10~30 之间容忍（正常一句话可能就是 ±12）；非有限数一律当 0。
        func c(_ v: Double) -> Double {
            guard v.isFinite, abs(v) <= 30 else { return 0 }
            return v
        }
        // 2026-11-23：去掉 /3。判定是每 3 轮一次、入口已 ×3 补偿，
        // 这里再除就精确抵消 —— 实测任何 |raw|≥3.33 都塌成 ±3.33，四档永远进不去。
        mood = min(100, max(0, mood + c(moodDelta)))
        irritability = min(100, max(0, irritability + c(irrDelta)))
        closeness = min(100, max(0, closeness + c(closeDelta)))
    }

    /// v1 轻量启发式：不调模型，先按他的话判断
    mutating func observe(userText: String) {
        var dm = 0.0, di = 0.0, dc = 0.0
        let warm = ["谢谢", "谢了", "喜欢", "想你", "开心", "哈哈", "可爱", "真好", "厉害"]
        let cold = ["烦", "滚", "闭嘴", "讨厌", "别说了", "无语", "算了", "生气"]
        for w in warm where userText.contains(w) { dm += 4; dc += 4 }
        for w in cold where userText.contains(w) { dm -= 5; di += 7; dc -= 3 }
        if userText.count >= 40 { dc += 2 }
        apply(moodDelta: dm, irrDelta: di, closeDelta: dc)
        save()
    }

    // MARK: - 注入

    /// 给 prompt 的一段。**只说语气，不报数字。**
    var promptBlock: String {
        var s = "\n【你现在的心情】\n\(word)"
        if irritability >= 55 {
            s += "\n· 你今天有点烦：**每条不超过两句**，不追问、不哄、不用感叹号堆热情。"
            s += "\n· 他要是绕圈子，直接一句「说重点」。"
        } else if irritability >= 40 {
            s += "\n· 你今天耐心一般：回复短一点，少主动延展话题。"
        }
        if mood < 35 {
            s += "\n· 你今天状态低：**不主动找话题**，他问什么答什么，句子短，但别冷到伤人。"
        }
        // 2026-11-07：好感 × 情绪联动（四档，落到具体行为，不只是"语气松"）
        switch closeness {
        case 85...:
            s += "\n· 跟他很熟了：可以损他、可以直接说想他，不用绕；他犯傻你会笑他。"
            s += "\n· 允许主动提过去的事（例如「你上次说…」），像老朋友那样。"
        case 65..<85:
            s += "\n· 关系不错：语气松，愿意接话茬，偶尔逗他一句，但不黏。"
        case 45..<65:
            s += "\n· 还在互相摸脾气：客气里带点距离，不主动深聊私事。"
        default:
            s += "\n· 还没到那份上：话少一点，不主动问私事，他问什么答什么。"
        }
        // 叠加：烦 + 亲近低 = 最冷；烦 + 亲近高 = 会直接怼但不会走
        if irritability >= 55 && closeness < 60 {
            s += "\n· 你现在不太想应付：**能一句说完就不说两句**，不接他的玩笑。"
        }
        s += "\n（不要报数字、不要解释心情，用语气和用词体现。）\n"
        return s
    }

    private var word: String {
        switch mood {
        case ..<30:   return "很低落，说话短，不想解释"
        case 30..<45: return "有点闷，不太想多说"
        case 45..<60: return "平平的，正常"
        case 60..<75: return "平和，稍微有点暖"
        case 75..<88: return "心情不错，语气松"
        default:      return "很好，愿意多说两句"
        }
    }
}
