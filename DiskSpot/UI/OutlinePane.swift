import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// Outline that hands Space to Quick Look and Return to zooming, like Finder.
final class DiskOutlineView: NSOutlineView {
    var onQuickLook: (() -> Void)?
    var onOpen: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ":
            onQuickLook?()
        case "\r":
            onOpen?()
        default:
            super.keyDown(with: event)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { attachQuickLook(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { detachQuickLook(panel) }
}

struct OutlinePane: NSViewRepresentable {
    let model: AppModel
    let root: Node?
    let version: Int
    let selection: Node?

    func makeCoordinator() -> OutlineCoordinator {
        OutlineCoordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = DiskOutlineView()
        outline.onQuickLook = { model.quickLook() }
        outline.onOpen = { if let node = model.selection { model.open(node) } }
        let columns: [(id: String, title: String, width: CGFloat, minWidth: CGFloat)] = [
            ("name", "Имя", 240, 120),
            ("size", "Размер", 76, 60),
            ("share", "Доля", 96, 70),
            ("files", "Файлов", 72, 56),
        ]
        for spec in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = spec.minWidth
            if spec.id != "name" {
                column.headerCell.alignment = .right
                column.resizingMask = .userResizingMask
            } else {
                column.resizingMask = [.autoresizingMask, .userResizingMask]
            }
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.usesAlternatingRowBackgroundColors = true
        outline.style = .fullWidth
        outline.intercellSpacing = NSSize(width: 8, height: 0)
        outline.rowHeight = 22
        outline.indentationPerLevel = 13
        outline.allowsMultipleSelection = false
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(OutlineCoordinator.doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu
        outline.headerView?.menu = context.coordinator.columnsMenu()
        outline.autosaveName = "DiskOutline"
        outline.autosaveTableColumns = true
        context.coordinator.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(OutlineCoordinator.clipViewResized(_:)),
            name: NSView.frameDidChangeNotification,
            object: scroll.contentView
        )
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(root: root, version: version, selection: selection)
    }
}

@MainActor
final class OutlineCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let model: AppModel
    weak var outline: NSOutlineView?
    private var root: Node?
    private var version = -1
    private var syncing = false
    private var icons: [String: NSImage] = [:]

    init(model: AppModel) {
        self.model = model
    }

    func update(root: Node?, version: Int, selection: Node?) {
        guard let outline else { return }
        if root !== self.root {
            self.root = root
            self.version = version
            syncing = true
            outline.reloadData()
            if let root { outline.expandItem(root) }
            syncing = false
        } else if version != self.version {
            self.version = version
            let expanded = (0..<outline.numberOfRows)
                .compactMap { outline.item(atRow: $0) as? Node }
                .filter { outline.isItemExpanded($0) }
            syncing = true
            outline.reloadData()
            if let root {
                for node in expanded where node.isInside(root) {
                    outline.expandItem(node)
                }
            }
            syncing = false
        }
        reveal(selection)
    }

    private func reveal(_ node: Node?) {
        guard let outline else { return }
        let current = outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? Node : nil
        guard node !== current else { return }
        syncing = true
        defer { syncing = false }
        guard let node, let root, node.isInside(root) else {
            outline.deselectAll(nil)
            return
        }
        for ancestor in node.chain.dropLast() {
            outline.expandItem(ancestor)
        }
        let row = outline.row(forItem: node)
        if row >= 0 {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return root == nil ? 0 : 1 }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return root! }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.children.isEmpty == false
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node, let column = tableColumn else { return nil }
        switch column.identifier.rawValue {
        case "name":
            return nameCell(outlineView, node)
        case "size":
            return textCell(outlineView, id: "size", text: Format.bytes(node.size), secondary: false)
        case "share":
            let view = outlineView.makeView(withIdentifier: ShareBarView.identifier, owner: nil) as? ShareBarView ?? ShareBarView()
            let total = node.parent?.size ?? node.size
            view.configure(fraction: total > 0 ? Double(node.size) / Double(total) : 0, text: Format.percent(node.size, of: total), kind: node.children.isEmpty ? node.kind : node.dominantKind)
            view.toolTip = "\(Format.percent(node.size, of: total)) от «\(node.parent?.name ?? node.name)»"
            return view
        default:
            let text = node.fileCount > 0 ? Format.count(node.fileCount) : ""
            return textCell(outlineView, id: "files", text: text, secondary: true)
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, let outline else { return }
        let node = outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? Node : nil
        model.select(node)
    }

    /// The name column takes whatever width the other columns leave, so nothing is cut off on the right.
    @objc func clipViewResized(_ notification: Notification) {
        fitNameColumn()
    }

    func fitNameColumn() {
        guard let outline, let clip = outline.enclosingScrollView?.contentView else { return }
        let visible = outline.tableColumns.filter { !$0.isHidden }
        guard let name = visible.first, name.identifier.rawValue == "name" else { return }
        let fixed = visible.dropFirst().reduce(CGFloat(0)) { $0 + $1.width }
        let spacing = outline.intercellSpacing.width * CGFloat(visible.count)
        // The full-width style adds about 4 pt of padding on top of the column widths and spacing.
        let padding: CGFloat = 6
        let target = max(name.minWidth, clip.bounds.width - fixed - spacing - padding)
        if abs(name.width - target) > 0.5 { name.width = target }
    }

    /// Header menu that shows and hides the optional columns, like Finder's list view.
    func columnsMenu() -> NSMenu {
        let menu = NSMenu()
        for (id, title) in [("size", "Размер"), ("share", "Доля"), ("files", "Файлов")] {
            let item = ClosureMenuItem(title, symbol: "") { [weak self] in
                guard let column = self?.outline?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id)) else { return }
                column.isHidden.toggle()
                self?.fitNameColumn()
            }
            item.image = nil
            item.representedObject = id
            menu.addItem(item)
        }
        menu.delegate = self
        return menu
    }

    @objc func doubleClicked(_ sender: NSOutlineView) {
        guard sender.clickedRow >= 0, let node = sender.item(atRow: sender.clickedRow) as? Node else { return }
        model.open(node)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === outline?.headerView?.menu {
            for item in menu.items {
                guard let id = item.representedObject as? String,
                      let column = outline?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id)) else { continue }
                item.state = column.isHidden ? .off : .on
            }
            return
        }
        menu.removeAllItems()
        guard let outline, outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
        NodeMenu.items(for: node, model: model).forEach(menu.addItem)
    }

    // MARK: Cells

    private func nameCell(_ outlineView: NSOutlineView, _ node: Node) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("nameCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? makeCell(identifier, withImage: true, alignment: .left)
        cell.textField?.stringValue = node.name
        cell.textField?.textColor = node.isSynthetic ? .secondaryLabelColor : .labelColor
        cell.imageView?.image = icon(for: node)
        cell.toolTip = node.isSynthetic ? node.name : Format.path(node.path)
        return cell
    }

    private func textCell(_ outlineView: NSOutlineView, id: String, text: String, secondary: Bool) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier(id + "Cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? makeCell(identifier, withImage: false, alignment: .right)
        cell.textField?.stringValue = text
        cell.textField?.textColor = secondary ? .secondaryLabelColor : .labelColor
        return cell
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier, withImage: Bool, alignment: NSTextAlignment) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.alignment = alignment
        text.lineBreakMode = withImage ? .byTruncatingMiddle : .byClipping
        text.font = withImage ? .systemFont(ofSize: NSFont.systemFontSize) : .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(text)
        cell.textField = text

        var constraints = [
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ]
        if withImage {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyDown
            cell.addSubview(image)
            cell.imageView = image
            constraints += [
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 1),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            ]
        } else {
            constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3))
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }

    private func icon(for node: Node) -> NSImage? {
        if node === root || node.role == .package || node.name.hasSuffix(".app") {
            return NSWorkspace.shared.icon(forFile: node.path)
        }
        switch node.role {
        case .folder:
            return cached("folder") { NSWorkspace.shared.icon(for: .folder) }
        case .file, .package:
            let ext = (node.name as NSString).pathExtension.lowercased()
            return cached("ext:" + ext) {
                NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
            }
        case .smallFiles:
            return symbol("square.grid.3x3")
        case .unseen:
            return symbol("eye.slash")
        case .systemGroup, .systemVolume:
            return symbol("internaldrive")
        case .remainder:
            return symbol("shippingbox")
        }
    }

    private func cached(_ key: String, _ make: () -> NSImage) -> NSImage {
        if let image = icons[key] { return image }
        let image = make()
        icons[key] = image
        return image
    }

    private func symbol(_ name: String) -> NSImage? {
        cached("symbol:" + name) {
            NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        }
    }
}

final class ShareBarView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("shareCell")

    private var fraction: Double = 0
    private var text = ""
    private var kind: FileKind = .other

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(fraction: Double, text: String, kind: FileKind) {
        self.fraction = max(0, min(1, fraction))
        self.text = text
        self.kind = kind
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let labelWidth: CGFloat = 46
        let barWidth = max(0, bounds.width - labelWidth - 8)
        let track = CGRect(x: 4, y: bounds.midY - 3, width: barWidth, height: 6)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        if fraction > 0 {
            let filled = CGRect(x: track.minX, y: track.minY, width: max(2, track.width * fraction), height: track.height)
            kind.color.setFill()
            NSBezierPath(roundedRect: filled, xRadius: 3, yRadius: 3).fill()
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = CGRect(x: bounds.width - labelWidth - 3, y: bounds.midY - size.height / 2, width: labelWidth, height: size.height)
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }
}
