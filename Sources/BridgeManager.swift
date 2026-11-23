import Foundation

/// QQ 桥的进程管家（2026-10-29）
///
/// 之前桥是手动跑的独立进程：我这边会话一结束就被回收，他得自己双击启动器。
/// 现在改成 **App 自己拉起/看护**：
///   · App 启动 → 读开关（桥-开关.json，默认开）→ 起 python 桥
///   · 每 5 秒看一次：进程死了就重启（限流，避免狂重启）；开关关了就把进程收掉
///   · App 退出 → 一起收掉（不留孤儿）
///   · 桥每 5 秒写一次心跳（qqbot-心跳.json），控制台靠它判断"活着没有"
final class BridgeManager {
    static let shared = BridgeManager()

    private var proc: Process?
    private var timer: Timer?
    private var restarts: [Date] = []
    private let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask)[0]
        .appendingPathComponent("Companion", isDirectory: true)

    private var switchURL: URL { support.appendingPathComponent("桥-开关.json") }
    private var logURL: URL { support.appendingPathComponent("QQ桥.log") }

    /// 桥脚本位置：项目里的 工具/QQ桥.py（App 在 <项目>/阿岚-原生/阿岚.app）
    private var scriptURL: URL {
        Bundle.main.bundleURL                     // …/阿岚.app
            .deletingLastPathComponent()          // …/阿岚-原生
            .deletingLastPathComponent()          // …/<项目>
            .appendingPathComponent("工具/QQ桥.py")
    }

    var enabled: Bool {
        guard let d = try? Data(contentsOf: switchURL),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let on = o["on"] as? Bool else { return true }   // 没文件 = 默认开
        return on
    }

    var alive: Bool {
        guard let p = proc, p.isRunning else { return false }
        return true
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.sync()
        }
        sync()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func sync() {
        guard enabled else {
            if let p = proc, p.isRunning {
                p.terminate()               // 桥收到 SIGTERM 会自己走干净
                AppLog.add("🌉 桥已按开关关闭")
            }
            proc = nil
            return
        }
        guard !alive else { return }
        // 限流：10 分钟内最多重启 6 次
        let now = Date()
        restarts = restarts.filter { now.timeIntervalSince($0) < 600 }
        guard restarts.count < 6 else { return }
        restarts.append(now)
        spawn()
    }

    /// 收掉遗留的旧桥（App 被 pkill 时 willTerminate 不触发，会留孤儿）
    private func killOrphans() {
        let heart = support.appendingPathComponent("qqbot-心跳.json")
        guard let d = try? Data(contentsOf: heart),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let pid = o["pid"] as? Int32, pid > 0, pid != getpid() else { return }
        if kill(pid, 0) == 0 { kill(pid, SIGTERM) }
    }

    private func ensureLog() {
        guard !FileManager.default.fileExists(atPath: logURL.path) else { return }
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: logURL.path)
    }

    private func spawn() {
        killOrphans()
        ensureLog()
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            AppLog.add("🌉 桥脚本不存在：\(scriptURL.path)")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-u", scriptURL.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        p.currentDirectoryURL = scriptURL.deletingLastPathComponent()
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            // ⚠️ 文件不存在时 FileHandle(forWritingTo:) 会直接失败、日志永远不落地
            self.ensureLog()
            if let fh = try? FileHandle(forWritingTo: self.logURL) {
                fh.seekToEndOfFile(); fh.write(d); try? fh.close()
            }
            // 桥自己的日志已经写文件，这里只把关键行转进 AppLog
            for line in s.split(separator: "\n") where line.contains("收到") || line.contains("发回") {
                AppLog.add("🌉 " + line)
            }
        }
        do {
            try p.run()
            proc = p
            AppLog.add("🌉 QQ 桥已启动（pid \(p.processIdentifier)）")
        } catch {
            AppLog.add("🌉 桥启动失败：\(error.localizedDescription.prefix(40))")
        }
    }

    func shutdown() {
        stopMonitoring()
        if let p = proc, p.isRunning { p.terminate() }
        proc = nil
    }
}
