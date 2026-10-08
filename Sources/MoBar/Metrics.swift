import Foundation

/// 一次采样的结果，只保留菜单栏要显示的四个数。
struct Sample {
    /// CPU 总占用百分比，0-100
    let cpuPercent: Double
    /// 内存已用百分比，0-100
    let memPercent: Double
    /// 下行速率，单位 MB/s
    let rxMBs: Double
    /// 上行速率，单位 MB/s
    let txMBs: Double
}

enum Format {
    /// 百分比：固定无小数，宽度靠等宽数字字体稳住。
    static func percent(_ value: Double) -> String {
        let clamped = value.isFinite ? min(max(value, 0), 999) : 0
        return String(format: "%.0f%%", clamped)
    }

    /// 速率：入参是 MB/s，拆成数字和单位两段返回。
    ///
    /// 拆开是为了菜单栏里把单位锚死：合成一个字符串左对齐的话，
    /// “13 KB/s” 和 “3.0 KB/s” 的单位位置会差一个小数点的宽度（实测 2.0pt），
    /// “999 KB/s” 对 “12.3 MB/s” 更是差到 7.2pt，看着在抽。
    static func rate(_ mbs: Double) -> (number: String, unit: String) {
        guard mbs.isFinite, mbs > 0 else { return ("0", "KB/s") }
        let kbs = mbs * 1024
        if kbs < 10 { return (String(format: "%.1f", kbs), "KB/s") }
        if kbs < 1000 { return (String(format: "%.0f", kbs), "KB/s") }
        let mb = kbs / 1024
        if mb < 10 { return (String(format: "%.1f", mb), "MB/s") }
        // 上限卡 999，给数字列留下确定的最大宽度（最宽取值是 “12.3”）
        return (String(format: "%.0f", min(mb, 999)), "MB/s")
    }

    /// tooltip 等纯文本场景用的合并形式
    static func rateText(_ mbs: Double) -> String {
        let value = rate(mbs)
        return "\(value.number) \(value.unit)"
    }
}
