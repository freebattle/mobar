import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())

// 布局自检：离屏渲染一帧后直接退出，不进事件循环
if let index = arguments.firstIndex(of: "--render") {
    let path = arguments.count > index + 1 ? arguments[index + 1] : "/tmp/mobar-preview.png"
    _ = NSApplication.shared  // 绘图需要 AppKit 起来
    exit(Preview.render(to: path) ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// 无 Dock 图标、无窗口，只有菜单栏。Info.plist 里的 LSUIElement 也是为这个。
app.setActivationPolicy(.accessory)
app.run()
