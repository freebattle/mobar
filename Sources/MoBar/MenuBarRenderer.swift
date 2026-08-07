import AppKit

/// 把两行内容画成 **template image** 交给系统着色，而不是自己挑颜色。
///
/// 之前用 NSColor.labelColor / secondaryLabelColor 自绘，同一时刻在两块屏幕上
/// 标签会解析成不同颜色（实测一块屏上标签亮度 0.443、背景 0.399，几乎看不见；
/// 另一块屏上是 0.942 纯白）。template image 由系统按每块屏幕的菜单栏外观着色，
/// 深浅色、菜单展开时的高亮反色也一并处理掉。
///
/// 版式对着 Mole for Mac 的菜单栏 HUD 逐像素量过（截图 2x，量 ink 包围盒再换算
/// 成字形步进宽度）：
/// - 8.5pt 等宽数字。原来 9pt 偏大，实测 mole 的 CPU/MEM/KB/s ink 宽为
///   33/37/36px，8.5pt 拟合最好。字重用 medium，比 mole 的 regular 略粗一点。
/// - 所有元素同一亮度。mole 的标签和数值偏离度分别是 +0.542 / +0.540，
///   即标签没有做减淡，我们原来把标签压到 65% 反而显脏。
/// - 列位置锚点见下面三个 anchor 常量。
/// - mole 在百分比和速率之间留了约 20pt 空档且里面是空的（最大偏离 ±0.011
///   纯噪声，它没有箭头），我们把 ↑ / ↓ 放进这个空档。
struct MenuBarRenderer {
    struct Model: Equatable {
        let cpu: String
        let mem: String
        let topNumber: String
        let topUnit: String
        let bottomNumber: String
        let bottomUnit: String
        let showLabels: Bool
    }

    /// 上排是上行。想换成上排下行，把这里改成 false。
    static let topIsUpload = true

    /// 箭头字形。mole 没有箭头，这是我们保留的区分方式。
    private static let upGlyph = "↑"
    private static let downGlyph = "↓"

    private static let fontSize: CGFloat = 8.5
    private static let fontWeight = NSFont.Weight.medium

    // MARK: 版式锚点（相对标签列原点，单位 pt，来自对 mole HUD 的测量）

    /// 百分比列右缘
    private static let percentRightAnchor: CGFloat = 48.1
    /// 速率数字列右缘。数字右对齐贴着这条线，位数变化时向左伸缩。
    private static let numberRightAnchor: CGFloat = 79.5
    /// 单位列左缘。锚死不动，这是本次修的错位问题。
    private static let unitLeftAnchor: CGFloat = 83.5

    /// 精简模式没有标签和箭头，用顺序排布
    private let compactPercentToNumber: CGFloat = 8
    private let compactNumberToUnit: CGFloat = 4

    private let font: NSFont
    private let hPad: CGFloat = 4
    private let rowHeight: CGFloat = 9

    private let labelWidth: CGFloat
    private let percentWidth: CGFloat
    private let arrowWidth: CGFloat
    /// 最宽取值是 "12.3"（两位数 + 小数点 + 一位），比 "999" 宽一个小数点
    private let numberWidth: CGFloat
    private let unitWidth: CGFloat

    /// 文字按行盒顶端对齐会整体偏下（实测比 mole 低 1.25pt），
    /// 这里在 init 时离屏量一次 ink 包围盒，把内容真正垂直居中。
    private var verticalNudge: CGFloat

    let barHeight: CGFloat

    init() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: Self.fontSize, weight: Self.fontWeight)
        self.font = font

        func advance(_ text: String) -> CGFloat {
            NSAttributedString(string: text, attributes: [.font: font]).size().width
        }

        labelWidth = max(advance("CPU"), advance("MEM"))
        percentWidth = advance("100%")
        arrowWidth = max(advance(Self.upGlyph), advance(Self.downGlyph))
        numberWidth = max(advance("12.3"), advance("999"))
        unitWidth = max(advance("KB/s"), advance("MB/s"))
        barHeight = NSStatusBar.system.thickness

        verticalNudge = 0
        // 拿刚才那份布局（nudge=0）离屏画一遍，量出 ink 中心和画布中心的差
        let measured = Self.measureNudge(renderer: self)
        verticalNudge = measured
    }

    /// 两种模式宽度不同，切换时 statusItem.length 要跟着改。
    func width(showLabels: Bool) -> CGFloat {
        if showLabels {
            return ceil(hPad * 2 + Self.unitLeftAnchor + unitWidth)
        }
        return ceil(hPad * 2 + percentWidth + compactPercentToNumber
            + numberWidth + compactNumberToUnit + unitWidth)
    }

    func image(for model: Model) -> NSImage {
        let size = NSSize(width: width(showLabels: model.showLabels), height: barHeight)
        // flipped: true 按左上角算坐标，两行位置好推
        let image = NSImage(size: size, flipped: true) { [self] rect in
            draw(model, in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - 绘制

    private func draw(_ model: Model, in rect: NSRect) {
        let top = ((rect.height - rowHeight * 2) / 2).rounded() + verticalNudge
        drawRow(index: 0, top: top, label: "CPU", percent: model.cpu,
                number: model.topNumber, unit: model.topUnit,
                rateUp: Self.topIsUpload, showLabels: model.showLabels)
        drawRow(index: 1, top: top, label: "MEM", percent: model.mem,
                number: model.bottomNumber, unit: model.bottomUnit,
                rateUp: !Self.topIsUpload, showLabels: model.showLabels)
    }

    private func drawRow(index: Int, top: CGFloat, label: String, percent: String,
                         number: String, unit: String, rateUp: Bool, showLabels: Bool) {
        let y = top + CGFloat(index) * rowHeight
        // 画布高度给足，避免小字号在 9pt 行高里被裁掉下缘
        let slot: CGFloat = 12
        func rect(_ x: CGFloat, _ width: CGFloat) -> NSRect {
            NSRect(x: x, y: y, width: width, height: slot)
        }

        if showLabels {
            // 锚点模式：各列位置由 anchor 反算，换字号字重也不会漂
            let percentX = hPad + Self.percentRightAnchor - percentWidth
            let numberX = hPad + Self.numberRightAnchor - numberWidth
            let unitX = hPad + Self.unitLeftAnchor

            draw(label, rect: rect(hPad, labelWidth), align: .left)
            draw(percent, rect: rect(percentX, percentWidth), align: .right)

            // 箭头居中放在百分比和数字之间的空档里
            let gapStart = hPad + Self.percentRightAnchor
            let arrowX = gapStart + max(0, (numberX - gapStart - arrowWidth) / 2)
            // 箭头和正文同字号同亮度，基线自然对齐，不需要 baselineOffset
            draw(rateUp ? Self.upGlyph : Self.downGlyph, rect: rect(arrowX, arrowWidth), align: .center)

            draw(number, rect: rect(numberX, numberWidth), align: .right)
            draw(unit, rect: rect(unitX, unitWidth), align: .left)
        } else {
            // 精简模式：顺序排布，数字仍然右对齐、单位仍然锚死
            var x = hPad
            draw(percent, rect: rect(x, percentWidth), align: .right)
            x += percentWidth + compactPercentToNumber
            draw(number, rect: rect(x, numberWidth), align: .right)
            x += numberWidth + compactNumberToUnit
            draw(unit, rect: rect(x, unitWidth), align: .left)
        }
    }

    private func draw(_ text: String, rect: NSRect, align: NSTextAlignment) {
        guard !text.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = .byClipping
        NSAttributedString(string: text, attributes: [
            .font: font,
            // template image 忽略颜色只取 alpha，这里的纯黑只是载体。
            // 全部元素同一亮度，对齐 mole 的做法。
            .foregroundColor: NSColor.black,
            .paragraphStyle: style,
        ]).draw(in: rect)
    }

    // MARK: - 垂直居中

    /// 用 nudge=0 的版式离屏画一帧，量 ink 包围盒，返回把它居中所需的偏移。
    /// 比写死一个魔法数字可靠：换字号或字重后会自动跟上。
    private static func measureNudge(renderer: MenuBarRenderer) -> CGFloat {
        let model = Model(cpu: "100%", mem: "100%", topNumber: "12.3", topUnit: "MB/s",
                          bottomNumber: "12.3", bottomUnit: "MB/s", showLabels: true)
        let size = NSSize(width: renderer.width(showLabels: true), height: renderer.barHeight)
        let scale = 2

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return 0 }
        rep.size = size

        let probe = NSImage(size: size, flipped: true) { rect in
            renderer.draw(model, in: rect)
            return true
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        probe.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return 0 }
        let bytesPerRow = rep.bytesPerRow, samples = rep.samplesPerPixel
        var inkTop = -1, inkBottom = -1
        for y in 0..<rep.pixelsHigh {
            var hasInk = false
            for x in 0..<rep.pixelsWide where data[y * bytesPerRow + x * samples + 3] > 8 {
                hasInk = true
                break
            }
            if hasInk {
                if inkTop < 0 { inkTop = y }
                inkBottom = y
            }
        }
        guard inkTop >= 0 else { return 0 }

        let inkCenter = Double(inkTop + inkBottom + 1) / 2 / Double(scale)
        let delta = Double(size.height) / 2 - inkCenter
        // 对齐到半点，保证 2x 下落在整像素上
        return CGFloat((delta * 2).rounded() / 2)
    }
}

extension MenuBarRenderer {
    /// 数据正常时的显示内容
    static func model(for sample: Sample, showLabels: Bool) -> Model {
        let up = Format.rate(sample.txMBs)
        let down = Format.rate(sample.rxMBs)
        let top = topIsUpload ? up : down
        let bottom = topIsUpload ? down : up
        return Model(
            cpu: Format.percent(sample.cpuPercent),
            mem: Format.percent(sample.memPercent),
            topNumber: top.number, topUnit: top.unit,
            bottomNumber: bottom.number, bottomUnit: bottom.unit,
            showLabels: showLabels
        )
    }

    /// 断流或数据源不可用时的占位内容。单位留空，不然会出现 "-- KB/s" 这种假读数。
    static func placeholder(showLabels: Bool) -> Model {
        Model(cpu: "--", mem: "--", topNumber: "--", topUnit: "",
              bottomNumber: "--", bottomUnit: "", showLabels: showLabels)
    }
}
