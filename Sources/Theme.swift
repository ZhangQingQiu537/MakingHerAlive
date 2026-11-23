import SwiftUI
import AppKit

/// ⭐ 2026-10-26：跟随系统的配色（v3 冷色）
///
/// 用动态 NSColor：系统切浅色/深色时，SwiftUI 会自动重绘，不用重启 App。
/// 只保留两个主色（墨蓝 / 灰蓝），不加渐变、不加阴影。
extension Color {

    private static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// 页面底色
    static let appPage = dyn(NSColor(red: 0.961, green: 0.969, blue: 0.980, alpha: 1),
                             NSColor(red: 0.063, green: 0.082, blue: 0.102, alpha: 1))

    /// 页眉（深墨蓝）
    static let appHeader = dyn(NSColor(red: 0.122, green: 0.169, blue: 0.220, alpha: 1),
                               NSColor(red: 0.043, green: 0.059, blue: 0.075, alpha: 1))

    /// 她的气泡
    static let appCard = dyn(NSColor.white,
                             NSColor(red: 0.110, green: 0.137, blue: 0.165, alpha: 1))

    /// 你的气泡（灰蓝）
    static let appMine = dyn(NSColor(red: 0.290, green: 0.420, blue: 0.541, alpha: 1),
                             NSColor(red: 0.220, green: 0.333, blue: 0.435, alpha: 1))

    /// 你的气泡上的字
    static let appOnMine = Color.white

    /// 正文
    static let appText = dyn(NSColor(red: 0.122, green: 0.169, blue: 0.220, alpha: 1),
                             NSColor(red: 0.902, green: 0.929, blue: 0.953, alpha: 1))

    /// 次要文字
    static let appSub = dyn(NSColor(red: 0.541, green: 0.592, blue: 0.651, alpha: 1),
                            NSColor(red: 0.565, green: 0.627, blue: 0.686, alpha: 1))

    /// 强调 / 描边
    static let appAccent = dyn(NSColor(red: 0.431, green: 0.565, blue: 0.710, alpha: 1),
                               NSColor(red: 0.510, green: 0.647, blue: 0.788, alpha: 1))

    /// 分割线
    static let appLine = dyn(NSColor(red: 0.882, green: 0.906, blue: 0.933, alpha: 1),
                             NSColor(red: 0.137, green: 0.173, blue: 0.204, alpha: 1))

    /// 系统提示气泡底
    static let appHint = dyn(NSColor(red: 0.988, green: 0.949, blue: 0.941, alpha: 1),
                             NSColor(red: 0.176, green: 0.129, blue: 0.129, alpha: 1))

    /// 输入栏底
    static let appBar = dyn(NSColor(red: 0.929, green: 0.945, blue: 0.961, alpha: 1),
                            NSColor(red: 0.082, green: 0.102, blue: 0.122, alpha: 1))
}
