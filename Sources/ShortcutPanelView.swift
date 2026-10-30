import AppKit
import SwiftUI

enum PanelMetrics {
    /// 顶部只留「软件名 + 搜索」，没有图标、条数、分隔线
    static let headerHeight: CGFloat = 45
    static let footerHeight: CGFloat = 0
    static let rowHeight: CGFloat = 26
    static let cornerRadius: CGFloat = 12
    static let columnGap: CGFloat = 10
    static let scrollerGutter: CGFloat = 0
    static let titleFont = NSFont.systemFont(ofSize: 12)
    static let capsFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    static let sectionFont = NSFont.systemFont(ofSize: 11.5, weight: .bold)
    /// 每个分区的色块圆角与块间距
    static let blockCorner: CGFloat = 8
    static let blockGap: CGFloat = 2
    /// 顶栏两个控件（软件名框、搜索框）统一用它的高度。
    /// 以前软件名框靠文字自身撑高（26.5pt）、搜索框写死 25pt，两者差 2pt，
    /// 顶边和底边各错 1pt，肉眼一眼就能看出不在一条线上。
    static let controlHeight: CGFloat = 26
    /// 顶栏控件的圆角
    static let controlCorner: CGFloat = 9
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
    /// 类目名（菜单名）。配色按名字走，不按序号——同一个菜单在任何 App 里
    /// 都是同一个颜色，扫一眼就知道是"文件"还是"编辑"。
    var name: String = ""
    /// 这个类目解析出来的色相下标（名字 → 颜色的结果，同屏内已避开撞色）。
    var hue: Int = 0
    var isFirst = false
    var isLast = false
}

/// 分区配色：一排系统色，**按类目名字**分配，一眼分出类目。
enum PanelPalette {
    /// 顺序有意交错冷暖，相邻两个菜单不会撞色。
    static let hues: [NSColor] = [
        .systemBlue, .systemOrange, .systemPurple, .systemTeal, .systemGreen, .systemPink,
        .systemIndigo, .systemBrown, .systemCyan, .systemYellow, .systemRed, .systemMint
    ]

    /// 常见菜单名 → 固定色相下标。
    /// 中英文都收录：同一个意思的菜单（中文 App 的"文件"和英文 App 的 "File"）
    /// 拿到同一个颜色，跨 App 也认得出来。
    static let namedHues: [String: Int] = [
        "常用": 0, "文件": 1, "编辑": 2, "显示": 3, "窗口": 4, "帮助": 5,
        "视图": 6, "工具": 7, "格式": 8, "插入": 9, "图像": 10, "系统": 11,
        "打印": 8, "字体": 7, "开发者": 6, "分享": 5, "服务": 2, "组件": 0,
        "主题": 3, "对象": 7, "选择": 9, "前往": 1, "历史记录": 5, "播放": 10,
        "录制": 4, "声音": 2, "账户": 1, "订阅": 6, "动作": 8, "邮件": 3,
        "消息": 0, "对话框": 11, "控件": 4, "标签": 10, "界面": 5, "权限": 9,
        "File": 1, "Edit": 2, "View": 6, "Window": 4, "Help": 5, "Format": 8,
        "Tools": 7, "Insert": 9, "Image": 10, "Print": 8, "Font": 7,
        "Developer": 6, "Share": 5, "Services": 2, "Theme": 3, "Object": 7,
        "Select": 9, "Go": 1, "History": 5, "Play": 10, "Record": 4,
        "Sound": 2, "Account": 1, "Subscribe": 6, "Action": 8, "Mail": 3,
        "Message": 0, "Dialog": 11, "Control": 4, "Tag": 10
    ]

    /// 名字 → 色相下标。常见名字走固定表；没收录的按名字的稳定哈希取一个。
    /// 用的是自己的 FNV-1a，不是 Swift 的 hashValue——后者每次进程启动都不同，
    /// 同一个菜单在两次启动里会拿到不同颜色。
    static func baseHue(for name: String) -> Int {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fixed = namedHues[key] { return fixed }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash % UInt64(hues.count))
    }

    /// 把一批类目名解析成色相下标。
    /// 常见菜单名永远是同一个颜色（跨 App 也一样）；没收录的名字如果跟别人撞了色，
    /// 就往后挪一个空位——挪多少取决于同屏有哪些类目，但顺序固定，所以同一个 App
    /// 每次打开结果都一样。
    static func resolveHues(for names: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        var taken = Set<Int>()
        // 先把固定表的类目定下来，它们的颜色不能被别人挤掉。
        for name in names where namedHues[name] != nil {
            let hue = namedHues[name]!
            if result[name] == nil {
                result[name] = hue
                taken.insert(hue)
            }
        }
        for name in names where namedHues[name] == nil {
            if result[name] != nil { continue }
            var hue = baseHue(for: name)
            var steps = 0
            while taken.contains(hue), steps < hues.count {
                hue = (hue + 1) % hues.count
                steps += 1
            }
            result[name] = hue
            taken.insert(hue)
        }
        return result
    }

    static func hue(forHue index: Int) -> NSColor {
        hues[abs(index) % hues.count]
    }

    /// 色块玻璃的着色：交给 NSGlassEffectView 的 tintColor，系统拿它去调玻璃的色。
    /// 要淡——玻璃的材质本身就有不透明度，着色一浓就变成实色方块，背后的壁纸透不过来，
    /// 玻璃感反而没了。
    /// 做成动态颜色，明暗切换时系统自己重新解，不用手动刷新。
    static func tint(forHue index: Int) -> NSColor {
        let hue = hue(forHue: index)
        let override = ProcessInfo.processInfo.environment["KEYGLANCE_BLOCK_TINT"]
            .flatMap { Double($0) }
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return hue.withAlphaComponent(override ?? (dark ? 0.08 : 0.06))
        }
    }

    static func title(forHue index: Int) -> NSColor {
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let hue = hue(forHue: index)
        return hue.blended(withFraction: dark ? 0.3 : 0.5, of: .labelColor) ?? hue
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

    /// 面板左右留白（色块自己再内缩半个列间距，视觉上是 sidePadding + columnGap/2）
    static let sidePadding: CGFloat = 5
    /// 面板上下留白（最外侧的行贴边）
    static let verticalPadding: CGFloat = 10
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
            // 没有可显示的内容（搜不到 / 这个 App 没有快捷键）：给一个矮面板，
            // 别用整屏高度——否则清空搜索时窗口会猛地长高再收回。
            return PanelColumns(columns: [], columnWidth: width, capsGutter: gutter,
                                rowHeight: PanelMetrics.rowHeight,
                                panelWidth: 420, panelHeight: minPanelHeight)
        }

        // 先试最舒展的行高（越高越好读），从矮面板长到高面板；
        // 面板长到顶还排不进宽度，就把行高压紧一点再来一遍。
        for rowHeight in [PanelMetrics.rowHeight, CGFloat(24), CGFloat(22)] {
            var height = minPanelHeight
            while height <= maxSize.height + 0.5 {
                let usable = height - chrome - 22
                let rowsPerColumn = Int(usable / rowHeight)
                if rowsPerColumn >= 4 {
                    let columns = pack(rows, rowsPerColumn: rowsPerColumn)
                    let needed = contentWidth(columnCount: columns.count, columnWidth: width)
                    if needed <= maxSize.width {
                        // 面板高度按「最高的那一列」实算，不用试探用的 height，
                        // 否则底部会多出一条十几点的空玻璃。
                        let tallest = CGFloat(columns.map { $0.count }.max() ?? 0) * rowHeight
                        if ProcessInfo.processInfo.environment["KEYGLANCE_DEBUG_LAYOUT"] == "1" {
                            NSLog("  fit h=\(Int(height)) rowH=\(Int(rowHeight)) rowsPerCol=\(rowsPerColumn) counts=\(columns.map { $0.count }) chrome=\(Int(chrome)) tallest=\(Int(tallest))")
                        }
                        return PanelColumns(columns: columns,
                                            columnWidth: width,
                                            capsGutter: gutter,
                                            rowHeight: rowHeight,
                                            panelWidth: max(420, needed),
                                            panelHeight: chrome + PanelColumns.verticalPadding + tallest)
                    }
                }
                height += 12
            }
        }

        // 满高、最紧的行高也排不下（条目特别多的 App）：横向滚动，绝不裁掉内容。
        let rowsPerColumn = max(4, Int((maxSize.height - chrome - 22) / 22))
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
        return 2 * sidePadding + CGFloat(columnCount) * (columnWidth + PanelMetrics.columnGap) + PanelMetrics.scrollerGutter
    }

    /// 每个菜单一行小节标题，后面跟它的条目；带上类目名用于配色。
    /// 颜色按**名字**解析：同一个菜单名在任何 App 里都是同一个颜色。
    static func flatRows(_ sections: [ShortcutSection]) -> [PanelEntry] {
        let names = sections.filter { !$0.items.isEmpty }.map(\.title)
        let hues = PanelPalette.resolveHues(for: names)
        var rows: [PanelEntry] = []
        for (index, section) in sections.enumerated() {
            guard !section.items.isEmpty else { continue }
            let hue = hues[section.title] ?? PanelPalette.baseHue(for: section.title)
            rows.append(PanelEntry(row: .header(section.title), section: index,
                                    name: section.title, hue: hue))
            rows.append(contentsOf: section.items.map {
                PanelEntry(row: .item($0), section: index, name: section.title, hue: hue)
            })
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

    /// 逐行填列：一列满了开下一列。菜单名不会单独留在列尾。
    ///
    /// 一个菜单长到跨列时，**续列不重复写菜单名**——颜色是按类目名字定的，
    /// 同一类目在两列里是同一个颜色，靠颜色就能认出是同一类目，
    /// 再写一遍名字反而啰嗦。
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
                // 标题后面至少要跟得上一行条目，否则这列就到底了，换列。
                // 只留标题在列尾的话，那一行颜色孤零零的，看不出是什么类目。
                if rowsPerColumn - current.count < 2 { flush() }
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
    /// 按住模式：面板是"摊开给人看"的，摊开时不抢焦点，
    /// 所以顶栏的搜索框这时用不了，也不该假装能用。
    @Published var isHeld = false

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

    /// 清单报上来的实际高度（行数 × 行高），窗口用它把底边对齐。
    var onContentHeight: ((CGFloat) -> Void)?
    /// 最近一次报上来的内容高度（仅调试日志用）。
    var contentReportedHeight: CGFloat = 0

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
            // 按住模式：面板故意不抢焦点，键盘还在前台 App 那边，
            // 这时聚焦搜索框没有意义（也聚不上）。
            if settings.showsSearchField && !model.isHeld {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
            }
        }
    }

    private var header: some View {
        // GlassEffectContainer：让系统把这一排玻璃统一处理（相邻的会合并成一次渲染）。
        // 玻璃本身交给系统画——形状、圆角、明暗、交互反馈都是 Apple 的事。
        GlassEffectContainer {
            HStack(spacing: 12) {
                appNameBox
                Spacer(minLength: 12)
                if settings.showsSearchField {
                    searchField
                }
            }
            // 两头对齐色块的左右边缘（留白 + 色块在列内的半个间距）
            .padding(.horizontal, PanelColumns.sidePadding + PanelMetrics.columnGap / 2)
            // 软件名框 / 搜索框离面板上边缘的距离，和色块离下边缘的距离一致（都是 10）
            .padding(.top, PanelColumns.verticalPadding)
            .frame(height: PanelMetrics.headerHeight, alignment: .top)
            // 中间那行说明：条数 · 双击切换 · esc 关闭。
            // 也装进玻璃药丸，高度跟左右两个控件一致（不然一行三种高度，肉眼能看出来）。
            .overlay {
                if model.panelWidth >= 880, !model.isLoading {
                    hintBox
                }
            }
        }
    }

    /// 顶栏中间那句提示：条数 + 怎么收起 + 怎么关闭。静态文字，用普通玻璃。
    private var hintBox: some View {
        Text(headerHint)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: PanelMetrics.controlHeight)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: PanelMetrics.controlCorner, style: .continuous))
    }

    /// 软件名：装在一块玻璃药丸里。静态标签用普通玻璃（不用交互玻璃）。
    private var appNameBox: some View {
        Text(model.appName.isEmpty ? "当前 App" : model.appName)
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: PanelMetrics.controlHeight)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: PanelMetrics.controlCorner, style: .continuous))
    }

    /// 顶栏中间那句：条数 + 怎么收起 + 怎么关闭。
    private var headerHint: String {
        var parts: [String] = []
        if model.query.isEmpty {
            parts.append("\(model.totalCount) 个快捷键")
        } else {
            parts.append("\(model.resultCount) / \(model.totalCount) 个快捷键")
        }
        if model.isHeld {
            // 按住模式：面板跟着修饰键走，松开就没了。
            parts.append("松开 \(settings.trigger.symbol) 隐藏")
        } else if model.query.isEmpty, settings.trigger != .off {
            parts.append("双击 \(settings.trigger.symbol) 再次切换")
        } else if model.query.isEmpty {
            parts.append("菜单栏图标可再次打开")
        }
        if !model.isHeld { parts.append("esc 关闭") }
        return parts.joined(separator: "  ·  ")
    }

    /// 搜索框：也是一块玻璃药丸。它是能点的控件，所以用**交互玻璃**——
    /// 悬停/聚焦时的反馈由系统自己给（macOS 27 的交互式玻璃）。
    ///
    /// 按住模式下键盘还留在前台 App 那边（面板故意不抢焦点），
    /// 这时搜索框点不动——所以把它**画成不可用的样子**，而不是
    /// 摆一个点下去没反应的框。按住模式下想搜索只能先松开修饰键。
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
        .frame(width: 200, height: PanelMetrics.controlHeight)
        .glassEffect(model.isHeld ? Glass.regular : .regular.interactive(),
                     in: RoundedRectangle(cornerRadius: PanelMetrics.controlCorner, style: .continuous))
        // 按住模式：明确告诉用户"现在这个框点不动"，而不是让它看着能用却没反应。
        // 不用大幅调暗——那看着像控件丢了，只是稍微收一点亮度。
        .opacity(model.isHeld ? 0.72 : 1)
        .allowsHitTesting(!model.isHeld)
        .help(model.isHeld ? "按住模式下搜索框不可用，松开修饰键后可搜索" : "")
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
                              allowsHorizontalScroll: layout.scrollsHorizontally,
                              onContentHeight: { height in model.onContentHeight?(height) })
                .padding(.horizontal, PanelColumns.sidePadding)
                .padding(.bottom, PanelColumns.verticalPadding)
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
