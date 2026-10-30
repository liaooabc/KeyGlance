import AppKit
import SwiftUI

/// 分区色块的玻璃层：每个菜单一块**真的**液态玻璃（NSGlassEffectView）。
/// 颜色交给 tintColor，圆角、边缘高光、明暗、背后的折射都让系统自己画
/// （macOS 26 起有 NSGlassEffectView，27 又加了交互式玻璃）。
///
/// 按"整块"建，不是一行一块：一行一块的话块与块之间会露出接缝，
/// 而且一个菜单十几行就是十几个玻璃视图，背景采样太贵。
///
/// **这一层挂在表格里**（不是裁剪视图里）：色块的坐标就是表格坐标，
/// 一套坐标从头用到尾。表格是 flipped 的（y 向下），这一层也必须 flipped，
/// 否则层内部的 y 是向上的，块会整个上下颠倒、跟文字对不上。
final class BlockGlassLayer: NSView {
    struct Block {
        /// 表格坐标里的矩形
        var rect: NSRect
        var tint: NSColor
        /// 这个块属于哪个分区（调试日志用）
        var section: Int = -1
        /// 这个块的类目名（调试日志用）
        var name: String = ""
        /// 这一块在第几列（调试日志用）
        var column: Int = -1
        /// 块里的行号范围（调试日志用）
        var rows: ClosedRange<Int> = 0...0
    }

    private var blocks: [Block] = []
    private var glassViews: [NSGlassEffectView] = []
    private weak var table: NSTableView?

    /// 跟表格保持一致：表格是 flipped 的，这一层也得是，
    /// 否则层内的 y 方向跟表格相反，块会跟文字错位。
    override var isFlipped: Bool { true }

    func attach(to table: NSTableView) {
        self.table = table
        // 压在单元格下面：色块是背景，文字仍然由单元格画在上面。
        table.addSubview(self, positioned: .below, relativeTo: nil)
    }

    /// 色块只是背景，不该挡住鼠标。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(blocks: [Block]) {
        self.blocks = blocks
        while glassViews.count < blocks.count {
            let glass = NSGlassEffectView()
            glass.style = (ProcessInfo.processInfo.environment["KEYGLANCE_BLOCK_STYLE"] == "clear")
                ? .clear : .regular
            glass.cornerRadius = PanelMetrics.blockCorner
            addSubview(glass)
            glassViews.append(glass)
        }
        while glassViews.count > blocks.count {
            glassViews.removeLast().removeFromSuperview()
        }
        for (i, block) in blocks.enumerated() {
            glassViews[i].tintColor = block.tint
        }
        refresh()
    }

    /// 表格变了尺寸、或者滚动时，玻璃都要跟着重新摆。
    func refresh() {
        guard let table else { return }
        if frame != table.bounds { frame = table.bounds }
        for (i, block) in blocks.enumerated() where i < glassViews.count {
            glassViews[i].frame = block.rect
        }
        if ProcessInfo.processInfo.environment["KEYGLANCE_DEBUG"] == "1", !blocks.isEmpty {
            var log = "KeyGlance glass blocks: "
            for (i, b) in blocks.enumerated() where i < glassViews.count {
                let f = glassViews[i].frame
                log += String(format: "[%@ frame=(%.0f,%.0f %.0fx%.0f)] ",
                              b.name, f.minX, f.minY, f.width, f.height)
            }
            NSLog("%@", log)
        }
    }

    override func layout() {
        super.layout()
        refresh()
    }
}

/// The shortcut grid, drawn by AppKit: one NSTableColumn per column of rows, one
/// row per slot. AppKit only creates the cells that are on screen, so an app with
/// hundreds of shortcuts still scrolls smoothly.
struct ShortcutTableView: NSViewRepresentable {
    let columns: [[PanelEntry]]
    let columnWidth: CGFloat
    let capsGutter: CGFloat
    let rowHeight: CGFloat
    /// Bumped on every opening so the list starts at the top again.
    let resetToken: Int
    /// Only when even the tallest panel cannot hold every column: then the grid is
    /// wider than the viewport and may be scrolled sideways instead of clipped.
    let allowsHorizontalScroll: Bool
    /// 清单实高（行数 × 行高），窗口据此把底边收齐。
    var onContentHeight: ((CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let table = HoverTableView()
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.autoresizingMask = [.width]
        table.rowHeight = rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.selectionHighlightStyle = .none
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.allowsColumnSelection = false
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.style = .plain
        table.focusRingType = .none
        table.onHover = { [weak coordinator = context.coordinator] row, column in
            coordinator?.updateHover(row: row, column: column)
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = allowsHorizontalScroll
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        // Must be off, otherwise AppKit recalculates (and clears) the insets we
        // use to keep content inside the rounded panel.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.verticalScrollElasticity = .allowed
        scroll.horizontalScrollElasticity = allowsHorizontalScroll ? .automatic : .none

        // 色块的玻璃层：挂在表格里、压在单元格下面，跟文字同一套坐标。
        let glass = BlockGlassLayer()
        glass.attach(to: table)

        context.coordinator.table = table
        context.coordinator.allowsHorizontalScroll = allowsHorizontalScroll
        context.coordinator.reportHeight = onContentHeight
        context.coordinator.glassLayer = glass
        // 横向滚动时整个表格（连同玻璃层）在裁剪视图里平移，玻璃自然跟着走；
        // 这里再刷新一次是为了表格尺寸变了之后重摆。
        context.coordinator.scrollToken = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            coordinator?.glassLayer?.refresh()
        }
        return scroll
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.allowsHorizontalScroll = allowsHorizontalScroll
        context.coordinator.reportHeight = onContentHeight
        context.coordinator.apply(columns: columns,
                                  columnWidth: columnWidth,
                                  capsGutter: capsGutter,
                                  rowHeight: rowHeight,
                                  resetToken: resetToken)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var allowsHorizontalScroll = false
        var capsGutter: CGFloat = 46
        var reportHeight: ((CGFloat) -> Void)?
        weak var table: HoverTableView?
        weak var glassLayer: BlockGlassLayer?
        var scrollToken: NSObjectProtocol?
        private var columns: [[PanelEntry]] = []
        private var lastResetToken = -1
        private var hovered: (row: Int, column: Int) = (-1, -1)

        deinit {
            if let scrollToken { NotificationCenter.default.removeObserver(scrollToken) }
        }

        /// 列数之外还要看内容：两个 App 的列数一样时，不能沿用它上一份数据。
        private func signature(_ columns: [[PanelEntry]]) -> String {
            columns.map { column in
                String(column.count) + ":" + column.map { entry in
                    switch entry.row {
                    case .header(let title): return "[" + title + "]"
                    case .item(let item): return item.title + item.keyString
                    }
                }.joined(separator: ",")
            }.joined(separator: "|")
        }

        func apply(columns: [[PanelEntry]], columnWidth: CGFloat, capsGutter: CGFloat, rowHeight: CGFloat, resetToken: Int) {
            guard let table else { return }
            let shouldResetScroll = resetToken != lastResetToken
            lastResetToken = resetToken

            self.capsGutter = capsGutter
            let columnsChanged = signature(columns) != signature(self.columns)
                || table.tableColumns.count != columns.count
            self.columns = columns

            if shouldResetScroll { self.resetScroll(table) }

            if table.rowHeight != rowHeight {
                table.rowHeight = rowHeight
            }

            if columnsChanged {
                self.resetScroll(table)
                // 列数和列宽没变时别拆了重建：拆列会让 NSTableView 把所有行视图重造一遍，
                // 90 行要多花 30ms 以上，换内容时正好被看出来。
                let width = columnWidth + PanelMetrics.columnGap
                let reusable = table.tableColumns.count == columns.count
                    && table.tableColumns.allSatisfy { abs($0.width - width) < 0.5 }
                if !reusable {
                    table.tableColumns.forEach { table.removeTableColumn($0) }
                    for index in columns.indices {
                        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
                        column.headerCell = NSTableHeaderCell(textCell: "")
                        column.width = width
                        column.minWidth = width
                        column.maxWidth = width
                        table.addTableColumn(column)
                    }
                }
                hovered = (-1, -1)
                table.reloadData()
            }
            clampSize(table)
            refreshGlass(table)
        }

        /// 按当前版面算出每个菜单色块的矩形，交给玻璃层画成真正的液态玻璃。
        /// 一个菜单在某一列里占的那几行合起来是一块（跨列时下一列里同一菜单是另一块）。
        /// 块的**颜色按类目名字**决定，不是按行号——同一个菜单在任何 App 里都同一个色。
        ///
        /// 矩形全部在**表格坐标**里算（玻璃层也挂在表格里，坐标系一致）：
        /// 表格是 flipped 的（y 向下），行号小的在上面，所以首行的 minY 是上边、
        /// 末行的 maxY 是下边。混着裁剪视图的坐标算会把 y 镜像掉，块整个颠倒。
        private func refreshGlass(_ table: HoverTableView) {
            guard let glassLayer else { return }
            let inset = PanelMetrics.columnGap / 2
            let gap = PanelMetrics.blockGap
            let flipped = table.isFlipped
            var result: [BlockGlassLayer.Block] = []

            for (c, column) in columns.enumerated() where !column.isEmpty {
                let colRect = table.rect(ofColumn: c)
                var i = 0
                while i < column.count {
                    let section = column[i].section
                    var j = i
                    while j + 1 < column.count, column[j + 1].section == section { j += 1 }
                    let r0 = table.rect(ofRow: i)
                    let r1 = table.rect(ofRow: j)
                    // 行号小的在上面；矩形在表格坐标里的"上边"跟表是不是 flipped 有关。
                    let down: CGFloat = flipped ? 1 : -1   // 「往下」在坐标里 y 是增是减
                    let top = (flipped ? r0.minY : r0.maxY) + (i != 0 ? gap * down : 0)
                    let bottom = (flipped ? r1.maxY : r1.minY) - (j != column.count - 1 ? gap * down : 0)
                    let rect = NSRect(x: colRect.minX + inset,
                                      y: flipped ? top : bottom,
                                      width: max(0, colRect.width - 2 * inset),
                                      height: max(0, abs(bottom - top)))
                    result.append(BlockGlassLayer.Block(rect: rect,
                                                       tint: PanelPalette.tint(forHue: column[i].hue),
                                                       section: section,
                                                       name: column[i].name,
                                                       column: c,
                                                       rows: i...j))
                    i = j + 1
                }
            }
            if ProcessInfo.processInfo.environment["KEYGLANCE_DEBUG"] == "1" {
                var log = "KeyGlance glass blocks: "
                for b in result {
                    log += String(format: "[%@ col%d rows%d-%d x=%.0f y=%.0f h=%.0f] ",
                                  b.name, b.column, b.rows.lowerBound, b.rows.upperBound,
                                  b.rect.minX, b.rect.minY, b.rect.height)
                }
                log += "| entries: "
                for (c, column) in columns.enumerated() {
                    log += "col\(c): "
                    for (r, e) in column.enumerated() {
                        log += "\(r)=\(e.name)\(e.isFirst ? "F" : "")\(e.isLast ? "L" : "") "
                    }
                    log += "| "
                }
                NSLog("%@", log)
            }
            glassLayer.update(blocks: result)
        }

        /// Scroll back to the first row, again after the next layout pass.
        private func resetScroll(_ table: NSTableView) {
            func scroll() {
                guard let scrollView = table.enclosingScrollView else { return }
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            scroll()
            DispatchQueue.main.async { scroll() }
        }

        /// Height: exactly rows × rowHeight, so there is nothing to scroll past the
        /// last row. Width: the columns' own width, unless they fit the viewport.
        private func clampSize(_ table: NSTableView) {
            let height = CGFloat(table.numberOfRows) * table.rowHeight
            guard height > 0 else { return }
            let clipWidth = table.enclosingScrollView?.contentSize.width ?? table.frame.width
            let columnsWidth = table.tableColumns.reduce(0) { $0 + $1.width }
                + CGFloat(max(0, table.tableColumns.count - 1)) * PanelMetrics.columnGap
            let width = max(clipWidth, allowsHorizontalScroll ? columnsWidth : clipWidth)
            if abs(table.frame.height - height) > 0.5 || abs(table.frame.width - width) > 0.5 {
                table.setFrameSize(NSSize(width: width, height: height))
            }
            if ProcessInfo.processInfo.environment["KEYGLANCE_DEBUG"] == "1" {
                let clip = table.enclosingScrollView?.contentSize.height ?? -1
                let offset = table.enclosingScrollView?.contentView.bounds.origin.y ?? -1
                NSLog("KeyGlance table: rows=\(table.numberOfRows) cols=\(table.numberOfColumns) tableH=\(Int(height)) clipH=\(Int(clip)) scrollY=\(Int(offset)) frameH=\(Int(table.frame.height))")
            }
            reportHeight?(height)
            if let scroll = table.enclosingScrollView {
                scroll.hasHorizontalScroller = allowsHorizontalScroll
                scroll.horizontalScrollElasticity = allowsHorizontalScroll ? .automatic : .none
                if !allowsHorizontalScroll, scroll.contentView.bounds.origin.x != 0 {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.origin.y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            columns.map { $0.count }.max() ?? 0
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let identifier = tableColumn?.identifier.rawValue,
                  let index = Int(identifier), index < columns.count else { return nil }

            // One identifier per column: a shared one lets AppKit hand the same
            // view to two columns at once.
            let reuseID = NSUserInterfaceItemIdentifier("row-\(index)")
            let cell = tableView.makeView(withIdentifier: reuseID, owner: nil) as? ShortcutRowCellView
                ?? ShortcutRowCellView()
            cell.identifier = reuseID
            let rows = columns[index]
            cell.entry = row < rows.count ? rows[row] : nil
            cell.capsGutter = capsGutter
            cell.isColumnHead = row == 0
            cell.isColumnTail = row == rows.count - 1
            cell.isHovered = hovered == (row, index)
            return cell
        }

        func updateHover(row: Int, column: Int) {
            guard let table, (row, column) != hovered else { return }
            let previous = hovered
            hovered = (row, column)
            for (r, c) in [(previous.row, previous.column), (row, column)] where r >= 0 && c >= 0 {
                if let cell = table.view(atColumn: c, row: r, makeIfNecessary: false) as? ShortcutRowCellView {
                    cell.isHovered = (r, c) == (row, column)
                    cell.needsDisplay = true
                }
            }
        }
    }
}

// MARK: - Table pieces

final class HoverTableView: NSTableView {
    var onHover: ((Int, Int) -> Void)?
    private var tracking: NSTrackingArea?

    /// The clip view stretches the table to fill itself; clamp it back to exactly
    /// rows × rowHeight so there is nothing to scroll into below the last row.
    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        let content = CGFloat(numberOfRows) * rowHeight
        if content > 0, size.height > content {
            size.height = content
        }
        super.setFrameSize(size)
        if content > 0, abs(bounds.height - content) > 0.5 {
            super.setFrameSize(NSSize(width: size.width, height: content))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        onHover?(row(at: point), column(at: point))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(-1, -1)
    }
}

final class ShortcutRowCellView: NSTableCellView {
    var entry: PanelEntry? { didSet { needsDisplay = true } }
    var capsGutter: CGFloat = 46 { didSet { if capsGutter != oldValue { needsDisplay = true } } }
    var isColumnHead = false { didSet { if isColumnHead != oldValue { needsDisplay = true } } }
    var isColumnTail = false { didSet { if isColumnTail != oldValue { needsDisplay = true } } }
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        guard let entry else { return }

        // 分区色块不再在这里画：改成由 BlockGlassLayer 用真的 NSGlassEffectView 画，
        // 一整块一个玻璃视图（形状、边缘高光、折射全交给系统）。
        // 单元格只负责字。

        switch entry.row {
        case .header(let title):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: PanelMetrics.sectionFont,
                .foregroundColor: PanelPalette.title(forHue: entry.hue)
            ]
            // 类目标题在行内垂直居中：这样色块顶部到标题、最后一行到色块底部
            // 的距离才一样（以前标题贴行底，上面 7pt、下面 2pt，看着头重脚轻）。
            let rect = NSRect(x: bounds.minX + PanelMetrics.columnGap / 2 + 11,
                              y: bounds.midY - 7,
                              width: max(0, bounds.width - 22),
                              height: 14)
            (title as NSString).draw(in: rect, withAttributes: attributes)

        case .item(let item):
            let content = NSRect(x: bounds.minX + PanelMetrics.columnGap / 2 + 11,
                                 y: bounds.minY,
                                 width: bounds.width - 11 - 12,
                                 height: bounds.height)
            if isHovered { drawHover(entry) }

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: PanelMetrics.titleFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
            let capsAttributes: [NSAttributedString.Key: Any] = [
                .font: PanelMetrics.capsFont,
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.85)
            ]

            // 快捷键在左：一组键帽右对齐到统一栏宽的右边缘，标题从栏后开始，
            // 于是整列标题排成一条直线（跟键指如飞一样）。
            var capRects: [(text: NSString, rect: NSRect)] = []
            var right = content.minX + capsGutter
            for cap in item.keys.reversed() {
                let text = cap as NSString
                let width = max(17, ceil(text.size(withAttributes: capsAttributes).width) + 6)
                let rect = NSRect(x: right - width, y: content.midY - 8, width: width, height: 16)
                capRects.append((text, rect))
                right -= width + 2
            }

            let titleRect = NSRect(x: content.minX + capsGutter + 10,
                                   y: content.midY - 8,
                                   width: max(0, content.maxX - (content.minX + capsGutter + 10)),
                                   height: 16)
            (item.title as NSString).draw(in: titleRect, withAttributes: titleAttributes)

            for (text, rect) in capRects {
                NSColor.labelColor.withAlphaComponent(0.10).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4.5, yRadius: 4.5).fill()
                let textSize = text.size(withAttributes: capsAttributes)
                let textRect = NSRect(x: rect.midX - textSize.width / 2,
                                      y: rect.midY - textSize.height / 2,
                                      width: textSize.width,
                                      height: textSize.height)
                text.draw(in: textRect, withAttributes: capsAttributes)
            }
        }
    }

    /// 这一行在它的分区色块里占的矩形：块内各行连成一体，只有首尾行露出圆角，
    /// 中间的行把矩形延伸出去（被本行裁掉）。NSCellView 不是 flipped，
    /// y = 0 在行的底部，向下是减 y。
    private func blockRect(_ entry: PanelEntry) -> NSRect {
        let gap = PanelMetrics.blockGap
        // 列的第一行 / 最后一行贴到列边：这样色块到面板边的距离就等于留白本身，
        // 左、右、下三边才会一模一样（以前块的 2pt 间隙全堆在底边）。
        let top = entry.isFirst ? (isColumnHead ? bounds.maxY : bounds.maxY - gap) : bounds.maxY + 12
        let bottom = entry.isLast ? (isColumnTail ? bounds.minY : bounds.minY + gap) : bounds.minY - 12
        let inset = PanelMetrics.columnGap / 2
        return NSRect(x: bounds.minX + inset,
                      y: bottom,
                      width: max(0, bounds.width - 2 * inset),
                      height: max(0, top - bottom))
    }

    private func fill(_ rect: NSRect, with color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        color.setFill()
        NSBezierPath(roundedRect: rect,
                     xRadius: PanelMetrics.blockCorner,
                     yRadius: PanelMetrics.blockCorner).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 悬停高亮：跟色块完全同一个形状，所以最后一行的圆角不会和块的圆角打架。
    private func drawHover(_ entry: PanelEntry) {
        fill(blockRect(entry), with: NSColor.labelColor.withAlphaComponent(0.085))
    }
}
