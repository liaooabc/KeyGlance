import AppKit
import SwiftUI

// MARK: - Material helper

struct MaterialView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

// MARK: - Settings

/// One scrolling page: no sidebar, every section stacked in place.
struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var trusted = Permissions.hasAccessibility
    @State private var refreshTimer: Timer?
    @State private var usageTick = 0

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 26) {
                generalSection
                permissionSection
                aboutSection
            }
            .padding(.horizontal, 26)
            .padding(.top, 30)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                let status = Permissions.hasAccessibility
                if status != trusted { trusted = status }
            }
        }
        .onDisappear { refreshTimer?.invalidate() }
    }

    // MARK: 通用

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("通用", "双击修饰键，随时查看前台 App 的全部快捷键。")

            Card {
                Row("触发方式") {
                    Picker("", selection: $settings.trigger) {
                        ForEach(TriggerKey.allCases) { key in
                            Text(key.title).tag(key)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 150)
                    .onChange(of: settings.trigger) { _, _ in
                        AppDelegate.shared?.restartMonitor()
                    }
                }
                Row("双击间隔") {
                    HStack(spacing: 10) {
                        Slider(value: $settings.doubleTapInterval, in: 0.2...0.6)
                            .frame(width: 130)
                        Text(String(format: "%.2f 秒", settings.doubleTapInterval))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                    }
                }
                Row("登录时自动启动", last: true) {
                    Toggle("", isOn: $settings.launchAtLogin).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
            }

            Card {
                Row("显示搜索框") {
                    Toggle("", isOn: $settings.showsSearchField).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                Row("显示菜单栏图标") {
                    Toggle("", isOn: $settings.showsMenuBarIcon).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        .onChange(of: settings.showsMenuBarIcon) { _, _ in
                            AppDelegate.shared?.updateStatusItemVisibility()
                        }
                }
                Row("面板动画", last: true) {
                    Toggle("", isOn: $settings.usesAnimation).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
            }

            Card {
                Row("显示「常用」分区") {
                    Toggle("", isOn: $settings.showsFrequent).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                Row("显示系统快捷键") {
                    Toggle("", isOn: $settings.showsSystemShortcuts).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                Row("记录快捷键使用") {
                    Toggle("", isOn: $settings.recordsUsage).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                Row("使用记录", last: true) {
                    HStack(spacing: 10) {
                        Text("\(UsageTracker.shared.totalCount) 次")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button("清除") {
                            UsageTracker.shared.clear()
                            usageTick += 1
                        }
                        .controlSize(.small)
                        .disabled(UsageTracker.shared.totalCount == 0)
                    }
                    .id(usageTick)
                }
            }
        }
    }

    // MARK: 权限

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("权限", "键览需要「辅助功能」权限来读取其它 App 的菜单栏。它不会记录你的输入。")

            Card {
                HStack(spacing: 12) {
                    Image(systemName: trusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(trusted ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trusted ? "辅助功能已授权" : "尚未授权辅助功能")
                            .font(.system(size: 13, weight: .semibold))
                        Text(trusted ? "可以读取前台 App 的菜单快捷键。" : "授权后双击修饰键才会显示快捷键面板。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !trusted {
                        Button("打开系统设置") { Permissions.openAccessibilitySettings() }
                            .controlSize(.small)
                    }
                    Button("重新检测") {
                        trusted = Permissions.hasAccessibility
                        if !trusted { NSSound.beep() }
                    }
                    .controlSize(.small)
                }
                .padding(14)
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("如果双击没有反应")
                        .font(.system(size: 12, weight: .semibold))
                    Text("在「系统设置 › 隐私与安全性 › 辅助功能」中勾选键览。授权后若状态未更新，请重新启动本 App。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("前往辅助功能") { Permissions.openAccessibilitySettings() }
                        Button("重新启动键览") { Permissions.relaunch() }
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
                .padding(14)
            }
        }
    }

    // MARK: 关于

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("键览 KeyGlance")
                        .font(.system(size: 16, weight: .semibold))
                    Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.2") · 双击修饰键，一览当前 App 的所有快捷键")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("实现方式")
                        .font(.system(size: 12, weight: .semibold))
                    Text("通过 macOS 辅助功能接口读取前台 App 的菜单栏，因此展示的快捷键与 App 内「菜单」完全一致；数据只在内存中处理，不联网、不写入磁盘。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
            }
        }
    }

    private func sectionHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Building blocks

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            // Every card fills the pane, whatever its content needs.
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
    }
}

struct Row<Content: View>: View {
    let label: String
    var last: Bool = false
    @ViewBuilder var content: Content

    init(_ label: String, last: Bool = false, @ViewBuilder content: () -> Content) {
        self.label = label
        self.last = last
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).font(.system(size: 12.5))
                Spacer(minLength: 20)
                content
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            if !last {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)
                    .padding(.leading, 14)
            }
        }
    }
}

final class SettingsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "键览设置"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView())
        window.minSize = NSSize(width: 620, height: 520)
        window.center()
        self.init(window: window)
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        forceOverlayScrollers()
    }

    /// SwiftUI's ScrollView follows the system preference, which with a mouse
    /// attached means a permanently visible scroll bar. Force the overlay kind so
    /// it only appears while scrolling.
    private func forceOverlayScrollers() {
        for delay in [0.05, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let content = self?.window?.contentView else { return }
                Self.applyOverlay(to: content)
            }
        }
    }

    private static func applyOverlay(to view: NSView) {
        if let scroll = view as? NSScrollView {
            scroll.scrollerStyle = .overlay
            scroll.autohidesScrollers = true
            scroll.verticalScrollElasticity = .allowed
        }
        view.subviews.forEach { applyOverlay(to: $0) }
    }
}
