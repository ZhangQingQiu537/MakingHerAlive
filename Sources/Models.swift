import Foundation

// 角色卡（从 SillyTavern 的 PNG tEXt chunk 读出）
struct CharacterCard: Codable {
    var name: String
    var description: String
    var personality: String
    var scenario: String
    var firstMes: String
    var mesExample: String
    var world: String?

    enum CodingKeys: String, CodingKey {
        case name, description, personality, scenario
        case firstMes = "first_mes"
        case mesExample = "mes_example"
        case world
    }
}

// 用户 persona
struct Persona: Codable {
    var name: String
    var description: String
}

// 世界书条目
struct WorldEntry: Codable {
    var uid: Int
    var key: [String]
    var content: String
    var constant: Bool
    var order: Int
    var position: Int?
    var disable: Bool?
    var comment: String?
}

struct WorldBook: Codable {
    var entries: [String: WorldEntry]
}

// 聊天消息
struct ChatMessage: Codable, Equatable {
    var name: String
    var isUser: Bool
    var mes: String
    /// 场景切换的分割线（is_system），只做展示，不进 LLM
    var isSystem: Bool = false
    /// ⭐ 她说这句时的思考原文（reasoning_content）
    ///
    /// 存在 jsonl 的 `extra.reasoning` 里 —— 不落盘的话重启就没了，
    /// 而"她当时为什么这么想"恰恰是隔天回看时最想看的（2026-09-25）。
    /// 只有她的话有，用户消息为空。
    var reasoning: String = ""
    /// ⭐ 2026-10-29 作品图：这张气泡对应的图片文件名（存在 extra.image）
    var imagePath: String = ""
    /// ⭐ 2026-11-08 修 D-12：作品气泡的路径与名字（存在 extra.workPath / extra.workName）
    ///    以前只放在内存里的 Bubble，重启就丢，按钮变成普通文字。
    var workPath: String = ""
    var workName: String = ""
    /// ⭐ 2026-11-11：消息时间（从 jsonl 的 send_date 解出来）。
    ///   原来丢掉时间戳，导致"她今晚说过晚安"只能按"最近 60 条"猜，会把昨天的晚安当成今天的。
    var sentAt: Date? = nil

    enum CodingKeys: String, CodingKey {
        case name
        case isUser = "is_user"
        case mes
        case isSystem = "is_system"
        case reasoning
    }
}

// 发给 LLM 的消息
struct LLMMessage: Codable {
    var role: String
    var content: String
    /// 工具调用回填用（role == "tool" 时带）
    var toolCallId: String? = nil
}
