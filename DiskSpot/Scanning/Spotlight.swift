import CoreServices
import Foundation

struct SpotlightHit: Sendable {
    let path: String
    let size: Int64
}

enum Spotlight {
    /// Items whose allocated size is at least `minSize`. Folders have no size in the index,
    /// only files and packages (.app, .photoslibrary…) do, so folder totals are built from paths.
    static func bigItems(in scope: String, minSize: Int64) -> [SpotlightHit] {
        let sizeAttribute = "kMDItemPhysicalSize" as CFString
        let text = "kMDItemPhysicalSize >= \(minSize)" as CFString
        guard let query = MDQueryCreate(kCFAllocatorDefault, text, [sizeAttribute] as CFArray, nil) else { return [] }
        MDQuerySetSearchScope(query, [scope] as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        MDQueryStop(query)

        let count = MDQueryGetResultCount(query)
        var hits: [SpotlightHit] = []
        hits.reserveCapacity(count)
        for index in 0..<count {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            // kMDItemPath is computed, it is not available through the value-list fast path.
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            var size: Int64 = 0
            if let value = MDQueryGetAttributeValueOfResultAtIndex(query, sizeAttribute, index) {
                let number = Unmanaged<CFNumber>.fromOpaque(value).takeUnretainedValue()
                CFNumberGetValue(number, .sInt64Type, &size)
            }
            hits.append(SpotlightHit(path: path, size: size))
        }
        return hits
    }

    /// Folders the user excluded in System Settings → Spotlight → Search Privacy.
    /// The list lives in a root-only plist; the Settings pane reads it through this SPI.
    static func exclusions() -> [String] {
        typealias CopyExclusionList = @convention(c) () -> Unmanaged<CFArray>?
        guard
            let handle = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY),
            let symbol = dlsym(handle, "_MDCopyExclusionList")
        else { return [] }
        let copy = unsafeBitCast(symbol, to: CopyExclusionList.self)
        guard let list = copy()?.takeRetainedValue() as? [Any] else { return [] }
        return list.compactMap { entry in
            if let path = entry as? String { return path }
            if let url = entry as? URL { return url.path }
            return nil
        }
        .sorted()
    }
}
