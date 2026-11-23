import Foundation

/// ⭐ 2026-10-26：产物内容体检
///
/// 为什么需要：DSH 沙箱只限制**写**、不限制**读**（实测能读 /etc/hosts 并写进工作区）。
/// 模型要是被任务文本带偏，可能把 ~/.ssh、.env 抄进产物目录。
/// 这里在**产物落地后**再做一道检查：看起来像密钥/凭据的，不向她展示、不给他点开。
enum SensitiveScan {

    /// 文件名黑名单（大小写不敏感）
    private static let badNames: Set<String> = [
        ".env", ".netrc", "id_rsa", "id_ed25519", "id_ecdsa",
        "credentials", "credentials.json", "secrets.json",
        ".npmrc", ".pypirc", "known_hosts",
    ]

    /// 内容特征
    private static let signatures: [(String, String)] = [
        ("BEGIN OPENSSH PRIVATE KEY", "OpenSSH 私钥"),
        ("BEGIN RSA PRIVATE KEY", "RSA 私钥"),
        ("BEGIN PRIVATE KEY", "私钥"),
        ("BEGIN EC PRIVATE KEY", "EC 私钥"),
        ("aws_secret_access_key", "AWS 凭据"),
        ("sk-ant-", "Anthropic Key"),
        ("sk-proj-", "OpenAI Key"),
        ("ghp_", "GitHub Token"),
        ("xoxb-", "Slack Token"),
    ]

    /// 返回 nil = 干净；否则返回原因
    static func reason(for path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent.lowercased()
        if badNames.contains(name) { return "文件名像凭据" }
        if name.hasPrefix(".env") { return "dotenv 文件" }

        // 只看文本。⚠️ 2026-10-28 修 M-05（审查报告）：原来 size ≥ 2MB 直接 `return nil`（放行），
        // 等于一把 2MB 以上的私钥随便过。现在超限只读前 2MB 继续查。
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, size > 0 else { return nil }
        let fh = try? FileHandle(forReadingFrom: url)
        defer { try? fh?.close() }
        let data = (try? fh?.read(upToCount: 2_000_000)) ?? nil ?? Data()
        // ⚠️ 2026-10-28 修 M-05：不能"解成功一种就只查那一种"。
        //    UTF-16LE（无 BOM）会被 .utf16 解成一堆错位字符 → 特征串永远匹配不到。
        //    正确做法：**每一种能解出来的文本都查一遍**，任一中命中就报。
        let candidates = [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1]
            .compactMap { String(data: data, encoding: $0) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return nil }
        for text in candidates {
            for (sig, why) in signatures where text.contains(sig) { return why }
        }
        guard let text = candidates.first else { return nil }

        // KEY=值 形式
        // ⚠️ 修 M-05：原来要**两条**才算，单行 `api_key=1234567890` 直接被放行。现在一条就报。
        let keys = ["api_key", "apikey", "secret", "token", "password", "passwd", "access_key"]
        for line in text.split(separator: "\n").prefix(200) {
            let l = line.lowercased()
            guard l.contains("=") else { continue }
            let k = l.split(separator: "=").first.map(String.init) ?? ""
            if keys.contains(where: { k.contains($0) }) && l.count > 12 { return "像含凭据的配置" }
        }

        // JSON 形式（单行也算）：按 , 和换行切块，再看 "key": "value"
        let jsonKeys = ["api_key", "apikey", "secret", "token", "password", "access_key", "private_key"]
        let chunks = text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "{" }).prefix(300)
        for c in chunks {
            let l = c.lowercased()
            guard let colon = l.firstIndex(of: ":") else { continue }
            let key = l[..<colon]
            guard jsonKeys.contains(where: { key.contains($0) }) else { continue }
            let value = l[l.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"\n\t"))
            // 修 M-05：单字段也算（原来要两条）
            if value.count >= 8 { return "像含凭据的 JSON" }
        }

        return nil
    }
}
