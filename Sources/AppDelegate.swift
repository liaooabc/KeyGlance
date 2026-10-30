import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static private(set) var shared: AppDelegate?

    private let settings = SettingsStore.shared
    private let panelController = ShortcutPanelController()
    private let monitor = ModifierTriggerMonitor()

    private var usageMonitor: Any?
    private var statusItem: NSStatusItem?
    private let contextMenu = NSMenu()
    private var statusClickMonitor: Any?
    private var permissionWatch: Timer?
    private var lastExternalApp: NSRunningApplication?
    /// 按住模式：修饰键此刻是不是按着的。切 App 时用它判断"要不要换内容"。
    private var isHoldingTrigger = false
    private var prefetchWork: DispatchWorkItem?
    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: OnboardingWindowController?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        panelController.hasOtherWindows = { [weak self] in
            guard let self else { return false }
            return (self.settingsWindow?.window?.isVisible ?? false)
                || (self.onboardingWindow?.window?.isVisible ?? false)
        }
        panelController.prewarm()
        restartMonitor()
        installUsageMonitor()
        updateStatusItemVisibility()

        scheduleUpdateCheck()

        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(workspaceAppActivated(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil)

        let env = ProcessInfo.processInfo.environment
        if let forced = env["KEYGLANCE_UI_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: forced == "light" ? .aqua : .darkAqua)
        }
        if env["KEYGLANCE_ONBOARDING"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.showOnboarding() }
        } else if !Permissions.hasAccessibility {
            // 授权丢了（换签名、重装）也直接把引导窗口拿出来，别让 App 静悄悄地没反应。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.showOnboarding() }
        }

        if env["KEYGLANCE_SHOW_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.openSettings() }
        }
        if env["KEYGLANCE_DEMO"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.showPanel() }
        }
        if let typed = env["KEYGLANCE_DEMO_TYPE"], !typed.isEmpty {
            // 仅调试：逐字输入再逐字删除，模拟真人打字时面板高度的反复变化。
            let chars = Array(typed)
            for (index, ch) in chars.enumerated() {
                let text = String(chars.prefix(index + 1))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0 + Double(index) * 0.25) {
                    self.panelController.debugSetQuery(text)
                }
            }
            for index in 0..<chars.count {
                let text = String(chars.prefix(chars.count - index - 1))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0 + Double(chars.count) * 0.25 + Double(index) * 0.25) {
                    self.panelController.debugSetQuery(text)
                }
            }
        }
        if env["KEYGLANCE_DEMO_SEARCH"] == "1" {
            // 仅调试：模拟"输入搜索词 → 删掉"，看面板高度和内容有没有复位。
            let query = env["KEYGLANCE_DEMO_QUERY"] ?? "zz"
            let setAt = Double(env["KEYGLANCE_DEMO_QUERY_AT"] ?? "") ?? 4
            let clearAt = Double(env["KEYGLANCE_DEMO_CLEAR_AT"] ?? "") ?? (setAt + 3)
            DispatchQueue.main.asyncAfter(deadline: .now() + setAt) { self.panelController.debugSetQuery(query) }
            DispatchQueue.main.asyncAfter(deadline: .now() + clearAt) { self.panelController.debugSetQuery("") }
        }
        if let raw = env["KEYGLANCE_DEMO_REPEAT"], let times = Int(raw), times > 0 {
            // 仅调试：反复开合面板，量入场/收起的帧率（第 1 次冷、之后走缓存）。
            var left = times
            func cycle() {
                guard left > 0 else { return }
                left -= 1
                self.showPanel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    if self.panelController.isVisible { self.panelController.hide() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { cycle() }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { cycle() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        if let usageMonitor { NSEvent.removeMonitor(usageMonitor) }
    }

    /// Records modifier combinations (never plain typing) so the panel can show
    /// which shortcuts this user actually reaches for.
    private func installUsageMonitor() {
        usageMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard SettingsStore.shared.recordsUsage else { return }
            guard self?.panelController.isVisible != true else { return }
            guard let caps = KeyCapFormatter.eventCaps(event) else { return }
            guard let app = NSWorkspace.shared.frontmostApplication,
                  let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier else { return }
            UsageTracker.shared.record(caps: caps, bundleID: bundleID)
        }
    }

    @objc private func workspaceAppActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastExternalApp = app
        // 按住模式：修饰键还按着，但用户已经切到别的 App 了——
        // 面板得跟着换成新 App 的快捷键，不然摊开的是上一个的。
        if settings.triggerGesture == .hold, isHoldingTrigger {
            panelController.showHeld(for: app)
            return
        }
        // 切过去之后让面板在后台把它的快捷键读好：等会儿双击 ⌘ 就能直接铺出来，
        // 不用"先显示、再换内容"。
        prefetchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panelController.prefetch(for: app) }
        prefetchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// The app to show shortcuts for: the frontmost app, or the last one we saw
    /// when our own panel is active.
    private var targetApplication: NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.bundleIdentifier != Bundle.main.bundleIdentifier, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApp = front
            return front
        }
        if let lastExternalApp, !lastExternalApp.isTerminated {
            return lastExternalApp
        }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier != Bundle.main.bundleIdentifier && $0.activationPolicy == .regular && $0.isActive
        }
    }

    // MARK: - Trigger

    func restartMonitor() {
        monitor.onTrigger = { [weak self] in
            self?.handleTrigger()
        }
        // 按住手势：按下摊开面板、松开收起。
        monitor.onHoldChange = { [weak self] held in
            self?.handleHold(held)
        }
        if settings.trigger == .off {
            monitor.stop()
        } else {
            monitor.start()
        }
    }

    /// 按住模式下把面板摊开 / 收起。
    private func handleHold(_ held: Bool) {
        isHoldingTrigger = held
        if held {
            guard Permissions.hasAccessibility else {
                showOnboarding()
                return
            }
            guard let app = targetApplication else { return }
            // 按住的时候要显示**当前**前台 App 的快捷键：用户多半是
            // 一边按着 ⌘ 一边在别的 App 里操作，面板不能把焦点抢走。
            panelController.showHeld(for: app)
        } else {
            panelController.hideHeld()
        }
    }

    private func handleTrigger() {
        if ProcessInfo.processInfo.environment["KEYGLANCE_DEBUG"] == "1" {
            NSLog("KeyGlance: double tap trigger, visible=\(panelController.isVisible)")
        }
        // 设置窗口开着的时候，用户是在那儿试手势，不是要唤出面板：
        // 这时双击只让设置界面的提示亮一下，不弹面板。
        if settingsWindow?.window?.isKeyWindow == true { return }
        if panelController.isVisible {
            panelController.hide()
            return
        }
        guard Permissions.hasAccessibility else {
            showOnboarding()
            return
        }
        guard let app = targetApplication else { return }
        panelController.show(for: app)
    }

    @objc func showPanel() {
        guard Permissions.hasAccessibility else {
            showOnboarding()
            return
        }
        guard let app = targetApplication else { return }
        if panelController.isVisible {
            panelController.hide()
        } else {
            panelController.show(for: app)
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // Heavy weight at 13.5pt: the glyph must read as solid as its
            // neighbours in the menu bar, 12pt bold was a touch too small and thin.
            let configuration = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .heavy)
            let image = NSImage(systemSymbolName: "command", accessibilityDescription: "键览")?
                .withSymbolConfiguration(configuration)
            image?.isTemplate = true
            button.image = image
            button.toolTip = "键览 — 双击 ⌘ 查看快捷键"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        contextMenu.delegate = self
        statusItem = item

        // A click on the status item must never count as "another app became
        // active" — set the grace period on mouse down, before that happens.
        statusClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window === self.statusItem?.button?.window {
                self.panelController.suppressAutoHide(for: 1.5)
            }
            return event
        }
    }

    func updateStatusItemVisibility() {
        guard let statusItem else { return }
        statusItem.isVisible = settings.showsMenuBarIcon
    }

    /// Left click shows the panel, right click (or ⌃-click) shows the menu.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        panelController.suppressAutoHide()
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        guard secondary else {
            // If the panel just closed itself because this click activated another
            // app, treat the click as "close" instead of reopening.
            if !panelController.isVisible && panelController.hiddenByActivationRecently { return }
            showPanel()
            return
        }
        guard let statusItem else { return }
        statusItem.menu = contextMenu
        sender.performClick(nil)
        statusItem.menu = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let about = NSMenuItem(title: "关于键览", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let checkTitle = Updater.shared.pendingVersion.map { "有新版本 \($0)…" } ?? "检查更新…"
        let check = NSMenuItem(title: checkTitle, action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        menu.addItem(check)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出键览", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func showAbout() {
        let credits = NSAttributedString(
            string: "双击修饰键，一览当前 App 的所有快捷键。\n只读取菜单栏，不记录任何输入内容；「常用」只在本机保存修饰键组合的次数，不联网。",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "键览",
            .credits: credits
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Updates

    /// 启动后看一眼 GitHub；设置里关了自动检查就不查。
    private func scheduleUpdateCheck() {
        guard SettingsStore.shared.automaticallyChecksForUpdates else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated { Updater.shared.checkIfStale() }
        }
    }

    /// 菜单里的「检查更新…」：打开设置里的更新区，顺便真的查一次。
    @MainActor @objc private func checkForUpdates() {
        openSettings()
        Updater.shared.check()
    }

    // MARK: - Windows

    @objc func openSettings() {
        // 面板挡着设置页，不管从哪儿打开设置都先关掉。
        if panelController.isVisible { panelController.hide() }
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
        settingsWindow?.present()
    }

    /// Once the user grants Accessibility, restart the app the way Apple's own
    /// apps do: the new AX client only takes effect in a fresh process, and the
    /// permission window goes away with it.
    private func startPermissionWatch() {
        permissionWatch?.invalidate()
        var fired = false
        permissionWatch = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] timer in
            guard !fired, Permissions.hasAccessibility else { return }
            fired = true
            timer.invalidate()
            self?.permissionWatch = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Permissions.relaunch()
            }
        }
    }

    func showOnboarding() {
        startPermissionWatch()
        if onboardingWindow == nil {
            onboardingWindow = OnboardingWindowController(onClose: { [weak self] in
                self?.permissionWatch?.invalidate()
                self?.permissionWatch = nil
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            })
        }
        onboardingWindow?.present()
    }
}
