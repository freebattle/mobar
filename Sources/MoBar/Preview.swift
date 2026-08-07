import AppKit

/// 离屏渲染布局自检，不影响正常运行路径。
/// 用法：MoBar --render /tmp/preview.png
///
/// 每种取值组合渲染两遍，分别模拟深色菜单栏（白字）和浅色菜单栏（黑字），
/// 用来确认 template image 的着色在两种外观下都成立。
/// 取值刻意覆盖会挤动版式的几种情况：位数不同、最宽取值、单位切换、断流占位。
enum Preview {
    private struct Case {
        let name: String
        let showLabels: Bool
        /// nil 表示渲染断流占位
        let sample: Sample?
    }

    static func render(to path: String) -> Bool {
        let renderer = MenuBarRenderer()
        let cases: [Case] = [
            // 数值取成和 Mole for Mac 截图一致，方便逐项对位
            Case(name: "mole 同值", showLabels: true,
                 sample: Sample(cpuPercent: 10, memPercent: 59, rxMBs: 5.0 / 1024, txMBs: 4.0 / 1024)),
            // 上下排位数不同：单位列必须纹丝不动
            Case(name: "位数不同", showLabels: true,
                 sample: Sample(cpuPercent: 3, memPercent: 100, rxMBs: 3.0 / 1024, txMBs: 13.0 / 1024)),
            // 最宽取值 + KB/MB 单位切换
            Case(name: "最宽换单位", showLabels: true,
                 sample: Sample(cpuPercent: 100, memPercent: 7, rxMBs: 12.3, txMBs: 999.0 / 1024)),
            Case(name: "精简模式", showLabels: false,
                 sample: Sample(cpuPercent: 3, memPercent: 100, rxMBs: 3.0 / 1024, txMBs: 13.0 / 1024)),
            Case(name: "断流占位", showLabels: true, sample: nil),
        ]

        let backdrops: [(bg: NSColor, tint: NSColor)] = [
            (NSColor(white: 0.40, alpha: 1), .white),
            (NSColor(white: 0.93, alpha: 1), .black),
        ]

        let gap: CGFloat = 8
        let cellWidth = max(renderer.width(showLabels: true), renderer.width(showLabels: false))
        let totalWidth = cellWidth * CGFloat(backdrops.count) + gap * CGFloat(backdrops.count + 1)
        let totalHeight = renderer.barHeight * CGFloat(cases.count) + gap * CGFloat(cases.count + 1)

        let canvas = NSImage(size: NSSize(width: totalWidth, height: totalHeight))
        canvas.lockFocus()
        NSColor(white: 0.65, alpha: 1).setFill()
        NSRect(origin: .zero, size: canvas.size).fill()

        for (row, item) in cases.enumerated() {
            let model = item.sample.map { MenuBarRenderer.model(for: $0, showLabels: item.showLabels) }
                ?? MenuBarRenderer.placeholder(showLabels: item.showLabels)
            let template = renderer.image(for: model)
            for (column, backdrop) in backdrops.enumerated() {
                let origin = NSPoint(
                    x: gap + (cellWidth + gap) * CGFloat(column),
                    y: totalHeight - renderer.barHeight - gap - (renderer.barHeight + gap) * CGFloat(row)
                )
                backdrop.bg.setFill()
                NSRect(origin: origin, size: NSSize(width: cellWidth, height: renderer.barHeight)).fill()

                // 手动模拟系统对 template image 的着色：用 alpha 当蒙版上色
                let tinted = NSImage(size: template.size, flipped: false) { rect in
                    template.draw(in: rect)
                    backdrop.tint.set()
                    rect.fill(using: .sourceIn)
                    return true
                }
                tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        canvas.unlockFocus()

        guard let tiff = canvas.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            let info = "完整=\(Int(renderer.width(showLabels: true)))pt"
                + " 精简=\(Int(renderer.width(showLabels: false)))pt"
                + " barHeight=\(Int(renderer.barHeight))pt"
                + " 行序=" + cases.map(\.name).joined(separator: "/")
            FileHandle.standardError.write(Data("[mobar] rendered \(info) -> \(path)\n".utf8))
            return true
        } catch {
            FileHandle.standardError.write(Data("[mobar] render failed: \(error)\n".utf8))
            return false
        }
    }
}
