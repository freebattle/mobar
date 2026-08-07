import Foundation

/// 只有两个开关，存 UserDefaults，没有设置界面，全在菜单里点。
enum Settings {
    enum SourceKind: String {
        case native
        case mole

        var displayName: String {
            switch self {
            case .native: return "系统原生"
            case .mole: return "mole status-go"
            }
        }
    }

    private static let showLabelsKey = "showLabels"
    private static let sourceKey = "source"

    static var showLabels: Bool {
        get {
            // 没写过就默认显示标签
            if UserDefaults.standard.object(forKey: showLabelsKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: showLabelsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: showLabelsKey) }
    }

    static var source: SourceKind {
        get {
            guard let raw = UserDefaults.standard.string(forKey: sourceKey),
                  let kind = SourceKind(rawValue: raw) else { return .native }
            return kind
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sourceKey) }
    }
}
