import Foundation

/// 她的作息（2026-11-10）
///
/// 以前只有"睡/醒"两态，工作日和周末一样、中午也一样。
/// 这里把一天切成几段，只做两件事：
///   ① 给 prompt 一句"你现在在做什么"（让她的话有落点）
///   ② 给主动开口做门控（午休不打扰、外出少说话）
///
/// ⚠️ 不做真延迟：回不回、回多快仍由模型判断，这里只给语境。
enum ScheduleStore {

    enum Phase: String {
        case sleep      // 睡
        case morning    // 刚起
        case gallery    // 在画廊
        case lunch      // 午休
        case outside    // 外出（周末下午）
        case evening    // 晚上在家
        case closed     // 夜里（还没睡）

        var label: String {
            switch self {
            case .sleep:    return "睡着"
            case .morning:  return "刚起"
            case .gallery:  return "在画廊"
            case .lunch:    return "午休"
            case .outside:  return "在外面"
            case .evening:  return "在家"
            case .closed:   return "夜里，还没睡"
            }
        }
    }

    static func isWeekend(_ d: Date = Date()) -> Bool {
        let w = Calendar.current.component(.weekday, from: d)   // 1=周日 7=周六
        return w == 1 || w == 7
    }

    /// 当前处于哪一段
    static func phase(_ d: Date = Date()) -> Phase {
        let h = Calendar.current.component(.hour, from: d)
        let m = Calendar.current.component(.minute, from: d)
        let weekend = isWeekend(d)

        if h >= 1 && h < 9 { return .sleep }
        if weekend {
            if h < 10 { return .morning }
            if h == 12 && m >= 30 || h == 13 { return .lunch }   // 周末也吃口饭
            // 2026-11-23：周末 10:00–12:29 与周日 14:00–17:59 原来落到 .closed（"夜里"）
            if h >= 10 && h < 12 || (h == 12 && m < 30) { return .gallery }
            if h >= 14 && h < 18 {
                return Calendar.current.component(.weekday, from: d) == 7 ? .outside : .gallery
            }
            if h >= 18 && h < 23 { return .evening }
            return .closed
        } else {
            if h < 10 { return .morning }
            if h == 12 && m >= 30 || h == 13 { return .lunch }
            if h >= 10 && h < 18 { return .gallery }
            if h >= 18 && h < 23 { return .evening }
            return .closed
        }
    }

    /// 注入 prompt 的一句（她此刻在哪、在干什么）
    static func nowLine(_ d: Date = Date()) -> String {
        switch phase(d) {
        case .sleep:   return "你现在已经睡了（不该回消息）"
        case .morning: return "你刚起来，还没出门（可能在看手机）"
        case .gallery: return "你在画廊，手上多半有事（回得简短一点）"
        case .lunch:   return "你在吃午饭，脑子放空（回得慢一点、句子短）"
        case .outside: return "你在外面跑事，不在电脑前（回得短，可能说\"晚点跟你说\"）"
        case .evening: return "你回家了，这时的你最松"
        case .closed:  return "夜里了，你在家，困但还没睡"
        }
    }

    /// 主动开口要不要压住（午休、外出、睡）
    static func quietForProactive(_ d: Date = Date()) -> Bool {
        switch phase(d) {
        case .sleep, .lunch, .outside: return true
        default: return false
        }
    }
}
