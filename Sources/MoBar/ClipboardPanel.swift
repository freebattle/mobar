import AppKit
import Carbon.HIToolbox

/// 不激活 MoBar 本身就能拿键盘焦点的浮层，前台 app 不变，关掉后 ⌘V 直接落回原来的输入位置。
private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 剪贴板历史浮层：快捷键在鼠标处呼出，↑↓ 选择，回车粘贴。
final class ClipboardPanelController: NSObject {
    private static let panelSize = NSSize(width: 380, height: 500)
    private static let sideInset: CGFloat = 12

    private let store: ClipboardStore
    private let panel: FloatingPanel
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    private var filtered: [ClipItem] = []
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var promptedForAccessibility = false

    var isVisible: Bool { panel.isVisible }

    init(store: ClipboardStore) {
        self.store = store
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: true)
        super.init()
        configurePanel()
        store.onChange = { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.reload(keepSelection: true)
        }
    }

    // MARK: - 外观

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self

        let size = Self.panelSize
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        panel.contentView = background

        searchField.frame = NSRect(x: 14, y: size.height - 14 - 28, width: size.width - 28, height: 28)
        searchField.placeholderString = "搜索剪贴板"
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        background.addSubview(searchField)

        let hintHeight: CGFloat = 28
        hintLabel.frame = NSRect(x: 14, y: 6, width: size.width - 28, height: hintHeight - 12)
        hintLabel.alignment = .center
        hintLabel.font = .systemFont(ofSize: 10.5)
        hintLabel.textColor = .tertiaryLabelColor
        background.addSubview(hintLabel)

        let listTop = searchField.frame.minY - 10
        scrollView.frame = NSRect(x: Self.sideInset, y: hintHeight,
                                  width: size.width - Self.sideInset * 2, height: listTop - hintHeight)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 6, right: 0)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        column.width = scrollView.contentSize.width
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 8)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        // 焦点始终留在搜索框里，方向键和回车由 keyMonitor 统一处理
        tableView.refusesFirstResponder = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        scrollView.documentView = tableView
        background.addSubview(scrollView)

        emptyLabel.frame = NSRect(x: 0, y: scrollView.frame.midY - 10, width: size.width, height: 20)
        emptyLabel.alignment = .center
        emptyLabel.textColor = .tertiaryLabelColor
        background.addSubview(emptyLabel)
    }

    // MARK: - 显示与关闭

    func toggle() {
        panel.isVisible ? close() : show()
    }

    func show() {
        searchField.stringValue = ""
        hintLabel.stringValue = AXIsProcessTrusted()
            ? "↩ 粘贴    ⌘1-9 快速粘贴    ⌘⌫ 删除    esc 关闭"
            : "↩ 复制（授予辅助功能权限后可直接粘贴）    esc 关闭"
        reload(keepSelection: false)

        panel.setFrameOrigin(Self.origin(near: NSEvent.mouseLocation, size: Self.panelSize))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        installMonitors()
    }

    func close() {
        removeMonitors()
        panel.orderOut(nil)
    }

    /// 面板左上角贴着鼠标，越界就往屏幕内收。坐标系是全局的左下角原点。
    private static func origin(near mouse: NSPoint, size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return mouse }
        let margin: CGFloat = 8
        var x = mouse.x + 2
        var y = mouse.y - 2 - size.height
        x = min(max(x, visible.minX + margin), visible.maxX - size.width - margin)
        y = min(max(y, visible.minY + margin), visible.maxY - size.height - margin)
        return NSPoint(x: x, y: y)
    }

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleKey(event) ? nil : event
        }
        // 点到别的 app 上就收起
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
    }

    // MARK: - 键盘

    private static let digitKeyCodes: [Int] = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]

    /// 返回 true 表示事件已处理，不再交给搜索框。
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = Int(event.keyCode)

        switch keyCode {
        case kVK_Escape:
            close()
            return true
        case kVK_DownArrow:
            moveSelection(by: 1)
            return true
        case kVK_UpArrow:
            moveSelection(by: -1)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            paste(row: tableView.selectedRow)
            return true
        default:
            break
        }

        guard flags.contains(.command) else { return false }
        if let index = Self.digitKeyCodes.firstIndex(of: keyCode) {
            paste(row: index)
            return true
        }
        if keyCode == kVK_Delete {
            deleteSelected()
            return true
        }
        return false
    }

    private func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let current = tableView.selectedRow
        let next = current < 0 ? 0 : min(max(current + delta, 0), filtered.count - 1)
        select(row: next)
    }

    private func select(row: Int) {
        guard row >= 0, row < filtered.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    @objc private func rowClicked() {
        paste(row: tableView.clickedRow)
    }

    private func deleteSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else { return }
        store.remove(filtered[row])  // onChange 会触发 reload
        select(row: min(row, filtered.count - 1))
    }

    // MARK: - 粘贴

    /// 写回剪贴板，收起面板，再给前台 app 发一个 ⌘V。
    /// 模拟按键要辅助功能权限，没有权限就只复制，用户自己按 ⌘V。
    private func paste(row: Int) {
        guard row >= 0, row < filtered.count else { return }
        let item = filtered[row]
        close()
        guard store.writeToPasteboard(item) else { return }

        guard AXIsProcessTrusted() else {
            if !promptedForAccessibility {
                promptedForAccessibility = true
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                AXIsProcessTrustedWithOptions(options)
            }
            return
        }
        // 等面板让出键盘焦点再发
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Self.postCommandV()
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - 数据

    private func reload(keepSelection: Bool) {
        let selectedID = keepSelection && tableView.selectedRow >= 0 && tableView.selectedRow < filtered.count
            ? filtered[tableView.selectedRow].id : nil

        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        filtered = query.isEmpty
            ? store.items
            : store.items.filter { $0.kind == .text && ($0.text ?? "").localizedCaseInsensitiveContains(query) }

        tableView.reloadData()
        emptyLabel.stringValue = query.isEmpty ? "还没有剪贴板记录" : "没有匹配的记录"
        emptyLabel.isHidden = !filtered.isEmpty

        let row = selectedID.flatMap { id in filtered.firstIndex { $0.id == id } } ?? 0
        if filtered.isEmpty {
            tableView.deselectAll(nil)
        } else {
            select(row: row)
        }
    }

    fileprivate func refreshSelectionState() {
        let selected = tableView.selectedRow
        tableView.enumerateAvailableRowViews { rowView, row in
            (rowView.view(atColumn: 0) as? ClipCardView)?.isSelected = row == selected
        }
    }
}

extension ClipboardPanelController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

extension ClipboardPanelController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        reload(keepSelection: false)
    }
}

extension ClipboardPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        ClipCardView.height(for: filtered[row], width: tableView.tableColumns[0].width)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let card = tableView.makeView(withIdentifier: ClipCardView.identifier, owner: nil) as? ClipCardView
            ?? ClipCardView()
        card.configure(with: filtered[row], index: row)
        card.isSelected = row == tableView.selectedRow
        return card
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshSelectionState()
    }
}

/// 一条记录的卡片：正文（单行垂直居中，多行最多三行）、⌘N 快捷提示。
private final class ClipCardView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ClipCard")

    private static let titleFont = NSFont.systemFont(ofSize: 14)
    private static let metaFont = NSFont.systemFont(ofSize: 10)
    private static let titleLineHeight = ceil(NSLayoutManager().defaultLineHeight(for: titleFont))
    private static let padding: CGFloat = 11
    private static let leading: CGFloat = 14
    private static let shortcutWidth: CGFloat = 30
    private static let trailingColumn: CGFloat = leading + shortcutWidth + 8
    private static let metaHeight: CGFloat = 14
    private static let maxLines: CGFloat = 3

    private static let cardColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.white.withAlphaComponent(0.75)
    }

    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")

    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        titleLabel.font = Self.titleFont
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = Int(Self.maxLines)
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.cell?.truncatesLastVisibleLine = true

        shortcutLabel.font = Self.metaFont
        shortcutLabel.textColor = .tertiaryLabelColor
        shortcutLabel.lineBreakMode = .byTruncatingTail
        shortcutLabel.alignment = .right

        [titleLabel, shortcutLabel].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func height(for item: ClipItem, width: CGFloat) -> CGFloat {
        let tHeight = titleHeight(item.preview, cardWidth: width)
        if tHeight <= titleLineHeight + 2 {
            return 44
        }
        return padding + tHeight + padding
    }

    private static func titleHeight(_ text: String, cardWidth: CGFloat) -> CGFloat {
        let width = cardWidth - leading - trailingColumn
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: titleFont]
        ).height
        return min(max(ceil(measured), titleLineHeight), titleLineHeight * maxLines)
    }

    func configure(with item: ClipItem, index: Int) {
        titleLabel.stringValue = item.preview
        titleLabel.textColor = item.kind == .image ? .secondaryLabelColor : .labelColor
        shortcutLabel.stringValue = index < 9 ? "⌘\(index + 1)" : ""
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        let titleHeight = Self.titleHeight(titleLabel.stringValue, cardWidth: width)
        let p = Self.padding
        let textWidth = width - Self.leading - Self.trailingColumn

        // 正文垂直居中
        let titleY = max(p, (height - titleHeight) / 2)
        titleLabel.frame = NSRect(x: Self.leading, y: titleY, width: textWidth, height: titleHeight)

        // ⌘N 提示统一跟卡片垂直居中，单行多行一致
        guard !shortcutLabel.stringValue.isEmpty else {
            shortcutLabel.frame = .zero
            return
        }
        let metaH = Self.metaHeight
        shortcutLabel.frame = NSRect(x: width - Self.leading - Self.shortcutWidth,
                                     y: (height - metaH) / 2,
                                     width: Self.shortcutWidth, height: metaH)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        Self.cardColor.setFill()
        path.fill()
        if isSelected {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }
}
