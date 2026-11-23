import Foundation

/// 通用原子写工具（Bug 12 修）
///
/// 写入策略：先写临时文件 → fsync（Data.write 默认）→ mv 覆盖；
/// 如果原文件存在，复制一份 `.bak` 留底（防止改完后发现新版本是垃圾）。
///
/// 用途：MemoryStore / CardStore / 任务状态 / 未来其他 store。
enum AtomicWrite {
    /// ⚠️ 2026-10-28 修 H-05（审查报告）：
    /// ① 原实现是 `removeItem(url)` + `moveItem(tmp, url)` —— 中间有一个**文件不存在的窗口**，
    ///    48 个并发写实测失败 8~14 次；断电/崩溃正好落在这个窗口就是数据没了。
    ///    改成 `replaceItemAt`（同卷原子 rename-over）。
    /// ② 并发写同一路径如果没有串行化，两个 tmp 会互相踩。这里加一把进程内全局锁，
    ///    写入本身都是几 KB 的小文件，串行化没有性能问题。
    private static let writeLock = NSLock()

    /// 把 data 原子写到 url；保留旧版本为 `*.bak`
    /// - Parameter posixPermissions: 传了就把 tmp 和 .bak 都设成这个权限（日记要用 0o600）。
    ///   ⚠️ 必须在 move **之前**设 tmp 的权限 —— 先写 644 再 chmod，中间那段时间是漏的。
    @discardableResult
    static func write(_ data: Data, to url: URL, backupExt: String = ".bak",
                      posixPermissions: Int? = nil) -> Bool {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString.prefix(8))")

        writeLock.lock()
        defer { writeLock.unlock() }

        do {
            try data.write(to: tmp, options: .atomic)
            let fm = FileManager.default
            if let p = posixPermissions {
                try? fm.setAttributes([.posixPermissions: p], ofItemAtPath: tmp.path)
            }
            // 备份旧文件（失败不阻断写入，但要留痕）
            if fm.fileExists(atPath: url.path) {
                let bak = URL(fileURLWithPath: url.path + backupExt)
                try? fm.removeItem(at: bak)
                do { try fm.copyItem(at: url, to: bak) }
                catch { AppLog.add("⚠️ 备份失败：\(bak.lastPathComponent)") }
            }
            if fm.fileExists(atPath: url.path) {
                do {
                    _ = try fm.replaceItemAt(url, withItemAt: tmp)
                } catch {
                    // 极少数卷不支持 replaceItemAt → 退回 remove+move（有窗口，但比不写强）
                    try? fm.removeItem(at: url)
                    try fm.moveItem(at: tmp, to: url)
                }
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
            // replaceItemAt 有些情况下会把权限带回旧文件的；最后再兜一次
            if let p = posixPermissions {
                try? fm.setAttributes([.posixPermissions: p], ofItemAtPath: url.path)
                if fm.fileExists(atPath: url.path + backupExt) {
                    try? fm.setAttributes([.posixPermissions: p],
                                          ofItemAtPath: url.path + backupExt)
                }
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            AppLog.add("❌ 原子写失败：\(url.lastPathComponent) · \(error.localizedDescription.prefix(50))")
            return false
        }
    }

    /// 把字符串原子写到 url（UTF-8）
    @discardableResult
    static func writeString(_ s: String, to url: URL, backupExt: String = ".bak",
                            posixPermissions: Int? = nil) -> Bool {
        guard let d = s.data(using: .utf8) else { return false }
        return write(d, to: url, backupExt: backupExt, posixPermissions: posixPermissions)
    }
}

/// 备份文件名冲突（C-P2-7，2026-09-24 上线）
///
/// 备份目录里如果已经有同名文件（典型：同一分钟内备份两次），自动加 `-2`/`-3`/... 后缀。
/// 不覆盖任何已有文件。
enum BackupNaming {
    /// 给定目标路径；若已存在返回 `name-2.ext`、`name-3.ext`...
    /// - dir: 备份目录
    /// - baseName: 不含扩展名的基础名（如"记忆卡片"）
    /// - ext: 扩展名（含点，如".json"）
    static func uniqueURL(in dir: URL, baseName: String, ext: String) -> URL {
        let stem = baseName
        var n = 1
        while true {
            let name = n == 1 ? "\(stem)\(ext)" : "\(stem)-\(n)\(ext)"
            let url = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
            if n > 9999 {   // 安全网，别无限循环
                return dir.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(6))\(ext)")
            }
        }
    }
}

/// 日志轮转（Batch B P2-3，2026-09-24 上线）
///
/// 两个日志都需要轮转：
///   - `live2d/debug.log`（WKWebView JS 错误日志，长期未轮转已 38KB+）
///   - `运行日志.txt`（App 主日志）
///
/// 策略：超过 `maxBytes`（默认 1MB）就把旧文件归档为 `.log.1`（覆盖旧的 .log.1），然后清空当前文件。
/// 不做按天轮转（这个 App 不是 24h 服务，且文件名带时间戳本身就有麻烦）。
enum LogRotation {
    /// 超 maxBytes 则把 url 归档为 `.log.1`，然后截断 url 为空
    /// - Returns: 是否做了轮转（false = 当前文件还小）
    @discardableResult
    static func rotateIfNeeded(_ url: URL, maxBytes: Int64 = 1_048_576) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        guard size > maxBytes else { return false }

        let archived = url.appendingPathExtension("1")
        // 删旧的 .log.1（保留 1 份）
        try? FileManager.default.removeItem(at: archived)
        try? FileManager.default.moveItem(at: url, to: archived)
        // 新建空文件（让调用方下次还能 append）
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return true
    }

    /// 追加一行（含自动轮转）；写完不返回行数（一般不需要）
    /// - line: 已经含换行符
    static func append(_ line: String, to url: URL, maxBytes: Int64 = 1_048_576) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        rotateIfNeeded(url, maxBytes: maxBytes)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            h.seekToEndOfFile()
            try? h.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}