import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static private(set) var shared: AppDelegate?

    private let settings = SettingsStore.shared
    private let panelController = ShortcutPanelController()
    private let monitor = ModifierDoubleTapMonitor()

    private var usageMonitor: Any?
    private var statusItem: NSStatusItem?
    private let contextMenu = NSMenu()
    private var statusClickMonitor: Any?
    private var permissionWatch: Timer?
    private var lastExternalApp: NSRunningApplication?
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
        if settings.trigger == .off {
            monitor.stop()
        } else {
            monitor.start()
        }
    }

    private func handleTrigger() {
        if ProcessInfo.processInfo.environment["KEYGLANCE_DEBUG"] == "1" {
            NSLog("KeyGlance: double tap trigger, visible=\(panelController.isVisible)")
        }
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
            string: "双击修饰键，一览当前 App 的所有快捷键。\n数据只在内存中处理，不联网、不写入磁盘。",
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
