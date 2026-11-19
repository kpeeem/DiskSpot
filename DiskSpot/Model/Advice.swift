import Darwin
import Foundation

public enum AdviceVerdict: String, Codable, CaseIterable, Sendable {
    case safe, regenerable, review, keep
}

public enum AdviceStatus: String, Codable, Sendable {
    case pending, trashed, kept, missing
}

public struct AdviceItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var path: String
    public var size: Int64
    public var verdict: AdviceVerdict
    public var reason: String
    public var status: AdviceStatus
    public var createdAt: Date
    public var statusAt: Date?

    public init(path: String, size: Int64, verdict: AdviceVerdict, reason: String) {
        id = UUID()
        self.path = path
        self.size = size
        self.verdict = verdict
        self.reason = reason
        status = .pending
        createdAt = .now
    }
}

public struct AdviceSheet: Codable, Sendable {
    public var title: String
    public var summary: String
    public var author: String
    public var updatedAt: Date
    public var items: [AdviceItem]

    public init(title: String, summary: String, author: String, items: [AdviceItem]) {
        self.title = title
        self.summary = summary
        self.author = author
        updatedAt = .now
        self.items = items
    }
}

public enum AdviceStore {
    public static let changedNotification = "dev.kpeeem.disk-advice.changed"
    public static let showNotification = "dev.kpeeem.disk-advice.show"

    public static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/DiskAdvice", directoryHint: .isDirectory)

    public static var file: URL { directory.appending(path: "advice.json") }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func load() -> AdviceSheet? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? decoder.decode(AdviceSheet.self, from: data)
    }

    @discardableResult
    public static func update(_ change: (inout AdviceSheet?) throws -> Void) throws -> AdviceSheet? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = directory.appending(path: ".lock").path.withCString { open($0, O_CREAT | O_RDWR | O_CLOEXEC, 0o600) }
        guard lock >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        flock(lock, LOCK_EX)
        defer {
            flock(lock, LOCK_UN)
            close(lock)
        }
        var sheet = load()
        try change(&sheet)
        if var sheet {
            sheet.updatedAt = .now
            try encoder.encode(sheet).write(to: file, options: .atomic)
        } else if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        post(changedNotification)
        return sheet
    }

    public static func mark(_ ids: Set<UUID>, as status: AdviceStatus) throws {
        try update { sheet in
            guard var current = sheet else { return }
            for index in current.items.indices where ids.contains(current.items[index].id) {
                current.items[index].status = status
                current.items[index].statusAt = .now
            }
            sheet = current
        }
    }

    public static func post(_ name: String) {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name(name), object: nil, userInfo: nil, deliverImmediately: true)
    }
}

public enum AdviceGuard {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    private static let protectedInHome: Set<String> = [
        "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public", "Applications", "Dev",
        "Library/Mobile Documents", "Library/CloudStorage", "Library/Application Support", "Library/Containers",
        "Library/Group Containers", "Library/Preferences", "Library/Keychains", "Library/Mail", "Library/Messages",
        "Library/Photos", "Library/Caches", "Library/Developer",
    ]
    private static let systemAreas = [
        "/private/tmp/", "/private/var/folders/", "/Library/Caches/", "/Library/Logs/",
        "/Library/Developer/CoreSimulator/Caches/",
    ]

    public static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = URL(filePath: expanded).standardizedFileURL.path
        let data = "/System/Volumes/Data"
        return standardized.hasPrefix(data + "/") ? String(standardized.dropFirst(data.count)) : standardized
    }

    public static func refusal(for path: String, verdict: AdviceVerdict) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return "does not exist" }
        guard verdict != .keep else { return nil }
        if path.hasPrefix(home + "/") {
            let relative = String(path.dropFirst(home.count + 1))
            if protectedInHome.contains(relative) { return "is a top-level folder that apps and the system rely on; point at something inside it" }
            if relative.hasPrefix("Library/Keychains") || relative.hasPrefix("Library/Mail") || relative.hasPrefix("Library/Messages") {
                return "holds keychains or mail and is never suggested for removal"
            }
            return nil
        }
        if systemAreas.contains(where: { path.hasPrefix($0) }) { return nil }
        if verdict == .review, path.hasPrefix("/Applications/"), path.hasSuffix(".app"),
           !path.dropFirst("/Applications/".count).dropLast(4).contains("/") {
            return nil
        }
        return "is outside the home folder and the known cache areas"
    }
}
