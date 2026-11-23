import Foundation

// P1 验证入口：读真实数据快照 → 组装 prompt → 打印
// 用法: swiftc -O -o /tmp/p1test Sources/*.swift && /tmp/p1test

let path = "/tmp/snapshot.json"
guard let data = FileManager.default.contents(atPath: path) else {
    print("找不到快照: \(path)")
    exit(1)
}

struct Snapshot: Codable {
    var card: CharacterCard
    var world: WorldBook
    var history: [ChatMessage]
    var persona: String
}

let snap = try JSONDecoder().decode(Snapshot.self, from: data)

let entries = snap.world.entries.values.sorted { $0.uid < $1.uid }
let builder = PromptBuilder(
    character: snap.card,
    persona: Persona(name: "小林", description: snap.persona),
    worldEntries: entries
)

let userMessage = "在忙吗"
let messages = builder.build(history: snap.history, userMessage: userMessage)

print(String(repeating: "=", count: 60))
print("组装结果：\(messages.count) 条消息")
print(String(repeating: "=", count: 60))

for (i, m) in messages.enumerated() {
    print("\n--- [\(i)] role=\(m.role)  长度=\(m.content.count) ---")
    if m.role == "system" {
        // system 太长，只显示结构概览
        let preview = m.content.prefix(260)
        print(preview + "...")
        print("\n[system 末尾 400 字]")
        print(String(m.content.suffix(400)))
    } else {
        print(m.content)
    }
}

// 世界书命中情况
let engine = WorldBookEngine()
let hit = engine.match(entries: entries, history: snap.history, userMessage: userMessage)
print("\n" + String(repeating: "=", count: 60))
print("世界书命中 \(hit.count)/\(entries.count) 条：")
for e in hit {
    print("  [order \(e.order)] \(e.comment ?? "?")  constant=\(e.constant)")
}

// 导出成 JSON，供 Python 调 API 验证
if let out = try? JSONEncoder().encode(messages) {
    try? out.write(to: URL(fileURLWithPath: "/tmp/messages.json"))
    print("\n已导出 /tmp/messages.json")
}
