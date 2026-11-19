import Foundation

let homeDirectory = NSHomeDirectory()

func resolvePath(_ raw: String) -> String {
    let expanded = (raw as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
    return url.path.isEmpty ? "/" : url.path
}

func sizeArgument(_ params: Params, _ key: String, fallback: Int64) throws -> Int64 {
    guard let text = params.string(key) else { return fallback }
    let normalized = text.uppercased().replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "")
    let units: [(String, Int64)] = [
        ("TB", 1 << 40), ("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10),
        ("T", 1 << 40), ("G", 1 << 30), ("M", 1 << 20), ("K", 1 << 10), ("B", 1),
    ]
    for (suffix, factor) in units where normalized.hasSuffix(suffix) {
        guard let value = Double(normalized.dropLast(suffix.count)), value >= 0 else {
            throw ToolFailure("\(key): \(text) is not a size; use bytes or a suffix such as 500M or 2G")
        }
        return Int64(value * Double(factor))
    }
    guard let value = Double(normalized), value >= 0 else {
        throw ToolFailure("\(key): \(text) is not a size; use bytes or a suffix such as 500M or 2G")
    }
    return Int64(value)
}

func roleName(_ role: Node.Role) -> String {
    switch role {
    case .folder: "folder"
    case .file: "file"
    case .package: "package"
    case .remainder: "remainder"
    case .smallFiles: "small_files"
    case .unseen: "unseen"
    case .systemGroup: "system_group"
    case .systemVolume: "system_volume"
    }
}

func share(_ part: Int64, of total: Int64) -> Any {
    guard total > 0 else { return NSNull() }
    return (Double(part) / Double(total) * 1000).rounded() / 10
}

struct ScanOptions: Equatable {
    let minSize: Int64
}

struct ScanResult {
    let root: Node
    let path: String
    let options: ScanOptions
    let files: Int
    let bytes: Int64
    let unreadable: Int
    let seconds: Double
    let finishedAt: Date

    var summary: [String: Any] {
        [
            "path": path,
            "size": root.size,
            "size_h": Format.bytes(root.size),
            "files": files,
            "unreadable_folders": unreadable,
            "min_size": options.minSize,
            "scanned_in_seconds": (seconds * 10).rounded() / 10,
            "finished_at": finishedAt,
        ]
    }
}

private final class NodeBox: @unchecked Sendable {
    var node: Node?
}

final class ScanStore {
    private let lock = NSLock()
    private var scans: [String: ScanResult] = [:]

    func cached(path: String, options: ScanOptions, maxAge: Double) -> ScanResult? {
        lock.withLock {
            guard let scan = scans[path], scan.options == options else { return nil }
            guard Date().timeIntervalSince(scan.finishedAt) <= maxAge else { return nil }
            return scan
        }
    }

    func store(_ scan: ScanResult) {
        lock.withLock { scans[scan.path] = scan }
    }

    func newest(path: String) -> ScanResult? {
        lock.withLock { scans[path] }
    }

    var all: [ScanResult] {
        lock.withLock { scans.values.sorted { $0.finishedAt > $1.finishedAt } }
    }
}

func runScan(path: String, options: ScanOptions, maxSeconds: Double) throws -> ScanResult {
    var info = stat()
    guard lstat(path, &info) == 0 else { throw ToolFailure("\(path) does not exist or cannot be read") }
    let context = ScanContext()
    let scanner = ExactScanner(context: context, fileThreshold: options.minSize, folderThreshold: options.minSize)
    let box = NodeBox()
    let finished = DispatchSemaphore(value: 0)
    let started = Date()
    DispatchQueue.global(qos: .userInitiated).async {
        box.node = scanner.scan(path: path)
        finished.signal()
    }
    if finished.wait(timeout: .now() + maxSeconds) == .timedOut {
        context.cancel()
        finished.wait()
        let counted = context.snapshot
        throw ToolFailure(
            "the scan of \(path) was still running after \(Int(maxSeconds)) s "
                + "(\(Format.bytes(counted.bytes)) in \(counted.files) files so far); "
                + "raise max_seconds, scan a smaller path, or raise min_size"
        )
    }
    guard let root = box.node else { throw ToolFailure("\(path) could not be scanned") }
    root.fixedPath = path
    let counted = context.snapshot
    return ScanResult(
        root: root,
        path: path,
        options: options,
        files: counted.files,
        bytes: counted.bytes,
        unreadable: counted.unreadable,
        seconds: Date().timeIntervalSince(started),
        finishedAt: Date()
    )
}

func scanArguments(
    _ params: Params,
    defaultPath: String,
    defaultMinSize: Int64,
    defaultMaxAge: Double = 900,
    store: ScanStore
) throws -> ScanResult {
    let path = resolvePath(params.string("path") ?? defaultPath)
    let options = ScanOptions(minSize: try sizeArgument(params, "min_size", fallback: defaultMinSize))
    let maxAge = try params.seconds("max_age_seconds", fallback: defaultMaxAge, limit: 86400)
    if try !params.flag("refresh", fallback: false), let cached = store.cached(path: path, options: options, maxAge: maxAge) {
        return cached
    }
    let scan = try runScan(path: path, options: options, maxSeconds: try params.seconds("max_seconds", fallback: 50, limit: 900))
    store.store(scan)
    return scan
}

let scanSchemaProperties: [String: Any] = [
    "min_size": Schema.size("keep entries at least this big as separate rows; smaller ones are folded into one \"small files\" row. Bytes or a suffix: 50M, 2G"),
    "max_seconds": Schema.number("give up after this many seconds (default 50, max 900)"),
    "refresh": Schema.boolean("scan again instead of reusing the scan this server already has for the path"),
    "max_age_seconds": Schema.number("reuse a scan of the same path and min_size if it is younger than this (default 900)"),
]

func flatten(_ node: Node, into result: inout [Node]) {
    for child in node.children {
        result.append(child)
        flatten(child, into: &result)
    }
}

func entryJSON(_ node: Node, total: Int64) -> [String: Any] {
    var json: [String: Any] = [
        "name": node.name,
        "size": node.size,
        "size_h": Format.bytes(node.size),
        "files": node.fileCount,
        "role": roleName(node.role),
        "share_percent": share(node.size, of: total),
    ]
    if node.existsOnDisk { json["path"] = node.path }
    if node.role == .file || node.role == .package { json["kind"] = node.kind.title }
    return json
}

func treeJSON(_ node: Node, depth: Int, limit: Int, total: Int64) -> [String: Any] {
    var json = entryJSON(node, total: total)
    guard !node.children.isEmpty else { return json }
    guard depth > 0 else {
        json["children_count"] = node.children.count
        return json
    }
    let shown = Array(node.children.prefix(limit))
    json["children"] = shown.map { treeJSON($0, depth: depth - 1, limit: limit, total: total) }
    let rest = node.children.dropFirst(shown.count)
    if !rest.isEmpty {
        let bytes = rest.reduce(Int64(0)) { $0 + $1.size }
        json["rest"] = ["count": rest.count, "size": bytes, "size_h": Format.bytes(bytes)]
    }
    return json
}
