import AppKit
import SwiftUI

enum PanelMetrics {
    /// 顶部只留「软件名 + 搜索」，没有图标、条数、分隔线
    static let headerHeight: CGFloat = 54
    static let footerHeight: CGFloat = 0
    static let rowHeight: CGFloat = 26
    static let cornerRadius: CGFloat = 12
    static let columnGap: CGFloat = 10
    static let scrollerGutter: CGFloat = 14
    static let titleFont = NSFont.systemFont(ofSize: 12)
    static let capsFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    static let sectionFont = NSFont.systemFont(ofSize: 11.5, weight: .bold)
    /// 每个分区的色块圆角与块间距
    static let blockCorner: CGFloat = 8
    static let blockGap: CGFloat = 3
}

/// 面板里的一行：要么是菜单名（小节标题），要么是一条快捷键。
enum PanelRow {
    case header(String)
    case item(ShortcutItem)
}

/// 一行 + 它属于哪个分区（配色用）+ 是不是这一块的第一个 / 最后一个，
/// 用来把整组画成一个圆角色块。
struct PanelEntry {
    var row: PanelRow
    var section: Int
    var isFirst = false
    var isLast = false
}

/// 分区配色：一排系统色，按菜单顺序轮着用，一眼分出类目。
enum PanelPalette {
    /// 顺序有意交错冷暖，相邻两个菜单不会撞色。
    static let hues: [NSColor] = [
        .systemBlue, .systemOrange, .systemPurple, .systemGreen, .systemPink,
        .systemTeal, .systemIndigo, .systemYellow, .systemRed, .systemCyan
    ]

    static func hue(for section: Int) -> NSColor {
        hues[abs(section) % hues.count]
    }

    static func fill(for section: Int) -> NSColor {
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return hue(for: section).withAlphaComponent(dark ? 0.14 : 0.2)
    }

    static func title(for section: Int) -> NSColor {
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return hue(for: section).blended(withFraction: dark ? 0.3 : 0.5, of: .labelColor) ?? hue(for: section)
    }
}

/// 面板几何：等宽的列、行高，列数由内容决定。
/// 菜单名是行内的小节标题，条目在列里自上往下流，一列满了就开下一列
/// （学「键指如飞」的排法：标题不压缩、不分页，所有条目一屏铺开）。
struct PanelColumns {
    var columns: [[PanelEntry]]
    var columnWidth: CGFloat
    /// 所有行共用的快捷键栏宽度：键帽右对齐到这里，标题因此排成一条直线。
    var capsGutter: CGFloat = 46
    var rowHeight: CGFloat
    var panelWidth: CGFloat
    var panelHeight: CGFloat
    /// 条目多到所有列都排不下时才为 true：这时允许横向滚动，绝不裁掉内容。
    var scrollsHorizontally: Bool = false

    static let edge: CGFloat = 7
    static let minColumnWidth: CGFloat = 148
    static let maxColumnWidth: CGFloat = 300
    static let minPanelHeight: CGFloat = 240
    static let fallbackSize = NSSize(width: 1452, height: 860)

    static func maxSize(for screen: NSScreen?) -> NSSize {
        guard let visible = screen?.visibleFrame else { return fallbackSize }
        return NSSize(width: min(fallbackSize.width, visible.width - 60),
                      height: min(fallbackSize.height, visible.height - 80))
    }

    static func make(sections: [ShortcutSection], maxSize: NSSize) -> PanelColumns {
        let result = compute(sections: sections, maxSize: maxSize)
        if ProcessInfo.processInfo.environment["KEYGLANCE_DEBUG_LAYOUT"] == "1" {
            NSLog("KeyGlance layout: rows=\(flatRows(sections).count) colW=\(Int(result.columnWidth)) cols=\(result.columns.count) rowH=\(Int(result.rowHeight)) panel=\(Int(result.panelWidth))×\(Int(result.panelHeight)) hscroll=\(result.scrollsHorizontally)")
        }
        return result
    }

    private static func compute(sections: [ShortcutSection], maxSize: NSSize) -> PanelColumns {
        let rows = flatRows(sections)
        let gutter = capsGutter(for: sections)
        let width = columnWidth(for: sections, gutter: gutter)
        let chrome = PanelMetrics.headerHeight + PanelMetrics.footerHeight

        guard !rows.isEmpty else {
            return PanelColumns(columns: [], columnWidth: width, capsGutter: gutter,
                                rowHeight: PanelMetrics.rowHeight,
                                panelWidth: 420, panelHeight: maxSize.height)
        }

        // 先试最舒展的行高（越高越好读），从矮面板长到高面板；
        // 面板长到顶还排不进宽度，就把行高压紧一点再来一遍。
        for rowHeight in [PanelMetrics.rowHeight, CGFloat(24), CGFloat(22)] {
            var height = minPanelHeight
            while height <= maxSize.height + 0.5 {
                let usable = height - chrome - 18
                let rowsPerColumn = Int(usable / rowHeight)
                if rowsPerColumn >= 4 {
                    let columns = pack(rows, rowsPerColumn: rowsPerColumn)
                    let needed = contentWidth(columnCount: columns.count, columnWidth: width)
                    if needed <= maxSize.width {
                        return PanelColumns(columns: columns,
                                            columnWidth: width,
                                            capsGutter: gutter,
                                            rowHeight: rowHeight,
                                            panelWidth: max(420, needed),
                                            panelHeight: height)
                    }
                }
                height += 12
            }
        }

        // 满高、最紧的行高也排不下（条目特别多的 App）：横向滚动，绝不裁掉内容。
        let rowsPerColumn = max(4, Int((maxSize.height - chrome - 18) / 22))
        let columns = pack(rows, rowsPerColumn: rowsPerColumn)
        return PanelColumns(columns: columns,
                            columnWidth: width,
                            capsGutter: gutter,
                            rowHeight: 22,
                            panelWidth: maxSize.width,
                            panelHeight: maxSize.height,
                            scrollsHorizontally: true)
    }

    static func contentWidth(columnCount: Int, columnWidth: CGFloat) -> CGFloat {
        guard columnCount > 0 else { return 420 }
        return 2 * edge + CGFloat(columnCount) * columnWidth + CGFloat(columnCount - 1) * PanelMetrics.columnGap + PanelMetrics.scrollerGutter
    }

    /// 每个菜单一行小节标题，后面跟它的条目；带上分区号用于配色。
    static func flatRows(_ sections: [ShortcutSection]) -> [PanelEntry] {
        var rows: [PanelEntry] = []
        for (index, section) in sections.enumerated() {
            guard !section.items.isEmpty else { continue }
            rows.append(PanelEntry(row: .header(section.title), section: index))
            rows.append(contentsOf: section.items.map { PanelEntry(row: .item($0), section: index) })
        }
        return rows
    }

    /// 键帽栏的宽度：按最宽的一组快捷键量（学键指如飞：快捷键在左、标题在右，
    /// 所有标题因此对齐成一条直线）。
    static func capsGutter(for sections: [ShortcutSection]) -> CGFloat {
        var widest: CGFloat = 24
        for section in sections {
            for item in section.items {
                widest = max(widest, capsWidth(item.keys))
            }
        }
        return min(96, ceil(widest))
    }

    static func capsWidth(_ keys: [String]) -> CGFloat {
        guard !keys.isEmpty else { return 0 }
        var total: CGFloat = 0
        for key in keys {
            total += max(17, ceil((key as NSString).size(withAttributes: [.font: PanelMetrics.capsFont]).width) + 6)
            total += 2
        }
        return total - 2
    }

    /// 所有列等宽：键帽栏 + 最长标题，夹在 148–300 之间。
    static func columnWidth(for sections: [ShortcutSection], gutter: CGFloat) -> CGFloat {
        var widest: CGFloat = 0
        for section in sections {
            let header = (section.title as NSString).size(withAttributes: [.font: PanelMetrics.sectionFont]).width
            widest = max(widest, header + 30)
            for item in section.items {
                let title = (item.title as NSString).size(withAttributes: [.font: PanelMetrics.titleFont]).width
                // 和 ShortcutRowCellView 的绘制内距对齐：左 11 + 键帽栏 + 间隙 10 + 右 12 + 4 点余量
                widest = max(widest, gutter + 10 + title + 27)
            }
        }
        return min(maxColumnWidth, max(minColumnWidth, ceil(widest)))
    }

    /// 逐行填列：一列满了开下一列。菜单名不会单独留在列尾；
    /// 一个菜单长到跨列时，续列顶上再写一次菜单名，读起来不迷路。
    static func pack(_ rows: [PanelEntry], rowsPerColumn: Int) -> [[PanelEntry]] {
        var columns: [[PanelEntry]] = []
        var current: [PanelEntry] = []

        func flush() {
            if !current.isEmpty {
                columns.append(markBlocks(current))
                current = []
            }
        }

        for entry in rows {
            if case .header = entry.row {
                // 别把一块挤到列底只剩一两行：剩下不到 3 行就整块挪到下一列，
                // 免得出现「列底孤零零一行」这种别扭的排版。
                if rowsPerColumn - current.count < 3 { flush() }
                current.append(entry)
                continue
            }
            if current.count >= rowsPerColumn {
                flush()
            }
            current.append(entry)
        }
        flush()
        return columns
    }

    /// 标出每一块的第一个 / 最后一行：同一列里相邻的「同分区」行算一块。
    private static func markBlocks(_ column: [PanelEntry]) -> [PanelEntry] {
        var result = column
        guard !result.isEmpty else { return result }
        for index in result.indices {
            let previous = index > 0 ? result[index - 1].section : nil
            let next = index + 1 < result.count ? result[index + 1].section : nil
            result[index].isFirst = previous != result[index].section
            result[index].isLast = next != result[index].section
        }
        return result
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

    var layout: PanelColumns {
        PanelColumns.make(sections: filteredSections,
                          maxSize: NSSize(width: maxPanelWidth, height: panelHeight))
    }

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

    private var layout: PanelColumns { model.layout }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(width: model.panelWidth)

        .onAppear {
            if settings.showsSearchField {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(model.appName.isEmpty ? "当前 App" : model.appName)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
            Spacer(minLength: 12)
            if settings.showsSearchField {
                searchField
            }
        }
        .padding(.horizontal, 14)
        .frame(height: PanelMetrics.headerHeight)
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

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.filteredSections.isEmpty {
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
            ShortcutTableView(columns: layout.columns,
                              columnWidth: layout.columnWidth,
                              capsGutter: layout.capsGutter,
                              rowHeight: layout.rowHeight,
                              resetToken: model.presentToken,
                              allowsHorizontalScroll: layout.scrollsHorizontally)
                .padding(.horizontal, PanelColumns.edge)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
