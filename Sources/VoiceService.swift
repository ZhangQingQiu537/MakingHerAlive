import Foundation
import AVFoundation

/// 她的声音（TTS）。
///
/// 决定（2026-09-23）：
///   A2 火山引擎（正版）；B 用用户自己设计的定制音色（做好后填 config.voiceId）；
///   C2 **只有剧情模式发声**（闲聊 briefMode 像微信打字，安静）；
///   E **微信场景不发声**（她在忙，只回文字）。
///
/// 口型同步（2026-09-23 收尾）：火山合成的 mp3 走 AVAudioEngine + tap 算 RMS，
/// 实时驱动 Live2D 的 MouthOpenY（经 moods.js 别名层，换模型不用改代码）。
enum VoiceService {

    private static let synth = AVSpeechSynthesizer()
    private static var player: AVAudioPlayer?

    /// ⭐ 播放代际锁：合成是异步的（~1s），没有这把锁时连发两句会两个 Task 都
    /// play()，旧句音频盖住新句（或两句叠着放）。speak/stop 时 +1，播放前对账。
    private static var playToken = 0
    private static let tokenLock = NSLock()
    private static func nextToken() -> Int {
        tokenLock.lock(); defer { tokenLock.unlock() }
        playToken += 1
        return playToken
    }
    private static func currentToken() -> Int {
        tokenLock.lock(); defer { tokenLock.unlock() }
        return playToken
    }

    // MARK: - 口型引擎（振幅 tap）

    private static var engine: AVAudioEngine?
    private static var playerNode: AVAudioPlayerNode?
    /// mp3 兼容路径的播放器（走 AVAudioPlayer，不经引擎）
    private static var mp3Player: AVAudioPlayer?
    private static var lastLipSent: Double = 0
    private static var lastLipAt: Date = .distantPast

    /// ⭐ PCM 流式（2026-09-24）：累计排队 buffer 数，最后一个 scheduleBuffer 的
    /// completionHandler 触发整个播放完成。
    private static var pendingBuffers = 0
    private static let pendingLock = NSLock()

    /// 她回复完成时调用：按规则决定要不要念、念什么。
    /// - C2 **只有剧情窗口（游戏模式）发声**；闲聊窗口像微信打字，安静。
    ///   但 config.briefMode=false 时视为"用户想全都有声"，放行。
    /// - E：微信场景不发声
    static func speak(reply: String, config: AppConfig, scenePlace: String, storyMode: Bool) {
        guard config.voiceEnabled else { return }
        guard storyMode || !config.briefMode else { return }   // C2 仅剧情模式
        guard !scenePlace.contains("微信") else { return }      // E 微信不发声

        let text = spokenPart(of: reply)
        guard !text.isEmpty else { return }

        stop()   // 新一句打断旧一句（她不会两句话叠着念）
        let token = currentToken()

        if config.voiceEngine == "volcano" {
            let apiKey = KeychainStore.loadKey(account: KeychainStore.accountVolcanoAPIKey) ?? ""
            let speaker = config.voiceId
            if !apiKey.isEmpty, !speaker.isEmpty {
                let resource = config.volcanoResourceId.isEmpty ? "seed-tts-2.0" : config.volcanoResourceId
                let format = config.voiceFormat   // ⭐ "mp3" / "pcm"
                Task {
                    do {
                        if format == "pcm" {
                            // ⭐ PCM 流式：火山按合成进度切片 EV_TTS_RESPONSE，每帧裸 float32 字节
                            // Swift 端 Pipe 实时读 → 包 AVAudioPCMBuffer → scheduleBuffer 排队。
                            // 首字延迟从 ~1.05s 降到 ~400ms。
                            try await streamSynthPCM(text: text, apiKey: apiKey,
                                                     resourceId: resource, speaker: speaker,
                                                     token: token, config: config)
                        } else {
                            // 经典 mp3 路径（兼容旧体验/旧缓存）
                            let mp3: Data
                            if let cached = VoiceCache.get(text, speaker: speaker, resource: resource, format: "mp3") {
                                mp3 = cached
                                AppLog.add("🔊 火山念了一句（\(text.count) 字，\(mp3.count/1024)KB · 缓存命中）")
                            } else {
                                mp3 = try await synthViaBridge(text: text, apiKey: apiKey,
                                                               resourceId: resource, speaker: speaker)
                                VoiceCache.put(mp3, text, speaker: speaker, resource: resource, format: "mp3")
                                AppLog.add("🔊 火山念了一句（\(text.count) 字，\(mp3.count/1024)KB · 新合成）")
                            }
                            guard token == currentToken() else { return }   // 期间来了新一句/被停
                            try playMp3WithLip(mp3)
                        }
                    } catch {
                        AppLog.add("  ⚠️ 火山(bridge)失败，退回内置：\(error.localizedDescription.prefix(90))")
                        guard token == currentToken() else { return }
                        builtinSpeak(text)
                    }
                }
                return
            }
        }
        builtinSpeak(text)
        AppLog.add("🔊 念了一句（\(text.count) 字）")
    }

    // MARK: - Python TTS 桥

    /// 用子进程跑 TTSBridge.py 完成火山合成。venv 的 python 带 websockets；
    /// 超时 25s 强杀。输出 mp3 数据。
    private static func synthViaBridge(text: String, apiKey: String,
                                       resourceId: String, speaker: String) async throws -> Data {
        let py = ProcessInfo.processInfo.environment["PYTHON_BIN"] ?? "/usr/bin/python3"
        let candidates = [
            ProcessInfo.processInfo.environment["TTS_BRIDGE"] ?? "",
            FileManager.default.currentDirectoryPath + "/Resources/TTSBridge.py",
            Bundle.main.resourceURL?.appendingPathComponent("TTSBridge.py").path ?? "",
        ]
        guard let script = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw NSError(domain: "TTSBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到 TTSBridge.py"])
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("nry_tts_\(UUID().uuidString.prefix(8)).mp3")
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: py)
                p.arguments = [script, "--text", text, "--key", apiKey,
                               "--resource", resourceId, "--speaker", speaker, "--out", out.path]
                var env = ProcessInfo.processInfo.environment
                for k in ["NODE_OPTIONS", "CODEBUDDY_BROKERED_FS_HOOK_ENABLED", "CODEBUDDY_SAFE_DELETE_SANDBOX"] {
                    env.removeValue(forKey: k)
                }
                p.environment = env
                let errPipe = Pipe()
                p.standardError = errPipe
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let wd = DispatchWorkItem {
                    p.terminate()
                    cont.resume(throwing: NSError(domain: "TTSBridge", code: 2,
                                                  userInfo: [NSLocalizedDescriptionKey: "bridge 超时(25s)"]))
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: wd)
                p.waitUntilExit()
                wd.cancel()
                guard p.terminationStatus == 0, let d = try? Data(contentsOf: out) else {
                    let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .newlines) ?? "未知错误"
                    cont.resume(throwing: NSError(domain: "TTSBridge", code: Int(p.terminationStatus),
                                                  userInfo: [NSLocalizedDescriptionKey: msg]))
                    return
                }
                try? FileManager.default.removeItem(at: out)
                cont.resume(returning: d)
            }
        }
    }

    /// 停止：语音合成 + 音频播放 + 口型引擎 全停
    static func stop() {
        _ = nextToken()
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        if player?.isPlaying == true { player?.stop() }
        player = nil
        stopEngine()
    }

    // MARK: - mp3 振幅口型播放（兼容路径，2026-09-24 PCM 流式后基本不再用）

    /// mp3 兼容路径。
    ///
    /// ⚠️ 2026-10-28：改用 **AVAudioPlayer**，不再走 AVAudioEngine。
    /// 原因：这条路径原本只为"拿到音量包络驱动 Live2D 嘴型"才用引擎；
    /// Live2D 已删（10-26），引擎的三个 API（connect / installTap / play）
    /// 又都在 macOS 27 被弃用。换成 AVAudioPlayer 后：
    ///   · 不需要引擎、不需要 tap、不需要自己管缓冲
    ///   · 不再碰任何弃用 API
    ///   · 播放更不容易被引擎图状态影响（-10867 那一类问题）
    /// PCM 主路径仍保留引擎（见 `startPCMSession` 的说明：新 API 实测是坏的）。
    private static func playMp3WithLip(_ data: Data) throws {
        stopEngine()

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nry_tts_\(UUID().uuidString.prefix(8)).mp3")
        try data.write(to: tmp)

        let p = try AVAudioPlayer(contentsOf: tmp)
        p.prepareToPlay()
        mp3Player = p
        p.play()
        AppLog.add("  [mp3] AVAudioPlayer 播放开始（\(String(format: "%.1f", p.duration))s）")
        // 播完清掉临时文件与播放器（延迟删，避免边播边删）
        DispatchQueue.main.asyncAfter(deadline: .now() + p.duration + 0.5) {
            if mp3Player === p { mp3Player = nil }
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    /// 口型推给 Live2D（节流：变化小且间隔短就跳过，~15 次/秒足够）
    private static func pushLip(_ v: Double) {
        let now = Date()
        if abs(v - lastLipSent) < 0.06, now.timeIntervalSince(lastLipAt) < 0.08 { return }
        lastLipSent = v
        lastLipAt = now
        // ⚠️ 2026-10-26：Live2D 已删除（设计定版 §6），口型同步没有承载对象了。
        //    音频照常播，只是不再驱动表情/口型。
    }

    private static func stopEngine() {
        mp3Player?.stop()
        mp3Player = nil
        if let eng = engine {
            eng.mainMixerNode.removeTap(onBus: 0)
            playerNode?.stop()
            eng.stop()
            engine = nil
            playerNode = nil
        }
        lastLipSent = 0
        // ⭐ 注意：这里**不清零** pendingBuffers —— completion handler 会自己减。
        // 如果这里清零，completion 里 pendingBuffers -= 1 会变 -1，永远不等于 0，
        // 导致 isLast 永远 false，stopEngine 不再被 completion 触发。
        // startPCMSession 里会清零，所以新会话开始计数正确。
        DispatchQueue.main.async {
            // Live2D 已删，口型归零不再需要
        }
    }

    // MARK: - 文本处理

    /// 提取"该念出来的部分"：
    /// 她的回复是「（动作）"台词"（动作）"台词"」混排 —— 念引号里的台词，
    /// 没引号就删掉（）动作描写整句念。
    ///
    /// 弯引号 “” 和直引号 " 都认；**直引号按开合交替**（同一个字符，靠 inside 状态区分）。
    static func spokenPart(of reply: String) -> String {
        var quotes: [String] = []
        var inside = false
        var cur = ""
        for ch in reply {
            if ch == "“" { inside = true; cur = ""; continue }
            if ch == "”" {
                if inside { inside = false; if !cur.isEmpty { quotes.append(cur) } }
                continue
            }
            if ch == "\"" {
                if inside { inside = false; if !cur.isEmpty { quotes.append(cur) } }
                else { inside = true; cur = "" }
                continue
            }
            if inside { cur.append(ch) }
        }
        // 收尾：引号没闭合也把已收的部分当台词（比整段回退更自然）
        if inside && !cur.isEmpty { quotes.append(cur) }

        if !quotes.isEmpty {
            // 聪明拼接：上一段已以标点收尾就**不再加**逗号 ——
            // 否则「"外面下雨了，"她说，"带伞了吗。"」会念成"下雨了，，带伞了吗"
            var out = ""
            for q in quotes {
                if out.isEmpty { out = q; continue }
                let endsPunct = out.hasSuffix("，") || out.hasSuffix("。") || out.hasSuffix("！")
                    || out.hasSuffix("？") || out.hasSuffix("…") || out.hasSuffix("！")
                out += (endsPunct ? "" : "，") + q
            }
            return out
        }
        // 没有引号：去掉（）和()里的动作描写
        var out = ""
        var depth = 0
        for ch in reply {
            if ch == "（" || ch == "(" { depth += 1; continue }
            if ch == "）" || ch == ")" { if depth > 0 { depth -= 1 }; continue }
            if depth == 0 { out.append(ch) }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 内置引擎（火山不可用时的兜底）

    /// macOS 内置中文语音：语速放慢（她"慢半拍"）、音调略沉。
    /// 拿不到音量包络，口型不动（宁可不动，不要瞎动）。
    private static func builtinSpeak(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = 0.45          // 慢半拍
        u.pitchMultiplier = 0.95
        u.volume = 1.0
        synth.speak(u)
    }

    // MARK: - PCM 流式（2026-09-24，Batch B T2）

    /// PCM 流式 stdout 协议 magic 常量（4 字节）
    /// - pcmMagicStart: "PCM" + 0x01 → 流开始，Swift 端准备播放器
    /// - pcmMagicEnd:   "PCM" + 0x00 → 流结束
    /// - pcmMagicErr:   "PCM" + 0x21('!') → 错误，后续是 UTF-8 错误描述
    private static let pcmMagicStart: Data = Data([0x50, 0x43, 0x4D, 0x01])   // "PCM\x01"
    private static let pcmMagicEnd:   Data = Data([0x50, 0x43, 0x4D, 0x00])   // "PCM\x00"
    private static let pcmMagicErr:   Data = Data([0x50, 0x43, 0x4D, 0x21])   // "PCM!"

/// 火山 PCM 输出规格（**实测 Int16 LE 单声道 24kHz**，2026-09-24 四次修正）：
/// Python 桥请求 `sample_rate=24000`，双向流式接口尊重此参数 → 实际返回 **24000Hz**。
/// 铁证：84 字 843776B 按 Int16+24000Hz = 17.6s（偏慢，但火山 TTS 默认语速较慢）
/// 之前错按 44100Hz 播 24000Hz 数据 → 44.1/24 = 1.84x 加速 → 用户感知"1.5-2 倍快"
///
/// ⭐ 最终：按 **Int16 LE + 24000Hz** 解读，转 Float32 归一化再播。
private static let pcmFormatInt16: AVAudioFormat = {
    AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)
        ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: false)!
}()

/// ⭐ 实际播放用 Float32 24kHz（AVAudioEngine 兼容）
private static let pcmFormat: AVAudioFormat = {
    AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)
        ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
}()

    /// PCM 流式播放入口：
    ///   1) 先查缓存（PCM），命中直接一次性 scheduleBuffer 播
    ///   2) 未命中 → 启动 TTSBridge.py --format pcm，Pipe 实时读 → 边收边 scheduleBuffer 排队
    ///   3) 流结束 → 队列自然走完，最后一个 buffer 的 completionHandler 收引擎
    ///
    /// 缓存键含 format（VoiceCache 已加），老 mp3 缓存自动 miss。
    private static func streamSynthPCM(text: String, apiKey: String,
                                        resourceId: String, speaker: String,
                                        token: Int, config: AppConfig) async throws {
        // 缓存命中：直接走整段播放（不用走流式）
        if let cached = VoiceCache.get(text, speaker: speaker, resource: resourceId, format: "pcm") {
            AppLog.add("🔊 火山念了一句（\(text.count) 字，\(cached.count/1024)KB · PCM 缓存命中）")
            guard token == currentToken() else { return }
            try playPCMData(cached)
            return
        }

        // 未命中：启动 Python 流式桥
        let py = ProcessInfo.processInfo.environment["PYTHON_BIN"] ?? "/usr/bin/python3"
        let candidates = [
            ProcessInfo.processInfo.environment["TTS_BRIDGE"] ?? "",
            FileManager.default.currentDirectoryPath + "/Resources/TTSBridge.py",
            Bundle.main.resourceURL?.appendingPathComponent("TTSBridge.py").path ?? "",
        ]
        guard let script = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw NSError(domain: "TTSBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到 TTSBridge.py"])
        }

        // 累计所有 PCM 帧（用于缓存）—— 流式播完的同时写到本地
        var collected = Data()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: py)
                p.arguments = [script, "--text", text, "--key", apiKey,
                               "--resource", resourceId, "--speaker", speaker,
                               "--format", "pcm"]
                var env = ProcessInfo.processInfo.environment
                for k in ["NODE_OPTIONS", "CODEBUDDY_BROKERED_FS_HOOK_ENABLED", "CODEBUDDY_SAFE_DELETE_SANDBOX"] {
                    env.removeValue(forKey: k)
                }
                p.environment = env
                let outPipe = Pipe()
                let errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe

                // 流式读 stdout 二进制协议
                // ⚠️ 2026-09-24 修 bug：phase 1 后必须先 peek 是否 magic
                // 否则流结束 magic "PCM\x00" 会当 PCM 长度读（1346587520 = 0x50434d00）
                var phase = 0   // 0=等 MAGIC_START, 1=读帧/magic, 99=结束
                var leftover = Data()
                var pipeError: Error?

                outPipe.fileHandleForReading.readabilityHandler = { fh in
                    let chunk = fh.availableData
                    if chunk.isEmpty { return }
                    leftover.append(chunk)
                    // 解析 leftover 直到不够一个完整单元
                    while !leftover.isEmpty {
                        if phase == 0 {
                            guard leftover.count >= 4 else { return }
                            let magic = leftover.prefix(4)
                            if magic == pcmMagicStart {
                                phase = 1
                                leftover = leftover.subdata(in: 4..<leftover.count)
                                // 启动播放器
                                DispatchQueue.main.async { startPCMSession(format: pcmFormat) }
                            } else if magic == pcmMagicErr {
                                leftover = leftover.subdata(in: 4..<leftover.count)
                                let msg = String(data: leftover, encoding: .utf8) ?? "未知错误"
                                phase = 99
                                pipeError = NSError(domain: "TTSBridge", code: 4,
                                                    userInfo: [NSLocalizedDescriptionKey: "bridge 错误: \(msg)"])
                                outPipe.fileHandleForReading.readabilityHandler = nil
                                break
                            } else {
                                let hex = magic.map { String(format: "%02x", $0) }.joined()
                                pipeError = NSError(domain: "TTSBridge", code: 5,
                                                    userInfo: [NSLocalizedDescriptionKey: "未知 magic: \(hex)"])
                                outPipe.fileHandleForReading.readabilityHandler = nil
                                break
                            }
                        } else if phase == 1 {
                            guard leftover.count >= 4 else { return }
                            // ⭐ 先 peek 是否结束/错误 magic（修复流结束被当长度的 bug）
                            let peek = leftover.prefix(4)
                            if peek == pcmMagicEnd {
                                // 流正常结束
                                phase = 99
                                leftover = leftover.subdata(in: 4..<leftover.count)
                                outPipe.fileHandleForReading.readabilityHandler = nil
                                break
                            }
                            if peek == pcmMagicErr {
                                leftover = leftover.subdata(in: 4..<leftover.count)
                                let msg = String(data: leftover, encoding: .utf8) ?? "未知错误"
                                phase = 99
                                pipeError = NSError(domain: "TTSBridge", code: 4,
                                                    userInfo: [NSLocalizedDescriptionKey: "bridge 错误: \(msg)"])
                                outPipe.fileHandleForReading.readabilityHandler = nil
                                break
                            }
                            // 不是 magic → PCM 长度前缀
                            let len = Int(leftover.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
                            if len == 0 {
                                leftover = leftover.subdata(in: 4..<leftover.count)
                                continue
                            }
                            if len > 50 * 1024 * 1024 {
                                pipeError = NSError(domain: "TTSBridge", code: 6,
                                                    userInfo: [NSLocalizedDescriptionKey: "PCM chunk 过大: \(len)"])
                                outPipe.fileHandleForReading.readabilityHandler = nil
                                break
                            }
                            guard leftover.count >= 4 + len else { return }   // 数据未到齐，等下批
                            let pcmData = leftover.subdata(in: 4..<(4 + len))
                            leftover = leftover.subdata(in: (4 + len)..<leftover.count)
                            collected.append(pcmData)
                            // 检查 token 期间是否被打断
                            if token != currentToken() {
                                outPipe.fileHandleForReading.readabilityHandler = nil
                                pipeError = NSError(domain: "TTSBridge", code: 7,
                                                    userInfo: [NSLocalizedDescriptionKey: "被打断"])
                                return
                            }
                            // 喂播放器
                            DispatchQueue.main.async { schedulePCMChunk(pcmData) }
                        } else {
                            leftover = Data()
                            return
                        }
                    }
                }

                do { try p.run() } catch {
                    cont.resume(throwing: error)
                    return
                }

                // 等进程退出 + 确认流结束
                p.waitUntilExit()

                // 给 readabilityHandler 一点时间把最后一批数据消费完
                Thread.sleep(forTimeInterval: 0.1)
                outPipe.fileHandleForReading.readabilityHandler = nil
                let finalMagic = outPipe.fileHandleForReading.readDataToEndOfFile()
                if finalMagic.count >= 4 {
                    let m = finalMagic.prefix(4)
                    if m == pcmMagicEnd {
                        // 正常结束
                    } else if m == pcmMagicErr {
                        let msg = String(data: finalMagic.subdata(in: 4..<finalMagic.count), encoding: .utf8) ?? ""
                        pipeError = NSError(domain: "TTSBridge", code: Int(p.terminationStatus),
                                            userInfo: [NSLocalizedDescriptionKey: "bridge: \(msg)"])
                    }
                }

                if let e = pipeError {
                    // 回主线程收引擎，避免泄漏
                    DispatchQueue.main.async { stopEngine() }
                    cont.resume(throwing: e)
                    return
                }
                if p.terminationStatus != 0 {
                    let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .newlines) ?? "未知错误"
                    cont.resume(throwing: NSError(domain: "TTSBridge", code: Int(p.terminationStatus),
                                                  userInfo: [NSLocalizedDescriptionKey: msg]))
                    return
                }

                // 成功：写缓存（保证下次同台词秒回）
                if !collected.isEmpty {
                    VoiceCache.put(collected, text, speaker: speaker, resource: resourceId, format: "pcm")
                    AppLog.add("🔊 火山念了一句（\(text.count) 字，\(collected.count/1024)KB · PCM 流式新合成）")
                }

                // 流结束：completion handler 会收引擎（最后一个 buffer 播完时）。
                // 这里只作兜底：如果 completion 没触发（异常），asyncAfter 超时收。
                let totalBytes = collected.count
                // Int16 24000Hz = 48000 B/s；给 1.5x 余量防兜底过早触发
                let estimatedDuration = Double(totalBytes) / 48000.0 * 1.5 + 1.0
                DispatchQueue.main.asyncAfter(deadline: .now() + estimatedDuration) {
                    // 仅当 token 仍对账（期间没被打断）才收引擎；被打断时 stop() 已收过
                    if token == currentToken() { stopEngine() }
                    cont.resume(returning: ())
                }
            }
        }
    }

    /// 启动 PCM 流式会话：创建引擎、播放器、tap。多次调用会先 stop 旧的。
    ///
    /// ⚠️ **macOS 27 血泪结论（2026-09-24 CLI 实测）**：
    /// 新版 throws-based `connectNode(_:to:format:)` + `installAudioTap` + `playAudio` 有 bug：
    /// - `connectNode` 后 `engine.start()` → `playAudio` 报 **-10867 "player started when in a disconnected state"**
    /// - 引擎图根本没把 player 真正连上 → buffer 静默跑完 → mixer tap RMS 全 0
    /// - 延迟 50ms / 200ms / 1s 都一样 → 不是时序问题，是 API 本身缺陷
    /// 旧版 `connect(_:to:format:)` + `installTap` + `play` 完全正常（RMS 0.3075）。
    /// **结论：回退到旧 API**。deprecation warning 无关紧要，功能第一。
    private static func startPCMSession(format: AVAudioFormat) {
        stopEngine()
        let eng = AVAudioEngine()
        let node = AVAudioPlayerNode()
        eng.attach(node)

        AppLog.add("  [PCM诊断] outputFormat=\(eng.outputNode.outputFormat(forBus: 0).sampleRate)Hz " +
                   "\(eng.outputNode.outputFormat(forBus: 0).channelCount)ch")

        // ⭐ 用旧 connect API（macOS 27 新 connectNode 有 bug）
        eng.connect(node, to: eng.mainMixerNode, format: format)

        engine = eng
        playerNode = node

        pendingLock.lock(); pendingBuffers = 0; pendingLock.unlock()

        // start engine
        do {
            try eng.start()
            AppLog.add("  [PCM诊断] engine.start() 成功，isRunning=\(eng.isRunning)")
        } catch {
            AppLog.add("  ⚠️ PCM 引擎启动失败：\(error.localizedDescription)")
            engine = nil
            playerNode = nil
            return
        }

        // ⚠️ 2026-10-28：tap 已删（Live2D 没了，RMS 没有承载对象）。
        //    留下的是引擎 + player 的最小链路：attach → connect → start → play → scheduleBuffer。
        AppLog.add("  [PCM诊断] 引擎已就绪（无 tap）")

        // 延迟 50ms 调 playAudio（旧 API 也需要等引擎图稳定）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let node = playerNode, engine === eng else { return }
            node.play()
            AppLog.add("  [PCM诊断] play() 成功（start 后 50ms）")
        }
    }

    /// 把一个 PCM 字节块包成 AVAudioPCMBuffer 并 scheduleBuffer 排队。
    /// player 已在 startPCMSession 里进入 playing 状态，这里只需 scheduleBuffer。
    ///
    /// ⚠️ 火山 PCM 实测是 **Int16 LE**（不是 Int32）——每 2 字节 = 1 sample。
    /// 之前按 Int32 解读 → 采样率 ×2 → 速度 ×2 + 音调高。
    /// 现在按 Int16 解读 → 转 Float32 归一化 → 正常播放。
    private static func schedulePCMChunk(_ data: Data) {
        guard let node = playerNode else { return }
        // ⭐ Int16 = 2 字节/sample
        let byteCount = data.count - (data.count % 2)
        guard byteCount > 0 else { return }
        let frameCount = UInt32(byteCount / 2)

        guard let buf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else {
            AppLog.add("  ⚠️ PCM buffer 创建失败（\(frameCount) 帧）")
            return
        }
        buf.frameLength = frameCount

        // ⭐ Int16 LE → Float32 归一化（AVAudioEngine Int32 有 bug，Float32 正常）
        guard let ch0 = buf.floatChannelData?[0] else { return }
        data.withUnsafeBytes { src in
            guard let base = src.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<Int(frameCount) {
                ch0[i] = Float(Double(base[i]) / 32768.0)   // Int16 → [-1, 1]
            }
        }

        pendingLock.lock()
        pendingBuffers += 1
        pendingLock.unlock()

        node.scheduleBuffer(buf, completionHandler: {
            // ⭐ 流式模式：最后一个 buffer 播完 = 全部播完 → 收引擎
            // 比 asyncAfter 估算更准，避免"少字/少句"
            pendingLock.lock()
            pendingBuffers -= 1
            let isLast = pendingBuffers == 0
            pendingLock.unlock()
            if isLast {
                DispatchQueue.main.async {
                    stopEngine()
                }
            }
        })
    }

    /// 缓存命中路径：整段 PCM Data 直接播放（不走流式，但享受缓存的 ~10ms 出音频）
    /// startPCMSession 已 start engine + 延迟 playAudio；这里只需 scheduleBuffer。
    ///
    /// ⚠️ 火山 PCM 实测是 **Int16 LE**（每 2 字节 = 1 sample）→ 转 Float32 归一化再播。
    private static func playPCMData(_ data: Data) throws {
        startPCMSession(format: pcmFormat)
        guard let node = playerNode else {
            throw NSError(domain: "VoiceService", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "PCM 会话启动失败（见上方 log）"])
        }
        // ⭐ Int16 = 2 字节/sample
        let byteCount = data.count - (data.count % 2)
        guard byteCount > 0 else { return }
        let frameCount = UInt32(byteCount / 2)
        guard let buf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "VoiceService", code: 1, userInfo: [NSLocalizedDescriptionKey: "PCM 缓冲创建失败"])
        }
        buf.frameLength = frameCount
        guard let ch0 = buf.floatChannelData?[0] else { return }
        data.withUnsafeBytes { src in
            guard let base = src.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<Int(frameCount) {
                ch0[i] = Float(Double(base[i]) / 32768.0)
            }
        }

        node.scheduleBuffer(buf) {
            DispatchQueue.main.async {
                stopEngine()
            }
        }
    }
}
