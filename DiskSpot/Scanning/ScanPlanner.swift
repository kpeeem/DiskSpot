import Foundation

struct Scope: Equatable, Sendable {
    enum Kind: Sendable { case volume, folder }

    let path: String
    let name: String
    let kind: Kind

    var isBoot: Bool { path == "/" }

    static var boot: Scope { Scope(path: "/", name: Volumes.name(of: "/"), kind: .volume) }
}

struct BlindSpot: Identifiable, Sendable {
    enum Reason: Sendable { case library, hidden, system, exclusion, notIndexed }
    enum State: Sendable, Equatable { case pending, scanning, done }

    let id = UUID()
    let title: String
    let detail: String
    let paths: [String]
    let reason: Reason
    var state: State = .pending
    var size: Int64 = 0

    func with(paths: [String]) -> BlindSpot {
        BlindSpot(title: title, detail: detail, paths: paths, reason: reason)
    }
}

struct PreparedScan: @unchecked Sendable {
    let root: Node
    let unseen: Node?
    let space: SpaceStats?
    let blindSpots: [BlindSpot]
    let hitCount: Int
    let queryDuration: TimeInterval
}

func isInside(_ path: String, _ folder: String) -> Bool {
    if path == folder || folder == "/" { return true }
    return path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
}

enum ScanPlanner {
    static func prepare(scope: Scope, threshold: Int64, exclusions: [String]) -> PreparedScan {
        var (spots, whole) = BlindSpotPlanner.plan(scope: scope, exclusions: exclusions)

        let started = Date()
        let hits = whole ? [] : Spotlight.bigItems(in: scope.path, minSize: threshold)
        let duration = Date().timeIntervalSince(started)
        if hits.isEmpty && !whole {
            // Nothing big in the index: indexing is off for this volume or the folder is not indexed.
            spots = [BlindSpotPlanner.wholeScope(scope)]
        }

        let skipped = spots.flatMap(\.paths) + ignoredPrefixes(for: scope)
        let builder = TreeBuilder(rootPath: scope.path, name: scope.name)
        var used = 0
        for hit in hits where !skipped.contains(where: { isInside(hit.path, $0) }) {
            builder.insert(path: hit.path, size: hit.size)
            used += 1
        }
        let root = builder.finish()

        var space: SpaceStats?
        var unseen: Node?
        if scope.kind == .volume, let stats = Volumes.space(at: scope.path) {
            space = stats
            if scope.isBoot {
                attachSystemVolumes(to: root)
            }
            let node = Node(name: "Не видно Spotlight", role: .unseen, kind: .unseen)
            root.refreshUnseen(node, used: stats.used)
            unseen = node
        }
        return PreparedScan(root: root, unseen: unseen, space: space, blindSpots: spots, hitCount: used, queryDuration: duration)
    }

    private static func attachSystemVolumes(to root: Node) {
        let volumes = Volumes.systemVolumes()
        guard !volumes.isEmpty else { return }
        let group = Node(name: "Системные тома APFS", role: .systemGroup, kind: .system)
        for volume in volumes {
            let node = Node(name: volume.name, role: .systemVolume, kind: .system, size: volume.used)
            node.fixedPath = volume.mountPoint
            group.append(node)
            group.size += volume.used
        }
        group.sortChildren()
        root.append(group)
        root.size += group.size
        root.sortChildren()
    }

    /// Paths whose Spotlight hits would be counted twice or belong to another volume.
    private static func ignoredPrefixes(for scope: Scope) -> [String] {
        var prefixes = Volumes.mountPoints().filter { mount in
            mount != "/" && mount != Volumes.dataVolume && mount != scope.path && isInside(mount, scope.path)
        }
        if scope.isBoot {
            // The sealed system volume is accounted for through statfs.
            prefixes += ["/System", "/usr", "/bin", "/sbin", "/dev"]
        }
        return prefixes
    }
}

enum BlindSpotPlanner {
    static func plan(scope: Scope, exclusions: [String]) -> (spots: [BlindSpot], whole: Bool) {
        let home = NSHomeDirectory()
        let onBootVolume = !scope.path.hasPrefix("/Volumes/")
        var candidates: [BlindSpot] = []

        if onBootVolume {
            candidates.append(BlindSpot(
                title: "Библиотека пользователя",
                detail: "~/Library — Spotlight индексирует её лишь частично",
                paths: [home + "/Library"],
                reason: .library
            ))
            let hidden = hiddenEntries(in: home)
            if !hidden.isEmpty {
                candidates.append(BlindSpot(
                    title: "Скрытые папки дома",
                    detail: "~/.* — Spotlight пропускает имена с точкой",
                    paths: hidden,
                    reason: .hidden
                ))
            }
            let system = systemPaths()
            if !system.isEmpty {
                candidates.append(BlindSpot(
                    title: "Системные папки",
                    detail: "/Library, /private, /opt, /usr/local и кэши /System",
                    paths: system,
                    reason: .system
                ))
            }
        }

        let covered = candidates.flatMap(\.paths)
        for exclusion in exclusions where !covered.contains(where: { isInside(exclusion, $0) }) {
            candidates.append(BlindSpot(
                title: (exclusion as NSString).lastPathComponent,
                detail: "Исключено из Spotlight в Настройках",
                paths: [exclusion],
                reason: .exclusion
            ))
        }

        let blindPaths = candidates.flatMap(\.paths) + exclusions
        let hasHiddenComponent = scope.path.split(separator: "/").contains { $0.hasPrefix(".") }
        if hasHiddenComponent || blindPaths.contains(where: { isInside(scope.path, $0) }) {
            return ([wholeScope(scope)], true)
        }

        var spots = candidates.compactMap { spot -> BlindSpot? in
            let inside = spot.paths.filter { $0 != scope.path && isInside($0, scope.path) }
            return inside.isEmpty ? nil : spot.with(paths: inside)
        }
        if scope.path != home && scope.path != "/" {
            let known = spots.flatMap(\.paths)
            let hidden = hiddenEntries(in: scope.path).filter { !known.contains($0) }
            if !hidden.isEmpty {
                spots.append(BlindSpot(
                    title: "Скрытые папки",
                    detail: "Имена с точкой внутри \(scope.name)",
                    paths: hidden,
                    reason: .hidden
                ))
            }
        }
        return (spots, false)
    }

    static func wholeScope(_ scope: Scope) -> BlindSpot {
        BlindSpot(
            title: scope.name,
            detail: "Spotlight не видит это место — считаю точным обходом",
            paths: [scope.path],
            reason: .notIndexed
        )
    }

    /// Hidden folders, plus hidden files big enough to matter.
    private static func hiddenEntries(in folder: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names
            .filter { $0.hasPrefix(".") }
            .map { folder == "/" ? "/" + $0 : folder + "/" + $0 }
            .filter { path in
                var info = stat()
                guard lstat(path, &info) == 0 else { return false }
                return (info.st_mode & S_IFMT) == S_IFDIR || Int64(info.st_blocks) * 512 >= 1_000_000
            }
            .sorted()
    }

    private static func systemPaths() -> [String] {
        let userContent: Set<String> = ["/Users", "/Applications", "/Volumes"]
        return Volumes.firmlinks()
            .map(\.source)
            .filter { !userContent.contains($0) }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }
}

final class TreeBuilder {
    let root: Node
    private let prefix: String

    init(rootPath: String, name: String) {
        root = Node(name: name, role: .folder, kind: .other)
        root.fixedPath = rootPath
        prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    }

    func insert(path: String, size: Int64) {
        guard path.hasPrefix(prefix) else { return }
        let components = path.dropFirst(prefix.count).split(separator: "/")
        guard !components.isEmpty else { return }
        var node = root
        for (position, component) in components.enumerated() {
            let isLast = position == components.count - 1
            let key = String(component)
            if let next = node.childIndex?[key] {
                if isLast {
                    next.size = max(next.size, size)
                    if next.role == .folder {
                        next.role = .package
                        next.kind = FileKind.classify(name: key)
                    }
                } else if next.role == .file {
                    next.role = .package
                }
                node = next
            } else {
                let child = isLast
                    ? Node(name: key, role: .file, kind: FileKind.classify(name: key), size: size, fileCount: 1)
                    : Node(name: key, role: .folder, kind: .other)
                node.append(child)
                if node.childIndex == nil { node.childIndex = [:] }
                node.childIndex![key] = child
                node = child
            }
        }
    }

    func finish() -> Node {
        Self.finalize(root)
        return root
    }

    private static func finalize(_ node: Node) {
        node.childIndex = nil
        guard !node.children.isEmpty else { return }
        var sum: Int64 = 0
        var count = 0
        for child in node.children {
            finalize(child)
            sum += child.size
            count += child.fileCount
        }
        if node.size > sum {
            // Spotlight stores the full size of a package but indexes only part of its contents.
            node.append(Node(name: "Остальное содержимое", role: .remainder, kind: node.kind, size: node.size - sum))
        } else {
            node.size = sum
        }
        node.fileCount = count
        node.sortChildren()
    }
}

extension Node {
    /// Keeps `unseen` equal to the space the volume reports as used minus everything we can see.
    func refreshUnseen(_ unseen: Node, used: Int64) {
        let visible = children.filter { $0 !== unseen }.reduce(Int64(0)) { $0 + $1.size }
        let hidden = max(0, used - visible)
        let attached = children.contains { $0 === unseen }
        unseen.size = hidden
        if hidden > 0 && !attached {
            append(unseen)
        } else if hidden == 0 && attached {
            children.removeAll { $0 === unseen }
            unseen.parent = nil
        }
        size = visible + hidden
        sortChildren()
    }
}
