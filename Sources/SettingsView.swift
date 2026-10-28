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
    @ObservedObject private var updater = Updater.shared
    @State private var trusted = Permissions.hasAccessibility
    @State private var refreshTimer: Timer?
    @State private var usageTick = 0

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 26) {
                generalSection
                permissionSection
                updateSection
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

    // MARK: 更新

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("更新", "版本信息取自 GitHub 上的发布页；下载、校验、替换都由键览自己完成，装好后自动重新打开。")

            Card {
                HStack(spacing: 12) {
                    Image(systemName: updateSymbol)
                        .font(.system(size: 22))
                        .foregroundStyle(updateTint)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("键览 \(updater.currentVersion)")
                                .font(.system(size: 13, weight: .semibold))
                            if case .upToDate = updater.phase {
                                UpdateBadge(text: "已是最新", color: .green)
                            }
                        }
                        Text(updateDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    updateControls
                }
                .padding(14)
            }

            Card {
                Row("自动检查更新") {
                    Toggle("", isOn: $settings.automaticallyChecksForUpdates)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                Row("自动下载并安装", last: true) {
                    Toggle("", isOn: $settings.automaticallyInstallsUpdates)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("开启「自动检查更新」后，启动时以及每 24 小时最多查一次；开着「自动下载并安装」时，查到新版本会在后台下好、替换并自动重启。")
                Text("更新会替换整个 App，如果 macOS 因此清掉了辅助功能授权，重新勾选一次就行。上次检查：\(lastCheckText)")
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lastCheckText: String {
        guard let date = updater.lastCheckDate else { return "还没有检查过" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    private var updateSymbol: String {
        switch updater.phase {
        case .idle, .checking: return "arrow.triangle.2.circlepath"
        case .upToDate: return "checkmark.seal.fill"
        case .available: return "arrow.down.circle.fill"
        case .downloading, .installing: return "arrow.down.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var updateTint: Color {
        switch updater.phase {
        case .idle, .checking: return .secondary
        case .upToDate: return .green
        case .available, .downloading, .installing: return .accentColor
        case .failed: return .orange
        }
    }

    private var updateDetail: String {
        switch updater.phase {
        case .idle:
            return "当前版本 \(updater.currentVersion)（\(updater.currentBuild)），可以手动检查有没有新版本。"
        case .checking:
            return "正在向 GitHub 查询最新版本…"
        case .upToDate(let version):
            return Version.isNewer(updater.currentVersion, than: version)
                ? "GitHub 上最新的发布是 \(version)，你跑的是 \(updater.currentVersion)，比发布版还新。"
                : "GitHub 上是 \(version)，你已经在用最新的版本。"
        case .available(let version, let url, _, _):
            return url == nil
                ? "有新版本 \(version) 可用（当前 \(updater.currentVersion)），这次只有发布页，需要手动下载。"
                : "有新版本 \(version) 可用（当前 \(updater.currentVersion)）。"
        case .downloading(let version, let progress):
            return "正在下载 \(version) … \(Int(progress * 100))%"
        case .installing(let version):
            return "正在安装 \(version)，键览会关闭并自动重新打开。"
        case .failed(let message):
            return message
        }
    }

    @ViewBuilder
    private var updateControls: some View {
        switch updater.phase {
        case .checking, .installing:
            ProgressView().controlSize(.small).frame(width: 84)
        case .downloading(_, let progress):
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(width: 96)
        case .available(let version, let url, _, _):
            HStack(spacing: 8) {
                Button("发布说明") { updater.presentReleaseNotes() }
                    .controlSize(.small)
                if url != nil {
                    Button("下载并安装 \(version)") { updater.install() }
                        .controlSize(.small)
                } else {
                    Button("打开下载页") { openReleases() }
                        .controlSize(.small)
                }
            }
        default:
            HStack(spacing: 8) {
                if case .failed = updater.phase {
                    Button("发布页") { openReleases() }
                        .controlSize(.small)
                }
                Button("检查更新") { updater.check() }
                    .controlSize(.small)
            }
        }
    }

    private func openReleases() {
        if let url = URL(string: Updater.releasesPage) { NSWorkspace.shared.open(url) }
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
                    Text("版本 \(updater.currentVersion) · 双击修饰键，一览当前 App 的所有快捷键")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("实现方式")
                        .font(.system(size: 12, weight: .semibold))
                    Text("通过 macOS 辅助功能接口读取前台 App 的菜单栏，因此展示的快捷键与 App 内「菜单」完全一致；不联网、不读取任何文字内容。「常用」只在本机保存修饰键组合的次数，可在「通用」里关闭并一键清除。")
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

/// 版本状态的小病标（「已是最新」）
struct UpdateBadge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(color.opacity(0.12))
            )
    }
}

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
