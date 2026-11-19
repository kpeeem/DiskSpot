import AppKit
import Foundation

struct SpaceStats: Hashable, Sendable {
    let total: Int64
    let available: Int64
    let purgeable: Int64
    var used: Int64 { total - available }
}

struct VolumeEntry: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let isBoot: Bool
    let space: SpaceStats?
    var id: String { path }
}

struct SystemVolume: Sendable {
    let name: String
    let mountPoint: String
    let used: Int64
}

private struct Mount {
    let path: String
    let type: String
    let blocks: UInt64
    let used: Int64
}

enum Volumes {
    static let dataVolume = "/System/Volumes/Data"

    static func list() -> [VolumeEntry] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey]
        var urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        #if DEBUG
        if ProcessInfo.processInfo.environment["DISKSPOT_DEMO"] != nil { urls = urls.filter { $0.path == "/" } }
        #endif
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsLocal ?? false, values?.volumeIsBrowsable ?? true else { return nil }
            return VolumeEntry(
                path: url.path,
                name: values?.volumeLocalizedName ?? url.lastPathComponent,
                isBoot: values?.volumeIsRootFileSystem ?? false,
                space: space(at: url.path)
            )
        }
    }

    static func name(of path: String) -> String {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeLocalizedNameKey])
        return values?.volumeLocalizedName ?? (path as NSString).lastPathComponent
    }

    static func space(at path: String) -> SpaceStats? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let blockSize = Int64(fs.f_bsize)
        let total = Int64(fs.f_blocks) * blockSize
        let available = Int64(fs.f_bavail) * blockSize
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let important = values?.volumeAvailableCapacityForImportantUsage ?? available
        return SpaceStats(total: total, available: available, purgeable: max(0, important - available))
    }

    /// Other APFS volumes of the boot container (sealed system, VM with swap, Preboot…).
    /// Their contents are outside the Data volume, so neither Spotlight nor a file walk sees them.
    static func systemVolumes() -> [SystemVolume] {
        let mounts = allMounts()
        guard let root = mounts.first(where: { $0.path == "/" }) else { return [] }
        return mounts
            .filter { mount in
                mount.type == "apfs" && mount.blocks == root.blocks && mount.path != dataVolume
                    && (mount.path == "/" || mount.path.hasPrefix("/System/Volumes/"))
                    && mount.used > 16 << 20
            }
            .map { SystemVolume(name: title(forSystemMount: $0.path), mountPoint: $0.path, used: $0.used) }
            .sorted { $0.used > $1.used }
    }

    static func mountPoints() -> [String] {
        allMounts().map(\.path)
    }

    private static func title(forSystemMount path: String) -> String {
        switch path {
        case "/": "macOS (запечатанный системный том)"
        case "/System/Volumes/VM": "VM — своп и sleepimage"
        case "/System/Volumes/Preboot": "Preboot"
        case "/System/Volumes/Update": "Обновления macOS"
        case "/System/Volumes/Recovery": "Recovery"
        default: (path as NSString).lastPathComponent
        }
    }

    private static func allMounts() -> [Mount] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = Int(getmntinfo(&buffer, MNT_NOWAIT))
        guard count > 0, let buffer else { return [] }
        return (0..<count).map { index in
            var cached = buffer[index]
            let path = withUnsafeBytes(of: &cached.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let type = withUnsafeBytes(of: &cached.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let used = spaceUsed(path) ?? (Int64(cached.f_blocks) - Int64(cached.f_bfree)) * Int64(cached.f_bsize)
            return Mount(path: path, type: type, blocks: cached.f_blocks, used: used)
        }
    }

    /// statfs reports container-wide numbers for every APFS volume; the per-volume figure
    /// (the one `df` shows) is only available through getattrlist.
    private static func spaceUsed(_ path: String) -> Int64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
        var buffer = [UInt8](repeating: 0, count: 64)
        guard getattrlist(path, &request, &buffer, buffer.count, 0) == 0 else { return nil }
        return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: MemoryLayout<UInt32>.size, as: Int64.self) }
    }

    /// Paths that live on the Data volume although they appear under the sealed system volume.
    static func firmlinks() -> [(source: String, target: String)] {
        guard let text = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t")
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
    }
}

enum Permissions {
    static func hasFullDiskAccess() -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DISKSPOT_DEMO"] != nil { return true }
        #endif
        let descriptor = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    @MainActor static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor static func openSpotlightSettings() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Spotlight.prefPane"))
    }
}
