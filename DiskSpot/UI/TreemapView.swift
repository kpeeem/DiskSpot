import AppKit
import Quartz
import SwiftUI

struct TreemapView: NSViewRepresentable {
    let model: AppModel
    let root: Node?
    let version: Int
    let selection: Node?
    let highlightedKind: FileKind?
    let searchText: String

    func makeNSView(context: Context) -> TreemapCanvas {
        let view = TreemapCanvas()
        view.onSelect = { node in model.select(node) }
        view.onOpen = { node in model.zoom(to: node) }
        view.onHover = { node in model.hovered = node }
        view.onQuickLook = { model.quickLook() }
        view.onZoomOut = { model.zoomOut() }
        view.menuProvider = { node in NodeMenu.make(for: node, model: model) }
        return view
    }

    func updateNSView(_ view: TreemapCanvas, context: Context) {
        view.update(root: root, version: version, selected: selection, highlightedKind: highlightedKind, searchText: searchText)
    }
}

final class TreemapCanvas: NSView {
    var onSelect: ((Node) -> Void)?
    var onOpen: ((Node) -> Void)?
    var onHover: ((Node?) -> Void)?
    var onQuickLook: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var menuProvider: ((Node) -> NSMenu?)?

    private let base = TreemapBaseView()
    private let overlay = TreemapOverlayView()
    private var root: Node?
    private var version = -1
    private var laidOutSize: CGSize = .zero
    private var cells: [TreemapCell] = []
    private weak var hoveredNode: Node?
    private weak var selectedNode: Node?
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Since macOS 14 views may draw outside their bounds; the map's background fill
        // would otherwise paint over the neighbouring list and summary bar.
        clipsToBounds = true
        for view in [base, overlay] as [NSView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            view.wantsLayer = true
            view.clipsToBounds = true
            addSubview(view)
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Карта занятого места")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func update(root: Node?, version: Int, selected: Node?, highlightedKind: FileKind?, searchText: String) {
        let previousRoot = self.root
        let previousCells = cells
        let rootChanged = root !== previousRoot
        if rootChanged || version != self.version {
            self.root = root
            self.version = version
            rebuild()
        }
        if rootChanged, let root, let previousRoot {
            animateZoom(from: previousRoot, to: root, previousCells: previousCells)
        }
        if base.highlightedKind != highlightedKind || base.searchText != searchText {
            base.highlightedKind = highlightedKind
            base.searchText = searchText
            base.needsDisplay = true
        }
        if selected !== selectedNode {
            selectedNode = selected
            overlay.selectedRect = rect(for: selected)
        }
    }

    override func layout() {
        super.layout()
        if bounds.size != laidOutSize { rebuild() }
    }

    private func rebuild() {
        laidOutSize = bounds.size
        cells = root.map { TreemapLayout.build(root: $0, in: bounds) } ?? []
        base.cells = cells
        base.needsDisplay = true
        hoveredNode = nil
        overlay.hoverRect = nil
        overlay.selectedRect = rect(for: selectedNode)
    }

    var isZoomAnimating: Bool { base.layer?.animation(forKey: "zoom") != nil }

    /// Zooming in grows the new map out of the cell it came from; zooming out shrinks it back into place.
    private func animateZoom(from previousRoot: Node, to root: Node, previousCells: [TreemapCell]) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, bounds.width > 0, bounds.height > 0,
              let layer = base.layer else { return }
        // Cells use flipped view coordinates. The transform acts in the superlayer's space, which AppKit
        // flips for a flipped view; otherwise y grows upwards from the bottom edge.
        let flipped = layer.superlayer?.isGeometryFlipped ?? true
        func layerOrigin(of rect: CGRect) -> CGPoint {
            CGPoint(x: rect.minX, y: flipped ? rect.minY : bounds.height - rect.maxY)
        }
        let start: CGAffineTransform
        if root.isInside(previousRoot), let cell = previousCells.first(where: { $0.node === root }) {
            let rect = cell.rect
            let origin = layerOrigin(of: rect)
            start = CGAffineTransform(translationX: origin.x, y: origin.y)
                .scaledBy(x: rect.width / bounds.width, y: rect.height / bounds.height)
        } else if previousRoot.isInside(root), let cell = cells.first(where: { $0.node === previousRoot }) {
            let rect = cell.rect
            let origin = layerOrigin(of: rect)
            start = CGAffineTransform(scaleX: bounds.width / rect.width, y: bounds.height / rect.height)
                .translatedBy(x: -origin.x, y: -origin.y)
        } else {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.duration = 0.18
            layer.add(fade, forKey: "fade")
            return
        }
        // AppKit keeps the layer's anchor at the origin, so the transform is applied about the top-left corner.
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = CATransform3DMakeAffineTransform(start)
        spring.toValue = CATransform3DIdentity
        spring.damping = 30
        spring.stiffness = 300
        spring.mass = 1
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "zoom")
    }

    /// The cell of the node, or of its nearest ancestor when the node is too small to be drawn.
    private func rect(for node: Node?) -> CGRect? {
        var current = node
        while let candidate = current {
            if let cell = cells.first(where: { $0.node === candidate }) {
                return candidate === root ? nil : cell.rect
            }
            current = candidate.parent
        }
        return nil
    }

    private func cell(at event: NSEvent) -> TreemapCell? {
        let point = convert(event.locationInWindow, from: nil)
        return cells.last { $0.rect.contains(point) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let hit = cell(at: event)
        guard hit?.node !== hoveredNode else { return }
        hoveredNode = hit?.node
        overlay.hoverRect = hit?.rect
        onHover?(hit?.node)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredNode = nil
        overlay.hoverRect = nil
        onHover?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let hit = cell(at: event) else { return }
        if event.clickCount >= 2 {
            onOpen?(hit.node)
        } else {
            onSelect?(hit.node)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ":
            onQuickLook?()
        case "\r":
            if let selectedNode { onOpen?(selectedNode) }
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let hit = cell(at: event) else { return nil }
        onSelect?(hit.node)
        return menuProvider?(hit.node)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { attachQuickLook(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { detachQuickLook(panel) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        base.needsDisplay = true
        overlay.needsDisplay = true
    }
}

private final class TreemapBaseView: NSView {
    var cells: [TreemapCell] = []
    var highlightedKind: FileKind?
    var searchText = ""

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let background = NSColor.windowBackgroundColor
        let area = dirtyRect.intersection(bounds)
        background.setFill()
        area.fill()

        for cell in cells where cell.rect.intersects(area) {
            if cell.isLeaf {
                drawLeaf(cell, dark: dark, background: background)
            } else {
                drawFolder(cell, dark: dark)
            }
        }
    }

    private func drawFolder(_ cell: TreemapCell, dark: Bool) {
        let level = CGFloat(min(cell.depth, 6))
        let fill = dark ? NSColor(white: 0.20 + level * 0.025, alpha: 1) : NSColor(white: 0.86 - level * 0.03, alpha: 1)
        fill.setFill()
        cell.rect.fill()

        guard let header = cell.header else { return }
        let label = NSMutableAttributedString(
            string: cell.node.name,
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: Self.paragraph]
        )
        label.append(NSAttributedString(
            string: "  " + Format.bytes(cell.node.size),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        ))
        label.draw(with: header.insetBy(dx: 5, dy: 1.5), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawLeaf(_ cell: TreemapCell, dark: Bool, background: NSColor) {
        let kind = cell.node.children.isEmpty ? cell.node.kind : cell.node.dominantKind
        var color = kind.color
        let dimmedByKind = highlightedKind.map { $0 != kind } ?? false
        let dimmedBySearch = !searchText.isEmpty && !cell.node.name.localizedCaseInsensitiveContains(searchText)
        if dimmedByKind || dimmedBySearch {
            color = color.blended(withFraction: 0.82, of: background) ?? color
        }
        let rect = cell.rect.width > 3 && cell.rect.height > 3 ? cell.rect.insetBy(dx: 0.5, dy: 0.5) : cell.rect
        color.setFill()
        rect.fill()

        if kind == .unseen {
            drawHatch(in: rect, dark: dark)
        }

        guard rect.width >= 56, rect.height >= 30 else { return }
        let textColor = Self.prefersDarkText(on: color) ? NSColor(white: 0.08, alpha: 0.9) : NSColor(white: 1, alpha: 0.95)
        let name = NSAttributedString(
            string: cell.node.name,
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: textColor, .paragraphStyle: Self.paragraph]
        )
        let size = NSAttributedString(
            string: Format.bytes(cell.node.size),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: textColor.withAlphaComponent(0.75)]
        )
        let inner = rect.insetBy(dx: 5, dy: 4)
        name.draw(with: CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: 14), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        size.draw(with: CGRect(x: inner.minX, y: inner.minY + 14, width: inner.width, height: 13), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawHatch(in rect: CGRect, dark: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: rect)
        context.setStrokeColor((dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.07)).cgColor)
        context.setLineWidth(1)
        var x = rect.minX - rect.height
        while x < rect.maxX {
            context.move(to: CGPoint(x: x, y: rect.maxY))
            context.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 7
        }
        context.strokePath()
        context.restoreGState()
    }

    private static func prefersDarkText(on color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return true }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.55
    }
}

private final class TreemapOverlayView: NSView {
    var hoverRect: CGRect? {
        didSet { if oldValue != hoverRect { needsDisplay = true } }
    }

    var selectedRect: CGRect? {
        didSet { if oldValue != selectedRect { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        if let selectedRect {
            let path = NSBezierPath(rect: selectedRect.insetBy(dx: 1.5, dy: 1.5))
            path.lineWidth = 3
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
        if let hoverRect {
            let outer = NSBezierPath(rect: hoverRect.insetBy(dx: 1, dy: 1))
            outer.lineWidth = 2
            NSColor(white: 1, alpha: 0.9).setStroke()
            outer.stroke()
            let inner = NSBezierPath(rect: hoverRect.insetBy(dx: 2.5, dy: 2.5))
            inner.lineWidth = 1
            NSColor(white: 0, alpha: 0.45).setStroke()
            inner.stroke()
        }
    }
}
