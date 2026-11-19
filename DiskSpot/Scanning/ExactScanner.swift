import Foundation

final class ScanContext: @unchecked Sendable {
    private struct LinkKey: Hashable {
        let device: Int32
        let inode: UInt64
    }

    private let lock = NSLock()
    private var files = 0
    private var bytes: Int64 = 0
    private var unreadable = 0
    private var cancelled = false
    private var seenLinks = Set<LinkKey>()

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }

    func add(files: Int, bytes: Int64, unreadable: Int = 0) {
        lock.withLock {
            self.files += files
            self.bytes += bytes
            self.unreadable += unreadable
        }
    }

    var snapshot: (files: Int, bytes: Int64, unreadable: Int) {
        lock.withLock { (files, bytes, unreadable) }
    }

    /// Hard-linked files are counted once, like `du` does.
    func firstSighting(device: Int32, inode: UInt64) -> Bool {
        lock.withLock { seenLinks.insert(LinkKey(device: device, inode: inode)).inserted }
    }
}

/// Folder totals collected during a walk. Small files and small folders are folded into one
/// aggregate so that scanning millions of cache files keeps the tree compact.
private struct Accumulator {
    var name: String
    var kept: [Node] = []
    var smallBytes: Int64 = 0
    var smallCount = 0
    var total: Int64 = 0
    var count = 0

    init(name: String, ownBytes: Int64 = 0) {
        self.name = name
        smallBytes = ownBytes
        total = ownBytes
    }

    mutating func addFile(size: Int64, name: @autoclosure () -> String, threshold: Int64) {
        total += size
        count += 1
        if size >= threshold {
            let fileName = name()
            let node = Node(name: fileName, role: .file, kind: FileKind.classify(name: fileName), size: size, fileCount: 1)
            node.isExact = true
            kept.append(node)
        } else {
            smallBytes += size
            smallCount += 1
        }
    }

    mutating func absorb(_ child: Accumulator, threshold: Int64) {
        total += child.total
        count += child.count
        if child.total >= threshold {
            kept.append(child.makeNode())
        } else {
            smallBytes += child.total
            smallCount += child.count
        }
    }

    func makeNode() -> Node {
        let node = Node(name: name, role: .folder, kind: .other, size: total, fileCount: count)
        var items = kept
        if smallBytes > 0 {
            let small = Node(name: "Мелкие файлы и папки", role: .smallFiles, kind: .smallFiles, size: smallBytes, fileCount: smallCount)
            small.isExact = true
            items.append(small)
        }
        items.sort { $0.size > $1.size }
        node.adopt(items)
        node.isExact = true
        return node
    }
}

struct ExactScanner: Sendable {
    let context: ScanContext
    var fileThreshold: Int64 = 1_000_000
    var folderThreshold: Int64 = 1_000_000
    /// Top levels are listed manually and walked in parallel; deeper levels go through fts.
    var splitDepth = 2

    /// Reading a dataless (evicted to iCloud) item would download it. With this policy such access
    /// fails instead, so a scan never pulls anything from the cloud.
    static func disableDatalessMaterialization() {
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    }

    func scan(path: String) -> Node? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let name = (path as NSString).lastPathComponent
        guard isDirectory(info), !isDataless(info) else {
            let size = Int64(info.st_blocks) * 512
            context.add(files: 1, bytes: size)
            let node = Node(name: name, role: .file, kind: FileKind.classify(name: name), size: size, fileCount: 1)
            node.isExact = true
            return node
        }
        guard var accumulator = scanDirectory(path: path, name: name, info: info, depth: splitDepth) else { return nil }
        accumulator.name = name
        return accumulator.makeNode()
    }

    /// Several roots at once; results keep the order of `paths`.
    func scan(paths: [String]) -> [(path: String, node: Node)] {
        var results = [Node?](repeating: nil, count: paths.count)
        results.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: paths.count) { index in
                buffer[index] = scan(path: paths[index])
            }
        }
        return zip(paths, results).compactMap { path, node in node.map { (path, $0) } }
    }

    private func isDirectory(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFDIR
    }

    private func isDataless(_ info: stat) -> Bool {
        info.st_flags & UInt32(SF_DATALESS) != 0
    }

    private func allocatedSize(_ info: stat, isRegularFile: Bool) -> Int64 {
        if isRegularFile, info.st_nlink > 1, !context.firstSighting(device: info.st_dev, inode: info.st_ino) {
            return 0
        }
        return Int64(info.st_blocks) * 512
    }

    private func scanDirectory(path: String, name: String, info: stat, depth: Int) -> Accumulator? {
        if context.isCancelled { return nil }
        if depth <= 0 { return walk(path: path, name: name) }

        let ownBytes = Int64(info.st_blocks) * 512
        var accumulator = Accumulator(name: name, ownBytes: ownBytes)
        guard let directory = opendir(path) else {
            context.add(files: 0, bytes: ownBytes, unreadable: 1)
            return accumulator
        }
        var subdirectories: [(path: String, name: String, info: stat)] = []
        var files = 0
        var bytes = ownBytes
        while let entry = readdir(directory) {
            let childName = withUnsafeBytes(of: &entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if childName == "." || childName == ".." { continue }
            let childPath = path == "/" ? "/" + childName : path + "/" + childName
            var childInfo = stat()
            guard lstat(childPath, &childInfo) == 0 else { continue }
            if isDirectory(childInfo) && isDataless(childInfo) {
                let own = Int64(childInfo.st_blocks) * 512
                accumulator.absorb(Accumulator(name: childName, ownBytes: own), threshold: folderThreshold)
                bytes += own
            } else if isDirectory(childInfo) {
                // A different device means a mount point (another volume, a disk image…).
                if childInfo.st_dev == info.st_dev {
                    subdirectories.append((childPath, childName, childInfo))
                }
            } else {
                let isRegular = (childInfo.st_mode & S_IFMT) == S_IFREG
                let size = allocatedSize(childInfo, isRegularFile: isRegular)
                accumulator.addFile(size: size, name: childName, threshold: fileThreshold)
                files += 1
                bytes += size
            }
        }
        closedir(directory)
        context.add(files: files, bytes: bytes)

        var results = [Accumulator?](repeating: nil, count: subdirectories.count)
        results.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: subdirectories.count) { index in
                let sub = subdirectories[index]
                buffer[index] = scanDirectory(path: sub.path, name: sub.name, info: sub.info, depth: depth - 1)
            }
        }
        if context.isCancelled { return nil }
        for case let child? in results {
            accumulator.absorb(child, threshold: folderThreshold)
        }
        return accumulator
    }

    private func walk(path: String, name: String) -> Accumulator? {
        guard let rootPath = strdup(path) else { return nil }
        defer { free(rootPath) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [rootPath, nil]
        guard let fts = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return nil }
        defer { fts_close(fts) }

        var stack: [Accumulator] = []
        var levels: [Int] = []
        var result: Accumulator?
        var pendingFiles = 0
        var pendingBytes: Int64 = 0
        var pendingUnreadable = 0
        var ticks = 0

        func flush() {
            context.add(files: pendingFiles, bytes: pendingBytes, unreadable: pendingUnreadable)
            pendingFiles = 0
            pendingBytes = 0
            pendingUnreadable = 0
        }

        func finish(_ folder: Accumulator) {
            if stack.isEmpty {
                result = folder
            } else {
                stack[stack.count - 1].absorb(folder, threshold: folderThreshold)
            }
        }

        while let entry = fts_read(fts) {
            ticks += 1
            if ticks & 0xFFF == 0 {
                flush()
                if context.isCancelled { return nil }
            }
            let kind = Int32(entry.pointee.fts_info)
            switch kind {
            case FTS_D:
                let own = entry.pointee.fts_statp.map { Int64($0.pointee.st_blocks) * 512 } ?? 0
                if let statPointer = entry.pointee.fts_statp, isDataless(statPointer.pointee) {
                    // fts then reports the folder as FTS_DP right away without reading it.
                    fts_set(fts, entry, FTS_SKIP)
                }
                pendingBytes += own
                stack.append(Accumulator(name: stack.isEmpty ? name : entryName(entry), ownBytes: own))
                levels.append(Int(entry.pointee.fts_level))
            case FTS_DP:
                guard let finished = stack.popLast() else { break }
                levels.removeLast()
                finish(finished)
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let statPointer = entry.pointee.fts_statp, !stack.isEmpty else { break }
                let size = allocatedSize(statPointer.pointee, isRegularFile: kind == FTS_F)
                pendingFiles += 1
                pendingBytes += size
                stack[stack.count - 1].addFile(size: size, name: entryName(entry), threshold: fileThreshold)
            case FTS_DNR, FTS_ERR:
                // A folder that could not be listed (permissions, SIP, privacy protection) comes back
                // as DNR/ERR instead of DP after its FTS_D; only its own blocks are known.
                if levels.last == Int(entry.pointee.fts_level), let opened = stack.popLast() {
                    levels.removeLast()
                    pendingUnreadable += 1
                    finish(opened)
                } else if kind == FTS_DNR {
                    let own = entry.pointee.fts_statp.map { Int64($0.pointee.st_blocks) * 512 } ?? 0
                    pendingUnreadable += 1
                    pendingBytes += own
                    finish(Accumulator(name: stack.isEmpty ? name : entryName(entry), ownBytes: own))
                }
            default:
                break
            }
        }
        flush()
        if !stack.isEmpty {
            // fts_read stopped early on an error: keep everything counted so far.
            context.add(files: 0, bytes: 0, unreadable: 1)
            while stack.count > 1 {
                let unfinished = stack.removeLast()
                stack[stack.count - 1].absorb(unfinished, threshold: folderThreshold)
            }
            result = stack.removeLast()
        }
        return result
    }

    private func entryName(_ entry: UnsafeMutablePointer<FTSENT>) -> String {
        let offset = MemoryLayout<FTSENT>.offset(of: \FTSENT.fts_name)!
        let start = UnsafeRawPointer(entry).advanced(by: offset).assumingMemoryBound(to: UInt8.self)
        return String(decoding: UnsafeBufferPointer(start: start, count: Int(entry.pointee.fts_namelen)), as: UTF8.self)
    }
}
