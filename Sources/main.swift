import AppKit

// App entry point. Accessory (menu bar) app: no dock icon, no main window.
let appDelegate = AppDelegate()
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = appDelegate
application.run()
