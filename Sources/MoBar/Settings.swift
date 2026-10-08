import Foundation

/// 几个开关存 UserDefaults，没有设置界面，全在菜单里点。
enum Settings {
    enum ClipboardShortcut: String, CaseIterable {
        case cmdShiftV
        case ctrlOptV
        case optV
        case optSpace

        var displayName: String {
            switch self {
            case .cmdShiftV: return "⌘⇧V"
            case .ctrlOptV: return "⌃⌥V"
            case .optV: return "⌥V"
            case .optSpace: return "⌥Space"
            }
        }
    }

    private static let showLabelsKey = "showLabels"
    private static let clipboardEnabledKey = "clipboardEnabled"
    private static let clipboardShortcutKey = "clipboardShortcut"

    static var clipboardEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: clipboardEnabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: clipboardEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: clipboardEnabledKey) }
    }

    static var clipboardShortcut: ClipboardShortcut {
        get {
            guard let raw = UserDefaults.standard.string(forKey: clipboardShortcutKey),
                  let shortcut = ClipboardShortcut(rawValue: raw) else { return .cmdShiftV }
            return shortcut
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: clipboardShortcutKey) }
    }

    static var showLabels: Bool {
        get {
            // 没写过就默认显示标签
            if UserDefaults.standard.object(forKey: showLabelsKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: showLabelsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: showLabelsKey) }
    }
}
