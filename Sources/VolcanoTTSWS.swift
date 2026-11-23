import Foundation

/// 火山引擎「豆包语音合成大模型 2.0」双向流式 WebSocket TTS。
///
/// ⚠️ 协议细节全部是 2026-09-23 实测解出来的（官方 protocols.py 未公开，走了不少弯路）：
///
///  端点   wss://openspeech.bytedance.com/api/v3/tts/bidirection
///  鉴权   `X-Api-Key: <新版 API Key>`（控制台>API Key管理 创建的 UUID 格式）
///         + `X-Api-Resource-Id`: seed-tts-2.0（合成）/ seed-icl-2.0（声音复刻音色）
///
///  帧格式 = Header(4B) + Optional + payload_len(4B) + payload
///    Header   = [0x11, 0x14, 0x10, 0x00]
///               （版本1|头长1, 客户端完整请求<<4 | 0x04携带事件, JSON<<4 | 无压缩, 保留）
///    Optional = event(4B) [+ session_len(4B) + session_id(UTF8)]
///    payload  = JSON
///
///  ⚠️ 事件码（**不是** 1/2/3/4，第一次就栽在这）：
///    上行 StartConnection=1  FinishConnection=2  StartSession=100  FinishSession=102  TaskRequest=200
///    下行 ConnectionStarted=50  SessionFinished=152
///         TTSSentenceStart=350  TTSSentenceEnd=351  TTSResponse=352(音频)
///
///  ⚠️ payload JSON 必须带 `namespace: "BidirectionalTTS"`，且 `session_id` **不在 JSON 里**（在 Optional 段）。
///
/// ⚠️ 两个实测教训（2026-09-23 深夜调试记录）：
///  ① 握手必须**逐步等服务端确认**（建连→等50→会话→等150→送文本→歇0.2s→结束会话）——
///     四帧连发不等确认，服务端竞态会回空错误帧（mt=0F、payload 为空）。
///  ② 服务端偶发抖动：握手中途 send 直接 NSURLErrorCancelled(-999)，同 Key 高频连接时
///     更易触发。对策 = 整段**自动重试**（synthesize 包 synthesizeOnce）。
///
/// ⚠️⚠️ **GUI App 进程里不要用本文件**（2026-09-23 终极结论）：
///  URLSessionWebSocketTask 在 GUI App 进程内连本端点**必败**（-999/-1011），
///  同代码 CLI 进程全环境通过；抓握手头逐字段对比排除了 UA/ATS/代理/IPv6/限流/缓存，
///  判定为 CFNetwork 在 GUI 进程下的环境差异，未解。App 内 TTS 走
///  `VoiceService.synthViaBridge`（Python TTSBridge.py 子进程）。本文件保留给 CLI 测试。
enum VolcanoTTSWS {

    static let url = "wss://openspeech.bytedance.com/api/v3/tts/bidirection"

    // 上行事件
    private static let evStartConn = 1
    private static let evStartSess = 100, evFinishSess = 102
    private static let evTaskRequest = 200
    // 下行事件
    private static let evConnStarted = 50
    private static let evSessFinished = 152, evSessFailed = 153
    private static let evTTSResponse = 352

    private static let mtAudioOnly = 0x0B
    private static let mtFullServer = 0x09
    private static let mtError = 0x0F

    struct TTSError: LocalizedError {
        let message: String
        var errorDescription: String? { "火山TTS：\(message)" }
    }

    private static let header = Data([0x11, 0x14, 0x10, 0x00])

    private static func frame(event: Int, sessionId: String?, json: [String: Any]?) -> Data {
        var d = header
        d.append(be32(event))
        if let s = sessionId {
            let b = Data(s.utf8)
            d.append(be32(b.count)); d.append(b)
        }
        let payload = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data("{}".utf8)
        d.append(be32(payload.count)); d.append(payload)
        return d
    }

    private static func be32(_ v: Int) -> Data {
        var x = Int32(v).bigEndian
        return withUnsafeBytes(of: &x) { Data($0) }
    }

    private static func read32(_ d: Data, _ off: Int) -> Int {
        guard off + 4 <= d.count else { return 0 }
        let v = d.subdata(in: off..<off+4).withUnsafeBytes { $0.load(as: Int32.self) }
        return Int(Int32(bigEndian: v))
    }

    private static func payload(_ event: Int, text: String = "", speaker: String) -> [String: Any] {
        [
            "user": ["uid": "makingheralive"],
            "event": event,
            "namespace": "BidirectionalTTS",
            "req_params": [
                "text": text,
                "speaker": speaker,
                "audio_params": ["format": "mp3", "sample_rate": 24000],
                // 括号里的动作描写不念（她的回复是「（动作）"台词"」混排）
                "additions": "{\"max_length_to_filter_parenthesis\":100}",
            ],
        ]
    }

    /// 解析服务端帧 → (msgType, event, payload)
    private static func parse(_ d: Data) -> (Int, Int, Data) {
        guard d.count >= 4 else { return (0, 0, Data()) }
        let mt = Int(d[d.startIndex + 1] >> 4)
        let flags = Int(d[d.startIndex + 1] & 0x0F)
        var off = 4
        var event = 0
        if flags & 0x04 != 0 { event = read32(d, off); off += 4 }
        // 音频/句级事件里，事件后紧跟 session_id（长度+内容）
        if (mt == mtAudioOnly || mt == mtFullServer) && (event == evTTSResponse) {
            let ln = read32(d, off); off += 4
            if ln > 0 && off + ln <= d.count { off += ln }
        }
        var payload = Data()
        if mt == mtAudioOnly || mt == mtFullServer || mt == mtError {
            let ln = read32(d, off)
            if ln > 0 && off + 4 + ln <= d.count { payload = d.subdata(in: off+4..<off+4+ln) }
        }
        return (mt, event, payload)
    }

    /// payload → 可读的错误文本（截断 150 字；空 payload 也要给个说法）
    private static func errText(_ pl: Data) -> String {
        let s = String(data: pl, encoding: .utf8) ?? ""
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "(服务端未给出原因)" }
        return t.count > 150 ? String(t.prefix(150)) + "…" : t
    }

    // MARK: - 公开入口（带自动重试）

    /// 合成：一整段文本 → mp3 数据。
    /// 服务端偶发 -999 抖动（常连续数秒）→ **最多试 3 次**，退避 1.5s/3s。
    /// 实测一轮对话里晚 5 秒出声，远好于退回机械音。
    static func synthesize(text: String,
                           apiKey: String,
                           resourceId: String,
                           speaker: String) async throws -> Data {
        var lastError: Error = TTSError(message: "未知错误")
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 3_000_000_000 / 2)
            }
            do {
                return try await synthesizeOnce(text: text, apiKey: apiKey,
                                                resourceId: resourceId, speaker: speaker)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - 单次合成

    /// 握手流程（与官方 demo 对齐）：
    /// 建连(1) → 等 ConnectionStarted(50) → 开会话(100) → 等 SessionStarted(150)
    /// → 送文本(200) → 小歇 0.2s → 结束会话(102) → 收音频
    private static func synthesizeOnce(text: String,
                                       apiKey: String,
                                       resourceId: String,
                                       speaker: String) async throws -> Data {
        guard !apiKey.isEmpty else { throw TTSError(message: "API Key 未配置") }
        guard !speaker.isEmpty else { throw TTSError(message: "音色 ID 未配置") }

        var req = URLRequest(url: URL(string: url)!)
        // ⭐ 绕过 nsurlsessiond 的共享缓存/连接池：WS 升级失败响应可能被守护进程缓存，
        //    之后每次连接都被立刻取消（-999）。ephemeral 会话 + 强制不缓存。
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        req.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")
        // ⭐⭐ 必须手动设 ASCII User-Agent！App 名是中文「阿岚」，CFNetwork 自动构造的
        //    UA 会把中文百分号编码（%E5%8D%97…）——字节网关直接拒绝握手（-1011 bad response），
        //    表现就是"永远 cancelled / 机械音兜底"。CLI 工具 UA 是纯 ASCII 所以一直没事。
        //    2026-09-23 用本地握手捕获服务器逐头对比抓到真凶。
        req.setValue("makingheralive/1.0", forHTTPHeaderField: "User-Agent")

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: req)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }

        // 收一帧，超时即抛（握手阶段用；超时=掐连接让 receive 醒来）
        func recvFrame(_ secs: UInt64) async throws -> (Int, Int, Data) {
            let w = Task {
                try? await Task.sleep(nanoseconds: secs * 1_000_000_000)
                task.cancel()
            }
            defer { w.cancel() }
            do {
                let msg = try await task.receive()
                guard case .data(let d) = msg else { throw TTSError(message: "服务端回了非二进制帧") }
                return parse(d)
            } catch {
                throw TTSError(message: "等待服务端响应超时/中断")
            }
        }

        // ① 建连 → 等 50
        try await task.send(.data(frame(event: evStartConn, sessionId: nil, json: nil)))
        let (mt0, ev0, pl0) = try await recvFrame(8)
        if mt0 == mtError || (ev0 != evConnStarted && ev0 != 0) {
            throw TTSError(message: "建连被拒：\(errText(pl0))")
        }

        // ② 开始会话（session_id 放在 Optional 段）→ 等 150
        let sid = UUID().uuidString
        try await task.send(.data(frame(event: evStartSess, sessionId: sid,
                                        json: payload(evStartSess, speaker: speaker))))
        let (mt1, ev1, pl1) = try await recvFrame(8)
        if mt1 == mtError || ev1 == evSessFailed {
            throw TTSError(message: "会话开启失败：\(errText(pl1))")
        }

        // ③ 送文本 → 稍等让服务端开始合成 → 结束会话
        try await task.send(.data(frame(event: evTaskRequest, sessionId: sid,
                                        json: payload(evTaskRequest, text: text, speaker: speaker))))
        try? await Task.sleep(nanoseconds: 200_000_000)
        try await task.send(.data(frame(event: evFinishSess, sessionId: sid, json: nil)))

        // ④ 收音频（看门狗兜底：服务端异常不关连接时别永远挂）
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            task.cancel()
        }
        defer { watchdog.cancel() }

        var audio = Data()
        while true {
            let msg: URLSessionWebSocketTask.Message
            do { msg = try await task.receive() }
            catch { break }        // 连接结束（或被看门狗掐断）
            guard case .data(let d) = msg else { continue }
            let (mt, event, pl) = parse(d)
            if mt == mtAudioOnly && event == evTTSResponse {
                if !pl.isEmpty { audio.append(pl) }
            } else if mt == mtError {
                throw TTSError(message: "服务端错误：\(errText(pl))")
            } else if event == evSessFinished {
                break
            } else if event == evSessFailed {
                throw TTSError(message: "会话失败：\(errText(pl))")
            }
        }
        guard !audio.isEmpty else { throw TTSError(message: "没收到音频") }
        return audio
    }
}
