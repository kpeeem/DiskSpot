import Foundation
import Synchronization

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

    func firstSighting(device: Int32, inode: UInt64) -> Bool {
        lock.withLock { seenLinks.insert(LinkKey(device: device, inode: inode)).inserted }
    }
}

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

private struct DirectoryEntry {
    let name: String
    let isDirectory: Bool
    let isRegular: Bool
    let device: Int32
    let inode: UInt64
    let links: UInt32
    let allocated: Int64
    let isDataless: Bool
    let isMountPoint: Bool

    init(name: String, info: stat) {
        self.name = name
        let type = info.st_mode & S_IFMT
        isDirectory = type == S_IFDIR
        isRegular = type == S_IFREG
        device = info.st_dev
        inode = info.st_ino
        links = UInt32(info.st_nlink)
        allocated = isDirectory ? 0 : Int64(info.st_blocks) * 512
        isDataless = info.st_flags & UInt32(SF_DATALESS) != 0
        isMountPoint = false
    }

    init(name: String, type: UInt32, device: Int32, inode: UInt64, flags: UInt32, links: UInt32, allocated: Int64, mountStatus: UInt32) {
        self.name = name
        isDirectory = type == VDIR.rawValue
        isRegular = type == VREG.rawValue
        self.device = device
        self.inode = inode
        self.links = links
        self.allocated = max(0, allocated)
        isDataless = flags & UInt32(SF_DATALESS) != 0
        isMountPoint = mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0
    }
}

private enum BulkDirectory {
    static let bufferSize = 128 * 1024
    static let openFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    private static let common = UInt32(ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FLAGS | ATTR_CMN_FILEID)
    private static let file = UInt32(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)

    private static let attributes: attrlist = {
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.commonattr = common | UInt32(ATTR_CMN_ERROR) | ATTR_CMN_RETURNED_ATTRS
        list.dirattr = UInt32(ATTR_DIR_MOUNTSTATUS)
        list.fileattr = file
        return list
    }()

    static let raisedDescriptorLimit: Void = {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let wanted = min(limit.rlim_max, rlim_t(OPEN_MAX))
        if limit.rlim_cur < wanted {
            limit.rlim_cur = wanted
            setrlimit(RLIMIT_NOFILE, &limit)
        }
    }()

    private struct Cursor {
        let bytes: UnsafeRawBufferPointer
        var offset: Int

        mutating func take<T>(_ type: T.Type) -> T? {
            guard offset + MemoryLayout<T>.size <= bytes.count else { return nil }
            let value = bytes.loadUnaligned(fromByteOffset: offset, as: type)
            offset += MemoryLayout<T>.size
            return value
        }
    }

    static func read(_ descriptor: Int32, buffer: UnsafeMutableRawBufferPointer, _ body: (DirectoryEntry) -> Void) -> Bool {
        var request = attributes
        var delivered = false
        while true {
            let count = getattrlistbulk(descriptor, &request, buffer.baseAddress, buffer.count, UInt64(FSOPT_RETURN_REALDEV))
            if count == 0 { return true }
            if count < 0 { return delivered ? false : readEntries(descriptor, body) }
            delivered = true
            var position = 0
            for _ in 0..<count {
                guard position + MemoryLayout<UInt32>.size <= buffer.count else { return true }
                let length = Int(buffer.loadUnaligned(fromByteOffset: position, as: UInt32.self))
                guard length >= 24, position + length <= buffer.count else { return true }
                let record = UnsafeRawBufferPointer(rebasing: buffer[position..<(position + length)])
                position += length
                if let entry = decode(record, descriptor: descriptor) { body(entry) }
            }
        }
    }

    private static func readEntries(_ descriptor: Int32, _ body: (DirectoryEntry) -> Void) -> Bool {
        let copy = dup(descriptor)
        guard copy >= 0 else { return false }
        guard let directory = fdopendir(copy) else {
            close(copy)
            return false
        }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            body(DirectoryEntry(name: name, info: info))
        }
        return true
    }

    private static func decode(_ record: UnsafeRawBufferPointer, descriptor: Int32) -> DirectoryEntry? {
        var cursor = Cursor(bytes: record, offset: MemoryLayout<UInt32>.size)
        guard let returned = cursor.take(attribute_set_t.self) else { return nil }
        let error = returned.commonattr & UInt32(ATTR_CMN_ERROR) != 0 ? cursor.take(UInt32.self) ?? 1 : 0
        guard returned.commonattr & UInt32(ATTR_CMN_NAME) != 0 else { return nil }
        let referenceOffset = cursor.offset
        guard let reference = cursor.take(attrreference_t.self) else { return nil }
        let start = referenceOffset + Int(reference.attr_dataoffset)
        let nameLength = Int(reference.attr_length)
        guard nameLength > 0, start >= cursor.offset, start + nameLength <= record.count, record[start + nameLength - 1] == 0 else { return nil }
        let name = String(decoding: UnsafeRawBufferPointer(rebasing: record[start..<(start + nameLength - 1)]), as: UTF8.self)
        let device = returned.commonattr & UInt32(ATTR_CMN_DEVID) != 0 ? cursor.take(Int32.self) ?? -1 : -1
        let type = returned.commonattr & UInt32(ATTR_CMN_OBJTYPE) != 0 ? cursor.take(UInt32.self) ?? 0 : 0
        let flags = returned.commonattr & UInt32(ATTR_CMN_FLAGS) != 0 ? cursor.take(UInt32.self) ?? 0 : 0
        let inode = returned.commonattr & UInt32(ATTR_CMN_FILEID) != 0 ? cursor.take(UInt64.self) ?? 0 : 0
        let mountStatus = returned.dirattr & UInt32(ATTR_DIR_MOUNTSTATUS) != 0 ? cursor.take(UInt32.self) ?? 0 : 0

        let complete = error == 0 && returned.commonattr & common == common && device != -1 && flags & UInt32(SF_FIRMLINK) == 0
        if complete, type == VDIR.rawValue, returned.dirattr & UInt32(ATTR_DIR_MOUNTSTATUS) != 0 {
            return DirectoryEntry(name: name, type: type, device: device, inode: inode, flags: flags, links: 0, allocated: 0, mountStatus: mountStatus)
        }
        if complete, type == VREG.rawValue, returned.fileattr & file == file,
           let links = cursor.take(UInt32.self), let allocated = cursor.take(Int64.self) {
            return DirectoryEntry(name: name, type: type, device: device, inode: inode, flags: flags, links: links, allocated: allocated, mountStatus: 0)
        }
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return DirectoryEntry(name: name, info: info)
    }
}

private struct Folder {
    let name: String
    var parent: Int32
    var smallBytes: Int64 = 0
    var smallCount = 0
    var files: [(name: String, size: Int64)] = []
}

private struct Unit {
    let path: String
    let parentUnit: Int
    let parentFolder: Int32
}

private final class WorkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var units: [Unit]
    private var results: [[Folder]?] = [nil]
    private var pending = [0]
    private var active = 0
    private let backlog = Atomic<Int>(1)
    let workers: Int

    init(root: Unit, workers: Int) {
        units = [root]
        self.workers = workers
    }

    func unit(_ index: Int) -> Unit {
        condition.withLock { units[index] }
    }

    func next(stopped: () -> Bool) -> Int? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if stopped() {
                condition.broadcast()
                return nil
            }
            if let index = pending.popLast() {
                backlog.store(pending.count, ordering: .relaxed)
                active += 1
                return index
            }
            if active == 0 {
                condition.broadcast()
                return nil
            }
            condition.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    func offer(_ unit: Unit) -> Bool {
        guard backlog.load(ordering: .relaxed) < workers else { return false }
        condition.lock()
        defer { condition.unlock() }
        guard pending.count < workers else { return false }
        units.append(unit)
        results.append(nil)
        pending.append(units.count - 1)
        backlog.store(pending.count, ordering: .relaxed)
        condition.signal()
        return true
    }

    func finish(_ index: Int, folders: [Folder]) {
        condition.lock()
        defer { condition.unlock() }
        results[index] = folders
        active -= 1
        if pending.isEmpty, active == 0 { condition.broadcast() }
    }

    func take() -> (units: [Unit], results: [[Folder]]) {
        condition.withLock {
            let finished = results.map { $0 ?? [] }
            results = []
            return (units, finished)
        }
    }
}

struct ExactScanner: Sendable {
    let context: ScanContext
    var fileThreshold: Int64 = 1_000_000
    var folderThreshold: Int64 = 1_000_000

    static func disableDatalessMaterialization() {
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    }

    func scan(path: String) -> Node? {
        BulkDirectory.raisedDescriptorLimit
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let name = (path as NSString).lastPathComponent
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_flags & UInt32(SF_DATALESS) == 0 else {
            let size = Int64(info.st_blocks) * 512
            context.add(files: 1, bytes: size)
            let node = Node(name: name, role: .file, kind: FileKind.classify(name: name), size: size, fileCount: 1)
            node.isExact = true
            return node
        }
        guard let folders = collect(path: path, device: info.st_dev) else { return nil }
        return build(folders, name: name)
    }

    func scan(paths: [String]) -> [(path: String, node: Node)] {
        var results = [Node?](repeating: nil, count: paths.count)
        results.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: paths.count) { index in
                buffer[index] = scan(path: paths[index])
            }
        }
        return zip(paths, results).compactMap { path, node in node.map { (path, $0) } }
    }

    private func allocatedSize(_ entry: DirectoryEntry) -> Int64 {
        if entry.isRegular, entry.links > 1, !context.firstSighting(device: entry.device, inode: entry.inode) {
            return 0
        }
        return entry.allocated
    }

    private func collect(path: String, device: Int32) -> [Folder]? {
        let queue = WorkQueue(root: Unit(path: path, parentUnit: -1, parentFolder: -1),
                              workers: max(2, ProcessInfo.processInfo.activeProcessorCount))
        DispatchQueue.concurrentPerform(iterations: queue.workers) { _ in
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: BulkDirectory.bufferSize, alignment: 8)
            defer { buffer.deallocate() }
            while let index = queue.next(stopped: { context.isCancelled }) {
                queue.finish(index, folders: scanUnit(index, queue: queue, device: device, buffer: buffer))
            }
        }
        if context.isCancelled { return nil }
        var (units, results) = queue.take()
        return merge(units, &results)
    }

    private func scanUnit(_ index: Int, queue: WorkQueue, device: Int32, buffer: UnsafeMutableRawBufferPointer) -> [Folder] {
        let unit = queue.unit(index)
        var folders = [Folder(name: (unit.path as NSString).lastPathComponent, parent: -1)]
        let descriptor = open(unit.path, BulkDirectory.openFlags)
        guard descriptor >= 0 else {
            context.add(files: 0, bytes: 0, unreadable: 1)
            return folders
        }
        walk(descriptor, folder: 0, path: unit.path, unit: index, device: device, folders: &folders, queue: queue, buffer: buffer)
        close(descriptor)
        return folders
    }

    private func walk(
        _ descriptor: Int32, folder: Int, path: String, unit: Int, device: Int32,
        folders: inout [Folder], queue: WorkQueue, buffer: UnsafeMutableRawBufferPointer
    ) {
        if context.isCancelled { return }
        var subdirectories: [(name: String, index: Int)] = []
        var files = 0
        var bytes: Int64 = 0
        let readable = BulkDirectory.read(descriptor, buffer: buffer) { entry in
            if entry.isDirectory {
                guard entry.device == device, !entry.isMountPoint else { return }
                folders.append(Folder(name: entry.name, parent: Int32(folder)))
                if !entry.isDataless { subdirectories.append((entry.name, folders.count - 1)) }
            } else {
                let size = allocatedSize(entry)
                if size >= fileThreshold {
                    folders[folder].files.append((entry.name, size))
                } else {
                    folders[folder].smallBytes += size
                    folders[folder].smallCount += 1
                }
                files += 1
                bytes += size
            }
        }
        context.add(files: files, bytes: bytes, unreadable: readable ? 0 : 1)
        for child in subdirectories {
            let childPath = path == "/" ? "/" + child.name : path + "/" + child.name
            if queue.offer(Unit(path: childPath, parentUnit: unit, parentFolder: Int32(child.index))) { continue }
            let childDescriptor = child.name.withCString { openat(descriptor, $0, BulkDirectory.openFlags) }
            guard childDescriptor >= 0 else {
                context.add(files: 0, bytes: 0, unreadable: 1)
                continue
            }
            walk(childDescriptor, folder: child.index, path: childPath, unit: unit, device: device,
                 folders: &folders, queue: queue, buffer: buffer)
            close(childDescriptor)
            if context.isCancelled { return }
        }
    }

    private func merge(_ units: [Unit], _ results: inout [[Folder]]) -> [Folder] {
        var all: [Folder] = []
        all.reserveCapacity(results.reduce(0) { $0 + $1.count })
        var roots = [Int](repeating: 0, count: units.count)
        var bases = [Int](repeating: 0, count: units.count)
        for index in results.indices {
            let local = results[index]
            results[index] = []
            guard let head = local.first else { continue }
            if index == 0 {
                all.append(head)
            } else {
                let unit = units[index]
                let root = unit.parentFolder == 0 ? roots[unit.parentUnit] : bases[unit.parentUnit] + Int(unit.parentFolder) - 1
                roots[index] = root
                all[root].smallBytes += head.smallBytes
                all[root].smallCount += head.smallCount
                all[root].files += head.files
            }
            let base = all.count
            bases[index] = base
            for var folder in local.dropFirst() {
                folder.parent = folder.parent == 0 ? Int32(roots[index]) : Int32(base + Int(folder.parent) - 1)
                all.append(folder)
            }
        }
        return all
    }

    private func build(_ folders: [Folder], name: String) -> Node {
        var accumulators = folders.map { folder in
            var accumulator = Accumulator(name: folder.name, ownBytes: folder.smallBytes)
            accumulator.smallCount = folder.smallCount
            accumulator.count = folder.smallCount
            for file in folder.files {
                accumulator.addFile(size: file.size, name: file.name, threshold: fileThreshold)
            }
            return accumulator
        }
        for index in accumulators.indices.reversed() where index > 0 {
            accumulators[Int(folders[index].parent)].absorb(accumulators[index], threshold: folderThreshold)
            accumulators[index] = Accumulator(name: "")
        }
        accumulators[0].name = name
        return accumulators[0].makeNode()
    }
}
