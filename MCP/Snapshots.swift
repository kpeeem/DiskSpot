import Foundation

struct SnapshotEntry: Codable {
    let path: String
    let size: Int64
    let files: Int
    let role: String
}

struct SnapshotHeader: Codable {
    let id: String
    let path: String
    let createdAt: Date
    let minSize: Int64
    let size: Int64
    let files: Int
    let unreadable: Int
    let label: String?

    var json: [String: Any] {
        [
            "id": id,
            "path": path,
            "created_at": createdAt,
            "min_size": minSize,
            "size": size,
            "size_h": Format.bytes(size),
            "files": files,
            "unreadable_folders": unreadable,
            "label": label as Any,
        ]
    }
}

struct Snapshot: Codable {
    let header: SnapshotHeader
    let entries: [SnapshotEntry]
}

private struct SnapshotFile: Codable {
    let header: SnapshotHeader
}

enum SnapshotStore {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: homeDirectory + "/Library/Application Support")
        return base.appendingPathComponent("diskspotmcp/snapshots", isDirectory: true)
    }()

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func identifier(path: String, at date: Date) -> String {
        let tail = (path as NSString).lastPathComponent
        let name = tail.isEmpty || tail == "/" ? "root" : tail
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
        return stamp.string(from: date) + "-" + safe
    }

    static func save(header: SnapshotHeader, entries: [SnapshotEntry]) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(header.id + ".json")
        try encoder.encode(Snapshot(header: header, entries: entries)).write(to: url, options: .atomic)
        return url
    }

    static func headers() -> [SnapshotHeader] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return (try? decoder.decode(SnapshotFile.self, from: data))?.header
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func load(_ id: String) throws -> Snapshot {
        let url = directory.appendingPathComponent(id + ".json")
        guard let data = try? Data(contentsOf: url) else {
            throw ToolFailure("no snapshot \(id); disk_status lists the stored ones")
        }
        return try decoder.decode(Snapshot.self, from: data)
    }

    static func remove(_ id: String) throws {
        let url = directory.appendingPathComponent(id + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolFailure("no snapshot \(id); disk_status lists the stored ones")
        }
        try FileManager.default.removeItem(at: url)
    }
}

func snapshotEntries(_ scan: ScanResult) -> [SnapshotEntry] {
    var nodes: [Node] = []
    flatten(scan.root, into: &nodes)
    var entries = [SnapshotEntry(path: scan.path, size: scan.root.size, files: scan.root.fileCount, role: roleName(scan.root.role))]
    for node in nodes where node.existsOnDisk {
        entries.append(SnapshotEntry(path: node.path, size: node.size, files: node.fileCount, role: roleName(node.role)))
    }
    return entries
}

struct Change {
    let path: String
    let role: String
    let before: Int64
    let after: Int64

    var delta: Int64 { after - before }

    var json: [String: Any] {
        [
            "path": path,
            "role": role,
            "before": before,
            "before_h": Format.bytes(before),
            "after": after,
            "after_h": Format.bytes(after),
            "delta": delta,
            "delta_h": (delta < 0 ? "−" : "+") + Format.bytes(abs(delta)),
        ]
    }
}

func changes(from: [SnapshotEntry], to: [SnapshotEntry]) -> [Change] {
    let before = Dictionary(from.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    let after = Dictionary(to.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    var result: [Change] = []
    for (path, entry) in after {
        let old = before[path]
        result.append(Change(path: path, role: entry.role, before: old?.size ?? 0, after: entry.size))
    }
    for (path, entry) in before where after[path] == nil {
        result.append(Change(path: path, role: entry.role, before: entry.size, after: 0))
    }
    return result
}
