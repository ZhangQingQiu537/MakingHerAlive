import AppKit

/// 表情包：**她只输出标签，App 把标签换成本地图片**。
///
/// 设计要点（2026-10-27 定）：
/// · 聊天记录里存标签原文 `[图:无语]`，不存图片路径 —— 换整套图不用改历史
/// · 标签 → 文件名，两套目录：`她/`（她的 Q 版脸）、`通用/`（猫 / 物件）
/// · 字卡（OK / 算了 / 好耶 / 。）**不存图，代码画**
/// · 找不到图就退化成纯文字（标签删掉），绝不留空框
///
/// ⚠️ SwiftUI 铁律：body 里不读盘。这里在启动时一次性读进内存（几十 KB × 20 张，无所谓）。
enum MemePack {

    static var root: URL {
        AppConfig.dir.appendingPathComponent("资产", isDirectory: true)
            .appendingPathComponent("表情", isDirectory: true)
    }

    /// prompt 里给她看的标签清单（前 10 个是"她的脸"，后 6 个是"通用"）
    static let faceTags = ["嫌弃", "无语", "困", "嗯", "别闹", "委屈", "得意", "晚安", "走了", "摸头"]
    static let commonTags = ["问号", "笑死", "服了", "沉默", "猫叹气", "猫爪"]
    /// 2026-10-29：字卡（"算了""OK"）取消 —— 在聊天里就是两个大字，很出戏
    static let textCardTags: Set<String> = []

    private static var cache: [String: NSImage] = [:]
    private static var loaded = false

    static func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let fm = FileManager.default
        for sub in ["她", "通用"] {
            let d = root.appendingPathComponent(sub, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: d,
                                                          includingPropertiesForKeys: nil) else { continue }
            for f in files where f.pathExtension.lowercased() == "png" {
                let tag = f.deletingPathExtension().lastPathComponent
                // 先查 `她/` 再查 `通用/`：重名以她的脸为准
                if cache[tag] == nil, let img = NSImage(contentsOf: f) {
                    cache[tag] = img
                }
            }
        }
    }

    static func image(for tag: String) -> NSImage? {
        loadIfNeeded()
        return cache[tag]
    }

    static var availableTags: [String] {
        loadIfNeeded()
        return cache.keys.sorted()
    }

    /// 有图的标签（prompt 里只列真的有图的 + 字卡）
    static var promptTags: [String] {
        loadIfNeeded()
        let withImage = cache.keys.filter { !textCardTags.contains($0) }.sorted()
        return withImage + textCardTags.sorted()
    }
}

/// 把一段文本拆成「文字 / 表情标签」
enum MemeParse {
    enum Segment: Equatable {
        case text(String)
        case meme(String)
    }

    /// 匹配 `[图:无语]` 或 `[图：无语]`
    static func segments(_ s: String) -> [Segment] {
        guard s.contains("[图") else { return s.isEmpty ? [] : [.text(s)] }
        var out: [Segment] = []
        var rest = Substring(s)
        let open = "[图"
        while let r = rest.range(of: open) {
            let before = rest[..<r.lowerBound]
            if !before.isEmpty { out.append(.text(String(before))) }
            let after = rest[r.lowerBound...]
            guard let close = after.firstIndex(of: "]") else {
                // 没闭合（流式中间态）→ 剩下的当文字
                out.append(.text(String(after)))
                return out
            }
            let contentStart = after.index(after.startIndex, offsetBy: open.count)  // 跳过 "[图"
            var tag = String(after[contentStart..<close])
            tag = tag.replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "：", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if tag.isEmpty {
                // `[图]` 这种不完整标签 → 丢掉
            } else {
                out.append(.meme(tag))
            }
            rest = after[after.index(after: close)...]
        }
        if !rest.isEmpty { out.append(.text(String(rest))) }
        return out
    }

    /// 去掉标签后的纯文字（给 TTS / 记忆提取用，别把"图 无语"念出来）
    static func plain(_ s: String) -> String {
        segments(s).compactMap { seg -> String? in
            if case .text(let t) = seg { return t }
            return nil
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 这一条里有没有能真的渲染出来的图（没图的标签会被丢掉，不算数）
    static func hasRenderableMeme(_ s: String) -> Bool {
        for seg in segments(s) {
            if case .meme(let tag) = seg {
                if MemePack.image(for: tag) != nil || MemePack.textCardTags.contains(tag) { return true }
            }
        }
        return false
    }
}
