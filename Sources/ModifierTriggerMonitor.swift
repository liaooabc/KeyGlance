import AppKit

/// Watches one modifier key and reports either a double tap or a press-and-hold.
/// Requires Accessibility / Input Monitoring trust for global events.
final class ModifierTriggerMonitor {
    /// The double-tap gesture completed.
    var onTrigger: (() -> Void)?
    /// Press-and-hold: true while the key is held down, false once released.
    var onHoldChange: ((Bool) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false
    private var lastRelease: TimeInterval = 0
    private var hasLastRelease = false
    private var pressStart: TimeInterval = 0
    /// 双击已经成功过一次：这一轮的最后一次松开不要再记成"等第二下"。
    private var didFire = false
    /// 按住模式：上一次回调时修饰键是不是按着的。
    private var lastHoldState = false

    func start() {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown,
                                                                   .leftMouseDown, .rightMouseDown,
                                                                   .otherMouseDown, .scrollWheel]) { [weak self] event in
            self?.handle(event, consume: false)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event, consume: true)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        isDown = false
        lastRelease = 0
        hasLastRelease = false
        didFire = false
    }

    /// Restarts without dropping the configuration.
    func restart() {
        start()
    }

    private func handle(_ event: NSEvent, consume: Bool) {
        switch event.type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            // 两次 ⌘ 之间只要按了键、点了鼠标或滚了轮，就不算双击
            // （不然 ⌘+滚轮缩放、⌘+拖拽这类操作会误触发面板）。
            if SettingsStore.shared.triggerGesture == .doubleTap {
                hasLastRelease = false
                didFire = false
                if event.type == .keyDown { isDown = false }
            }

        case .flagsChanged:
            guard let flag = SettingsStore.shared.trigger.flag else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let down = flags.contains(flag)
            let now = event.timestamp

            if SettingsStore.shared.triggerGesture == .hold {
                handleHold(down: down, flags: flags, flag: flag)
                return
            }

            if down {
                let extra = flags.subtracting([flag, .capsLock, .numericPad, .function, .help])
                if !extra.isEmpty {
                    isDown = false
                    hasLastRelease = false
                    return
                }
                if !isDown {
                    isDown = true
                    pressStart = now
                    let interval = SettingsStore.shared.doubleTapInterval
                    if hasLastRelease, now - lastRelease <= interval {
                        hasLastRelease = false
                        didFire = true
                        DispatchQueue.main.async { [weak self] in
                            self?.onTrigger?()
                        }
                    }
                }
            } else if isDown {
                isDown = false
                lastRelease = now
                if didFire {
                    // 这一轮已经双击成功了，松开只是收尾
                    didFire = false
                } else {
                    hasLastRelease = true
                }
            }

        default:
            break
        }
    }

    /// 按住手势：按下就把面板摊开，松开就收起来。
    ///
    /// **必须只按着这一个键**：⌘⇧ 这种组合不算——那是在用带修饰键的快捷键
    /// （比如 ⇧⌘4 截屏），不是想看这张表。判据是"除它之外没有别的修饰键"。
    /// 用了 `flags` 而不是"记一次按下"：加一个修饰键时（⌘→⌘⇧）也能立刻收起来。
    private func handleHold(down: Bool, flags: NSEvent.ModifierFlags, flag: NSEvent.ModifierFlags) {
        let extra = flags.subtracting([flag, .capsLock, .numericPad, .function, .help])
        let solo = down && extra.isEmpty
        guard solo != lastHoldState else { return }
        lastHoldState = solo
        onHoldChange?(solo)
    }
}
