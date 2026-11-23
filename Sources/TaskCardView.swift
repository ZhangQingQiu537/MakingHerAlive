import SwiftUI
import AppKit

/// ⭐ 2026-10-26：任务卡（聊天流里的那一条）
///
/// 设计原则（见 `设计-外挂DSH与任务卡-20261026.md`）：
/// - 它**是她的一条消息**，不是系统通知
/// - 不显示百分比，只说「第几步 / 在做什么」
/// - 点开是抽屉，不是新页面
struct DSHTaskCardView: View {
    let task: DSHTask
    var onTap: ((DSHTask) -> Void)? = nil
    /// 权限三选一：(decision, always)
    var onPermission: ((String, Bool) -> Void)? = nil

    private var accent: Color {
        switch task.status {
        case "done":                 return Color(red: 0.37, green: 0.61, blue: 0.48)
        case "failed", "timeout":    return Color(red: 0.73, green: 0.42, blue: 0.42)
        case "waiting_permission":   return Color(red: 0.75, green: 0.54, blue: 0.32)
        case "cancelled":            return Color(red: 0.55, green: 0.58, blue: 0.62)
        default:                     return Color.appAccent
        }
    }

    private var title: String {
        switch task.status {
        case "queued":              return "排队中 · \(task.title)"
        case "done":                return "\(task.title) · 好了"
        case "failed":              return "\(task.title) · 没弄成"
        case "timeout":             return "\(task.title) · 超时了"
        case "cancelled":           return "\(task.title) · 已停"
        case "waiting_permission":  return "\(task.title) · 需要你定"
        case "long_running":        return "\(task.title) · 还在做"
        default:                    return task.title
        }
    }

    private var subtitle: String {
        if !task.summary.isEmpty && ["done", "failed", "timeout", "refused"].contains(task.status) {
            return task.summary
        }
        if task.status == "queued" { return "前面还有任务" }
        if task.status == "waiting_permission", let r = task.request {
            return "要\(r.kind == "network" ? "联网" : r.kind)：\(r.target)"
        }
        return task.currentStep.isEmpty ? "准备中…" : task.currentStep
    }

    private var progress: Double {
        switch task.status {
        case "done":    return 1
        case "queued":  return 0.05
        case "waiting_permission", "cancelled", "failed", "timeout": return 0
        default:        return 0.55
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                    .opacity(task.status == "running" ? 0.9 : 1)
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color.appText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            HStack(alignment: .top, spacing: 8) {
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color.appSub)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if task.durationMs > 0 {
                    Text(Self.dur(task.durationMs))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(Color.appSub)
                }
            }

            if progress > 0 {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.appLine)
                        Capsule().fill(accent.opacity(0.85))
                            .frame(width: max(6, g.size.width * progress))
                    }
                }
                .frame(height: 2)
            }

            if task.status == "waiting_permission" {
                HStack(spacing: 8) {
                    pill("允许这次", filled: true, action: { onPermission?("allow_once", false) })
                    // 只有网络类能兑现「总是允许」（写进 权限策略.json 后由任务中心自动放行）
                    if task.request?.kind == "network" {
                        pill("总是允许", filled: false, action: { onPermission?("allow_always", true) })
                    }
                    pill("不行", filled: false, action: { onPermission?("deny", false) })
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: 520, alignment: .leading)
        .background(Color.appCard)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.appLine, lineWidth: 0.5)
        )
        .cornerRadius(14)
        .contentShape(Rectangle())
        .onTapGesture { onTap?(task) }
    }

    private func pill(_ t: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t)
            .font(.system(size: 12))
            .foregroundColor(filled ? .white : Color.appText)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(filled ? Color.appMine
                                 : Color.appBar)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.appLine, lineWidth: filled ? 0 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    static func dur(_ ms: Int) -> String {
        let s = ms / 1000
        return s < 60 ? "\(s)s" : "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// 抽屉：看步骤、产物、取消
struct DSHTaskDetailView: View {
    let task: DSHTask
    var onCancel: (() -> Void)? = nil
    var onPermission: ((String, Bool) -> Void)? = nil
    var onExtend: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss


    private var statusColor: Color {
        switch task.status {
        case "done":               return Color(red: 0.37, green: 0.61, blue: 0.48)
        case "failed", "timeout":  return Color(red: 0.73, green: 0.42, blue: 0.42)
        case "waiting_permission": return Color(red: 0.75, green: 0.54, blue: 0.32)
        case "cancelled":          return Color(red: 0.55, green: 0.58, blue: 0.62)
        default:                   return Color.appAccent
        }
    }

    private var statusLine: String {
        switch task.status {
        case "queued":             return "排队中"
        case "running":            return task.currentStep.isEmpty ? "准备中…" : task.currentStep
        case "long_running":       return "还在做（已超 8 分钟）"
        case "waiting_permission": return task.request.map { "需要你决定：\($0.kind) · \($0.target)" } ?? "等你决定"
        case "done":               return "已完成"
        case "failed":             return "没弄成"
        case "timeout":            return "超时停了"
        case "refused":            return "没授权，已放弃"
        case "cancelled":          return "已取消"
        default:                   return task.status
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(task.title).font(.system(size: 15, weight: .medium))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // ⭐ 状态块：跑着的时候 detail 还是空的，这里必须给出"现在在干嘛"
                    HStack(spacing: 8) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(statusLine)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        if task.durationMs > 0 {
                            Text(DSHTaskCardView.dur(task.durationMs))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(10)
                    .background(Color.appCard)
                    .cornerRadius(9)

                    if !task.summary.isEmpty {
                        Text(task.summary)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }

                    if task.status == "waiting_permission", let r = task.request {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("它想要：\(r.kind) · \(r.target)").font(.system(size: 13, weight: .medium))
                            Text(r.reason).font(.system(size: 12)).foregroundColor(.secondary)
                            HStack(spacing: 8) {
                                Button("允许这次") { onPermission?("allow_once", false); dismiss() }
                                    .buttonStyle(.borderedProminent)
                                // 只有网络类能兑现「总是允许」，其它类型不摆这个按钮（避免假按钮）
                                if r.kind == "network" {
                                    Button("总是允许") { onPermission?("allow_always", true); dismiss() }
                                        .buttonStyle(.bordered)
                                }
                                Button("不行") { onPermission?("deny", false); dismiss() }
                                    .buttonStyle(.bordered)
                            }
                            .font(.system(size: 12))
                            .padding(.top, 2)
                        }
                        .padding(12)
                        .background(Color.appHint)
                        .cornerRadius(10)
                    }

                    ForEach(Array(task.detail.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Color(red: 0.37, green: 0.61, blue: 0.48))
                                .padding(.top, 2)
                            Text(line).font(.system(size: 13)).foregroundColor(.primary)
                        }
                    }

                    if !task.artifacts.isEmpty {
                        Divider().padding(.vertical, 4)
                        ForEach(task.artifacts, id: \.self) { a in
                            Button {
                                // 文件在 → 在 Finder 里选中；文件没了 → 打开任务目录，别拉起空窗口
                                if FileManager.default.fileExists(atPath: a) {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a)])
                                } else {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: task.dir))
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc")
                                        .font(.system(size: 12))
                                        .foregroundColor(Color.appAccent)
                                    Text(URL(fileURLWithPath: a).lastPathComponent)
                                        .font(.system(size: 13)).lineLimit(1)
                                    Spacer()
                                    Image(systemName: "arrow.up.forward.square")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if task.status == "long_running" {
                        HStack(spacing: 8) {
                            Button("继续等 10 分钟") { onExtend?(); dismiss() }
                                .buttonStyle(.borderedProminent)
                            Button("停掉") { onCancel?(); dismiss() }
                                .buttonStyle(.bordered)
                        }
                        .font(.system(size: 12))
                        .padding(.top, 4)
                    }

                    if task.inputTokens > 0 {
                        Text("用时 \(DSHTaskCardView.dur(task.durationMs)) · \(task.inputTokens + task.outputTokens) tokens · \(TaskCost.text(task))")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 18)
            }

            if !task.isTerminal {
                Button {
                    onCancel?()
                    dismiss()
                } label: {
                    Text("别弄了")
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.appHint)
                        .foregroundColor(Color(red: 0.73, green: 0.42, blue: 0.42))
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18).padding(.bottom, 16)
            }
        }
    }
}

/// ⭐ 2026-10-26：任务记录（最近 30 天）
struct DSHTaskHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tasks: [DSHTask] = DSHTaskCenter.shared.recentTasks(hours: 24 * 30)
    @State private var selected: DSHTask?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("任务记录").font(.system(size: 15, weight: .medium))
                Spacer()
                Text("\(tasks.count) 条").font(.system(size: 11)).foregroundStyle(.secondary)
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            Divider()

            if tasks.isEmpty {
                VStack(spacing: 8) {
                    Text("还没有任务").font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("跟她说「帮我整理…」就会有了").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(tasks.reversed()) { t in
                            Button { selected = t } label: { row(t) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 460, height: 540)
        .background(Color.appPage)
        .sheet(item: $selected) { t in
            DSHTaskDetailView(task: t, onCancel: { DSHTaskCenter.shared.cancel(id: t.id) },
                              onExtend: { DSHTaskCenter.shared.extend(id: t.id) })
                .frame(width: 420, height: 460)
        }
    }

    private func row(_ t: DSHTask) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color(t.status)).frame(width: 7, height: 7).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(t.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.appText)
                    .lineLimit(1)
                if !t.summary.isEmpty {
                    Text(t.summary).font(.system(size: 11.5)).foregroundStyle(Color.appSub).lineLimit(2)
                }
                Text("\(short(t.createdAt)) · \(DSHTaskCardView.dur(t.durationMs))")
                    .font(.system(size: 10.5)).foregroundStyle(Color.appSub)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Color.appSub)
        }
        .padding(11)
        .background(Color.appCard)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.appLine, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func color(_ s: String) -> Color {
        switch s {
        case "done": return Color(red: 0.37, green: 0.61, blue: 0.48)
        case "failed", "timeout": return Color(red: 0.73, green: 0.42, blue: 0.42)
        case "waiting_permission", "long_running": return Color(red: 0.75, green: 0.54, blue: 0.32)
        default: return Color.appAccent
        }
    }

    private func short(_ iso: String) -> String {
        guard let d = ISO.fmt.date(from: iso) else { return "" }
        let f = DateFormatter(); f.dateFormat = "M-d HH:mm"
        return f.string(from: d)
    }
}
