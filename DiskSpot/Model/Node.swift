import Foundation

final class Node: @unchecked Sendable {
    enum Role: UInt8 {
        case folder
        case file
        case package
        case remainder
        case smallFiles
        case unseen
        case systemGroup
        case systemVolume
    }

    var name: String
    var role: Role
    var kind: FileKind
    weak var parent: Node?
    var children: [Node] = []
    var size: Int64
    var fileCount: Int
    var isExact = false
    var fixedPath: String?
    var childIndex: [String: Node]?

    init(name: String, role: Role, kind: FileKind, size: Int64 = 0, fileCount: Int = 0) {
        self.name = name
        self.role = role
        self.kind = kind
        self.size = size
        self.fileCount = fileCount
    }

    var isSynthetic: Bool {
        switch role {
        case .folder, .file, .package: false
        default: true
        }
    }

    var isDirectory: Bool { role == .folder || role == .package }

    var path: String {
        if let fixedPath { return fixedPath }
        guard let parent else { return name }
        let base = parent.path
        if isSynthetic { return base }
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }

    var existsOnDisk: Bool { !isSynthetic || role == .systemVolume }

    var url: URL? { existsOnDisk ? URL(fileURLWithPath: path) : nil }

    var dominantKind: FileKind {
        var node = self
        while let first = node.children.first { node = first }
        return node.kind
    }

    func isInside(_ other: Node) -> Bool {
        var current: Node? = self
        while let node = current {
            if node === other { return true }
            current = node.parent
        }
        return false
    }

    var chain: [Node] {
        var result: [Node] = []
        var current: Node? = self
        while let node = current {
            result.append(node)
            current = node.parent
        }
        return result.reversed()
    }

    func sortChildren() {
        children.sort { $0.size > $1.size }
    }

    func adopt(_ nodes: [Node]) {
        for old in children where old.parent === self { old.parent = nil }
        children = nodes
        for node in nodes { node.parent = self }
    }

    func append(_ node: Node) {
        node.parent = self
        children.append(node)
    }

    func propagate(sizeDelta: Int64, fileDelta: Int) {
        var current = parent
        while let node = current {
            node.size += sizeDelta
            node.fileCount += fileDelta
            node.sortChildren()
            current = node.parent
        }
    }

    func detach() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        parent.size -= size
        parent.fileCount -= fileCount
        parent.propagate(sizeDelta: -size, fileDelta: -fileCount)
        self.parent = nil
    }

    func realChild(named name: String) -> Node? {
        children.first { !$0.isSynthetic && $0.name == name }
    }

    /// Walks (and optionally creates) folders down to `absolutePath`, which must lie inside this node.
    func descendant(at absolutePath: String, create: Bool) -> Node? {
        let base = path
        if absolutePath == base { return self }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard absolutePath.hasPrefix(prefix) else { return nil }
        var node = self
        for component in absolutePath.dropFirst(prefix.count).split(separator: "/") {
            let name = String(component)
            if let next = node.realChild(named: name) {
                node = next
            } else if create {
                let next = Node(name: name, role: .folder, kind: .other)
                node.append(next)
                node = next
            } else {
                return nil
            }
        }
        return node
    }

    func descendant(relativePath: String) -> Node? {
        var node = self
        for component in relativePath.split(separator: "/") {
            guard let next = node.realChild(named: String(component)) else { return nil }
            node = next
        }
        return node
    }
}
