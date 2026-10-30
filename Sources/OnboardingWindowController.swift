import AppKit
import SwiftUI

struct OnboardingView: View {
    @State private var trusted = Permissions.hasAccessibility
    @State private var isRelaunching = false
    /// 轮询权限的定时器。以前是局部变量，窗口关掉也一直在跑，每开一次引导就漏一个。
    @State private var pollTimer: Timer?
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 22)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)

            Text("欢迎使用键览")
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 16)

            Text("双击 ⌘，立刻看到当前 App 的所有快捷键。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 10) {
                bullet("hand.raised.fill", "需要「辅助功能」权限", "macOS 只允许获得授权的 App 读取其它 App 的菜单栏，快捷键正是从这里读取的。")
                bullet("lock.shield.fill", "权限只用于读取", "不记录键盘内容，不联网，不上传任何数据。")
            }
            .padding(.top, 22)
            .padding(.horizontal, 34)

            Spacer(minLength: 18)

            HStack(spacing: 10) {
                Button("稍后设置") { onClose() }
                    .controlSize(.large)
                Button(trusted ? "权限已生效，开始使用" : "打开系统设置授权") {
                    if Permissions.hasAccessibility {
                        trusted = true
                        onClose()
                    } else {
                        Permissions.promptAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 22)

            Text(trusted
                 ? (isRelaunching ? "已授权，正在重新启动键览…" : "已授权，可以开始使用。")
                 : "在系统设置里勾选键览后，App 会自动重新启动并关闭此窗口。\n如果列表里已经有键览却不生效：点 − 删掉，再把「应用程序」里的键览拖进去加一次。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.bottom, 14)
        }
        .frame(width: 520, height: 472)
        .background(MaterialView(material: .hudWindow).ignoresSafeArea())
        .onAppear {
            if !trusted { Permissions.promptAccessibility() }
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                let status = Permissions.hasAccessibility
                guard status != trusted else { return }
                trusted = status
                // Apple's own apps restart once the permission is granted: the new
                // Accessibility client only takes effect in a fresh process, and it
                // dismisses this window the same way.
                if status { isRelaunching = true }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func bullet(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

final class OnboardingWindowController: NSWindowController {
    private var onClose: (() -> Void)?

    convenience init(onClose: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 472),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.title = "欢迎使用键览"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = NSHostingView(rootView: OnboardingView(onClose: onClose))
        window.center()
        self.init(window: window)
        self.onClose = onClose
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
