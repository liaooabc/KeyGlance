import AppKit
import Combine
import ServiceManagement

enum TriggerKey: String, CaseIterable, Identifiable {
    case command
    case control
    case option
    case shift
    case off

    var id: String { rawValue }

    var flag: NSEvent.ModifierFlags? {
        switch self {
        case .command: return .command
        case .control: return .control
        case .option: return .option
        case .shift: return .shift
        case .off: return nil
        }
    }

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .off: return "—"
        }
    }

    var title: String {
        switch self {
        case .command: return "Command ⌘"
        case .control: return "Control ⌃"
        case .option: return "Option ⌥"
        case .shift: return "Shift ⇧"
        case .off: return "关闭双击触发"
        }
    }
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    @Published var trigger: TriggerKey {
        didSet { defaults.set(trigger.rawValue, forKey: Keys.trigger) }
    }

    /// Seconds allowed between the two taps.
    @Published var doubleTapInterval: Double {
        didSet { defaults.set(doubleTapInterval, forKey: Keys.interval) }
    }

    @Published var showsSearchField: Bool {
        didSet { defaults.set(showsSearchField, forKey: Keys.search) }
    }

    @Published var showsMenuBarIcon: Bool {
        didSet { defaults.set(showsMenuBarIcon, forKey: Keys.statusItem) }
    }

    @Published var usesAnimation: Bool {
        didSet { defaults.set(usesAnimation, forKey: Keys.animation) }
    }

    /// Show a "常用" column built from the shortcuts you actually press.
    @Published var showsFrequent: Bool {
        didSet { defaults.set(showsFrequent, forKey: Keys.frequent) }
    }

    /// Show system-wide shortcuts (Mission Control, Spotlight, screenshots …).
    @Published var showsSystemShortcuts: Bool {
        didSet { defaults.set(showsSystemShortcuts, forKey: Keys.system) }
    }

    /// Allow the usage counter that feeds the "常用" column.
    @Published var recordsUsage: Bool {
        didSet { defaults.set(recordsUsage, forKey: Keys.records) }
    }

    @Published var launchAtLogin: Bool {
        didSet { updateLoginItem(launchAtLogin) }
    }

    private enum Keys {
        static let trigger = "triggerKey"
        static let interval = "doubleTapInterval"
        static let search = "showsSearchField"
        static let statusItem = "showsMenuBarIcon"
        static let animation = "usesAnimation"
        static let frequent = "showsFrequent"
        static let system = "showsSystemShortcuts"
        static let records = "recordsUsage"
    }

    private init() {
        defaults.register(defaults: [
            Keys.trigger: TriggerKey.command.rawValue,
            Keys.interval: 0.35,
            Keys.search: true,
            Keys.statusItem: true,
            Keys.animation: true,
            Keys.frequent: true,
            Keys.system: true,
            Keys.records: true
        ])
        trigger = TriggerKey(rawValue: defaults.string(forKey: Keys.trigger) ?? "") ?? .command
        doubleTapInterval = defaults.double(forKey: Keys.interval)
        showsSearchField = defaults.bool(forKey: Keys.search)
        showsMenuBarIcon = defaults.bool(forKey: Keys.statusItem)
        usesAnimation = defaults.bool(forKey: Keys.animation)
        showsFrequent = defaults.bool(forKey: Keys.frequent)
        showsSystemShortcuts = defaults.bool(forKey: Keys.system)
        recordsUsage = defaults.bool(forKey: Keys.records)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var loginItemStatusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "已开启"
        case .requiresApproval: return "等待在系统设置中批准"
        case .notRegistered: return "未注册"
        case .notFound: return "未找到登录项"
        @unknown default: return "未知"
        }
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("KeyGlance login item error: \(error.localizedDescription)")
            DispatchQueue.main.async {
                if self.launchAtLogin != enabled {
                    self.launchAtLogin = !enabled
                }
            }
        }
    }
}
