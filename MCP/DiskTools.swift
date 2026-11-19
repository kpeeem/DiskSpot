import Foundation

func syncTool(_ name: String, _ description: String, _ schema: [String: Any], _ body: @escaping (Params) throws -> Any) -> Tool {
    Tool(name: name, description: description, schema: schema) { params, completion in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                completion(.success(try body(params)))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

func spaceJSON(_ space: SpaceStats) -> [String: Any] {
    [
        "total": space.total,
        "total_h": Format.bytes(space.total),
        "used": space.used,
        "used_h": Format.bytes(space.used),
        "available": space.available,
        "available_h": Format.bytes(space.available),
        "purgeable": space.purgeable,
        "purgeable_h": Format.bytes(space.purgeable),
        "used_percent": share(space.used, of: space.total),
    ]
}

private func withScanProperties(_ properties: [String: Any]) -> [String: Any] {
    properties.merging(scanSchemaProperties) { own, _ in own }
}

func makeDiskTools(_ store: ScanStore) -> [Tool] {
    [
        syncTool(
            "disk_status",
            "Whether this server can read every folder, which folders Spotlight does not index, and the scans and snapshots it holds.",
            Schema.object([:])
        ) { _ in
            [
                "full_disk_access": Permissions.hasFullDiskAccess(),
                "boot_volume": Volumes.space(at: "/").map { spaceJSON($0) } as Any,
                "spotlight_exclusions": Spotlight.exclusions(),
                "snapshot_directory": SnapshotStore.directory.path,
                "snapshots": SnapshotStore.headers().map(\.json),
                "scans_in_memory": store.all.map(\.summary),
            ]
        },

        syncTool(
            "disk_volumes",
            "Every local volume with total, used, free and purgeable space, plus the other APFS volumes of the boot container (sealed system, VM swap, Preboot) whose contents no file walk sees.",
            Schema.object([:])
        ) { _ in
            [
                "volumes": Volumes.list().map { entry -> [String: Any] in
                    var json: [String: Any] = ["path": entry.path, "name": entry.name, "boot": entry.isBoot]
                    if let space = entry.space { json["space"] = spaceJSON(space) }
                    return json
                },
                "system_volumes": Volumes.systemVolumes().map {
                    ["name": $0.name, "mount_point": $0.mountPoint, "used": $0.used, "used_h": Format.bytes($0.used)]
                },
                "data_volume": Volumes.dataVolume,
            ]
        },

        syncTool(
            "disk_tree",
            "Exact sizes as a tree, the way du counts them: allocated blocks, hard links once, nothing downloaded from iCloud. Mount points are not followed. Entries below min_size are folded into one \"small files\" row per folder.",
            Schema.object(withScanProperties([
                "path": Schema.text("folder to measure (default ~)"),
                "depth": Schema.integer("levels of children to return (default 2, max 8)"),
                "limit": Schema.integer("children per level (default 12, max 100)"),
            ]))
        ) { params in
            let scan = try scanArguments(params, defaultPath: "~", defaultMinSize: 100 << 20, store: store)
            let depth = try params.count("depth", fallback: 2, limit: 8)
            let limit = try params.count("limit", fallback: 12, limit: 100)
            return ["scan": scan.summary, "tree": treeJSON(scan.root, depth: depth, limit: limit, total: scan.root.size)]
        },

        syncTool(
            "disk_top",
            "The heaviest folders and files anywhere under a path, flat and sorted by size, from the same exact scan disk_tree uses.",
            Schema.object(withScanProperties([
                "path": Schema.text("folder to measure (default ~)"),
                "kind": Schema.choice("what to list (default both)", ["folders", "files", "both"]),
                "limit": Schema.integer("entries to return (default 20, max 200)"),
            ]))
        ) { params in
            let scan = try scanArguments(params, defaultPath: "~", defaultMinSize: 50 << 20, store: store)
            let kind = try params.choice("kind", options: ["folders", "files", "both"], fallback: "both")
            let limit = try params.count("limit", fallback: 20, limit: 200)
            var nodes: [Node] = []
            flatten(scan.root, into: &nodes)
            let wanted = nodes.filter { node in
                switch kind {
                case "folders": node.isDirectory
                case "files": node.role == .file || node.role == .package
                default: node.existsOnDisk
                }
            }
            let top = wanted.sorted { $0.size > $1.size }.prefix(limit)
            return [
                "scan": scan.summary,
                "kind": kind,
                "entries": top.map { entryJSON($0, total: scan.root.size) },
            ]
        },

        syncTool(
            "disk_big_files",
            "Big files straight from the Spotlight index, with no walk: an answer in a second for a whole volume. Folders have no size in the index and excluded folders are missing, so use disk_top for folder totals.",
            Schema.object([
                "scope": Schema.text("folder to search in (default ~)"),
                "min_size": Schema.size("smallest file to report (default 500M)"),
                "limit": Schema.integer("files to return (default 40, max 500)"),
            ])
        ) { params in
            let scope = resolvePath(params.string("scope") ?? "~")
            let minSize = try sizeArgument(params, "min_size", fallback: 500 << 20)
            let limit = try params.count("limit", fallback: 40, limit: 500)
            let hits = Spotlight.bigItems(in: scope, minSize: minSize).sorted { $0.size > $1.size }
            let total = hits.reduce(Int64(0)) { $0 + $1.size }
            return [
                "scope": scope,
                "min_size": minSize,
                "found": hits.count,
                "total_size": total,
                "total_size_h": Format.bytes(total),
                "items": hits.prefix(limit).map { hit in
                    [
                        "path": hit.path,
                        "size": hit.size,
                        "size_h": Format.bytes(hit.size),
                        "kind": FileKind.classify(name: (hit.path as NSString).lastPathComponent).title,
                    ]
                },
            ]
        },

        syncTool(
            "disk_recent",
            "What has been written lately: files at least min_size whose contents changed in the last days, from the Spotlight index, summed per folder. This is the fastest answer to \"what filled the disk recently\".",
            Schema.object([
                "scope": Schema.text("folder to search in (default ~)"),
                "days": Schema.number("how far back to look (default 7, max 365)"),
                "min_size": Schema.size("smallest file to count (default 50M)"),
                "limit": Schema.integer("rows per list (default 25, max 200)"),
            ])
        ) { params in
            let scope = resolvePath(params.string("scope") ?? "~")
            let minSize = try sizeArgument(params, "min_size", fallback: 50 << 20)
            let limit = try params.count("limit", fallback: 25, limit: 200)
            let days = min(max(try params.number("days") ?? 7, 0.01), 365)
            let hits = Spotlight.recentItems(in: scope, minSize: minSize, seconds: days * 86400)
            let total = hits.reduce(Int64(0)) { $0 + $1.size }
            let prefix = scope.hasSuffix("/") ? scope : scope + "/"
            var byFolder: [String: (bytes: Int64, files: Int)] = [:]
            var byBranch: [String: (bytes: Int64, files: Int)] = [:]
            for hit in hits {
                let parent = (hit.path as NSString).deletingLastPathComponent
                byFolder[parent, default: (0, 0)].bytes += hit.size
                byFolder[parent, default: (0, 0)].files += 1
                guard hit.path.hasPrefix(prefix) else { continue }
                let first = hit.path.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
                let branch = first.map { prefix + $0 } ?? scope
                byBranch[branch, default: (0, 0)].bytes += hit.size
                byBranch[branch, default: (0, 0)].files += 1
            }
            func rows(_ groups: [String: (bytes: Int64, files: Int)]) -> [[String: Any]] {
                groups.sorted { $0.value.bytes > $1.value.bytes }.prefix(limit).map { entry in
                    [
                        "path": entry.key,
                        "size": entry.value.bytes,
                        "size_h": Format.bytes(entry.value.bytes),
                        "files": entry.value.files,
                        "share_percent": share(entry.value.bytes, of: total),
                    ]
                }
            }
            return [
                "scope": scope,
                "days": days,
                "min_size": minSize,
                "found": hits.count,
                "total_size": total,
                "total_size_h": Format.bytes(total),
                "branches": rows(byBranch),
                "folders": rows(byFolder),
                "items": hits.sorted { $0.size > $1.size }.prefix(limit).map { hit in
                    [
                        "path": hit.path,
                        "size": hit.size,
                        "size_h": Format.bytes(hit.size),
                        "changed_at": hit.changed as Any,
                        "kind": FileKind.classify(name: (hit.path as NSString).lastPathComponent).title,
                    ]
                },
            ]
        },

        syncTool(
            "disk_snapshot",
            "Measure a path exactly and store the result, so that disk_diff can later say what grew. Snapshots are JSON files under Application Support and hold every folder and file at least min_size.",
            Schema.object(withScanProperties([
                "path": Schema.text("folder to measure (default ~)"),
                "label": Schema.text("note to keep with the snapshot"),
            ]))
        ) { params in
            let scan = try scanArguments(params, defaultPath: "~", defaultMinSize: 50 << 20, defaultMaxAge: 60, store: store)
            let created = Date()
            let header = SnapshotHeader(
                id: SnapshotStore.identifier(path: scan.path, at: created),
                path: scan.path,
                createdAt: created,
                minSize: scan.options.minSize,
                size: scan.root.size,
                files: scan.files,
                unreadable: scan.unreadable,
                label: params.string("label")
            )
            let entries = snapshotEntries(scan)
            let url = try SnapshotStore.save(header: header, entries: entries)
            return ["snapshot": header.json, "entries": entries.count, "file": url.path, "scan": scan.summary]
        },

        syncTool(
            "disk_diff",
            "What changed between a snapshot and now (or between two snapshots): folders and files that grew, appeared, shrank or went away, biggest change first.",
            Schema.object([
                "from": Schema.text("snapshot id; without it the newest snapshot of path"),
                "to": Schema.text("snapshot id, or now for a fresh scan (default now)"),
                "path": Schema.text("which snapshots to choose from when from is omitted (default the newest of any path)"),
                "min_delta": Schema.size("ignore changes smaller than this (default 10M)"),
                "limit": Schema.integer("rows per list (default 15, max 200)"),
                "max_seconds": Schema.number("give up on the fresh scan after this many seconds (default 50, max 900)"),
            ])
        ) { params in
            let headers = SnapshotStore.headers()
            guard !headers.isEmpty else { throw ToolFailure("no snapshots yet; call disk_snapshot first") }
            let fromHeader: SnapshotHeader
            if let id = params.string("from") {
                guard let found = headers.first(where: { $0.id == id }) else {
                    throw ToolFailure("no snapshot \(id); disk_status lists the stored ones")
                }
                fromHeader = found
            } else if let path = params.string("path").map(resolvePath) {
                guard let found = headers.first(where: { $0.path == path }) else {
                    throw ToolFailure("no snapshot of \(path); disk_status lists the stored ones")
                }
                fromHeader = found
            } else {
                fromHeader = headers[0]
            }
            let from = try SnapshotStore.load(fromHeader.id)
            let limit = try params.count("limit", fallback: 15, limit: 200)
            let minDelta = try sizeArgument(params, "min_delta", fallback: 10 << 20)
            let target = params.string("to") ?? "now"
            let toEntries: [SnapshotEntry]
            let toSummary: [String: Any]
            if target.lowercased() == "now" {
                let scan = try runScan(
                    path: from.header.path,
                    options: ScanOptions(minSize: from.header.minSize),
                    maxSeconds: try params.seconds("max_seconds", fallback: 50, limit: 900)
                )
                store.store(scan)
                toEntries = snapshotEntries(scan)
                toSummary = scan.summary
            } else {
                let other = try SnapshotStore.load(target)
                guard other.header.path == from.header.path else {
                    throw ToolFailure("\(other.header.id) measured \(other.header.path), not \(from.header.path)")
                }
                toEntries = other.entries
                toSummary = other.header.json
            }
            let all = changes(from: from.entries, to: toEntries)
            let significant = all.filter { abs($0.delta) >= minDelta }
            let root = all.first { $0.path == from.header.path }
            return [
                "from": from.header.json,
                "to": toSummary,
                "min_delta": minDelta,
                "total_delta": root?.delta as Any,
                "total_delta_h": root.map { ($0.delta < 0 ? "−" : "+") + Format.bytes(abs($0.delta)) } as Any,
                "grown": significant.filter { $0.delta > 0 && $0.before > 0 }.sorted { $0.delta > $1.delta }.prefix(limit).map(\.json),
                "appeared": significant.filter { $0.before == 0 }.sorted { $0.delta > $1.delta }.prefix(limit).map(\.json),
                "shrunk": significant.filter { $0.delta < 0 && $0.after > 0 }.sorted { $0.delta < $1.delta }.prefix(limit).map(\.json),
                "gone": significant.filter { $0.after == 0 }.sorted { $0.delta < $1.delta }.prefix(limit).map(\.json),
            ]
        },

        syncTool(
            "disk_snapshot_forget",
            "Delete a stored snapshot.",
            Schema.object(["id": Schema.text("snapshot id")], required: ["id"])
        ) { params in
            let id = try params.requiredString("id")
            try SnapshotStore.remove(id)
            return ["forgotten": id, "snapshots": SnapshotStore.headers().map(\.json)]
        },
    ]
}
