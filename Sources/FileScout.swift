import Foundation
import PDFKit

/// 她自己去看文件（2026-10-29）
///
/// 设计本心（他原话）：
///   "一个阅读文档的工具、一个自我整理能力、一个访问我电脑的能力，这个本身就是必需品…
///    至少在我提出一个非常基础的工作要求的时候她得能做到。"
///
/// 所以这不是"派任务"，是她**自己的手**：
///   · 只读，不写、不删、不覆盖（写/删仍要走 DSH + 确认）
///   · **白名单目录**：文稿 / 桌面 / 下载 / 阿岚工作区 —— 不碰系统、不碰别的项目
///   · 本地解析，0.2 秒，不弹卡、不问"要我帮你弄吗"
///   · 只在她这句话里**真的提到文件**时才动手（不扫全盘）
enum FileScout {

    static let roots: [URL] = {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return ["Documents", "Desktop", "Downloads", "阿岚工作区"]
            .map { home.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }
    }()

    private static let textExts: Set<String> = ["txt", "md", "csv", "json", "log"]

    /// 在白名单里找这个文件（最多下钻 2 层）
    static func locate(_ name: String) -> URL? {
        let want = name.lowercased()
        let stem = (name as NSString).deletingPathExtension.lowercased()
        let fm = FileManager.default
        for root in roots {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                        options: [.skipsHiddenFiles],
                                        errorHandler: { _, _ in true }) else { continue }
            var depthGuard = 0
            for case let url as URL in e {
                depthGuard += 1
                if depthGuard > 4000 { break }
                let n = url.lastPathComponent.lowercased()
                if n == want || (stem.count >= 2 && n.contains(stem)) {
                    return url
                }
            }
        }
        return nil
    }

    /// 读成纯文本（docx 解压抽正文；其它按 UTF-8 读）
    static func read(_ url: URL) -> String? {
        // ⚠️ 2026-10-30 修（审查 §6.2-8）：目录里放一个指向 ~/.ssh 的软链，
        //    原来的白名单只检查"路径前缀"就放行了。这里先解析真实路径，
        //    真实路径必须仍落在白名单目录里，否则一律不读。
        let real = url.resolvingSymlinksInPath().standardizedFileURL.path
        let allowed = roots.contains { r in
            let root = r.resolvingSymlinksInPath().standardizedFileURL.path
            return real == root || real.hasPrefix(root + "/")
        }
        guard allowed else { return nil }

        let ext = url.pathExtension.lowercased()
        if textExts.contains(ext) {
            guard let d = try? Data(contentsOf: url) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        if ext == "docx" { return docxText(url) }
        // ⚠️ 2026-11-03：PDF 以前返回 nil —— 她"看得见文件、读不出内容"。
        //    用系统自带 PDFKit 抽文字，抽不出来（扫描件）就明说。
        if ext == "pdf" { return pdfText(url) }
        return nil
    }

    /// PDF 抽文字（PDFKit，系统自带）。扫描件没有文字层 → 返回 nil
    static func pdfText(_ url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        var out = ""
        for i in 0..<min(doc.pageCount, 60) {
            if let page = doc.page(at: i), let t = page.string { out += t + "\n" }
            if out.count > 20000 { break }
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(20000))
    }

    static func docxText(_ url: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", url.path, "word/document.xml"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let xml = String(data: out, encoding: .utf8), !xml.isEmpty else { return nil }

        var t = xml
        t = t.replacingOccurrences(of: "</w:p>", with: "\n")
        t = t.replacingOccurrences(of: "<w:tab/>", with: "\t")
        t = t.replacingOccurrences(of: "<w:br/>", with: "\n")
        while let a = t.firstIndex(of: "<"), let b = t[a...].firstIndex(of: ">") {
            t.removeSubrange(a...b)
        }
        t = t.replacingOccurrences(of: "&lt;", with: "<")
             .replacingOccurrences(of: "&gt;", with: ">")
             .replacingOccurrences(of: "&amp;", with: "&")
             .replacingOccurrences(of: "&quot;", with: "\"")
             .replacingOccurrences(of: "&apos;", with: "'")
        let lines = t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                      .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

}
