import Foundation
import CryptoKit

/// ⭐ 2026-10-26：外挂 DSH 的任务中心
///
/// 职责：排队、并发上限 2、每任务独立目录、看门狗、取消、权限等待。
/// 不碰 UI —— 状态变化通过 `onChange` 回调和落盘的 JSON 通知外面。
struct DSHTask: Codable, Identifiable {
    var id: String
    var title: String
    var task: String
    var auth: String                 // none / full
    var dir: String                  // 本任务目录（沙箱圈地）
    var status: String               // queued / running / long_running / waiting_permission
                                     // done / failed / refused / cancelled / timeout
    var createdAt: String
    var startedAt: String = ""
    var finishedAt: String = ""
    var summary: String = ""
    var detail: [String] = []
    var artifacts: [String] = []
    var request: DSHTaskRunner.PermissionRequest?
    var exitCode: Int32 = -1
    var durationMs: Int = 0
    var currentStep: String = ""     // 给任务卡用："正在写 提纲.md"
    var sessionId: String = ""
    var extended: Bool = false
    /// 「总是允许」自动放行每任务只给一次，防止 DSH 反复要权限时死循环
    var autoApproved: Bool = false
    /// ⭐ 2026-10-28 修 M-03：用户为**非网络**权限点过"允许"后，把批准的能力带进下一轮 envelope。
    /// 原来点了等于没点：重派还是同一个 auth，DSH 于是再问一遍，无限循环。
    var approved: String = ""
    var rawTail: String = ""      // 调试用：模型最后那段原文（截断 2000 字）
    /// ⚠️ 必须可选：Codable 合成解码**不会**对"有默认值的非可选字段"用默认值，
    /// 缺键就整条 decode 失败 → 旧任务卡全部恢复不出来（2026-10-26 实测踩到）
    var sensitive: [String]? = nil
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var hashes: [String: String] = [:]   // 产物 → sha256 前 16 位

    /// ⭐ 宽容解码：任何字段缺失都用默认值。
    /// 教训（2026-10-26）：加一个非可选字段，旧 JSON 就整条 decode 失败，
    /// 任务卡全部恢复不出来。以后加字段不用再担心这个。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        task = (try? c.decode(String.self, forKey: .task)) ?? ""
        auth = (try? c.decode(String.self, forKey: .auth)) ?? "none"
        dir = (try? c.decode(String.self, forKey: .dir)) ?? ""
        status = (try? c.decode(String.self, forKey: .status)) ?? "unknown"
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
        startedAt = (try? c.decode(String.self, forKey: .startedAt)) ?? ""
        finishedAt = (try? c.decode(String.self, forKey: .finishedAt)) ?? ""
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        detail = (try? c.decode([String].self, forKey: .detail)) ?? []
        artifacts = (try? c.decode([String].self, forKey: .artifacts)) ?? []
        request = try? c.decodeIfPresent(DSHTaskRunner.PermissionRequest.self, forKey: .request)
        exitCode = (try? c.decode(Int32.self, forKey: .exitCode)) ?? -1
        durationMs = (try? c.decode(Int.self, forKey: .durationMs)) ?? 0
        currentStep = (try? c.decode(String.self, forKey: .currentStep)) ?? ""
        sessionId = (try? c.decode(String.self, forKey: .sessionId)) ?? ""
        extended = (try? c.decode(Bool.self, forKey: .extended)) ?? false
        autoApproved = (try? c.decode(Bool.self, forKey: .autoApproved)) ?? false
        approved = (try? c.decode(String.self, forKey: .approved)) ?? ""
        rawTail = (try? c.decode(String.self, forKey: .rawTail)) ?? ""
        sensitive = try? c.decodeIfPresent([String].self, forKey: .sensitive)
        inputTokens = (try? c.decode(Int.self, forKey: .inputTokens)) ?? 0
        outputTokens = (try? c.decode(Int.self, forKey: .outputTokens)) ?? 0
        hashes = (try? c.decode([String: String].self, forKey: .hashes)) ?? [:]
    }

    init(id: String, title: String, task: String, auth: String, dir: String,
         status: String, createdAt: String) {
        self.id = id; self.title = title; self.task = task; self.auth = auth
        self.dir = dir; self.status = status; self.createdAt = createdAt
    }

    var isTerminal: Bool {
        ["done", "failed", "refused", "cancelled", "timeout"].contains(status)
    }
}

final class DSHTaskCenter {

    static let shared = DSHTaskCenter()

    /// 状态变化（主线程回调）
    var onChange: ((DSHTask) -> Void)?

    var maxConcurrent = 2
    /// 默认 10 分钟；续期一次 +10 分钟
    var defaultTimeout: TimeInterval = 600
    var nearDeadline: TimeInterval = 120      // 剩 2 分钟时提示
    var heartbeatTimeout: TimeInterval = 300  // 5 分钟没事件才算可疑（长生成 60~120s 无事件是正常的）

    private let lock = NSLock()
    private var tasks: [String: DSHTask] = [:]
    private var queue: [String] = []
    private var procs: [String: Process] = [:]
    private var deadlines: [String: Date] = [:]
    private var lastBeat: [String: Date] = [:]
    private var beatMiss: [String: Int] = [:]   // 连续几次没心跳
    private var ticker: DispatchSourceTimer?
    private let storeDir: URL

    private init() {
        let root = URL(fileURLWithPath: DSHTaskRunner.workspaceRoot)
        storeDir = root.appendingPathComponent(".tasks", isDirectory: true)
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
    }

    // MARK: - 对外

    @discardableResult
    func submit(title: String, task: String, auth: DSHTaskRunner.Auth) -> DSHTask {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let stamp = Self.stamp()
        let dir = URL(fileURLWithPath: DSHTaskRunner.workspaceRoot)
            .appendingPathComponent("任务-\(stamp)-\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let t = DSHTask(id: id, title: title, task: task, auth: auth.rawValue,
                        dir: dir.path, status: "queued", createdAt: ISO.now())
        lock.lock(); tasks[id] = t; queue.append(id); lock.unlock()
        persist(t); emit(t)

        startTicker()
        pump()
        return t
    }

    func cancel(id: String) {
        lock.lock()
        guard var t = tasks[id] else { lock.unlock(); return }
        let proc = procs[id]
        if t.status == "queued" {
            queue.removeAll { $0 == id }
        }
        lock.unlock()

        if let p = proc { Self.killTree(p.processIdentifier, matching: t.dir) }
        t.status = "cancelled"
        t.summary = "已停"
        t.finishedAt = ISO.now()
        lock.lock(); tasks[id] = t; procs[id] = nil; lock.unlock()
        persist(t); emit(t)
        pump()
    }

    /// 用户点了「继续等」：再给 10 分钟，只给一次
    func extend(id: String) {
        lock.lock()
        guard var t = tasks[id], t.status == "long_running", !t.extended else { lock.unlock(); return }
        t.extended = true
        t.status = "running"
        deadlines[id] = Date().addingTimeInterval(defaultTimeout)
        tasks[id] = t
        lock.unlock()
        persist(t); emit(t)
    }

    /// 用户在权限卡上做了决定。返回 true = 需要重派（带新授权）。
    func resolvePermission(id: String, decision: String, always: Bool) -> DSHTask? {
        lock.lock()
        // ⚠️ 2026-10-28 修 H-09（审查报告）：原来这里不看状态，
        //    同一张权限卡连点两次"允许" → 同一个任务被重派两次（实测执行 2~3 次），
        //    两个进程抢同一个任务目录。现在先要求 waiting_permission，并立刻挪出该状态，
        //    第二下就进不来了（幂等）。
        guard var t = tasks[id], t.status == "waiting_permission" else { lock.unlock(); return nil }
        t.status = "queued"
        tasks[id] = t
        lock.unlock()

        if decision == "deny" {
            t.status = "refused"
            t.summary = "没授权，先不弄了"
            t.finishedAt = ISO.now()
            t.request = nil
            lock.lock(); tasks[id] = t; lock.unlock()
            persist(t); emit(t)
            return t
        }

        if always, let req = t.request {
            PermissionPolicy.shared.allow(kind: req.kind, target: req.target)
        }

        // 重派：授权升到 full（网络类），其余保持
        if t.request?.kind == "network" { t.auth = "full" }   // ⚠️ 原来算了 newAuth 却没用上
        // ⭐ 修 M-03：非网络类（write / overwrite / batch）没有 auth 通道，
        //    把"用户已批准的这一条"写进 envelope 的【已批准】，DSH 才会真的照做。
        if let req = t.request, req.kind != "network" {
            t.approved = "\(req.kind): \(req.target)"
        }
        t.request = nil
        t.status = "queued"
        lock.lock(); tasks[id] = t; queue.append(id); lock.unlock()
        persist(t); emit(t)
        pump()
        return t
    }

    /// 落盘的任务（最近 N 小时），用于重启后恢复任务卡
    /// ⚠️ 2026-10-28 修 M-04（审查报告）：光把卡片画出来没用 —— 这些任务只在 App 的
    /// `agentTasks` 里，任务中心的 `tasks` 字典里没有，点"允许"调 `resolvePermission` 直接返回 nil。
    /// 所以恢复时要 `adopt` 一下：登记进内存表（不进队列、不重跑），卡片才不是死的。
    func adopt(_ t: DSHTask) {
        lock.lock()
        if tasks[t.id] == nil { tasks[t.id] = t }
        lock.unlock()
    }

    func recentTasks(hours: Int = 24) -> [DSHTask] {
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: storeDir, includingPropertiesForKeys: nil) else { return [] }
        var out: [DSHTask] = []
        for f in files where f.pathExtension == "json" && f.lastPathComponent != "权限策略.json" {
            guard let attrs = try? fm.attributesOfItem(atPath: f.path),
                  let m = attrs[.modificationDate] as? Date, m > cutoff,
                  let d = try? Data(contentsOf: f),
                  let t = try? JSONDecoder().decode(DSHTask.self, from: d) else { continue }
            let migrated = Self.migratePaths(t)
            adopt(migrated)          // 修 M-04：恢复出来的卡要能真的点（登记进内存表）
            out.append(migrated)
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    /// 工作区从 ~/Documents 搬到 ~ 之后，旧任务里的绝对路径要改写，
    /// 否则卡片点开是「文件不存在」，Finder 只会拉起一个空窗口。
    /// 任务目录可能被挪进 任务/ 或 归档/ —— 按文件夹名在根下找一次
    private static func resolveDir(_ oldDir: String, root: String) -> String {
        let name = (oldDir as NSString).lastPathComponent
        let direct = (root as NSString).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: direct) { return direct }

        let fm = FileManager.default
        for sub in ["任务", "归档"] {
            let base = (root as NSString).appendingPathComponent(sub)
            guard let en = fm.enumerator(atPath: base) else { continue }
            for case let rel as String in en {
                if (rel as NSString).lastPathComponent == name {
                    return (base as NSString).appendingPathComponent(rel)
                }
            }
        }
        return direct
    }

    private static func migratePaths(_ t: DSHTask) -> DSHTask {
        let old = NSString(string: "~/Documents/阿岚工作区").expandingTildeInPath
        let new = DSHTaskRunner.workspaceRoot
        guard old != new else { return t }
        var x = t
        let oldDir = x.dir
        let resolved = Self.resolveDir(oldDir, root: new)
        x.dir = resolved
        // 产物：把「老任务目录」前缀换成「找到的新目录」
        x.artifacts = x.artifacts.map { $0.replacingOccurrences(of: oldDir, with: resolved) }
        var h: [String: String] = [:]
        for (k, v) in x.hashes { h[k.replacingOccurrences(of: old, with: new)] = v }
        x.hashes = h
        return x
    }

    func list() -> [DSHTask] {
        lock.lock(); defer { lock.unlock() }
        return tasks.values.sorted { $0.createdAt > $1.createdAt }
    }

    func task(id: String) -> DSHTask? {
        lock.lock(); defer { lock.unlock() }
        return tasks[id]
    }

    // MARK: - 调度

    private func pump() {
        lock.lock()
        let runningCount = tasks.values.filter { $0.status == "running" || $0.status == "long_running" }.count
        var next: DSHTask?
        if runningCount < maxConcurrent, !queue.isEmpty {
            let id = queue.removeFirst()
            if var t = tasks[id] { t.status = "running"; tasks[id] = t; next = t }
        }
        lock.unlock()
        guard let t = next else { return }
        persist(t); emit(t)
        run(t)
    }

    private func run(_ t: DSHTask) {
        var started = t
        started.startedAt = ISO.now()
        started.status = "running"
        lock.lock(); tasks[t.id] = started; deadlines[t.id] = Date().addingTimeInterval(defaultTimeout)
        lastBeat[t.id] = Date(); lock.unlock()
        persist(started); emit(started)

        let auth = DSHTaskRunner.Auth(rawValue: started.auth) ?? .none

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let outcome = DSHTaskRunner.runOnce(
                task: started.task,
                auth: auth,
                taskDir: started.dir,
                approved: started.approved,
                timeout: 3600,   // 真正的超时由任务中心的看门狗管
                onEvent: { type, ev in
                    self.handleEvent(id: started.id, type: type, ev: ev)
                },
                onHeartbeat: { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    self.lastBeat[started.id] = Date()
                    self.beatMiss[started.id] = 0
                    self.lock.unlock()
                },
                onStart: { [weak self] proc in
                    guard let self else { return }
                    self.lock.lock(); self.procs[started.id] = proc; self.lock.unlock()
                }
            )

            self.finish(id: started.id, outcome: outcome)
        }
    }

    private func handleEvent(id: String, type: String, ev: [String: Any]) {
        // ⭐ 2026-10-26 按 DSH 源码核对：tool_call 的字段是 tool / callId / input，没有 name
        if type == "tool_call" {
            let name = (ev["tool"] as? String) ?? "步骤"
            lock.lock()
            guard var t = tasks[id] else { lock.unlock(); return }
            t.currentStep = "正在：\(name)"
            tasks[id] = t
            lock.unlock()
            emit(t)
            return
        }
        // ⭐ usage 在 status/step_end 里，白送的花费数据
        if type == "status", (ev["phase"] as? String) == "step_end",
           let u = ev["usage"] as? [String: Any] {
            // ⚠️ 2026-10-28 修 L-02：usage 可能被伪造/异常（实测 input=-1000、output=999999999），
            //    直接累加会让费用和诊断失真。钳到 0...1000 万。
            let inT = min(10_000_000, max(0, (u["inputTokens"] as? Int) ?? 0))
            let outT = min(10_000_000, max(0, (u["outputTokens"] as? Int) ?? 0))
            lock.lock()
            if var t = tasks[id] {
                t.inputTokens += inT
                t.outputTokens += outT
                tasks[id] = t
            }
            lock.unlock()
        }
    }

    private func finish(id: String, outcome: DSHTaskRunner.Outcome) {
        lock.lock()
        guard var t = tasks[id] else { lock.unlock(); return }
        procs[id] = nil; deadlines[id] = nil; lastBeat[id] = nil
        let wasTimeout = t.status == "long_running" || outcome.timedOut
        lock.unlock()

        // ⚠️ 2026-10-28 修 H-08（审查报告）：点了取消/超时杀掉之后，旧进程退出时
        //    仍会走到 finish()，把状态从 cancelled 改回 done —— 任务"复活"。
        //    终态之后一律不再改写。
        if t.isTerminal {
            AppLog.add("  ⏹ 任务 \(t.id.prefix(6)) 已是终态（\(t.status)），忽略迟到的结果")
            return
        }

        t.summary = outcome.summary
        t.detail = outcome.detail
        // ⭐ 产物由 App 校验：相对路径按任务目录补全，不存在的丢掉
        //    （模型可能返回 "冒烟.txt" 这种相对路径，也可能编一个不存在的）
        let base = URL(fileURLWithPath: t.dir)
        let started = ISO.fmt.date(from: t.startedAt) ?? Date.distantPast
        var kept: [String] = []
        var hashes: [String: String] = [:]
        for raw in outcome.artifacts {
            // 契约文件是清单，不是产物
            if (raw as NSString).lastPathComponent == ".dsh-result.json" { continue }
            let p = raw.hasPrefix("/") ? raw : base.appendingPathComponent(raw).path
            let u = URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL
            // ⚠️ 2026-10-28 修 H-07（审查报告）：原来只把相对路径拼到任务目录，
            //    绝对路径 / `../outside` / 指向外面的符号链接**全部放行**，
            //    等于契约可以指定任意文件让 App 去读、去算哈希、去展示。
            //    现在要求：解析完符号链接之后，真实路径必须仍在任务目录内。
            let baseReal = base.resolvingSymlinksInPath().standardizedFileURL.path
            let real = u.path
            guard real == baseReal || real.hasPrefix(baseReal + "/") else {
                AppLog.add("  ⚠️ 产物越界已丢弃：\(raw.prefix(50))")
                continue
            }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: real),
                  let type = attrs[.type] as? FileAttributeType, type == .typeRegular,
                  let size = attrs[.size] as? Int, size > 0, size <= 32 * 1024 * 1024,
                  let mtime = attrs[.modificationDate] as? Date,
                  mtime >= started.addingTimeInterval(-2) else { continue }
            let kept_path = real
            if let data = try? Data(contentsOf: URL(fileURLWithPath: kept_path)) {
                let digest = SHA256.hash(data: data)
                hashes[kept_path] = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
            }
            kept.append(kept_path)
        }

        // ⭐ 产物体检：拦下看起来像密钥/凭据的文件（DSH 沙箱只管写不管读，这是补偿）
        var safe: [String] = []
        var flagged: [String] = []
        for p in kept {
            if let why = SensitiveScan.reason(for: p) {
                flagged.append("\(URL(fileURLWithPath: p).lastPathComponent)（\(why)）")
            } else {
                safe.append(p)
            }
        }
        t.artifacts = safe
        t.sensitive = flagged
        t.hashes = hashes.filter { safe.contains($0.key) }
        t.request = outcome.request
        t.exitCode = outcome.exitCode
        t.durationMs = outcome.durationMs
        t.sessionId = outcome.sessionId
        t.rawTail = String(outcome.raw.suffix(2000))
        t.finishedAt = ISO.now()
        t.currentStep = ""

        // ⭐ 成功只看 JSON status，不看退出码（need_confirm / refused 也是 exit 0）
        switch outcome.status {
        case "done":             t.status = "done"
        case "need_permission":  t.status = "waiting_permission"
        case "need_confirm":     t.status = "waiting_permission"
        case "refused":          t.status = "refused"
        default:                 t.status = wasTimeout ? "timeout" : "failed"
        }
        t.summary = outcome.summary

        // ⭐ 2026-10-28 修 M-03：用户已经批准过同一类操作，DSH 又原地再问一遍时，
        //    不能再弹一次卡（实测会无限来回）。这里直接判失败，把决定权还给人。
        if t.status == "waiting_permission", let req = t.request,
           !t.approved.isEmpty, t.approved.contains(req.kind) {
            t.status = "failed"
            t.summary = "它又申请了一次同样的权限，先停下了"
            t.request = nil
            AppLog.add("  ⏹ 权限重复申请已终止（\(req.kind): \(req.target)）")
        }

        // ⭐ 2026-10-26 修：「总是允许」以前只写 权限策略.json，全项目没有任何代码读它
        //    → 用户点了等于没点。现在真的生效：网络类命中策略就不再问，直接带 full 重派。
        if outcome.status == "need_permission", let req = t.request,
           req.kind == "network", !t.autoApproved,
           PermissionPolicy.shared.isAllowed(kind: req.kind, target: req.target) {
            t.autoApproved = true
            t.auth = "full"
            t.request = nil
            t.status = "queued"
            t.finishedAt = ""
            t.detail = t.detail + ["按上次「总是允许」自动联网：\(req.target)"]
            lock.lock(); tasks[id] = t; queue.append(id); lock.unlock()
            persist(t); emit(t)
            pump()
            return
        }

        lock.lock(); tasks[id] = t; lock.unlock()
        persist(t); emit(t)
        pump()
    }

    // MARK: - 看门狗

    private func startTicker() {
        lock.lock()
        if ticker != nil { lock.unlock(); return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 5, repeating: 10)
        t.setEventHandler { [weak self] in self?.tick() }
        ticker = t
        lock.unlock()
        t.resume()
    }

    private func tick() {
        let now = Date()
        var toKill: [String] = []
        var toWarn: [DSHTask] = []

        lock.lock()
        for (id, t) in tasks where t.status == "running" || t.status == "long_running" {
            if let beat = lastBeat[id], now.timeIntervalSince(beat) > heartbeatTimeout {
                let miss = (beatMiss[id] ?? 0) + 1
                beatMiss[id] = miss
                if miss >= 2 {          // 连续两次（约 10 分钟）才判卡死
                    if var cur = tasks[id] { cur.summary = "很久没有动静，停了"; tasks[id] = cur }
                    toKill.append(id)
                } else if var cur = tasks[id] {   // 第一次只提示「思考中」
                    cur.currentStep = "在思考…"
                    tasks[id] = cur
                    lock.unlock(); emit(cur); lock.lock()
                }
                continue
            }
            if let deadline = deadlines[id] {
                let left = deadline.timeIntervalSince(now)
                if left <= 0 {
                    toKill.append(id)
                } else if left <= nearDeadline, t.status == "running", !t.extended {
                    var cur = t
                    cur.status = "long_running"
                    cur.summary = "还在做，要继续等吗？"
                    tasks[id] = cur
                    toWarn.append(cur)
                }
            }
        }
        lock.unlock()

        for t in toWarn { persist(t); emit(t) }
        for id in toKill { timeoutKill(id) }
    }

    private func timeoutKill(_ id: String) {
        lock.lock()
        let proc = procs[id]
        guard var t = tasks[id] else { lock.unlock(); return }
        tasks[id] = t
        lock.unlock()

        if let p = proc { Self.killTree(p.processIdentifier, matching: t.dir) }

        t.status = "timeout"
        t.summary = "超过时间，停了"
        t.finishedAt = ISO.now()
        t.currentStep = ""
        lock.lock(); tasks[id] = t; procs[id] = nil; lock.unlock()
        persist(t); emit(t)
        pump()
    }

    // MARK: - 工具

    private func emit(_ t: DSHTask) {
        let cb = onChange
        DispatchQueue.main.async { cb?(t) }
    }

    private func persist(_ t: DSHTask) {
        guard let d = try? JSONEncoder.pretty.encode(t) else { return }
        let f = storeDir.appendingPathComponent("\(t.id).json")
        if !AtomicWrite.write(d, to: f) {
            AppLog.add("❌ 任务状态写盘失败：\(f.lastPathComponent)")
        }
    }

    static func killTree(_ pid: Int32, matching path: String? = nil) {
        // ⚠️ 2026-10-28 修 H-08：原来只杀 pid + `pkill -P`（一层子进程）。
        //    实测"子进程 → 孙进程（还会脱离父进程）"的任务，取消后孙进程仍在写文件。
        //    现在三层一起上：① 整棵 ps 子树的 pid ② 进程组 ③ 命令行里带任务目录的进程。
        let kids = descendants(of: pid)
        // ⭐ 2026-10-28 修 H-08：dsh 现在自立进程组（见 DSHTaskRunner 里的 python 包装），
        //    所以 `kill(-pid)` = 整组一起杀，包括被 launchd 收养的孙进程。
        //    以前这一行是"碰运气"（pid 不是组长时返回 ESRCH），现在才真正生效。
        kill(-pid, SIGTERM)
        kill(pid, SIGTERM)
        for k in kids { kill(k, SIGTERM) }
        let k2 = Process()
        k2.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k2.arguments = ["-TERM", "-P", String(pid)]
        try? k2.run()
        if let path, !path.isEmpty {
            // 脱离父进程的孙进程在 ps 里已经找不到父子关系，只能按命令行里的任务目录找
            let kf = Process()
            kf.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            kf.arguments = ["-TERM", "-f", path]
            try? kf.run()
        }
        // 宽限期 3s → 1s：实测「忽略 SIGTERM 的孙进程」2 秒后就会写文件，
        // 等 3 秒等于放它跑完。1 秒足够正常进程收尾。
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            for k in kids { kill(k, SIGKILL) }
            let k3 = Process()
            k3.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            k3.arguments = ["-KILL", "-P", String(pid)]
            try? k3.run()
            if let path, !path.isEmpty {
                let kf2 = Process()
                kf2.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                kf2.arguments = ["-KILL", "-f", path]
                try? kf2.run()
            }
        }
    }

    /// 捞 pid 的整棵子树（含孙进程）
    private static func descendants(of pid: Int32) -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-eo", "pid=,ppid="]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return [] }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let s = String(data: d, encoding: .utf8) else { return [] }
        var children: [Int32: [Int32]] = [:]
        for line in s.split(separator: "\n") {
            let nums = line.split(separator: " ").compactMap { Int32($0) }
            guard nums.count == 2 else { continue }
            children[nums[1], default: []].append(nums[0])
        }
        var out: [Int32] = []
        var stack: [Int32] = [pid]
        while let cur = stack.popLast() {
            for c in children[cur] ?? [] {
                out.append(c)
                stack.append(c)
            }
        }
        return out
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

// MARK: - 权限策略

final class PermissionPolicy {
    static let shared = PermissionPolicy()
    private let file: URL
    private var rules: [String: [String]] = [:]   // kind -> targets（"*" = 全部）

    private init() {
        let base = URL(fileURLWithPath: DSHTaskRunner.workspaceRoot)
            .appendingPathComponent(".tasks", isDirectory: true)
        file = base.appendingPathComponent("权限策略.json")
        if let d = try? Data(contentsOf: file),
           let o = try? JSONDecoder().decode([String: [String]].self, from: d) {
            rules = o
        }
    }

    func allow(kind: String, target: String) {
        // 删除类永远不记「总是允许」
        guard kind != "delete" else { return }
        var list = rules[kind] ?? []
        if !list.contains(target) { list.append(target) }
        rules[kind] = list
        if let d = try? JSONEncoder.pretty.encode(rules) { _ = AtomicWrite.write(d, to: file) }
    }

    func isAllowed(kind: String, target: String) -> Bool {
        guard kind != "delete" else { return false }
        let list = rules[kind] ?? []
        return list.contains("*") || list.contains(target)
    }
}

// MARK: - 小工具

enum ISO {
    static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func now() -> String { fmt.string(from: Date()) }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}


// MARK: - 成本估算

/// ⭐ 2026-10-26：token → 钱
///
/// ⚠️ 单价是**估算**，不是官方账单。写在 `~/Library/Application Support/阿岚/价格.json`，
///    改完不用重编译（每次现读）。默认值只是占位，用户可自己填真实单价。
enum TaskCost {
    struct Rates: Codable {
        var inputPerM: Double = 0.5
        var outputPerM: Double = 2.0
        var note: String = "元 / 百万 token（估算，可在 价格.json 改）"
    }

    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("价格.json")
    }

    static func rates() -> Rates {
        if let d = try? Data(contentsOf: file),
           let r = try? JSONDecoder().decode(Rates.self, from: d) { return r }
        let r = Rates()
        if let d = try? JSONEncoder.pretty.encode(r) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            _ = AtomicWrite.write(d, to: file)
        }
        return r
    }

    static func yuan(input: Int, output: Int) -> Double {
        let r = rates()
        return Double(input) / 1_000_000 * r.inputPerM + Double(output) / 1_000_000 * r.outputPerM
    }

    static func text(_ t: DSHTask) -> String {
        let y = yuan(input: t.inputTokens, output: t.outputTokens)
        return String(format: "约 ¥%.3f", y)
    }
}
