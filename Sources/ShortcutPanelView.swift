import AppKit
import SwiftUI

enum PanelMetrics {
    static let headerHeight: CGFloat = 58
    static let footerHeight: CGFloat = 30
    static let rowHeight: CGFloat = 28
    static let sectionHeaderHeight: CGFloat = 28
    static let scrollerGutter: CGFloat = 14
    static let maxListHeight: CGFloat = 512
    static let cornerRadius: CGFloat = 22
    static let horizontalPadding: CGFloat = 14
    static let columnGap: CGFloat = 12
    static let minimumColumnWidth: CGFloat = 138
    static let wrappedColumnWidth: CGFloat = 180
    static let idealColumnWidth: CGFloat = 205
}

/// Fixed panel geometry with per-menu column widths measured from the content.
struct PanelLayout {
    var panelWidth: CGFloat
    var panelHeight: CGFloat
    var columnWidths: [CGFloat]
    var contentHeight: CGFloat

    static let edge: CGFloat = 7
    static let minimumColumnWidth: CGFloat = 130
    static let maximumColumnWidth: CGFloat = 330
    static let fallbackSize = NSSize(width: 1452, height: 600)

    /// Largest panel we may use on this screen.
    static func maxSize(for screen: NSScreen?) -> NSSize {
        guard let visible = screen?.visibleFrame else { return fallbackSize }
        return NSSize(width: min(fallbackSize.width, visible.width - 60),
                      height: min(fallbackSize.height, visible.height - 120))
    }

    /// Width follows the measured columns (so no empty band on the right);
    /// height stays fixed so the panel never jumps between apps.
    static func make(sections: [ShortcutSection], maxSize: NSSize) -> PanelLayout {
        var widths = sections.map { measuredWidth(for: $0) }
        if !widths.isEmpty {
            let available = maxSize.width - 2 * edge - PanelMetrics.scrollerGutter
            let total = widths.reduce(0, +)
            if total > available, total > 0 {
                let scale = available / total
                widths = widths.map { max(minimumColumnWidth, ($0 * scale).rounded(.down)) }
            }
            widths[widths.count - 1] += PanelMetrics.scrollerGutter
        }

        let contentWidth = widths.reduce(0, +) + 2 * edge
        let panelWidth = sections.isEmpty ? 560 : max(560, min(maxSize.width, contentWidth))

        let maxItems = sections.map { $0.items.count }.max() ?? 0
        let contentHeight = PanelMetrics.sectionHeaderHeight + CGFloat(maxItems) * PanelMetrics.rowHeight
        return PanelLayout(panelWidth: panelWidth,
                           panelHeight: maxSize.height,
                           columnWidths: widths,
                           contentHeight: contentHeight)
    }

    /// Width the column needs for its longest "title + key caps" row.
    static func measuredWidth(for section: ShortcutSection) -> CGFloat {
        let titleFont = NSFont.systemFont(ofSize: 12.5)
        let capsFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        var widest: CGFloat = 68
        for item in section.items {
            let title = (item.title as NSString).size(withAttributes: [.font: titleFont]).width
            var caps: CGFloat = 0
            for cap in item.keys {
                caps += max(17, ceil((cap as NSString).size(withAttributes: [.font: capsFont]).width) + 6) + 2
            }
            widest = max(widest, title + 8 + caps + 22)
        }
        return min(maximumColumnWidth, max(minimumColumnWidth, ceil(widest)))
    }

    var listHeight: CGFloat {
        panelHeight - PanelMetrics.headerHeight - PanelMetrics.footerHeight - 2
    }
}

final class ShortcutPanelModel: ObservableObject {
    @Published var appName: String = ""
    @Published var icon: NSImage?
    @Published var bundleID: String = ""
    @Published var sections: [ShortcutSection] = []
    @Published var frequentSection: ShortcutSection?
    @Published var systemSection: ShortcutSection?
    @Published var query: String = ""
    @Published var isLoading: Bool = false
    @Published var presentToken: Int = 0
    @Published var contentVisible: Bool = true
    @Published var panelWidth: CGFloat = 1320
    @Published var panelHeight: CGFloat = 600
    @Published var maxPanelWidth: CGFloat = 1452

    /// 常用 → this app's menus → 系统
    var allSections: [ShortcutSection] {
        var result: [ShortcutSection] = []
        if let frequentSection { result.append(frequentSection) }
        result.append(contentsOf: sections)
        if let systemSection { result.append(systemSection) }
        return result
    }

    var totalCount: Int { allSections.reduce(0) { $0 + $1.items.count } }

    var filteredSections: [ShortcutSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allSections }
        return allSections.compactMap { section in
            let items = section.items.filter { $0.searchable.localizedCaseInsensitiveContains(trimmed) }
            return items.isEmpty ? nil : ShortcutSection(title: section.title, items: items)
        }
    }

    var resultCount: Int { filteredSections.reduce(0) { $0 + $1.items.count } }

    func reset() {
        sections = []
        frequentSection = nil
        systemSection = nil
        query = ""
    }
}

struct ShortcutPanelView: View {
    @ObservedObject var model: ShortcutPanelModel
    @ObservedObject private var settings = SettingsStore.shared
    @FocusState private var searchFocused: Bool

    private var layout: PanelLayout {
        PanelLayout.make(sections: model.filteredSections,
                         maxSize: NSSize(width: model.maxPanelWidth, height: model.panelHeight))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            separator
            content
            separator
            footer
        }
        .frame(width: model.panelWidth)
        .opacity(model.contentVisible ? 1 : 0)
        .scaleEffect(model.contentVisible ? 1 : 0.985)
        .onAppear {
            if settings.showsSearchField {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            appIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(model.appName.isEmpty ? "当前 App" : model.appName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if settings.showsSearchField {
                searchField
            }
        }
        .padding(.horizontal, 16)
        .frame(height: PanelMetrics.headerHeight)
    }

    private var subtitle: String {
        if model.isLoading { return " " }
        if model.sections.isEmpty { return "没有可用的菜单快捷键" }
        if model.query.isEmpty { return "\(model.totalCount) 个快捷键" }
        return "\(model.resultCount) / \(model.totalCount) 个快捷键"
    }

    private var appIcon: some View {
        Group {
            if let icon = model.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: 28, height: 28)
                    .overlay(Image(systemName: "app.dashed").font(.system(size: 13)).foregroundStyle(.secondary))
            }
        }
        .shadow(color: .black.opacity(0.16), radius: 1.5, y: 0.5)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("搜索快捷键", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .frame(width: 200, height: 25)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(height: 1)
    }

    @ViewBuilder
    private var content: some View {
        let sections = model.filteredSections
        if model.isLoading {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sections.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: model.allSections.isEmpty ? "keyboard.badge.ellipsis" : "magnifyingglass")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(model.allSections.isEmpty ? "这个 App 没有可显示的快捷键" : "没有匹配的快捷键")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ShortcutTableView(sections: sections,
                              columnWidths: layout.columnWidths,
                              resetToken: model.presentToken)
                .padding(.horizontal, 7)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Text(triggerHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 5) {
                Text("输入以筛选").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary).font(.system(size: 11))
                KeyCapView(text: "esc")
                Text("关闭").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: PanelMetrics.footerHeight)
    }

    private var triggerHint: String {
        let trigger = settings.trigger
        guard trigger != .off else { return "菜单栏图标可再次打开此面板" }
        return "双击 \(trigger.symbol) 再次切换"
    }
}

struct KeyCapView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.primary.opacity(0.85))
            .frame(minWidth: 16, minHeight: 16)
            .padding(.horizontal, text.count > 1 ? 2.5 : 0)
            .background(
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(Color.primary.opacity(0.09))
            )

    }
}
