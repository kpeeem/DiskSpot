import AppKit
import SwiftUI

/// Finder-style path bar for the zoomed-in folder; clicking a component zooms out to it.
struct PathBar: NSViewRepresentable {
    let model: AppModel
    let node: Node?
    let version: Int

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSPathControl {
        let control = NSPathControl()
        control.pathStyle = .standard
        control.isEditable = false
        control.focusRingType = .none
        control.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        control.backgroundColor = .clear
        control.target = context.coordinator
        control.action = #selector(Coordinator.clicked(_:))
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSPathControl, context: Context) {
        let chain = node?.chain ?? []
        let coordinator = context.coordinator
        guard chain.map(ObjectIdentifier.init) != coordinator.nodes.map(ObjectIdentifier.init) || version != coordinator.version else { return }
        coordinator.nodes = chain
        coordinator.version = version
        let items = chain.map { node in
            let item = NSPathControlItem()
            item.title = node.name
            item.image = Self.icon(for: node)
            return item
        }
        // Changing the items invalidates AppKit layout; doing that inside SwiftUI's update pass throws.
        DispatchQueue.main.async {
            control.pathItems = items
        }
    }

    private static func icon(for node: Node) -> NSImage? {
        let image: NSImage?
        switch node.role {
        case .folder where node.parent == nil:
            image = NSWorkspace.shared.icon(forFile: node.path)
        case .folder:
            image = NSWorkspace.shared.icon(for: .folder)
        case .package, .file:
            image = NSWorkspace.shared.icon(forFile: node.path)
        default:
            image = NSImage(systemSymbolName: node.kind.symbol, accessibilityDescription: nil)
        }
        image?.size = NSSize(width: 16, height: 16)
        return image
    }

    @MainActor
    final class Coordinator: NSObject {
        let model: AppModel
        var nodes: [Node] = []
        var version = -1

        init(model: AppModel) { self.model = model }

        @objc func clicked(_ sender: NSPathControl) {
            guard let clicked = sender.clickedPathItem, let index = sender.pathItems.firstIndex(where: { $0 === clicked }), nodes.indices.contains(index) else { return }
            model.zoom(to: nodes[index])
        }
    }
}
