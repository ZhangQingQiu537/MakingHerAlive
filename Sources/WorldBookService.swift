import Foundation

/// 世界书读写（useDirect 模式下，所有权在 App 这里）
///
/// ⚠️ 这个文件**只在主 App 项目里**——控制台自己有一份副本（阿岚-控制台/Sources/Backend.swift）。
/// 两边路径 / 字段约定必须一致；改这里要同步改那边（共享常量 `WorldBookService.fileURL`）。
///
/// 设计原则（2026-09-24 修 Bug 6）：
///   1. **路径单一来源**——`WorldBookService.fileURL` 一处定义，两边都调
///   2. **字段单一来源**——`stage` 占位符（"当前从Lx起步"）一处定义
///   3. **写入原子**——先写临时文件再 mv
///
/// 当前条目数（v2.1 画廊偶遇版）：19 条
enum WorldBookService {

    /// 世界书 JSON 文件路径（直连模式）
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("资产", isDirectory: true)
            .appendingPathComponent("世界书.json")
    }

    /// 阶段占位符（uid14 content 里的活靶心）
    /// ⚠️ 控制台那边的"阶段文案"必须与之完全一致，否则 updateStage 会找不到位置写。
    static let stagePlaceholder = "当前从L[1-4]起步"

    /// 把当前阶段写进 uid14（"当前从L2起步" → "当前从L3起步"）
    /// 这样状态机才是真的在演进，而不是每轮都从头判断
    ///
    /// 写入策略（2026-09-24）：**先写临时文件，再 mv 原子替换**——
    /// 写入半路进程被杀也不会把世界书弄成半残；旧文件保留为 .bak
    ///
    /// ⚠️ C-P2-3（2026-09-24）：uid14 缺失时**降级创建**——
    /// 旧逻辑找不到 uid14 就静默返回 false，结果是控制台/世界书版本一变就再也写不进去；
    /// 现在自动建一条「uid14 阶段」条目，按 order=300 排（uid0 同级），
    /// 至少能保证阶段继续演进；下次启动世界书模板若带 uid14，可手工合并。
    @discardableResult
    static func updateStage(_ stage: Int) -> Bool {
        guard let url = fileURL as URL?,
              let d = try? Data(contentsOf: url),
              var obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }

        // 兜底：保证 entries 是数组
        if obj["entries"] == nil { obj["entries"] = [] }
        guard var entries = obj["entries"] as? [[String: Any]] else { return false }

        var hit = false
        for i in entries.indices where (entries[i]["uid"] as? Int) == 14 {
            let c = entries[i]["content"] as? String ?? ""
            let newC = c.replacingOccurrences(
                of: stagePlaceholder,
                with: "当前从L\(stage)起步")
            if newC != c { entries[i]["content"] = newC; hit = true }
        }

        // ⭐ C-P2-3 修复：没找到 uid14 时降级创建
        if !hit {
            AppLog.add("⚠️ 世界书 uid14 缺失，自动创建（C-P2-3 兜底）")
            let maxUid = entries.compactMap { ($0["uid"] as? Int) }.max() ?? 0
            let newUid = max(maxUid + 1, 14)
            entries.append([
                "uid": newUid,
                "key": ["uid14", "当前从L[1-4]起步", "阶段状态机"],
                "keysecondary": [] as [String],
                "comment": "uid14 阶段（C-P2-3 自动创建：原条目缺失）",
                "content": "当前从L\(stage)起步",
                "constant": true,
                "order": 300,
                "position": 0,
                "disable": false,
                "selective": false,
                "excludeRecursion": false,
                "probability": 100,
                "useProbability": true,
            ])
        }

        obj["entries"] = entries
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return false }
        return atomicWrite(out, to: url)
    }

    /// 原子写：先写临时文件 → 备份旧文件 → mv 覆盖
    private static func atomicWrite(_ data: Data, to url: URL) -> Bool {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".世界书.json.tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            // 留 .bak 以防万一
            let bak = dir.appendingPathComponent("世界书.json.bak")
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try? FileManager.default.removeItem(at: bak)
                try? FileManager.default.copyItem(at: url, to: bak)
            }
            _ = try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmp, to: url)
            return true
        } catch {
            // 清理临时文件
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }
}