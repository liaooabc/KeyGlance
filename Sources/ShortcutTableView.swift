import AppKit
import SwiftUI

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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let table = HoverTableView()
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.autoresizingMask = [.width]
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: PanelMetrics.columnGap, height: 0)
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

        context.coordinator.table = table
        context.coordinator.allowsHorizontalScroll = allowsHorizontalScroll
        return scroll
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.allowsHorizontalScroll = allowsHorizontalScroll
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
        weak var table: HoverTableView?
        private var columns: [[PanelEntry]] = []
        private var lastResetToken = -1
        private var hovered: (row: Int, column: Int) = (-1, -1)

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
                table.tableColumns.forEach { table.removeTableColumn($0) }
                for index in columns.indices {
                    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
                    column.headerCell = NSTableHeaderCell(textCell: "")
                    column.width = columnWidth
                    column.minWidth = columnWidth
                    column.maxWidth = columnWidth
                    table.addTableColumn(column)
                }
                hovered = (-1, -1)
                table.reloadData()
            }
            clampSize(table)
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
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        guard let entry else { return }

        drawBlock(entry)

        switch entry.row {
        case .header(let title):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: PanelMetrics.sectionFont,
                .foregroundColor: PanelPalette.title(for: entry.section)
            ]
            // 类目标题在行内垂直居中：这样色块顶部到标题、最后一行到色块底部
            // 的距离才一样（以前标题贴行底，上面 7pt、下面 2pt，看着头重脚轻）。
            let rect = NSRect(x: bounds.minX + 11,
                              y: bounds.midY - 7,
                              width: max(0, bounds.width - 22),
                              height: 14)
            (title as NSString).draw(in: rect, withAttributes: attributes)

        case .item(let item):
            let content = NSRect(x: bounds.minX + 11,
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
        let top = entry.isFirst ? bounds.maxY - gap : bounds.maxY + 12
        let bottom = entry.isLast ? bounds.minY + gap : bounds.minY - 12
        return NSRect(x: bounds.minX,
                      y: bottom,
                      width: max(0, bounds.width),
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

    /// 分区色块：整块一个浅色底，跨行连续。
    private func drawBlock(_ entry: PanelEntry) {
        fill(blockRect(entry), with: PanelPalette.fill(for: entry.section))
    }

    /// 悬停高亮：跟色块完全同一个形状，所以最后一行的圆角不会和块的圆角打架。
    private func drawHover(_ entry: PanelEntry) {
        fill(blockRect(entry), with: NSColor.labelColor.withAlphaComponent(0.085))
    }
}
