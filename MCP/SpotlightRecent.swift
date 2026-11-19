import CoreServices
import Foundation

extension Spotlight {
    struct RecentHit: Sendable {
        let path: String
        let size: Int64
        let changed: Date?
    }

    static func recentItems(in scope: String, minSize: Int64, seconds: Double) -> [RecentHit] {
        let sizeAttribute = "kMDItemPhysicalSize" as CFString
        let dateAttribute = "kMDItemFSContentChangeDate" as CFString
        let text = "kMDItemPhysicalSize >= \(minSize) && kMDItemFSContentChangeDate >= $time.now(-\(Int(seconds)))" as CFString
        guard let query = MDQueryCreate(kCFAllocatorDefault, text, [sizeAttribute, dateAttribute] as CFArray, nil) else { return [] }
        MDQuerySetSearchScope(query, [scope] as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        MDQueryStop(query)

        let count = MDQueryGetResultCount(query)
        var hits: [RecentHit] = []
        hits.reserveCapacity(count)
        for index in 0..<count {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            var size: Int64 = 0
            if let value = MDQueryGetAttributeValueOfResultAtIndex(query, sizeAttribute, index) {
                CFNumberGetValue(Unmanaged<CFNumber>.fromOpaque(value).takeUnretainedValue(), .sInt64Type, &size)
            }
            var changed: Date?
            if let value = MDQueryGetAttributeValueOfResultAtIndex(query, dateAttribute, index) {
                changed = Unmanaged<CFDate>.fromOpaque(value).takeUnretainedValue() as Date
            }
            hits.append(RecentHit(path: path, size: size, changed: changed))
        }
        return hits
    }
}
