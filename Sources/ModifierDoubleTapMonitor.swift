import AppKit

/// Detects a double tap of a single modifier key anywhere in the system.
/// Requires Accessibility / Input Monitoring trust for global events.
final class ModifierDoubleTapMonitor {
    var onTrigger: (() -> Void)?
    /// Called on any qualifying modifier release, so the UI can show a hint.
    var onStateChange: ((Bool) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false
    private var lastRelease: TimeInterval = 0
    private var hasLastRelease = false
    private var pressStart: TimeInterval = 0

    func start() {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown]) { [weak self] event in
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
    }

    /// Restarts without dropping the configuration.
    func restart() {
        start()
    }

    private func handle(_ event: NSEvent, consume: Bool) {
        switch event.type {
        case .keyDown, .leftMouseDown:
            // Any real key press in between cancels the gesture.
            hasLastRelease = false
            if event.type == .keyDown { isDown = false }

        case .flagsChanged:
            guard let flag = SettingsStore.shared.trigger.flag else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let down = flags.contains(flag)
            let now = event.timestamp

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
                        DispatchQueue.main.async { [weak self] in
                            self?.onTrigger?()
                        }
                    }
                }
            } else if isDown {
                isDown = false
                lastRelease = now
                hasLastRelease = true
            }

        default:
            break
        }
    }
}
