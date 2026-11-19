import AppKit

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

@MainActor
enum NodeMenu {
    static func make(for node: Node, model: AppModel) -> NSMenu {
        let menu = NSMenu()
        items(for: node, model: model).forEach(menu.addItem)
        return menu
    }

    static func items(for node: Node, model: AppModel) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if node.existsOnDisk {
            items.append(ClosureMenuItem("Показать в Finder", symbol: "folder") { model.reveal(node) })
        }
        if !node.children.isEmpty {
            items.append(ClosureMenuItem("Приблизить", symbol: "plus.magnifyingglass") { model.zoom(to: node) })
        }
        if node.role == .unseen || node === model.root {
            let title = model.scope.kind == .volume ? "Посчитать весь том точно" : "Посчитать всю папку точно"
            items.append(ClosureMenuItem(title, symbol: "scope") { model.scanEverythingExactly() })
        } else if node.isDirectory && node.existsOnDisk {
            items.append(ClosureMenuItem("Посчитать точно", symbol: "scope") { model.scanExactly(node) })
        }
        if node.existsOnDisk {
            items.append(ClosureMenuItem("Скопировать путь", symbol: "doc.on.doc") { model.copyPath(node) })
        }
        if model.canTrash(node) {
            items.append(.separator())
            items.append(ClosureMenuItem("Переместить в Корзину…", symbol: "trash") { model.confirmTrash(node) })
        }
        return items
    }
}
