import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let renderer = MenuBarRenderer()
    private var source: NativeMetricsSource?
    private var staleTimer: Timer?

    private var lastSample: Sample?
    private var lastUpdate: Date?
    private var failureMessage: String?
    private var displayedModel: MenuBarRenderer.Model?

    private let clipboardStore = ClipboardStore()
    private lazy var clipboardPanel = ClipboardPanelController(store: clipboardStore)
    private var clipboardHotKey: HotKey?

    /// 超过这个时间没有新样本就显示占位符，避免停在最后一帧骗人。
    private static let staleAfter: TimeInterval = 7

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: renderer.width(showLabels: Settings.showLabels))
        statusItem = item
        item.button?.imagePosition = .imageOnly
        item.menu = buildMenu()

        activateSource()
        render()
        applyClipboardSettings()

        // 只负责把「数据断流」翻成占位符，本身不采样
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.render() }
        RunLoop.main.add(timer, forMode: .common)
        staleTimer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        staleTimer?.invalidate()
        source?.stop()
        clipboardStore.stop()
    }

    // MARK: - 剪贴板历史

    private func applyClipboardSettings() {
        clipboardHotKey = nil
        guard Settings.clipboardEnabled else {
            clipboardStore.stop()
            clipboardPanel.close()
            return
        }
        clipboardStore.start()
        let shortcut = Settings.clipboardShortcut
        clipboardHotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers) { [weak self] in
            self?.clipboardPanel.toggle()
        }
    }

    // MARK: - 数据源

    private func activateSource() {
        source?.stop()
        lastSample = nil
        lastUpdate = nil
        failureMessage = nil

        let next = NativeMetricsSource()
        next.onSample = { [weak self] sample in
            guard let self else { return }
            self.lastSample = sample
            self.lastUpdate = Date()
            self.failureMessage = nil
            self.render()
        }
        next.onFailure = { [weak self] message in
            guard let self else { return }
            self.failureMessage = message
            self.lastSample = nil
            self.lastUpdate = nil
            self.render()
        }
        source = next
        next.start()
    }

    // MARK: - 渲染

    private func render() {
        let showLabels = Settings.showLabels
        let stale = lastUpdate.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? true
        let model = (stale ? nil : lastSample).map { MenuBarRenderer.model(for: $0, showLabels: showLabels) }
            ?? MenuBarRenderer.placeholder(showLabels: showLabels)

        // 内容没变就不重画，省掉每 2 秒一次的无谓位图生成
        if model != displayedModel {
            displayedModel = model
            statusItem?.button?.image = renderer.image(for: model)
        }
        statusItem?.length = renderer.width(showLabels: showLabels)
        statusItem?.button?.toolTip = tooltip
    }

    private var tooltip: String {
        if let failureMessage { return failureMessage }
        guard let lastSample, let lastUpdate,
              Date().timeIntervalSince(lastUpdate) <= Self.staleAfter else {
            return "等待数据"
        }
        return "CPU \(Format.percent(lastSample.cpuPercent))"
            + "  内存 \(Format.percent(lastSample.memPercent))"
            + "  ↓\(Format.rateText(lastSample.rxMBs))  ↑\(Format.rateText(lastSample.txMBs))"
    }

    // MARK: - 菜单

    /// 没有设置窗口，开关全在菜单里点，状态存 UserDefaults。
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let labels = NSMenuItem(title: "显示 CPU / MEM 标签", action: #selector(toggleLabels), keyEquivalent: "l")
        labels.target = self
        labels.state = Settings.showLabels ? .on : .off
        menu.addItem(labels)
        menu.addItem(.separator())

        let clipboard = NSMenuItem(title: "剪贴板历史", action: #selector(toggleClipboard(_:)), keyEquivalent: "")
        clipboard.target = self
        clipboard.state = Settings.clipboardEnabled ? .on : .off
        menu.addItem(clipboard)

        let shortcutMenu = NSMenu()
        for shortcut in Settings.ClipboardShortcut.allCases {
            let item = NSMenuItem(title: shortcut.displayName, action: #selector(selectClipboardShortcut(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = shortcut.rawValue
            item.state = Settings.clipboardShortcut == shortcut ? .on : .off
            shortcutMenu.addItem(item)
        }
        let shortcutItem = NSMenuItem(title: "  呼出快捷键", action: nil, keyEquivalent: "")
        shortcutItem.submenu = shortcutMenu
        menu.addItem(shortcutItem)

        let clear = NSMenuItem(title: "  清空历史记录", action: #selector(clearClipboard), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        menu.addItem(.separator())

        let restart = NSMenuItem(title: "重启数据源", action: #selector(restartSource), keyEquivalent: "r")
        restart.target = self
        menu.addItem(restart)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 MoBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        return menu
    }

    @objc private func toggleLabels(_ sender: NSMenuItem) {
        Settings.showLabels.toggle()
        sender.state = Settings.showLabels ? .on : .off
        displayedModel = nil  // 宽度变了，强制重画
        render()
    }

    @objc private func restartSource() {
        source?.restart()
    }

    @objc private func toggleClipboard(_ sender: NSMenuItem) {
        Settings.clipboardEnabled.toggle()
        sender.state = Settings.clipboardEnabled ? .on : .off
        applyClipboardSettings()
    }

    @objc private func selectClipboardShortcut(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let shortcut = Settings.ClipboardShortcut(rawValue: raw) else { return }
        Settings.clipboardShortcut = shortcut
        statusItem?.menu = buildMenu()
        applyClipboardSettings()
    }

    @objc private func clearClipboard() {
        let alert = NSAlert()
        alert.messageText = "清空剪贴板历史？"
        alert.informativeText = "全部 \(clipboardStore.items.count) 条记录会被删除，无法恢复。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            clipboardStore.removeAll()
        }
    }
}
