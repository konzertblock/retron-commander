import AppKit
import SwiftUI

enum FileTableContextAction: String {
    case open, view, edit, copy, move, rename, delete, properties, refresh
}

private final class NortonDOSScroller: NSScroller {
    override func draw(_ dirtyRect: NSRect) {
        let trackColor = NSColor(RetronTheme.nortonCommander.background)
        let edgeColor = NSColor(RetronTheme.nortonCommander.panelBorder)
        let knobColor = NSColor(RetronTheme.nortonCommander.selection)
        trackColor.setFill()
        bounds.fill()
        let track = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        edgeColor.setStroke()
        track.lineWidth = 1
        track.stroke()

        let knob = rect(for: .knob).insetBy(dx: 2, dy: 2)
        if !knob.isEmpty {
            knobColor.setFill()
            NSBezierPath(rect: knob).fill()
            edgeColor.setStroke()
            let outline = NSBezierPath(rect: knob.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
        }
    }
}

private final class NortonHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard RetronTheme.selected == .nortonCommander else {
            super.draw(withFrame: cellFrame, in: controlView)
            return
        }
        NSColor(RetronTheme.nortonCommander.background).setFill()
        cellFrame.fill()
        let font = NSFont(name: "Monaco", size: 14) ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.yellow]
        let size = stringValue.size(withAttributes: attributes)
        stringValue.draw(at: NSPoint(x: cellFrame.midX - size.width / 2, y: cellFrame.midY - size.height / 2), withAttributes: attributes)
        NSColor(RetronTheme.nortonCommander.panelBorder).setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: cellFrame.maxX - 0.5, y: cellFrame.minY))
        separator.line(to: NSPoint(x: cellFrame.maxX - 0.5, y: cellFrame.maxY))
        separator.lineWidth = 1
        separator.stroke()
    }
}

private final class NortonTableRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        NSColor(RetronTheme.nortonCommander.background).setFill()
        dirtyRect.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(RetronTheme.nortonCommander.selection).setFill()
        dirtyRect.fill()
    }
}

struct CompactFileTable: NSViewRepresentable {
    @ObservedObject var model: FilePaneModel
    let onOpen: () -> Void
    let onContextAction: (FileTableContextAction) -> Void
    let onFileDrop: ([URL], Bool) -> Void
    let onKeyDown: (NSEvent) -> Bool
    let onTableReady: (NSTableView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model, onOpen: onOpen, onContextAction: onContextAction, onFileDrop: onFileDrop, onKeyDown: onKeyDown) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        let theme = RetronTheme.selected
        configureScrollers(on: scroll, theme: theme)
        scroll.backgroundColor = theme == .nortonCommander ? NSColor(theme.background) : .textBackgroundColor

        let table = ContextMenuTableView()
        table.keyHandler = { [weak coordinator = context.coordinator] event in coordinator?.onKeyDown(event) ?? false }
        table.rowHeight = theme == .nortonCommander ? 24 : 20
        table.intercellSpacing = NSSize(width: theme == .nortonCommander ? 0 : 4, height: 0)
        table.usesAlternatingRowBackgroundColors = theme != .nortonCommander
        table.gridStyleMask = theme == .nortonCommander ? [.solidVerticalGridLineMask] : []
        table.gridColor = NSColor(theme.panelBorder)
        table.backgroundColor = theme == .nortonCommander ? NSColor(theme.background) : .textBackgroundColor
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let header = AutoSizingTableHeaderView()
        header.onAutoSizeColumn = { [weak coordinator = context.coordinator] index in
            coordinator?.autoSizeColumn(index)
        }
        table.headerView = header
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClick(_:))
        onTableReady(table)
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu

        configureColumns(to: table, theme: theme)

        scroll.documentView = table
        context.coordinator.tableView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        context.coordinator.model = model
        context.coordinator.onOpen = onOpen
        context.coordinator.onContextAction = onContextAction
        context.coordinator.onFileDrop = onFileDrop
        context.coordinator.onKeyDown = onKeyDown
        (scroll.documentView as? ContextMenuTableView)?.keyHandler = { [weak coordinator = context.coordinator] event in coordinator?.onKeyDown(event) ?? false }
        onTableReady(table)
        let theme = RetronTheme.selected
        let themeChanged = context.coordinator.lastTheme != theme
        if themeChanged {
            configureColumns(to: table, theme: theme)
            configureScrollers(on: scroll, theme: theme)
        }
        if context.coordinator.lastEntries != model.entries || themeChanged {
            context.coordinator.lastEntries = model.entries
            table.reloadData()
        }
        context.coordinator.lastTheme = theme
        scroll.backgroundColor = theme == .nortonCommander ? NSColor(theme.background) : .textBackgroundColor
        table.backgroundColor = theme == .nortonCommander ? NSColor(theme.background) : .textBackgroundColor
        table.rowHeight = theme == .nortonCommander ? 24 : 20
        table.usesAlternatingRowBackgroundColors = theme != .nortonCommander
        table.selectionHighlightStyle = .regular
        table.gridStyleMask = theme == .nortonCommander ? [.solidVerticalGridLineMask] : []
        table.gridColor = NSColor(theme.panelBorder)
        let selectedRows = IndexSet(model.entries.enumerated().compactMap { model.selectedIDs.contains($0.element.id) ? $0.offset : nil })
        if table.selectedRowIndexes != selectedRows {
            context.coordinator.isApplyingModelSelection = true
            table.selectRowIndexes(selectedRows, byExtendingSelection: false)
            context.coordinator.isApplyingModelSelection = false
        }
        context.coordinator.updateNortonSelectionColors(in: table)
    }

    private func configureScrollers(on scroll: NSScrollView, theme: RetronTheme) {
        let isNorton = theme == .nortonCommander
        scroll.scrollerStyle = isNorton ? .legacy : .overlay
        scroll.autohidesScrollers = true
        scroll.verticalScroller = isNorton ? NortonDOSScroller() : NSScroller()
        scroll.horizontalScroller = isNorton ? NortonDOSScroller() : NSScroller()
    }

    private func addColumn(to table: NSTableView, id: String, title: String, width: CGFloat, min: CGFloat, max: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        if RetronTheme.selected == .nortonCommander { column.headerCell = NortonHeaderCell(textCell: title) }
        column.width = width
        column.minWidth = min
        column.maxWidth = max
        column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
        table.addTableColumn(column)
    }

    private func configureColumns(to table: NSTableView, theme: RetronTheme) {
        table.tableColumns.forEach { table.removeTableColumn($0) }
        if theme == .nortonCommander {
            addColumn(to: table, id: "name", title: "Name", width: 180, min: 120, max: 700)
            addColumn(to: table, id: "size", title: "Size", width: 80, min: 64, max: 180)
            addColumn(to: table, id: "date", title: "Date", width: 85, min: 74, max: 120)
            addColumn(to: table, id: "time", title: "Time", width: 62, min: 56, max: 100)
        } else {
            addColumn(to: table, id: "name", title: "Name", width: 150, min: 92, max: 600)
            addColumn(to: table, id: "ext", title: "Ext", width: 36, min: 28, max: 120)
            addColumn(to: table, id: "size", title: "Size", width: 54, min: 45, max: 150)
            addColumn(to: table, id: "date", title: "Date", width: 96, min: 76, max: 180)
            addColumn(to: table, id: "attributes", title: "Attr", width: 48, min: 32, max: 80)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var model: FilePaneModel
        var onOpen: () -> Void
        var onContextAction: (FileTableContextAction) -> Void
        var onFileDrop: ([URL], Bool) -> Void
        var onKeyDown: (NSEvent) -> Bool
        weak var tableView: NSTableView?
        var lastEntries: [FileEntry]?
        var lastTheme: RetronTheme = RetronTheme.selected
        var isApplyingModelSelection = false

        init(model: FilePaneModel, onOpen: @escaping () -> Void, onContextAction: @escaping (FileTableContextAction) -> Void, onFileDrop: @escaping ([URL], Bool) -> Void, onKeyDown: @escaping (NSEvent) -> Bool) {
            self.model = model
            self.onOpen = onOpen
            self.onContextAction = onContextAction
            self.onFileDrop = onFileDrop
            self.onKeyDown = onKeyDown
        }

        func numberOfRows(in tableView: NSTableView) -> Int { model.entries.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            RetronTheme.selected == .nortonCommander ? NortonTableRowView() : nil
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard model.entries.indices.contains(row) else { return nil }
            let entry = model.entries[row]
            guard !entry.isParent, entry.archiveURL == nil else { return nil }
            return entry.url as NSURL
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard model.archiveURL == nil,
                  info.draggingPasteboard.types?.contains(.fileURL) == true,
                  let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
                  !urls.isEmpty else { return [] }
            tableView.setDropRow(tableView.numberOfRows, dropOperation: .above)
            return [.copy, .move]
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard model.archiveURL == nil,
                  let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  !urls.isEmpty else { return false }
            let destination = model.directory.standardizedFileURL
            let valid = urls.filter { url in
                let source = url.standardizedFileURL
                return source != destination && !destination.path.hasPrefix(source.path.hasSuffix("/") ? source.path : source.path + "/")
            }
            guard !valid.isEmpty else { return false }
            onFileDrop(valid, NSApp.currentEvent?.modifierFlags.contains(.option) == true)
            return true
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard model.entries.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return nil }
            let entry = model.entries[row]
            let theme = RetronTheme.selected
            let value: String
            switch id {
            case "name": value = theme == .nortonCommander && entry.isParent ? "▶UP--DIR◀" : entry.name
            case "ext": value = entry.extensionName
            case "size":
                if theme == .nortonCommander { value = entry.isParent ? "" : (entry.isDirectory ? "<SUB-DIR>" : String(entry.byteSize)) }
                else { value = entry.displaySize }
            case "date": value = entry.modifiedAt.map { theme == .nortonCommander ? CompactFileTable.dosDateFormatter.string(from: $0) : $0.formatted(date: .numeric, time: .shortened) } ?? ""
            case "time": value = entry.modifiedAt.map { CompactFileTable.dosTimeFormatter.string(from: $0) } ?? ""
            case "attributes": value = entry.attributes
            default: value = ""
            }
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: value)
            label.font = theme == .nortonCommander ? (NSFont(name: "Monaco", size: 14) ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)) : NSFont.systemFont(ofSize: 13)
            if theme == .nortonCommander { label.textColor = NSColor(theme.foreground) }
            if theme == .nortonCommander, tableView.selectedRowIndexes.contains(row) { label.textColor = NSColor(theme.background) }
            if theme == .nortonCommander { label.alignment = id == "date" || id == "time" ? .center : (id == "name" ? .left : .right) }
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            if id == "name", theme.usesIcons {
                let icon = NSWorkspace.shared.icon(forFile: entry.url.path)
                icon.size = NSSize(width: 16, height: 16)
                let imageView = NSImageView(image: icon)
                imageView.imageScaling = .scaleProportionallyDown
                imageView.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(imageView)
                cell.imageView = imageView
                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 16),
                    imageView.heightAnchor.constraint(equalToConstant: 16),
                    label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 5)
                ])
            } else {
                NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3)])
            }
            NSLayoutConstraint.activate([
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingModelSelection, let tableView else { return }
            updateNortonSelectionColors(in: tableView)
            let selectedIDs = Set(tableView.selectedRowIndexes.compactMap { model.entries.indices.contains($0) ? model.entries[$0].id : nil })
            let focusedID = model.entries.indices.contains(tableView.selectedRow) ? model.entries[tableView.selectedRow].id : nil
            // NSTableView can notify during SwiftUI's AppKit layout/update pass. Defer
            // published model mutations so they cannot recursively invalidate the same
            // window constraint pass.
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                if self.model.selectedIDs != selectedIDs { self.model.selectedIDs = selectedIDs }
                if self.model.focusedID != focusedID { self.model.focusedID = focusedID }
            }
        }

        func updateNortonSelectionColors(in tableView: NSTableView) {
            guard RetronTheme.selected == .nortonCommander else { return }
            let normal = NSColor(RetronTheme.nortonCommander.foreground)
            let selected = NSColor(RetronTheme.nortonCommander.background)
            for row in 0..<tableView.numberOfRows {
                let color = tableView.selectedRowIndexes.contains(row) ? selected : normal
                for column in 0..<tableView.numberOfColumns {
                    let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView
                    cell?.textField?.textColor = color
                }
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
            model.sortBy(column: key == "time" ? "date" : key, ascending: descriptor.ascending)
        }

        func autoSizeColumn(_ index: Int) {
            guard let tableView, tableView.tableColumns.indices.contains(index) else { return }
            let column = tableView.tableColumns[index]
            let key = column.identifier.rawValue
            let bodyFont = NSFont.systemFont(ofSize: 13)
            let headerFont = NSFont.systemFont(ofSize: 12, weight: .medium)
            var width = (column.title as NSString).size(withAttributes: [.font: headerFont]).width
            for entry in model.entries {
                let value: String
                switch key {
                case "name": value = entry.name
                case "ext": value = entry.extensionName
                case "size": value = entry.displaySize
                case "date": value = entry.modifiedAt.map { $0.formatted(date: .numeric, time: .shortened) } ?? ""
                case "time": value = entry.modifiedAt.map { CompactFileTable.dosTimeFormatter.string(from: $0) } ?? ""
                case "attributes": value = entry.attributes
                default: value = ""
                }
                width = max(width, (value as NSString).size(withAttributes: [.font: bodyFont]).width)
            }
            width += key == "name" ? 36 : 18
            column.width = min(column.maxWidth, max(column.minWidth, ceil(width)))
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard !model.selectedEntries.isEmpty else { return }

            let hasFiles = model.selectedEntries.contains { !$0.isDirectory && !$0.isParent }
            let items: [(String, FileTableContextAction)] = [
                ("Open", .open), ("View", .view), ("Edit", .edit), ("Copy…", .copy),
                ("Move/Rename…", .move), ("Rename…", .rename), ("Delete", .delete),
                ("Properties…", .properties), ("Refresh", .refresh)
            ]
            for (index, item) in items.enumerated() {
                if index == 1 && !hasFiles { continue }
                if index == 2 && !hasFiles { continue }
                if index == 3 || index == 4 || index == 5 || index == 6 || index == 7 {
                    if index == 5 && model.selectedEntries.count != 1 { continue }
                }
                if index == 8 { menu.addItem(.separator()) }
                let menuItem = NSMenuItem(title: item.0, action: #selector(contextMenuAction(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = item.1.rawValue
                menu.addItem(menuItem)
            }
        }

        @objc private func contextMenuAction(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                  let action = FileTableContextAction(rawValue: raw) else { return }
            onContextAction(action)
        }

        @objc func doubleClick(_ sender: NSTableView) {
            guard sender.clickedRow >= 0, sender.clickedRow < model.entries.count else { return }
            model.focusedID = model.entries[sender.clickedRow].id
            if model.selectedIDs.isEmpty { model.selectedIDs = [model.entries[sender.clickedRow].id] }
            onOpen()
        }
    }

    @MainActor private static let dosDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "dd.MM.yy"
        return formatter
    }()

    @MainActor private static let dosTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "H:mm"
        return formatter
    }()
}

@MainActor
private final class AutoSizingTableHeaderView: NSTableHeaderView {
    var onAutoSizeColumn: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, let tableView else {
            super.mouseDown(with: event)
            return
        }
        let x = convert(event.locationInWindow, from: nil).x
        for index in 0..<tableView.numberOfColumns {
            if abs(x - headerRect(ofColumn: index).maxX) <= 5 {
                onAutoSizeColumn?(index)
                return
            }
        }
        super.mouseDown(with: event)
    }
}

@MainActor
private final class ContextMenuTableView: NSTableView {
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 && !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        super.rightMouseDown(with: event)
    }
}
