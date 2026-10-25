import AppKit
import SwiftUI

/// The shortcut grid, drawn by AppKit: one NSTableColumn per menu, one row per
/// item. AppKit only creates the cells that are on screen, so scrolling never
/// re-lays out the whole tree.
struct ShortcutTableView: NSViewRepresentable {
    let sections: [ShortcutSection]
    let columnWidths: [CGFloat]
    /// Bumped on every opening so the list starts at the top again.
    let resetToken: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let table = HoverTableView()
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.headerView = nil
        table.rowSizeStyle = .custom
        // Width follows the scroll view; height must stay = rows × rowHeight,
        // otherwise the clip view stretches it and you can scroll into empty space.
        table.autoresizingMask = [.width]
        table.rowHeight = PanelMetrics.rowHeight
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
        // The panel never scrolls sideways: columns are sized to fit the width.
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        // Must be off, otherwise AppKit recalculates (and clears) the insets we
        // use to keep the first row clear of the floating header bar.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.verticalScrollElasticity = .allowed
        scroll.horizontalScrollElasticity = .none

        let strip = ShortcutHeaderStrip()
        let container = ShortcutTableContainer(strip: strip, scroll: scroll)
        context.coordinator.table = table
        context.coordinator.strip = strip
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.apply(sections: sections, columnWidths: columnWidths, resetToken: resetToken)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: HoverTableView?
        weak var strip: ShortcutHeaderStrip?
        private var sections: [ShortcutSection] = []
        private var columnWidths: [CGFloat] = []
        private var lastResetToken = -1
        private var hovered: (row: Int, column: Int) = (-1, -1)

        private func signature(_ sections: [ShortcutSection]) -> String {
            sections.map { "\($0.title)#\($0.items.count)" }.joined(separator: "|")
        }

        func apply(sections: [ShortcutSection], columnWidths: [CGFloat], resetToken: Int) {
            guard let table else { return }
            let shouldResetScroll = resetToken != lastResetToken
            lastResetToken = resetToken
            if shouldResetScroll { self.resetScroll(table) }
            let columnsChanged = signature(sections) != signature(self.sections)
            let widthsChanged = columnWidths.count != self.columnWidths.count
                || zip(columnWidths, self.columnWidths).contains { abs($0 - $1) > 0.5 }
            self.sections = sections
            self.columnWidths = columnWidths
            guard columnsChanged || widthsChanged else { return }
            self.resetScroll(table)

            if columnsChanged || table.tableColumns.count != sections.count {
                table.tableColumns.forEach { table.removeTableColumn($0) }
                for index in sections.indices {
                    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
                    column.headerCell = NSTableHeaderCell(textCell: "")
                    table.addTableColumn(column)
                }
            }
            applyWidths()
            strip?.titles = sections.map { $0.title }
            strip?.widths = columnWidths
            strip?.needsDisplay = true
            hovered = (-1, -1)
            table.reloadData()
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
        /// last row. Width: at least the clip width but never more than the columns
        /// need, so a panel that fits cannot be nudged left or right either.
        private func clampSize(_ table: NSTableView) {
            let height = CGFloat(table.numberOfRows) * table.rowHeight
            guard height > 0 else { return }
            let clipWidth = table.enclosingScrollView?.contentSize.width ?? table.frame.width
            // Exactly the viewport width: no horizontal scroll range at all.
            let width = max(clipWidth, 1)
            if abs(table.frame.height - height) > 0.5 || abs(table.frame.width - width) > 0.5 {
                table.setFrameSize(NSSize(width: width, height: height))
            }
            if let scroll = table.enclosingScrollView {
                scroll.hasHorizontalScroller = false
                scroll.horizontalScrollElasticity = .none
                if scroll.contentView.bounds.origin.x != 0 {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.origin.y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }

        private func applyWidths() {
            guard let table else { return }
            for (index, column) in table.tableColumns.enumerated() {
                let width = index < columnWidths.count ? columnWidths[index] : 180
                column.width = width
                column.minWidth = width
                column.maxWidth = width
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            sections.map { $0.items.count }.max() ?? 0
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let identifier = tableColumn?.identifier.rawValue,
                  let index = Int(identifier), index < sections.count else { return nil }

            // One identifier per column: a shared one lets AppKit hand the same
            // view to two columns at once.
            let reuseID = NSUserInterfaceItemIdentifier("row-\(index)")
            let cell = tableView.makeView(withIdentifier: reuseID, owner: nil) as? ShortcutRowCellView
                ?? ShortcutRowCellView()
            cell.identifier = reuseID
            let items = sections[index].items
            cell.item = row < items.count ? items[row] : nil
            cell.isHovered = hovered == (row, index)
            cell.showsLeadingSeparator = index > 0
            cell.trailingGutter = index == sections.count - 1 ? PanelMetrics.scrollerGutter : 0
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

    // Avoid the default scroll-wheel step feeling coarse; keep rows crisp.
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
    }
}

/// A frosted header bar that floats over the rows the way AppKit's own pinned
/// headers do: content scrolls underneath, the material blurs it.
final class ShortcutHeaderStrip: NSView {
    var titles: [String] = [] { didSet { needsDisplay = true } }
    var widths: [CGFloat] = [] { didSet { needsDisplay = true } }
    var horizontalOffset: CGFloat = 0 { didSet { if horizontalOffset != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.8)
        ]
        var x = -horizontalOffset
        for (index, title) in titles.enumerated() {
            let width = index < widths.count ? widths[index] : 160
            let text = title as NSString
            let textSize = text.size(withAttributes: attributes)
            // AppKit's own table headers centre their titles over the column.
            let rect = NSRect(x: x + (width - textSize.width) / 2,
                              y: (bounds.height - textSize.height) / 2,
                              width: min(textSize.width, max(0, width - 12)),
                              height: textSize.height)
            text.draw(in: rect, withAttributes: attributes)
            x += width
        }
    }
}

/// Header strip above the scrolling rows: no background of its own, so the
/// column titles sit directly on the panel glass and blend with the app header.
final class ShortcutTableContainer: NSView {
    private let strip: ShortcutHeaderStrip
    private let scroll: NSScrollView
    private var boundsObserver: NSObjectProtocol?

    init(strip: ShortcutHeaderStrip, scroll: NSScrollView) {
        self.strip = strip
        self.scroll = scroll
        super.init(frame: .zero)
        addSubview(scroll)
        addSubview(strip)

        scroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                               object: scroll.contentView,
                                                               queue: .main) { [weak self] _ in
            guard let self else { return }
            let clip = self.scroll.contentView
            // Horizontal movement is never allowed: pin the offset to zero even if
            // a trackpad swipe or the elastic bounce tries to move it.
            if abs(clip.bounds.origin.x) > 0.01 {
                clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y))
            }
            self.strip.horizontalOffset = clip.bounds.origin.x
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let header = PanelMetrics.sectionHeaderHeight
        // Re-assert on every layout: the system flips the style back when the
        // pointing device changes (mouse vs trackpad).
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        strip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: header)
        scroll.frame = NSRect(x: 0, y: header, width: bounds.width, height: max(0, bounds.height - header))
    }
}

final class ShortcutRowCellView: NSTableCellView {
    var item: ShortcutItem? { didSet { needsDisplay = true } }
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    var showsLeadingSeparator = false { didSet { if showsLeadingSeparator != oldValue { needsDisplay = true } } }
    /// Extra room on the right of the last column so the overlay scroller never
    /// sits on top of the key caps.
    var trailingGutter: CGFloat = 0 { didSet { if trailingGutter != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        if showsLeadingSeparator {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSRect(x: bounds.minX, y: bounds.minY, width: 1, height: bounds.height).fill()
        }
        guard let item else { return }
        let bounds = NSRect(x: self.bounds.minX + 7,
                            y: self.bounds.minY,
                            width: self.bounds.width - 7 - 10 - trailingGutter,
                            height: self.bounds.height)
        if isHovered {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: -1, dy: 2), xRadius: 5, yRadius: 5).fill()
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let capsAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.85)
        ]

        var capRects: [(text: NSString, rect: NSRect)] = []
        var right = bounds.maxX
        for cap in item.keys.reversed() {
            let text = cap as NSString
            let width = max(17, ceil(text.size(withAttributes: capsAttributes).width) + 6)
            let rect = NSRect(x: right - width, y: bounds.midY - 8.5, width: width, height: 17)
            capRects.append((text, rect))
            right -= width + 2
        }

        let titleRect = NSRect(x: bounds.minX,
                               y: bounds.midY - 8.5,
                               width: max(0, right - 4 - bounds.minX),
                               height: 17)
        (item.title as NSString).draw(in: titleRect, withAttributes: titleAttributes)

        for (text, rect) in capRects {
            NSColor.labelColor.withAlphaComponent(0.09).setFill()
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
