import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let renderer = MenuBarRenderer()
    private var source: MetricsSource?
    private var staleTimer: Timer?

    private var lastSample: Sample?
    private var lastUpdate: Date?
    private var failureMessage: String?
    private var displayedModel: MenuBarRenderer.Model?

    /// 超过这个时间没有新样本就显示占位符，避免停在最后一帧骗人。
    private static let staleAfter: TimeInterval = 7

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: renderer.width(showLabels: Settings.showLabels))
        statusItem = item
        item.button?.imagePosition = .imageOnly
        item.menu = buildMenu()

        activateSource(Settings.source)
        render()

        // 只负责把「数据断流」翻成占位符，本身不采样
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.render() }
        RunLoop.main.add(timer, forMode: .common)
        staleTimer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        staleTimer?.invalidate()
        source?.stop()
    }

    // MARK: - 数据源

    private func activateSource(_ kind: Settings.SourceKind) {
        source?.stop()
        lastSample = nil
        lastUpdate = nil
        failureMessage = nil

        let next: MetricsSource = kind == .native ? NativeMetricsSource() : MoleStatusSource()
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
            return "等待数据（数据源：\(source?.displayName ?? "-")）"
        }
        return "CPU \(Format.percent(lastSample.cpuPercent))"
            + "  内存 \(Format.percent(lastSample.memPercent))"
            + "  ↓\(Format.rateText(lastSample.rxMBs))  ↑\(Format.rateText(lastSample.txMBs))"
            + "\n数据源：\(source?.displayName ?? "-")"
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

        let sourceHeader = NSMenuItem(title: "数据源", action: nil, keyEquivalent: "")
        sourceHeader.isEnabled = false
        menu.addItem(sourceHeader)

        for kind in [Settings.SourceKind.native, .mole] {
            let item = NSMenuItem(title: "  " + kind.displayName, action: #selector(selectSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.state = Settings.source == kind ? .on : .off
            menu.addItem(item)
        }
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

    @objc private func selectSource(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = Settings.SourceKind(rawValue: raw),
              kind != Settings.source else { return }
        Settings.source = kind
        statusItem?.menu = buildMenu()
        activateSource(kind)
        render()
    }

    @objc private func restartSource() {
        source?.restart()
    }
}
