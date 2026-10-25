import AppKit
import SwiftUI

enum HideReason { case user, activation }

final class ShortcutPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ShortcutPanelController {
    private var panel: ShortcutPanel?
    private var glass: NSGlassEffectView?
    private var hosting: NSHostingView<ShortcutPanelView>?
    private let model = ShortcutPanelModel()

    private var themeObserver: NSObjectProtocol?
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var previousApp: NSRunningApplication?
    private var targetScreen: NSScreen?
    private var loadToken = 0
    private var autoHideSuppressedUntil = Date.distantPast
    private var lastActivationHide: Date?

    /// Last known panel content per app, so a second ⌘⌘ opens instantly.
    private struct CachedPanel {
        var sections: [ShortcutSection]
        var frequent: ShortcutSection?
        var system: ShortcutSection?
        var layout: PanelLayout
        var signature: String
        var stamp: Date
    }
    private var cache: [String: CachedPanel] = [:]
    private var lastPanelSize: NSSize?

    init() {
        observeThemeChanges()
    }

    /// Told by AppDelegate: does the app still have a settings/about window up?
    var hasOtherWindows: (() -> Bool)?

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    // MARK: - Public

    /// Shows the panel for the app that was frontmost when the gesture happened.
    func show(for app: NSRunningApplication) {
        let start = CACurrentMediaTime()
        loadToken += 1
        let token = loadToken

        previousApp = app
        let bundleID = app.bundleIdentifier ?? ""
        model.appName = app.localizedName ?? "当前 App"
        model.icon = app.icon
        model.bundleID = bundleID
        model.query = ""
        model.presentToken += 1

        let screen = screenWithMouse()
        targetScreen = screen
        let maximum = PanelLayout.maxSize(for: screen)
        model.maxPanelWidth = maximum.width
        model.panelHeight = maximum.height

        if let cached = cache[bundleID], !cached.sections.isEmpty {
            // Warm path: appear immediately at the remembered size, refresh underneath.
            apply(cached)
            let w1 = CACurrentMediaTime()
            let panel = ensurePanel()
            if lastPanelSize != NSSize(width: cached.layout.panelWidth, height: cached.layout.panelHeight) {
                panel.setFrame(frame(for: cached.layout), display: false)
                lastPanelSize = NSSize(width: cached.layout.panelWidth, height: cached.layout.panelHeight)
            }
            let w2 = CACurrentMediaTime()
            present(panel)
            let w3 = CACurrentMediaTime()
            debugLog("warm: apply %.1fms, frame %.1fms, present %.1fms, total %.1fms",
                     (w1 - start) * 1000, (w2 - w1) * 1000, (w3 - w2) * 1000, (w3 - start) * 1000)
            load(app: app, bundleID: bundleID, token: token, firstShow: false)
        } else {
            // Cold path: read the menus first, then appear once at the final size.
            load(app: app, bundleID: bundleID, token: token, firstShow: true)
        }
    }

    /// True when the panel closed itself because another app became active a
    /// moment ago — clicking the status item causes exactly that, and the click
    /// should close the panel rather than reopen it.
    var hiddenByActivationRecently: Bool {
        guard let lastActivationHide else { return false }
        return Date().timeIntervalSince(lastActivationHide) < 0.5
    }

    func hide(reason: HideReason = .user) {
        if reason == .activation { lastActivationHide = Date() }
        guard let panel, panel.isVisible else { return }
        loadToken += 1
        removeMonitors()
        // Let the content sink away quickly, then drop the window.
        if SettingsStore.shared.usesAnimation {
            withAnimation(.easeIn(duration: 0.12)) { model.contentVisible = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak panel] in
                panel?.orderOut(nil)
            }
        } else {
            panel.orderOut(nil)
        }
        // Only hand the app back when the panel was its last window. With the
        // settings (or about) window open the app must stay alive and active.
        let keepAppAlive = hasOtherWindows?() ?? false
        if keepAppAlive {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSApp.hide(nil)
            if let previousApp, previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                previousApp.activate(options: [.activateAllWindows])
            }
        }
    }

    /// Clicking the menu bar icon briefly activates another app, which would
    /// otherwise close the panel before the click handler can toggle it.
    func suppressAutoHide(for interval: TimeInterval = 0.8) {
        autoHideSuppressedUntil = Date().addingTimeInterval(interval)
    }

    func toggle(for app: NSRunningApplication) {
        if isVisible { hide() } else { show(for: app) }
    }

    /// Builds the window and lays out the view hierarchy once, so the first
    /// real ⌘⌘ does not pay for SwiftUI and glass setup.
    func prewarm() {
        let panel = ensurePanel()
        let sample = (0..<8).map {
            ShortcutItem(group: "常用", submenu: nil, title: "示例快捷键 \($0)", keys: ["⇧", "⌘", "K"])
        }
        model.panelWidth = PanelMetrics.minimumColumnWidth
        model.sections = [ShortcutSection(title: "常用", items: sample)]
        panel.setFrame(NSRect(x: 0, y: -4000, width: 620, height: 420), display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        model.sections = []
    }

    // MARK: - Loading

    private func load(app: NSRunningApplication, bundleID: String, token: Int, firstShow: Bool) {
        let wantsSystem = SettingsStore.shared.showsSystemShortcuts
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let t1 = CACurrentMediaTime()
            let sections = ShortcutExtractor.sections(for: app)
            let system = wantsSystem ? SystemShortcuts.section() : nil
            let t2 = CACurrentMediaTime()

            DispatchQueue.main.async {
                guard let self, token == self.loadToken else { return }
                let frequent = Self.frequentSection(from: sections, bundleID: app.bundleIdentifier)
                var all: [ShortcutSection] = []
                if let frequent { all.append(frequent) }
                all.append(contentsOf: sections)
                if let system { all.append(system) }

                let layout = PanelLayout.make(sections: all,
                                              maxSize: NSSize(width: self.model.maxPanelWidth,
                                                              height: self.model.panelHeight))
                let signature = all.map(\.signature).joined(separator: "|")
                self.cache[bundleID] = CachedPanel(sections: sections,
                                                   frequent: frequent,
                                                   system: system,
                                                   layout: layout,
                                                   signature: signature,
                                                   stamp: Date())

                let m0 = CACurrentMediaTime()
                if firstShow || self.panel?.isVisible != true {
                    // Show the glass panel right away at its final size with a
                    // "reading" header, then let the rows land a beat later.
                    self.model.isLoading = true
                    self.model.sections = []
                    self.model.frequentSection = nil
                    self.model.systemSection = nil
                    self.model.panelWidth = layout.panelWidth
                    let panel = self.ensurePanel()
                    panel.setFrame(self.frame(for: layout), display: false)
                    self.lastPanelSize = NSSize(width: layout.panelWidth, height: layout.panelHeight)
                    self.present(panel)
                    self.debugLog("panel up: extract %.1fms, total %.1fms (%d items)",
                                  (t2 - t1) * 1000, (CACurrentMediaTime() - t1) * 1000, all.reduce(0) { $0 + $1.items.count })

                    DispatchQueue.main.async {
                        guard token == self.loadToken, self.panel?.isVisible == true else { return }
                        let f0 = CACurrentMediaTime()
                        self.model.sections = sections
                        self.model.frequentSection = frequent
                        self.model.systemSection = system
                        self.hosting?.layoutSubtreeIfNeeded()
                        self.panel?.displayIfNeeded()
                        withAnimation(.easeOut(duration: 0.15)) {
                            self.model.isLoading = false
                        }
                        self.debugLog("content laid out in %.1fms", (CACurrentMediaTime() - f0) * 1000)
                    }
                } else if signature != self.currentSignature {
                    // Content changed while the panel was already up.
                    self.model.sections = sections
                    self.model.frequentSection = frequent
                    self.model.systemSection = system
                    self.model.panelWidth = layout.panelWidth
                    self.resize(to: NSSize(width: layout.panelWidth, height: layout.panelHeight))
                }
            }
        }
    }

    private var currentSignature: String {
        var all: [ShortcutSection] = []
        if let frequent = model.frequentSection { all.append(frequent) }
        all.append(contentsOf: model.sections)
        if let system = model.systemSection { all.append(system) }
        return all.map(\.signature).joined(separator: "|")
    }

    private func apply(_ cached: CachedPanel) {
        // Only touch the model when the content really differs; every assignment
        // republishes and re-renders the whole column tree.
        if cached.signature != currentSignature {
            model.sections = cached.sections
            model.frequentSection = cached.frequent
            model.systemSection = cached.system
        }
        if model.panelWidth != cached.layout.panelWidth {
            model.panelWidth = cached.layout.panelWidth
        }
    }

    /// "常用": the combinations you press most in this app, matched back to menu titles.
    private static func frequentSection(from sections: [ShortcutSection], bundleID: String?) -> ShortcutSection? {
        guard SettingsStore.shared.showsFrequent, let bundleID else { return nil }
        let combos = UsageTracker.shared.topCombos(bundleID: bundleID, limit: 14)
        guard !combos.isEmpty else { return nil }

        var byCombo: [String: ShortcutItem] = [:]
        for section in sections {
            for item in section.items where byCombo[item.keyString] == nil {
                byCombo[item.keyString] = item
            }
        }

        var items: [ShortcutItem] = []
        var seenTitles = Set<String>()
        for combo in combos {
            guard let item = byCombo[combo], !seenTitles.contains(item.title) else { continue }
            seenTitles.insert(item.title)
            items.append(ShortcutItem(group: "常用", submenu: item.group, title: item.title, keys: item.keys))
            if items.count >= 8 { break }
        }
        guard items.count >= 2 else { return nil }
        return ShortcutSection(title: "常用", items: items)
    }

    // MARK: - Panel plumbing

    private func ensurePanel() -> ShortcutPanel {
        if let panel { return panel }

        // A titled window with a transparent, full-size content view is what gives
        // us Apple's own rounded window shape and a shadow that follows it. A
        // borderless window gets a rectangular shadow, which reads as a black line
        // along the corners.
        let panel = ShortcutPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 300),
                                  styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                                  backing: .buffered,
                                  defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        if ProcessInfo.processInfo.environment["KEYGLANCE_APPEARANCE"] == nil {
            panel.appearance = NSAppearance(named: systemIsDark ? .darkAqua : .aqua)
        }
        switch ProcessInfo.processInfo.environment["KEYGLANCE_APPEARANCE"] {
        case "light": panel.appearance = NSAppearance(named: .aqua)
        case "dark": panel.appearance = NSAppearance(named: .darkAqua)
        default: break
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 300))
        container.wantsLayer = true
        container.layer?.cornerRadius = PanelMetrics.cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true

        let glass = NSGlassEffectView(frame: container.bounds)
        glass.cornerRadius = PanelMetrics.cornerRadius
        glass.style = .regular
        // The glass tints itself; the colour is resolved per appearance in updateTint().
        glass.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: ShortcutPanelView(model: model))
        // Never let SwiftUI's ideal size resize the panel; we drive the geometry.
        hosting.sizingOptions = []
        // The panel is a titled window whose title bar is invisible. Without this
        // SwiftUI reserves the title bar as safe area and pushes the content down.
        hosting.safeAreaRegions = []
        hosting.frame = glass.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.cornerRadius = PanelMetrics.cornerRadius
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        glass.contentView = hosting

        container.addSubview(glass)
        panel.contentView = container
        container.layoutSubtreeIfNeeded()

        self.panel = panel
        self.glass = glass
        self.hosting = hosting
        return panel
    }

    private func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private func frame(for layout: PanelLayout) -> NSRect {
        let size = NSSize(width: layout.panelWidth, height: layout.panelHeight)
        return frame(for: size)
    }

    private func frame(for size: NSSize) -> NSRect {
        var rect = NSRect(origin: .zero, size: size)
        let visible = (targetScreen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        rect.origin = NSPoint(x: visible.midX - size.width / 2,
                              y: visible.midY - size.height / 2)
        if rect.maxX > visible.maxX { rect.origin.x = visible.maxX - rect.width }
        if rect.minX < visible.minX { rect.origin.x = visible.minX }
        if rect.maxY > visible.maxY { rect.origin.y = visible.maxY - rect.height }
        if rect.minY < visible.minY { rect.origin.y = visible.minY }
        return rect
    }

    private func resize(to size: NSSize) {
        guard let panel else { return }
        let target = frame(for: size)
        guard panel.frame != target else { return }
        panel.setFrame(target, display: true)
        panel.invalidateShadow()
    }

    /// Follow the system appearance: the window itself can keep an old appearance
    /// while it is open, so listen for the theme change and re-resolve everything.
    private func observeThemeChanges() {
        guard themeObserver == nil else { return }
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.debugLog("theme changed: app=%@ panel=%@",
                              NSApp.effectiveAppearance.name.rawValue,
                              self.panel?.effectiveAppearance.name.rawValue ?? "nil")
                self.reapplyAppearance()
                // The glass sometimes keeps the old backdrop for a frame; settle it again.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.reapplyAppearance()
                }
            }
        }
    }

    /// The system's dark mode, straight from the preference — NSApp's effective
    /// appearance can still be stale for an accessory app with no windows, which
    /// made the glass paint its light (near white) tint for a frame.
    private var systemIsDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    private func reapplyAppearance() {
        guard let panel else { return }
        let forced = ProcessInfo.processInfo.environment["KEYGLANCE_APPEARANCE"]
        if forced == nil {
            panel.appearance = NSAppearance(named: systemIsDark ? .darkAqua : .aqua)
        }
        updateTint()
        panel.contentView?.needsLayout = true
        panel.contentView?.needsDisplay = true
        glass?.needsDisplay = true
        panel.invalidateShadow()
    }

    /// NSGlassEffectView resolves its tint once, so re-resolve it for the current
    /// appearance instead of painting a scrim over the content.
    private func updateTint() {
        guard let glass else { return }
        let isDark = systemIsDark
        // Both modes use the frosted style; light just needs a much lighter tint
        // than the 0.90 that used to make the panel look like a solid sheet.
        glass.style = .regular
        glass.tintColor = isDark
            ? NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 0.62)
            : NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.25)
        if ProcessInfo.processInfo.environment["KEYGLANCE_DEBUG"] == "1" {
            NSLog("KeyGlance tint: dark=\(isDark) style=\(glass.style.rawValue) alpha=\(glass.tintColor?.alphaComponent ?? -1)")
        }
    }

    private func present(_ panel: ShortcutPanel) {
        reapplyAppearance()
        NSApp.activate(ignoringOtherApps: true)

        // The glass paints its backdrop a frame or two after the window appears;
        // those frames are the white flash. Put the window on screen invisibly,
        // let it compose, then reveal it in a single step (no partial alpha).
        let animated = SettingsStore.shared.usesAnimation
        model.contentVisible = !animated
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.displayIfNeeded()
        panel.invalidateShadow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak panel] in
            guard let panel, panel.isVisible else { return }
            panel.alphaValue = 1
            guard animated else { return }
            // Launchpad-like entrance: the content springs up into place while the
            // glass plate itself is already there, so nothing re-renders the blur.
            withAnimation(.interpolatingSpring(stiffness: 340, damping: 30)) {
                self.model.contentVisible = true
            }
        }
        // Settle the tint once more after the first frame: the glass resolves its
        // material slightly after the window appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.reapplyAppearance()
        }
        installMonitors()
    }

    private func debugLog(_ format: String, _ args: CVarArg...) {
        guard ProcessInfo.processInfo.environment["KEYGLANCE_DEBUG"] == "1" else { return }
        NSLog("KeyGlance perf: " + String(format: format, arguments: args))
    }

    // MARK: - Monitors

    private func installMonitors() {
        removeMonitors()

        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            let point = NSEvent.mouseLocation
            // Clicks in the menu bar belong to the status item, not to "outside".
            if let screen = panel.screen ?? NSScreen.main, point.y > screen.frame.maxY - 26 {
                    return
            }
            if !panel.frame.contains(point) {
                self.hide()
            }
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { // esc
                self?.hide()
                return nil
            }
            return event
        }

        guard ProcessInfo.processInfo.environment["KEYGLANCE_NOAUTOHIDE"] != "1" else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                              object: nil,
                                                                              queue: .main) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if Date() < self.autoHideSuppressedUntil {
                return
            }
            if app.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.hide(reason: .activation)
            }
        }
    }

    private func removeMonitors() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        outsideMonitor = nil
        keyMonitor = nil
        activationObserver = nil
    }
}
