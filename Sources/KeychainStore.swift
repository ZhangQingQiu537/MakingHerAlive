import Foundation
import Security

/// DeepSeek API Key 的 Keychain 存储（脱离 ST 后，Key 由 App 自己管）。
///
/// 为什么用 Keychain 而不是明文文件：
/// ST 现在把 Key 明文存在 `data/default-user/secrets.json` 里（谁都能读）。
/// 迁到 Keychain 后至少跟系统权限走，不会再明文落盘。
///
/// ⚠️ 已知代价（用户权衡后保留钥匙串，2026-09-23）：adhoc 签名每次构建 cdhash 都变，
/// 钥匙串把"重新签名的 App"当陌生程序，**每次构建后可能弹一次授权窗**（输登录密码 +
/// 始终允许）。系统级信任优先于免弹窗。
enum KeychainStore {

    static let service = "com.makingheralive.app"
    static let accountDeepSeek = "deepseek-api-key"
    static let accountVolcano = "volcano-tts-token"
    /// 火山新版控制台 API Key（UUID 格式，v3 WebSocket TTS 用这个）
    static let accountVolcanoAPIKey = "volcano-api-key"
    /// 火山引擎 ARK 平台 Key（文生图用这个，和 TTS Key 分开开通）
    static let accountVolcanoArk = "volcano-ark-key"
    /// 博查搜索 Key（联网补作品剧情知识用）
    static let accountBocha = "bocha-key"

    /// 覆盖保存（已存在就先删再加）
    @discardableResult
    static func saveKey(_ key: String, account: String = accountDeepSeek) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var attrs = base
        attrs[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func loadKey(account: String = accountDeepSeek) -> String? {
        // ⭐ 2026-10-26：先读本地镜像（secrets.json，600 权限）。
        //    adhoc 签名每次构建 cdhash 都变 → 钥匙串每次都要重新授权，
        //    启动被弹窗卡住（boot 走不到"启动完成"）。镜像本来就是同机 600，安全性等价。
        if let v = mirrorValue(account), !v.isEmpty { return v }

        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// 从镜像文件里取一个 key
    private static func mirrorValue(_ account: String) -> String? {
        guard let d = try? Data(contentsOf: mirrorURL),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return nil }
        return o[account]
    }

    // MARK: - 跨进程镜像（供 Python 问候脚本读，权限 600）

    // 旧代码 `migrateFromSTSimplified(secretsPath:)` 已删（Bug 11）：
    // ST 目录已 chmod 555 只读，迁移路径事实上已死；useDirect=true 时 Keychain 里本就有 Key，
    // 不需要再从 ST secrets.json 拉。

    private static var mirrorURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("secrets.json")
    }

    /// 把两个 Key 导出到 600 权限的镜像文件（Python 脚本读不了 Keychain，走文件）。
    /// 每次启动幂等写一次；Key 变了自然覆盖。用户选择钥匙串为主存储，文件只是跨进程桥。
    ///
    /// ⚠️ 2026-09-24 修 Bug 10：先创建空文件 chmod 600，再写入。
    /// 旧代码先 write 再 chmod，第一次写入时文件瞬间是默认 644 权限（race）——
    /// 理论上极小窗口可被同机用户读。新代码：空文件先 600，再覆盖内容，权限不 race。
    static func writeMirror() {
        var dict: [String: String] = [:]
        if let k = loadKey(), !k.isEmpty { dict[accountDeepSeek] = k }
        if let k = loadKey(account: accountVolcanoAPIKey), !k.isEmpty { dict[accountVolcanoAPIKey] = k }
        if let k = loadKey(account: accountVolcanoArk), !k.isEmpty { dict[accountVolcanoArk] = k }
        if let k = loadKey(account: accountBocha), !k.isEmpty { dict[accountBocha] = k }
        guard !dict.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        do {
            try FileManager.default.createDirectory(at: mirrorURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // 1) 先建空文件（如果还没有）并 chmod 600
            if !FileManager.default.fileExists(atPath: mirrorURL.path) {
                FileManager.default.createFile(atPath: mirrorURL.path, contents: nil)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: mirrorURL.path)
            // 2) 再写内容（permissions 不变）
            try data.write(to: mirrorURL, options: .atomic)
        } catch {}
    }
}
