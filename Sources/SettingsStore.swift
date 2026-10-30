import AppKit
import Combine
import ServiceManagement

/// 触发方式 = 修饰键 × 手势，合成一个选项。
///
/// - **双击**：双击这个键，摊开面板；再双击，收起来。
/// - **按住**：按住这个键，面板一直摊着；松开，收起来（像临时摊开一张快捷键表）。
///
/// 设置里就是一个下拉框，不用分成"用哪个键"和"什么手势"两栏。
enum TriggerMode: String, CaseIterable, Identifiable {
    case doubleTapCommand
    case doubleTapControl
    case doubleTapOption
    case doubleTapShift
    case holdCommand
    case holdControl
    case holdOption
    case holdShift
    case off

    var id: String { rawValue }

    /// 用哪个修饰键。
    var key: TriggerKey {
        switch self {
        case .doubleTapCommand, .holdCommand: return .command
        case .doubleTapControl, .holdControl: return .control
        case .doubleTapOption, .holdOption: return .option
        case .doubleTapShift, .holdShift: return .shift
        case .off: return .off
        }
    }

    /// 什么手势。
    var gesture: TriggerGesture {
        switch self {
        case .doubleTapCommand, .doubleTapControl, .doubleTapOption, .doubleTapShift:
            return .doubleTap
        case .holdCommand, .holdControl, .holdOption, .holdShift:
            return .hold
        case .off:
            return .doubleTap
        }
    }

    var symbol: String { key.symbol }

    var title: String {
        switch self {
        case .doubleTapCommand: return "双击 Command ⌘"
        case .doubleTapControl: return "双击 Control ⌃"
        case .doubleTapOption: return "双击 Option ⌥"
        case .doubleTapShift: return "双击 Shift ⇧"
        case .holdCommand: return "按住 Command ⌘"
        case .holdControl: return "按住 Control ⌃"
        case .holdOption: return "按住 Option ⌥"
        case .holdShift: return "按住 Shift ⇧"
        case .off: return "关闭触发"
        }
    }

    /// 一句话说明这个手势怎么用，不看说明也能明白。
    var hint: String {
        switch self {
        case .off: return "不响应修饰键；用菜单栏图标打开面板"
        default:
            return gesture == .hold
                ? "按住 \(symbol) 显示，松开隐藏"
                : "双击 \(symbol) 显示，再双击隐藏"
        }
    }
}

/// 触发用的修饰键。
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
}

/// 触发手势：双击，还是按住。
enum TriggerGesture: String, CaseIterable, Identifiable {
    case doubleTap
    case hold

    var id: String { rawValue }
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    /// 触发方式（修饰键 × 手势合成一个选项）。
    ///
    /// 「关闭触发」和「隐藏菜单栏图标」不能同时成立——那时 App 没有任何入口
    /// 能打开设置（没有 Dock 图标、没有全局热键）。后改的那一项让步退回。
    @Published var triggerMode: TriggerMode {
        didSet {
            if triggerMode == .off, !showsMenuBarIcon {
                triggerMode = lastEnabledTriggerMode
                NSSound.beep()
                return
            }
            if triggerMode != .off { lastEnabledTriggerMode = triggerMode }
            defaults.set(triggerMode.rawValue, forKey: Keys.triggerMode)
        }
    }

    /// 上一次真正生效的触发方式：用户选了「关闭触发」又被挡回来时退回它。
    private var lastEnabledTriggerMode: TriggerMode = .doubleTapCommand

    /// 触发用的修饰键。跟随 triggerMode，别单独改。
    var trigger: TriggerKey { triggerMode.key }

    /// 触发手势。跟随 triggerMode，别单独改。
    var triggerGesture: TriggerGesture { triggerMode.gesture }

    /// Seconds allowed between the two taps.
    @Published var doubleTapInterval: Double {
        didSet { defaults.set(doubleTapInterval, forKey: Keys.interval) }
    }

    @Published var showsSearchField: Bool {
        didSet { defaults.set(showsSearchField, forKey: Keys.search) }
    }

    @Published var showsMenuBarIcon: Bool {
        didSet {
            // 见 triggerMode：这两个开关至少要留一个入口。
            if !showsMenuBarIcon, triggerMode == .off {
                showsMenuBarIcon = true
                NSSound.beep()
                return
            }
            defaults.set(showsMenuBarIcon, forKey: Keys.statusItem)
        }
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
        didSet {
            // 注册/注销失败时要把开关拨回去，那一次赋值不要再触发注册。
            guard !isRevertingLoginItem else { return }
            updateLoginItem(launchAtLogin)
        }
    }

    private var isRevertingLoginItem = false

    /// 启动时（以及每 24 小时）看一眼 GitHub 上有没有新版本。
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { defaults.set(automaticallyChecksForUpdates, forKey: Keys.autoCheckUpdates) }
    }

    /// 查到新版本就直接下载安装并重启，不再问。
    @Published var automaticallyInstallsUpdates: Bool {
        didSet { defaults.set(automaticallyInstallsUpdates, forKey: Keys.autoInstallUpdates) }
    }

    private enum Keys {
        /// UserDefaults 的持久化域名。用来区分"用户真设过的值"和"register 注册的默认值"。
        static let domain = "com.hushixiong.KeyGlance"
        static let trigger = "triggerKey"
        static let triggerGesture = "triggerGesture"
        static let triggerMode = "triggerMode"
        static let interval = "doubleTapInterval"
        static let search = "showsSearchField"
        static let statusItem = "showsMenuBarIcon"
        static let animation = "usesAnimation"
        static let frequent = "showsFrequent"
        static let system = "showsSystemShortcuts"
        static let records = "recordsUsage"
        static let autoCheckUpdates = "automaticallyChecksForUpdates"
        static let autoInstallUpdates = "automaticallyInstallsUpdates"
    }

    private init() {
        // 只注册 triggerMode。老的 triggerKey / triggerGesture **不能**注册默认值：
        // 注册了 defaults.object(forKey:) 就分不出"用户设过没有"，迁移逻辑会失效。
        defaults.register(defaults: [
            Keys.triggerMode: TriggerMode.doubleTapCommand.rawValue,
            Keys.interval: 0.35,
            Keys.search: true,
            Keys.statusItem: true,
            Keys.animation: true,
            Keys.frequent: true,
            Keys.system: true,
            Keys.records: true,
            Keys.autoCheckUpdates: true,
            Keys.autoInstallUpdates: false
        ])
        triggerMode = Self.loadTriggerMode(from: defaults)
        doubleTapInterval = defaults.double(forKey: Keys.interval)
        showsSearchField = defaults.bool(forKey: Keys.search)
        showsMenuBarIcon = defaults.bool(forKey: Keys.statusItem)
        usesAnimation = defaults.bool(forKey: Keys.animation)
        showsFrequent = defaults.bool(forKey: Keys.frequent)
        showsSystemShortcuts = defaults.bool(forKey: Keys.system)
        recordsUsage = defaults.bool(forKey: Keys.records)
        automaticallyChecksForUpdates = defaults.bool(forKey: Keys.autoCheckUpdates)
        automaticallyInstallsUpdates = defaults.bool(forKey: Keys.autoInstallUpdates)
        launchAtLogin = SMAppService.mainApp.status == .enabled

        // 旧版本或手动改过 defaults 可能已经留下"两个入口都没了"的状态：
        // 启动时补回菜单栏图标，否则用户再也打不开设置。
        if triggerMode == .off, !showsMenuBarIcon {
            showsMenuBarIcon = true
            defaults.set(true, forKey: Keys.statusItem)
        }
        if triggerMode != .off { lastEnabledTriggerMode = triggerMode }
    }

    /// 读触发方式。新版本是一个合成值；老版本存的是分开的
    /// "triggerKey"（哪个键）和 "triggerGesture"（什么手势），这里合并一次。
    private static func loadTriggerMode(from defaults: UserDefaults) -> TriggerMode {
        // 判断"用户到底设过没有"必须查**持久化域**：`register(defaults:)` 注册的默认值
        // 会让 object(forKey:) / string(forKey:) 都返回非 nil，分不出注册值和真值。
        let stored = defaults.persistentDomain(forName: Keys.domain) ?? [:]
        if let raw = stored[Keys.triggerMode] as? String,
           let mode = TriggerMode(rawValue: raw) {
            return mode
        }
        // 老设置：两个分开的键，拼成一个。
        let key = TriggerKey(rawValue: stored[Keys.trigger] as? String ?? "") ?? .command
        let gesture = TriggerGesture(rawValue: stored[Keys.triggerGesture] as? String ?? "") ?? .doubleTap
        let mode: TriggerMode
        switch (key, gesture) {
        case (.command, .doubleTap): mode = .doubleTapCommand
        case (.control, .doubleTap): mode = .doubleTapControl
        case (.option, .doubleTap): mode = .doubleTapOption
        case (.shift, .doubleTap): mode = .doubleTapShift
        case (.command, .hold): mode = .holdCommand
        case (.control, .hold): mode = .holdControl
        case (.option, .hold): mode = .holdOption
        case (.shift, .hold): mode = .holdShift
        case (.off, _): mode = .off
        }
        defaults.set(mode.rawValue, forKey: Keys.triggerMode)
        // 老键清掉：留着没用，还会让人以为设置还看那两个。
        defaults.removeObject(forKey: Keys.trigger)
        defaults.removeObject(forKey: Keys.triggerGesture)
        return mode
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
            // 失败就把开关拨回真实状态：以前这里的条件是"和刚设的值不同才回退"，
            // 而它恒等于刚设的值，所以开关永远停在"开"，实际却没注册成功。
            DispatchQueue.main.async {
                self.isRevertingLoginItem = true
                self.launchAtLogin = !enabled
                self.isRevertingLoginItem = false
                NSSound.beep()
            }
        }
    }
}
