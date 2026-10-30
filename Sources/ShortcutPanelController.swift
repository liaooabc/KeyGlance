import AppKit
import Combine
import SwiftUI

enum HideReason { case user, activation }

/// SwiftUI 的宿主视图会把自己的"理想高度"报给 Auto Layout，玻璃底板的 contentView
/// 一旦照它走，面板变高度时内容就被撑成 700/990 这种数，露出来的部分自然错位。
/// 这里直接不报理想尺寸，尺寸只由外层容器的 bounds 决定。
final class FixedHostingView<Content: View>: NSHostingView<Content> {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

/// 玻璃和 SwiftUI 之间垫一层：只做一件事——把自己的 bounds 抄给子视图。
/// NSGlassEffectView 会把 contentView 按 SwiftUI 的理想高度来摆，面板一改高度
/// （搜索、清空搜索）内容就错位：上半截被裁掉、下面空一大片。
final class FillingHostView: NSView {
    override func layout() {
        super.layout()
        for subview in subviews where subview.frame != bounds {
            subview.frame = bounds
        }
    }
}

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
    /// 打开面板时冻结的摆放基准：中心点 + 系统允许的横向范围 + 垂直可见区。
    /// 台前调度会在屏幕左边让出一条窗口缩略栏，窗口落进那条带里会被系统夹回右边，
    /// 若每次 resize 都按整屏重新居中，窗口就会"贴着缩略栏、右侧空一截"。
    private var panelAnchor: (center: NSPoint, allowedX: ClosedRange<CGFloat>, visible: NSRect)?
    /// 台前调度留给左侧缩略栏的禁区：系统不报告它，但可以直接问——
    /// 把一个跑到屏幕外的矩形 constrain 回来，夹住的位置就是边界（实测 221pt）。
    /// 这个值现在只用来做体检/日志：面板最终要落在**整屏**的正中，
    /// 会伸进这条禁区里，靠"上屏之后再挪一次"躲开系统的夹取（见 `present`）。
    private func allowedXRange(for screen: NSScreen?) -> (left: CGFloat, right: CGFloat) {
        guard let screen, let probe = panel else {
            let fallback = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            return (fallback.minX, fallback.maxX)
        }
        let probeSize = NSSize(width: 200, height: 100)
        let y = screen.frame.midY
        let farLeft = probe.constrainFrameRect(
            NSRect(x: -10000, y: y, width: probeSize.width, height: probeSize.height), to: screen)
        let farRight = probe.constrainFrameRect(
            NSRect(x: 10000, y: y, width: probeSize.width, height: probeSize.height), to: screen)
        return (farLeft.minX, farRight.maxX)
    }
    private var prefetchToken = 0
    private var queryObserver: AnyCancellable?
    private var loadToken = 0
    private var autoHideSuppressedUntil = Date.distantPast
    private var lastActivationHide: Date?

    /// Last known panel content per app, so a second ⌘⌘ opens instantly.
    private struct CachedPanel {
        var sections: [ShortcutSection]
        var frequent: ShortcutSection?
        var system: ShortcutSection?
        var layout: PanelColumns
        var signature: String
        var stamp: Date
    }
    private var cache: [String: CachedPanel] = [:]
    private var lastPanelSize: NSSize?
    private var appliedAppearanceKey: String?
    private var shadowSize: NSSize = .zero
    /// 入场动画还在跑的时间点：在这之前任何改窗口尺寸的请求都推迟，
    /// 否则一次 setFrame(display:)+invalidateShadow 就是 40ms 的卡顿，正好落在淡入里。
    private var revealEndsAt: CFTimeInterval = 0
    /// 每次 present/hide 自增；旧的延迟回调看到编号变了就不要再动窗口。
    private var presentGeneration = 0
    /// 已按下淡入、在等内容落地（冷启动）。
    private var awaitingContent = false
    private var revealPending = false
    /// 淡入进行中：这期间不许换内容、不许改尺寸。
    private var revealInFlight = false

    init() {
        observeThemeChanges()
        // 旧版把"舞台几何"反推着存进了 UserDefaults。那份值会过期（系统改一次缩略栏
        // 宽度就失效），面板就会长期偏在一侧。现在每次都直接量，用不到了就清掉。
        UserDefaults.standard.removeObject(forKey: "stageWidthLimitsByScreen")
        UserDefaults.standard.removeObject(forKey: "stageCenterOffsetsByScreen")
        // 搜索词一变，面板高度就跟着结果的版面走（只改高度、顶边不动）。
        // 只靠表格回调不够：搜不到结果时表格根本不在，回调不会来。
        queryObserver = model.$query
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] query in
                guard let self else { return }
                if let panel = self.panel {
                    self.debugLog("query '%@': panel h=%.0f top=%.0f, layout h=%.0f",
                                  query, panel.frame.height, panel.frame.maxY,
                                  self.model.layout.panelHeight)
                }
                // 不再跟着搜索词改窗口高度（见 onContentHeight 里的说明）。
            }
        model.onContentHeight = { [weak self] height in
            guard let self else { return }
            self.model.contentReportedHeight = height
            let target = PanelMetrics.headerHeight + PanelColumns.verticalPadding + height
            guard abs((self.panel?.frame.height ?? 0) - target) > 1 else { return }
            // 搜索时不改面板高度：一边过滤一边改窗口尺寸，玻璃/内容很容易有一帧对不上，
            // 看到的就是"内容往上窜、只剩下面一截"。搜索只在打开时按完整清单击一次高度。
            guard self.model.query.isEmpty else {
                self.debugLog("skip resize while searching (want %.0f, have %.0f)",
                              target, self.panel?.frame.height ?? -1)
                return
            }
            // 搜索/清空搜索时面板高度会跟着结果变，这时顶边钉住不动：
            // 按中心缩放的话，内容会在打字、删字时整体上下漂。
            self.resize(to: NSSize(width: self.model.panelWidth, height: target), keepTop: true)
        }
    }

    /// Told by AppDelegate: does the app still have a settings/about window up?
    var hasOtherWindows: (() -> Bool)?

    /// 按住模式：面板摊开时不激活键览、不抢焦点——用户多半是一边按着 ⌘
    /// 一边在别的 App 里操作，面板要是抢了焦点，⌘C 就跑到面板里去了。
    private var heldMode = false

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    // MARK: - Public

    /// 按住模式下摊开面板。跟普通打开的区别只有两处：不激活键览、不抢焦点。
    func showHeld(for app: NSRunningApplication) {
        heldMode = true
        model.isHeld = true
        show(for: app)
    }

    /// 按住模式：松开修饰键，把面板收回去。
    func hideHeld() {
        heldMode = false
        model.isHeld = false
        // 面板还没出现（菜单还在读）就松开了：把这次加载作掉，
        // 否则它落地之后面板会一个人留在屏幕上（修饰键早就不在了）。
        if panel?.isVisible != true {
            loadToken += 1
            presentGeneration += 1
            return
        }
        hide(reason: .user)
    }

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
        // 量允许范围要用一个真实的窗口去问 AppKit（constrainFrameRect），
        // 窗口先建好（启动时 prewarm 已经建过，这里只是取出来）。
        ensurePanel()
        // 先量出系统允许摆放的范围，再据此定中心和最大宽度：
        // 台前调度的缩略栏让出来的那条禁区不算在可视中心里，面板要按剩下的范围居中。
        panelAnchor = anchor(for: screen)
        let maximum = maxSize(for: screen)
        model.maxPanelWidth = maximum.width
        model.panelHeight = maximum.height

        if let cached = cache[bundleID], !cached.sections.isEmpty {
            // Warm path: appear immediately with the cached content.
            apply(cached)
            let w1 = CACurrentMediaTime()
            let panel = ensurePanel()
            // 尺寸只认 model.layout：视图是按它排的，缓存里那份可能是别的可用宽度下算的。
            let layout = model.layout
            if model.panelWidth != layout.panelWidth { model.panelWidth = layout.panelWidth }
            let size = NSSize(width: layout.panelWidth, height: layout.panelHeight)
            // 每次都按算好的位置摆一次（整屏正中）。
            panel.setFrame(frame(for: layout), display: false)
            lastPanelSize = size
            let w2 = CACurrentMediaTime()
            // 有缓存内容：先用它淡入（面板要快）；真变了的内容只更新缓存，下次打开再用。
            present(panel, waitForContent: false)
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
        debugLog("hide reason=%@ visible=%@", reason == .activation ? "activation" : "user",
                 panel?.isVisible == true ? "yes" : "no")
        if reason == .activation { lastActivationHide = Date() }
        guard let panel, panel.isVisible else { return }
        loadToken += 1
        presentGeneration += 1
        let hideGeneration = presentGeneration
        awaitingContent = false
        revealPending = false
        revealInFlight = false
        revealEndsAt = 0
        panelAnchor = nil
        removeMonitors()
        // Let the content sink away quickly, then drop the window.
        if SettingsStore.shared.usesAnimation, let hosting {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.09
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                hosting.animator().alphaValue = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self, weak panel] in
                // 90ms 内又打开了面板就不要收：那是新的那次 present，编号已经变了。
                guard let self, hideGeneration == self.presentGeneration else { return }
                panel?.orderOut(nil)
            }
        } else {
            hosting?.alphaValue = 1
            panel.orderOut(nil)
        }
        // Only hand the app back when the panel was its last window. With the
        // settings (or about) window open the app must stay alive and active.
        let keepAppAlive = hasOtherWindows?() ?? false
        if heldMode {
            // 按住模式从头到尾没有激活过键览，焦点一直在前台那个 App 身上。
            // 这里千万别去 activate 谁——那会把用户的键盘抢回来。
            panel.orderOut(nil)
        } else if keepAppAlive {
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

    /// 仅调试：改搜索词，复现"输入 → 删除"时的高度/内容复位问题。
    func debugSetQuery(_ text: String) {
        let before = panel?.frame ?? .zero
        model.query = text
        debugLog("query '%@': panel %.0fx%.0f top=%.0f -> target %.0fx%.0f",
                 text, before.width, before.height, before.maxY,
                 model.layout.panelWidth, model.layout.panelHeight)
    }

    /// 后台把一个 App 的快捷键读好放进缓存。切到某个 App 后顺手做这件事，
    /// 双击 ⌘ 时就有"新鲜且已排好版"的内容可用——面板打开后不再换内容。
    func prefetch(for app: NSRunningApplication) {
        guard !isVisible, let bundleID = app.bundleIdentifier, !bundleID.isEmpty,
              bundleID != Bundle.main.bundleIdentifier else { return }
        prefetchToken += 1
        let token = prefetchToken
        let wantsSystem = SettingsStore.shared.showsSystemShortcuts
        let maxSize = self.maxSize(for: NSScreen.main)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let sections = ShortcutExtractor.sections(for: app)
            guard !sections.isEmpty else { return }
            let system = wantsSystem ? SystemShortcuts.section() : nil
            DispatchQueue.main.async {
                guard let self, token == self.prefetchToken else { return }
                let frequent = Self.frequentSection(from: sections, bundleID: bundleID)
                var all: [ShortcutSection] = []
                if let frequent { all.append(frequent) }
                all.append(contentsOf: sections)
                if let system { all.append(system) }
                let layout = PanelColumns.make(sections: all, maxSize: maxSize)
                self.cache[bundleID] = CachedPanel(sections: sections,
                                                   frequent: frequent,
                                                   system: system,
                                                   layout: layout,
                                                   signature: all.map(\.signature).joined(separator: "|"),
                                                   stamp: Date())
                self.debugLog("prefetched %@ (%d items)", app.localizedName ?? bundleID, all.reduce(0) { $0 + $1.items.count })
            }
        }
    }

    /// Builds the window and lays out the view hierarchy once, so the first
    /// real ⌘⌘ does not pay for SwiftUI and glass setup.
    func prewarm() {
        let panel = ensurePanel()
        let sample = (0..<8).map {
            ShortcutItem(group: "常用", submenu: nil, title: "示例快捷键 \($0)", keys: ["⇧", "⌘", "K"])
        }
        model.panelWidth = PanelColumns.minColumnWidth
        model.sections = [ShortcutSection(title: "常用", items: sample)]
        panel.setFrame(NSRect(x: 0, y: -4000, width: 620, height: 420), display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        model.sections = []
    }

    // MARK: - Loading

    private func load(app: NSRunningApplication, bundleID: String, token: Int, firstShow: Bool) {
        // 缓存还新鲜（切到这个 App 时已经后台读过）就不必再读一遍菜单栏：
        // 重复打开同一个 App 时内容稳定，也就不会出现"打开后文字又重排一次"。
        if !firstShow, let cached = cache[bundleID], Date().timeIntervalSince(cached.stamp) < 2 {
            debugLog("cache fresh (%.2fs), skip extract", Date().timeIntervalSince(cached.stamp))
            return
        }
        let wantsSystem = SettingsStore.shared.showsSystemShortcuts
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let t1 = CACurrentMediaTime()
            let sample = ProcessInfo.processInfo.environment["KEYGLANCE_SAMPLE"] == "1"
            let sections = sample ? SampleShortcuts.sections() : ShortcutExtractor.sections(for: app)
            // 样张里已经有「系统」这一栏，别再叠一份真的系统快捷键。
            let system = (wantsSystem && !sample) ? SystemShortcuts.section() : nil
            let t2 = CACurrentMediaTime()

            DispatchQueue.main.async {
                guard let self, token == self.loadToken else { return }
                let frequent = Self.frequentSection(from: sections, bundleID: app.bundleIdentifier)
                var all: [ShortcutSection] = []
                if let frequent { all.append(frequent) }
                all.append(contentsOf: sections)
                if let system { all.append(system) }

                let layout = PanelColumns.make(sections: all,
                                               maxSize: NSSize(width: self.model.maxPanelWidth,
                                                               height: self.model.panelHeight))
                // 窗口尺寸一律以 model.layout 为准：视图就是按它排的，
                // 两处各算一遍容易一个高一个矮，底下就多出一条空玻璃。
                let signature = all.map(\.signature).joined(separator: "|")
                self.cache[bundleID] = CachedPanel(sections: sections,
                                                   frequent: frequent,
                                                   system: system,
                                                   layout: layout,
                                                   signature: signature,
                                                   stamp: Date())

                // 内容落地：一次赋完、排一次版。冷启动时它发生在窗口还不可见的时候。
                let applyContent: () -> Void = { [weak self] in
                    guard let self else { return }
                    let f0 = CACurrentMediaTime()
                    self.model.sections = sections
                    self.model.frequentSection = frequent
                    self.model.systemSection = system
                    self.model.panelWidth = layout.panelWidth
                    // 不加过渡动画：内容本来就跟着入场动画一起淡进来，
                    // 再叠一层交叉淡出会和入场抢主线程，看起来就像掉帧。
                    self.model.isLoading = false
                    let f1 = CACurrentMediaTime()
                    self.hosting?.layoutSubtreeIfNeeded()
                    let f2 = CACurrentMediaTime()
                    self.panel?.displayIfNeeded()
                    let f3 = CACurrentMediaTime()
                    self.syncSizeToModel()
                    let f4 = CACurrentMediaTime()
                    self.debugLog("content laid out in %.1fms (publish %.1f layout %.1f display %.1f size %.1f)",
                                  (f4 - f0) * 1000, (f1 - f0) * 1000, (f2 - f1) * 1000, (f3 - f2) * 1000, (f4 - f3) * 1000)
                }

                if firstShow || self.panel?.isVisible != true {
                    // 冷启动：面板按最终尺寸隐形上屏，内容排好之后才淡入。
                    self.model.isLoading = true
                    self.model.sections = []
                    self.model.frequentSection = nil
                    self.model.systemSection = nil
                    self.model.panelWidth = layout.panelWidth
                    let panel = self.ensurePanel()
                    panel.setFrame(self.frame(for: layout), display: false)
                    self.lastPanelSize = NSSize(width: layout.panelWidth, height: layout.panelHeight)
                    self.present(panel, waitForContent: true)
                    let generation = self.presentGeneration
                    self.debugLog("panel up: %@ extract %.1fms, total %.1fms (%d items)",
                                  self.model.appName, (t2 - t1) * 1000, (CACurrentMediaTime() - t1) * 1000, all.reduce(0) { $0 + $1.items.count })

                    DispatchQueue.main.async {
                        guard token == self.loadToken, self.panel?.isVisible == true else { return }
                        applyContent()
                        self.contentDidLand(generation: generation)
                    }
                } else if signature != self.currentSignature {
                    // 面板已经开着：菜单内容变了（Safari 这类会跟着页面走）。
                    // 这时候换版要整表重排，用户看到的就是"打开后又自己变了一次"，
                    // 所以只把新内容存进缓存，等下次打开再用（那时排版在淡入之前完成）。
                    self.debugLog("content changed while open: cached for next open")
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

        // 只管装玻璃：圆角交给 NSGlassEffectView 自己画，别再套一层不同曲线的遮罩，
        // 否则容器和玻璃会画出两条几乎重合但弧度不同的边。
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 300))
        container.wantsLayer = true

        let glass = NSGlassEffectView(frame: container.bounds)
        glass.cornerRadius = PanelMetrics.cornerRadius
        glass.style = .regular
        // The glass tints itself; the colour is resolved per appearance in updateTint().
        glass.autoresizingMask = [.width, .height]

        let hosting = FixedHostingView(rootView: ShortcutPanelView(model: model))
        // Never let SwiftUI's ideal size resize the panel; we drive the geometry.
        hosting.sizingOptions = []
        // The panel is a titled window whose title bar is invisible. Without this
        // SwiftUI reserves the title bar as safe area and pushes the content down.
        hosting.safeAreaRegions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        let hostBox = FillingHostView(frame: container.bounds)
        hostBox.addSubview(hosting)

        // 玻璃只负责画背景，内容单独一层盖在它上面。
        // 以前内容放在 glass.contentView 里，NSGlassEffectView 会按内容的"理想高度"
        // 自己长到 900+，把容器也撑大——面板一变高度内容就错位（只露下面一截）。
        container.addSubview(glass)
        container.addSubview(hostBox)
        for view in [glass, hostBox] {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
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

    private func frame(for layout: PanelColumns) -> NSRect {
        let size = NSSize(width: layout.panelWidth, height: layout.panelHeight)
        return frame(for: size)
    }

    /// 面板可用的最大尺寸：按整屏能给的范围算。台前调度让出来的缩略栏禁区不算在内——
    /// 面板最终要落在整屏的正中，会伸进那条禁区，靠"上屏之后再挪一次"躲开系统的夹取。
    private func maxSize(for screen: NSScreen?) -> NSSize {
        var size = PanelColumns.maxSize(for: screen)
        if let raw = ProcessInfo.processInfo.environment["KEYGLANCE_MAXW"], let w = Double(raw) {
            size.width = min(size.width, CGFloat(w))
        }
        // 调试用：假装只允许这么宽的面板，用来复现收窄后的排版。
        if let raw = ProcessInfo.processInfo.environment["KEYGLANCE_STAGE_LIMIT"], let w = Double(raw) {
            size.width = min(size.width, CGFloat(w))
        }
        return size
    }

    /// 面板的摆放基准：水平取**整屏**的正中，垂直落在可见区域内。
    /// 之后的尺寸变化只改大小，中心点不动。
    private func anchor(for screen: NSScreen?) -> (center: NSPoint, allowedX: ClosedRange<CGFloat>, visible: NSRect) {
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = screen?.visibleFrame ?? frame
        return (NSPoint(x: frame.midX, y: visible.midY), frame.minX...frame.maxX, visible)
    }

    private func frame(for size: NSSize) -> NSRect {
        let anchor = panelAnchor ?? self.anchor(for: targetScreen ?? NSScreen.main)
        var rect = NSRect(x: anchor.center.x - size.width / 2,
                          y: anchor.center.y - size.height / 2,
                          width: size.width,
                          height: size.height)
        if rect.maxX > anchor.allowedX.upperBound { rect.origin.x = anchor.allowedX.upperBound - rect.width }
        if rect.minX < anchor.allowedX.lowerBound { rect.origin.x = anchor.allowedX.lowerBound }
        if rect.maxY > anchor.visible.maxY { rect.origin.y = anchor.visible.maxY - rect.height }
        if rect.minY < anchor.visible.minY { rect.origin.y = anchor.visible.minY }
        return rect
    }

    /// 窗口尺寸以视图正在用的那份 layout 为准，保证内容正好铺满、底边不多一条空玻璃。
    /// 仅调试：把窗口/宿主视图/表格三层的实际高度打出来，看是哪一层没跟上。
    private func sampleGeometry(tag: String) {
        guard ProcessInfo.processInfo.environment["KEYGLANCE_DEBUG"] == "1" else { return }
        let window = panel?.frame.height ?? -1
        let host = hosting?.frame.height ?? -1
        let hostTop = hosting.map { $0.convert($0.bounds, to: nil).maxY } ?? -1
        let containerH = panel?.contentView?.frame.height ?? -1
        let glassH = glass?.frame.height ?? -1
        let boxH = glass?.contentView?.frame.height ?? -1
        if let hosting {
            debugLog("     intrinsic: host=%@ fitting=%@ boxFitting=%@ glassFitting=%@",
                     NSStringFromSize(hosting.intrinsicContentSize),
                     NSStringFromSize(hosting.fittingSize),
                     NSStringFromSize(hosting.superview?.fittingSize ?? .zero),
                     NSStringFromSize(glass?.fittingSize ?? .zero))
        }
        debugLog("geom %@: window h=%.0f container=%.0f glass=%.0f box=%.0f host=%.0f layout h=%.0f reported=%.0f",
                 tag, window, containerH, glassH, boxH, host, model.layout.panelHeight, model.contentReportedHeight)
    }

    /// 让窗口高度跟上当前版面（搜索、清空搜索、内容换版都用这一处）。
    private func syncHeightToLayout(keepTop: Bool) {
        guard let panel, panel.isVisible, !model.isLoading else { return }
        resize(to: NSSize(width: model.panelWidth, height: model.layout.panelHeight), keepTop: keepTop)
    }

    private func syncSizeToModel() {
        guard panel != nil else { return }
        let layout = model.layout
        resize(to: NSSize(width: layout.panelWidth, height: layout.panelHeight))
    }

    private func resize(to size: NSSize, keepTop: Bool = false) {
        guard let panel else { return }
        var target = frame(for: size)
        if keepTop, panel.isVisible {
            // 顶边不动，只往下长/收；超出可见区再整体上推。
            let anchor = panelAnchor ?? self.anchor(for: targetScreen ?? NSScreen.main)
            target.origin.y = panel.frame.maxY - size.height
            if target.maxY > anchor.visible.maxY { target.origin.y = anchor.visible.maxY - size.height }
            if target.minY < anchor.visible.minY { target.origin.y = anchor.visible.minY }
        }
        guard panel.frame != target else { return }
        if CACurrentMediaTime() < revealEndsAt {
            // 入场动画期间不动尺寸：等淡入结束再来，尺寸不变的话这次请求本来也是空转。
            DispatchQueue.main.asyncAfter(deadline: .now() + (revealEndsAt - CACurrentMediaTime()) + 0.01) { [weak self] in
                self?.resize(to: size)
            }
            return
        }
        let t0 = CACurrentMediaTime()
        panel.setFrame(target, display: true)
        panel.invalidateShadow()
        // 窗口和内容必须在同一个 runloop 里一起到位：先 setFrame、再立刻把内容摆好，
        // 否则中间会有一帧"窗口已经是新高度、内容还是旧高度"，看到的正是
        // "上半截被裁掉、只剩下面一截"。
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        sampleGeometry(tag: "after-resize")
        debugLog("resize keepTop=%@ %.0fx%.0f@y%.0f -> %.0fx%.0f@y%.0f in %.1fms (visible=%@)",
                 keepTop ? "yes" : "no",
                 panel.frame.width, panel.frame.height, panel.frame.minY,
                 size.width, size.height, target.minY,
                 (CACurrentMediaTime() - t0) * 1000, panel.isVisible ? "yes" : "no")
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
                self.reapplyAppearance(force: true)
                // The glass sometimes keeps the old backdrop for a frame; settle it again.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.reapplyAppearance(force: true)
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

    /// 明暗没变就别重排：整窗 `needsLayout` + 重算阴影在这么大的面板上要 40ms 以上，
    /// 每次打开都做一遍，入场动画一开始就卡。
    private func reapplyAppearance(force: Bool = false) {
        guard let panel else { return }
        let forced = ProcessInfo.processInfo.environment["KEYGLANCE_APPEARANCE"]
        let isDark = forced.map { $0 == "dark" } ?? systemIsDark
        let key = "\(isDark)-" + (forced ?? "system")
        if !force, appliedAppearanceKey == key, glass?.tintColor != nil { return }
        appliedAppearanceKey = key

        if forced == nil {
            panel.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        }
        updateTint(isDark: isDark)
        panel.contentView?.needsLayout = true
        panel.contentView?.needsDisplay = true
        glass?.needsDisplay = true
        invalidateShadowIfNeeded(panel)
    }

    private func invalidateShadowIfNeeded(_ panel: NSPanel) {
        let size = panel.frame.size
        guard shadowSize != size else { return }
        shadowSize = size
        panel.invalidateShadow()
    }

    /// NSGlassEffectView resolves its tint once, so re-resolve it for the current
    /// appearance instead of painting a scrim over the content.
    private func updateTint(isDark: Bool) {
        guard let glass else { return }
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

    /// 把窗口隐形上屏，等玻璃采样好背景再淡入内容。
    /// `waitForContent`：冷启动时内容还在读菜单栏，等它排版完再淡入，
    /// 否则整表重画（90 行约 100ms）会落在淡入里，看起来就是掉帧。
    private func present(_ panel: ShortcutPanel, waitForContent: Bool) {
        reapplyAppearance()
        // 按住模式**不激活键览**：用户的 ⌘ 还得继续送到前台那个 App 去，
        // 面板只是浮在上面看一眼。
        if !heldMode {
            NSApp.activate(ignoringOtherApps: true)
        }

        // The glass paints its backdrop a frame or two after the window appears;
        // those frames are the white flash. Put the window on screen invisibly,
        // let it compose, then reveal it in a single step (no partial alpha).
        let animated = SettingsStore.shared.usesAnimation
        panel.alphaValue = 0
        // 按住模式也用 makeKeyAndOrderFront：面板是 `.nonactivatingPanel`，
        // 拿 key 状态**不会激活键览**（前台 App 照旧是 active，⌘C 照样发给它），
        // 但玻璃需要 key 状态才能采样到背景——用 orderFront 的话材质不渲染，
        // 整个面板变成一块死黑，色块的颜色也全丢了。
        panel.makeKeyAndOrderFront(nil)
        // 台前调度会在窗口上屏这一刻按"舞台区"把它夹一下：左边缩略栏占着的那条
        // 禁区（实测 221pt）不让窗口进去，超宽时还会整块右移、右边缘被切掉。
        // 关键在于**夹取只发生在上屏这一刻**：窗口已经在屏上了，再挪它系统就不管了。
        // 所以顺序必须是"先上屏、再摆到整屏真正的正中"——摆在上屏之前会被夹到 221，
        // 看起来就是"贴着缩略栏、右边空一截"。
        let placed = frame(for: panel.frame.size)
        panel.setFrame(placed, display: false)
        panel.displayIfNeeded()
        if let screen = targetScreen ?? NSScreen.main {
            let f = screen.frame, v = screen.visibleFrame
            let allowed = allowedXRange(for: screen)
            debugLog("geometry panel=%.0fx%.0f at (%.0f,%.0f) | screen %.0fx%.0f | visible x=%.0f w=%.0f | 屏幕正中 %.1f | 台前调度禁区 x<%.0f",
                     panel.frame.width, panel.frame.height, panel.frame.minX, panel.frame.minY,
                     f.width, f.height, v.minX, v.width, f.midX, allowed.left)
        }
        invalidateShadowIfNeeded(panel)
        if ProcessInfo.processInfo.environment["KEYGLANCE_DEBUG_CAPTURE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.captureDebug()
            }
        }
        if ProcessInfo.processInfo.environment["KEYGLANCE_DEBUG"] == "1" { startFrameProbe() }
        // 内容用一个 AppKit 的透明度动画淡进来：只改 hosting view 的 layer opacity，
        // 由合成器完成，不触发 SwiftUI 重排（以前用 scaleEffect，每帧几千万像素重画，
        // 大面板上直接掉到个位数帧）。
        // 关了动画就直接显示内容，别沿用上一次收起时残留的 0 透明度。
        hosting?.alphaValue = animated ? 0 : 1

        presentGeneration += 1
        let generation = presentGeneration
        revealInFlight = false
        revealPending = false
        awaitingContent = waitForContent
        revealEndsAt = 0
        guard animated else {
            panel.alphaValue = 1
            installMonitors()
            return
        }
        // 0.08s：够玻璃和首屏 cell 就位，别让淡入的第一帧还在构图。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self, weak panel] in
            guard let self, generation == self.presentGeneration, let panel, panel.isVisible else { return }
            if self.awaitingContent {
                // 内容还没落地：先按下不动，等 contentDidLand() 再淡入；
                // 但最多再等 0.3s，宁可先淡入空面板也不要让窗口迟迟不出现。
                self.revealPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, generation == self.presentGeneration, self.awaitingContent else { return }
                    self.awaitingContent = false
                    self.beginReveal(generation: generation)
                }
                return
            }
            self.beginReveal(generation: generation)
        }
        // 不再延迟重刷外观：玻璃的 tint 在 present 前已经算好，收尾那次
        // `reapplyAppearance()` 会整窗重排 + 重算阴影（实测能卡 100ms 以上），
        // 正好落在入场动画里，看起来就是掉帧。
        installMonitors()
    }

    /// 调试用：把面板内容渲染成 PNG（玻璃这种系统材质渲染不出来，但玻璃视图的
    /// frame 边框能画出来，用来对位置）。
    private func captureDebug() {
        guard let panel, let view = panel.contentView else { return }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                          pixelsWide: Int(view.bounds.width),
                                          pixelsHigh: Int(view.bounds.height),
                                          bitsPerSample: 8, samplesPerPixel: 4,
                                          hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/kgcap.png"))
            NSLog("KeyGlance capture written")
        }
    }

    /// 内容排完了、可以显示：冷启动的淡入从这里开始。
    private func contentDidLand(generation: Int) {
        guard generation == presentGeneration else { return }
        awaitingContent = false
        guard revealPending else { return }
        // 隔一个 runloop 再淡入：表格把行视图建完常常还有一趟收尾，
        // 紧接着淡入的话第一帧就会赶上它（大面板上实测 25ms）。
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.presentGeneration, self.revealPending else { return }
            self.beginReveal(generation: generation)
        }
    }

    /// 真正的那一次淡入。淡入期间整条主线程只服务合成器。
    private func beginReveal(generation: Int) {
        guard generation == presentGeneration, let panel, panel.isVisible, let hosting else { return }
        revealPending = false
        revealInFlight = true
        revealEndsAt = CACurrentMediaTime() + 0.16
        panel.alphaValue = 1
        debugLog("reveal start at %.0fms", (CACurrentMediaTime() - probeStart) * 1000)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.85, 0.3, 1)
            hosting.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.revealInFlight = false
            self.revealEndsAt = 0
            self.debugLog("reveal end at %.0fms", (CACurrentMediaTime() - self.probeStart) * 1000)
        }
    }

    // MARK: - 帧率探针（仅调试）

    private var frameLink: CADisplayLink?
    private var frameTimes: [CFTimeInterval] = []
    private var probeStart: CFTimeInterval = CACurrentMediaTime()

    private func startFrameProbe() {
        frameTimes = []
        probeStart = CACurrentMediaTime()
        guard frameLink == nil, let hosting else { return }
        let link = hosting.displayLink(target: self, selector: #selector(frameTick(_:)))
        link.add(to: .main, forMode: .common)
        frameLink = link
    }

    /// 每 0.5 秒报一次：帧数 / 平均间隔 / 最长一帧，用来看入场和静止时的流畅度。
    @objc private func frameTick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        frameTimes.append(now)
        guard let first = frameTimes.first, now - first >= 0.5 else { return }
        let deltas = zip(frameTimes.dropFirst(), frameTimes).map { $0.0 - $0.1 }
        for (index, delta) in deltas.enumerated() where delta > 0.024 {
            NSLog("KeyGlance hitch: at %.0fms %.1fms", (frameTimes[index] - probeStart) * 1000, delta * 1000)
        }
        let worst = deltas.max() ?? 0
        let avg = deltas.isEmpty ? 0 : deltas.reduce(0, +) / Double(deltas.count)
        NSLog("KeyGlance frames: t=%.1fs n=%d avg=%.1fms worst=%.1fms",
              now - probeStart, frameTimes.count, avg * 1000, worst * 1000)
        frameTimes = [now]
    }

    private func debugLog(_ format: String, _ args: CVarArg...) {
        guard ProcessInfo.processInfo.environment["KEYGLANCE_DEBUG"] == "1" else { return }
        NSLog("KeyGlance perf: " + String(format: format, arguments: args))
    }

    // MARK: - Monitors

    private func installMonitors() {
        removeMonitors()

        // 按住模式：面板是"摊开给人看"的，点外面、或者切到别的 App 都**不能**关它——
        // 它跟着修饰键走，修饰键松开才收。
        if heldMode { return }

        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            // 调试时不想被随手一点关掉（截图/自动测试会被打断）。
            guard ProcessInfo.processInfo.environment["KEYGLANCE_NOAUTOHIDE"] != "1" else { return }
            let point = NSEvent.mouseLocation
            self.debugLog("global click at (%.0f,%.0f) panel=(%.0f,%.0f %.0fx%.0f) inside=%@",
                          point.x, point.y, panel.frame.minX, panel.frame.minY,
                          panel.frame.width, panel.frame.height,
                          panel.frame.contains(point) ? "yes" : "no")
            // Clicks in the menu bar belong to the status item, not to "outside".
            if let screen = panel.screen ?? NSScreen.main, point.y > screen.frame.maxY - 26 {
                    return
            }
            if !panel.frame.contains(point) {
                self.hide()
            }
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if let self {
                let responder = event.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                self.debugLog("key keyCode=%d chars=%@ query='%@' responder=%@ panelH=%.0f top=%.0f",
                              event.keyCode, event.charactersIgnoringModifiers ?? "",
                              self.model.query, responder,
                              self.panel?.frame.height ?? -1, self.panel?.frame.maxY ?? -1)
            }
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
            self.debugLog("app activated: %@", app.localizedName ?? app.bundleIdentifier ?? "?")
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
