import CoreServices
import Darwin
import Foundation

public enum AdviceVerdict: String, Codable, CaseIterable, Sendable {
    case safe, regenerable, review, keep
}

public enum AdviceStatus: String, Codable, Sendable {
    case pending, trashed, kept, missing, done, failed
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
    public var action: String?
    public var argument: String?
    public var output: String?
    public var label: String?

    public init(path: String, size: Int64, verdict: AdviceVerdict, reason: String, action: String? = nil, argument: String? = nil, label: String? = nil) {
        id = UUID()
        self.path = path
        self.size = size
        self.verdict = verdict
        self.reason = reason
        status = .pending
        createdAt = .now
        self.action = action
        self.argument = argument
        self.label = label ?? action.flatMap { AdviceActions.definition($0)?.title(argument) }
    }

    public var isAction: Bool { action != nil }
    public var key: String { action.map { "\($0) \(argument ?? "")" } ?? path }
    public var isRemovable: Bool { status == .pending && verdict != .keep && action == nil && !path.isEmpty }
    public var isRunnable: Bool { status == .pending && verdict != .keep && action != nil }

    public var title: String { label ?? URL(filePath: path).lastPathComponent }
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

    public static func mark(_ ids: Set<UUID>, as status: AdviceStatus, output: String? = nil) throws {
        try update { sheet in
            guard var current = sheet else { return }
            for index in current.items.indices where ids.contains(current.items[index].id) {
                current.items[index].status = status
                current.items[index].statusAt = .now
                if let output { current.items[index].output = output }
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
        "/Library/Developer/CoreSimulator/Caches", "/Users/Shared/", "/cores/", "/.adobeTemp",
    ]
    private static let reviewAreas = ["/Library/Application Support/", "/Library/Audio/", "/Library/Frameworks/", "/Library/Java/", "/usr/local/"]
    private static let neverInLibrary = [
        "/Library/Preferences", "/Library/LaunchDaemons", "/Library/LaunchAgents", "/Library/Extensions", "/Library/Keychains",
        "/Library/Security", "/Library/PrivilegedHelperTools", "/Library/SystemExtensions", "/Library/Filesystems",
        "/Library/StartupItems", "/Library/Apple", "/Library/Updates", "/Library/Developer/CommandLineTools",
    ]

    public static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var standardized = URL(filePath: expanded).standardizedFileURL.path
        let data = "/System/Volumes/Data"
        if standardized.hasPrefix(data + "/") { standardized = String(standardized.dropFirst(data.count)) }
        for (alias, real) in [("/tmp/", "/private/tmp/"), ("/var/", "/private/var/")] where standardized.hasPrefix(alias) {
            standardized = real + standardized.dropFirst(alias.count)
        }
        return standardized
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
        if neverInLibrary.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return "belongs to system or installed software and is never removed by hand"
        }
        if path.hasPrefix("/private/var/folders/"), info.st_uid != getuid() {
            return "belongs to another user or the system"
        }
        if systemAreas.contains(where: { path.hasPrefix($0) && path.count > $0.count }) { return nil }
        if verdict == .review {
            if path.hasPrefix("/Applications/"), !path.dropFirst("/Applications/".count).contains("/") || path.hasSuffix(".app") {
                return nil
            }
            if reviewAreas.contains(where: { path.hasPrefix($0) && path.dropFirst($0.count).contains(where: { $0 != "/" }) }) { return nil }
            if path.hasPrefix("/Library/"), path.split(separator: "/").count >= 3 { return nil }
            return "is outside the areas that can be suggested"
        }
        return "outside the home folder only caches, logs and temporary files can be marked safe or regenerable; use review for software"
    }
}

public struct AdviceActionDefinition: Sendable {
    public let id: String
    public let needsArgument: Bool
    public let title: @Sendable (String?) -> String
    public let explanation: String
    let command: @Sendable (String?) -> (tool: String, arguments: [String])?
    let validate: @Sendable (String?) -> String?
    let estimate: @Sendable (String?) -> Int64

    public func commandLine(_ argument: String?) -> String? {
        command(argument).map { ([$0.tool] + $0.arguments).joined(separator: " ") }
    }
}

public enum AdviceActions {
    static let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    static let docker = ["/usr/local/bin/docker", FileManager.default.homeDirectoryForCurrentUser.path + "/.orbstack/bin/docker"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    static let trash = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash", directoryHint: .isDirectory)

    public static let all: [AdviceActionDefinition] = [
        AdviceActionDefinition(
            id: "brew-cleanup", needsArgument: false,
            title: { _ in "Homebrew: remove old versions and downloads" },
            explanation: "brew cleanup --prune=all removes outdated versions and cached downloads; installed formulae and casks stay.",
            command: { _ in brew.map { ($0, ["cleanup", "--prune=all"]) } },
            validate: { _ in brew == nil ? "Homebrew is not installed" : nil },
            estimate: { _ in
                guard let brew, let text = run(brew, ["cleanup", "-n", "--prune=all"]).output.components(separatedBy: "approximately ").last else { return 0 }
                return parseSize(text)
            }),
        AdviceActionDefinition(
            id: "brew-uninstall-cask", needsArgument: true,
            title: { "Uninstall \($0 ?? "cask") with Homebrew" },
            explanation: "brew uninstall --cask removes the app and the files Homebrew installed for it.",
            command: { argument in brew.flatMap { brew in argument.map { (brew, ["uninstall", "--cask", $0]) } } },
            validate: { argument in
                guard let brew else { return "Homebrew is not installed" }
                guard let argument, argument.range(of: "^[a-z0-9@._+-]+$", options: .regularExpression) != nil else { return "invalid cask name" }
                let installed = run(brew, ["list", "--cask"]).output.split(whereSeparator: \.isWhitespace).map(String.init)
                return installed.contains(argument) ? nil : "\(argument) is not an installed cask"
            },
            estimate: { argument in
                guard let argument, let brew else { return 0 }
                var total = folderSize(URL(filePath: "/opt/homebrew/Caskroom/" + argument))
                if let data = run(brew, ["info", "--cask", "--json=v2", argument]).output.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let casks = json["casks"] as? [[String: Any]], let artifacts = casks.first?["artifacts"] as? [[String: Any]] {
                    for artifact in artifacts {
                        for app in artifact["app"] as? [Any] ?? [] {
                            if let name = app as? String { total += folderSize(URL(filePath: "/Applications/" + name)) }
                        }
                    }
                }
                return total
            }),
        AdviceActionDefinition(
            id: "simctl-delete-unavailable", needsArgument: false,
            title: { _ in "Delete simulators whose runtime is gone" },
            explanation: "xcrun simctl delete unavailable removes simulators that can no longer start.",
            command: { _ in ("/usr/bin/xcrun", ["simctl", "delete", "unavailable"]) },
            validate: { _ in nil },
            estimate: { _ in simulators().filter { !$0.available }.reduce(0) { $0 + folderSize(simulatorFolder($1.udid)) } }),
        AdviceActionDefinition(
            id: "simctl-delete-device", needsArgument: true,
            title: { argument in "Delete simulator \(simulators().first { $0.udid == argument }?.name ?? argument ?? "")" },
            explanation: "xcrun simctl delete removes the simulator and the apps installed in it.",
            command: { argument in argument.map { ("/usr/bin/xcrun", ["simctl", "delete", $0]) } },
            validate: { argument in
                guard let argument, simulators().contains(where: { $0.udid == argument }) else { return "no such simulator" }
                return nil
            },
            estimate: { argument in argument.map { folderSize(simulatorFolder($0)) } ?? 0 }),
        AdviceActionDefinition(
            id: "simctl-runtime-delete", needsArgument: true,
            title: { argument in "Delete simulator runtime \(runtimes().first { $0.identifier == argument }.map { "iOS \($0.version)" } ?? argument ?? "")" },
            explanation: "xcrun simctl runtime delete removes a downloaded simulator runtime; simulators that use it stop working.",
            command: { argument in argument.map { ("/usr/bin/xcrun", ["simctl", "runtime", "delete", $0]) } },
            validate: { argument in
                guard let runtime = runtimes().first(where: { $0.identifier == argument }) else { return "no such runtime" }
                return runtime.deletable ? nil : "this runtime cannot be deleted"
            },
            estimate: { argument in runtimes().first { $0.identifier == argument }?.size ?? 0 }),
        AdviceActionDefinition(
            id: "docker-prune", needsArgument: false,
            title: { _ in "Docker: remove unused images, containers and build cache" },
            explanation: "docker system prune -af removes stopped containers, unused images, networks and build cache; volumes stay.",
            command: { _ in docker.map { ($0, ["system", "prune", "-af"]) } },
            validate: { _ in
                guard let docker else { return "Docker is not installed" }
                return run(docker, ["info", "--format", "{{.ServerVersion}}"]).status == 0 ? nil : "Docker or OrbStack is not running"
            },
            estimate: { _ in
                guard let docker else { return 0 }
                return run(docker, ["system", "df", "--format", "{{.Reclaimable}}"]).output
                    .split(separator: "\n").reduce(0) { $0 + parseSize(String($1)) }
            }),
        AdviceActionDefinition(
            id: "empty-trash", needsArgument: false,
            title: { _ in "Empty the Trash" },
            explanation: "Permanently deletes everything in the Trash. This cannot be undone.",
            command: { _ in nil },
            validate: { _ in nil },
            estimate: { _ in folderSize(trash) }),
    ]

    public static func definition(_ id: String) -> AdviceActionDefinition? {
        all.first { $0.id == id }
    }

    public static func refusal(_ id: String, argument: String?) -> String? {
        guard let definition = definition(id) else { return "unknown action \(id); known: " + all.map(\.id).joined(separator: ", ") }
        if definition.needsArgument, argument?.isEmpty ?? true { return "\(id) needs an argument" }
        return definition.validate(argument)
    }

    public static func estimate(_ id: String, argument: String?) -> Int64 {
        definition(id)?.estimate(argument) ?? 0
    }

    public static func perform(_ id: String, argument: String?) -> (ok: Bool, output: String) {
        guard let definition = definition(id) else { return (false, "unknown action") }
        if let refusal = definition.validate(argument) { return (false, refusal) }
        if id == "empty-trash" {
            let failure = AdviceTrash.emptyTrash()
            return (failure == nil, failure ?? "The Trash is empty")
        }
        guard let command = definition.command(argument) else { return (false, "the tool is not available") }
        let result = run(command.tool, command.arguments)
        return (result.status == 0, result.output)
    }

    public static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    public struct Simulator: Sendable {
        public let udid: String
        public let name: String
        public let runtime: String
        public let state: String
        public let available: Bool
    }

    public struct Runtime: Sendable {
        public let identifier: String
        public let version: String
        public let size: Int64
        public let lastUsed: String?
        public let deletable: Bool
    }

    public static func simulators() -> [Simulator] {
        guard let data = run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"]).output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else { return [] }
        return devices.flatMap { runtime, list in
            list.compactMap { device in
                guard let udid = device["udid"] as? String else { return nil }
                return Simulator(udid: udid, name: device["name"] as? String ?? udid,
                                 runtime: runtime.components(separatedBy: ".").last ?? runtime,
                                 state: device["state"] as? String ?? "", available: device["isAvailable"] as? Bool ?? true)
            }
        }
    }

    public static func runtimes() -> [Runtime] {
        guard let data = run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"]).output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [] }
        return json.values.compactMap { entry in
            guard let identifier = entry["identifier"] as? String else { return nil }
            return Runtime(identifier: identifier, version: entry["version"] as? String ?? "",
                           size: (entry["sizeBytes"] as? NSNumber)?.int64Value ?? 0,
                           lastUsed: entry["lastUsedAt"] as? String, deletable: entry["deletable"] as? Bool ?? false)
        }
    }

    public static func simulatorFolder(_ udid: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Developer/CoreSimulator/Devices/" + udid, directoryHint: .isDirectory)
    }

    public static func folderSize(_ url: URL) -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return 0 }
        guard info.st_mode & S_IFMT == S_IFDIR else { return Int64(info.st_blocks) * 512 }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
        guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in walk {
            total += Int64((try? item.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    static func parseSize(_ text: String) -> Int64 {
        let scanner = Scanner(string: text.trimmingCharacters(in: .whitespaces))
        guard let value = scanner.scanDouble() else { return 0 }
        let unit = (scanner.scanCharacters(from: .letters) ?? "B").uppercased()
        let factor: Double = switch unit.first {
        case "K": 1e3
        case "M": 1e6
        case "G": 1e9
        case "T": 1e12
        default: 1
        }
        return Int64(value * factor)
    }
}

public enum AdviceTrash {
    public static func move(_ urls: [URL]) -> (done: [URL], errors: [String]) {
        var done: [URL] = []
        var errors: [String] = []
        var denied: [URL] = []
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                done.append(url)
            } catch let error as CocoaError where error.code == .fileWriteNoPermission || error.code == .fileReadNoPermission {
                denied.append(url)
            } catch {
                errors.append("\(url.path): \(error.localizedDescription)")
            }
        }
        guard !denied.isEmpty else { return (done, errors) }
        let files = denied.map { "POSIX file \"\(escape($0.path))\" as alias" }.joined(separator: ", ")
        if let failure = finder("delete {\(files)}") {
            errors += denied.map { "\($0.path): \(failure)" }
        } else {
            done += denied
        }
        return (done, errors)
    }

    public static func emptyTrash() -> String? {
        finder("empty trash")
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func finder(_ command: String) -> String? {
        let run: @Sendable () -> String? = {
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"Finder\" to \(command)")?.executeAndReturnError(&error)
            guard let error else { return nil }
            return error[NSAppleScript.errorMessage] as? String ?? "Finder refused"
        }
        return Thread.isMainThread ? run() : DispatchQueue.main.sync(execute: run)
    }
}

public enum SystemSurvey {
    public struct App: Sendable {
        public let path: String
        public let size: Int64
        public let lastLaunch: Date?
    }

    public static func applications(size: (String) -> Int64) -> [App] {
        var bundles: [String] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? [] where !name.hasPrefix(".") {
            let path = "/Applications/" + name
            if name.hasSuffix(".app") {
                bundles.append(path)
            } else if let inner = try? FileManager.default.contentsOfDirectory(atPath: path) {
                bundles += inner.filter { $0.hasSuffix(".app") }.map { path + "/" + $0 }
            }
        }
        return bundles.map { App(path: $0, size: size($0), lastLaunch: lastLaunch(of: $0)) }
    }

    public static func lastLaunch(of bundle: String) -> Date? {
        var dates: [Date] = []
        if let executable = Bundle(path: bundle)?.executablePath {
            var info = stat()
            if lstat(executable, &info) == 0 {
                dates.append(Date(timeIntervalSince1970: TimeInterval(info.st_atimespec.tv_sec)))
            }
        }
        if let item = MDItemCreate(kCFAllocatorDefault, bundle as CFString),
           let used = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date, used > Date(timeIntervalSince1970: 1_262_304_000) {
            dates.append(used)
        }
        return dates.max()
    }

    public static func report(size: (String) -> Int64) -> [String: Any] {
        func top(_ path: String, limit: Int = 8) -> [[String: Any]] {
            let children = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).map { path + "/" + $0 }
            return children.map { ($0, size($0)) }.sorted { $0.1 > $1.1 }.prefix(limit).map { ["path": $0.0, "size": $0.1] }
        }
        let userRoot = AdviceGuard.normalize((NSTemporaryDirectory() as NSString).deletingLastPathComponent)
        let now = Date()
        let simulators = AdviceActions.simulators().map { ($0, size(AdviceActions.simulatorFolder($0.udid).path)) }
        let casks = AdviceActions.brew.map { AdviceActions.run($0, ["list", "--cask"]).output.split(whereSeparator: \.isWhitespace).map(String.init) } ?? []
        return [
            "library_caches": top("/Library/Caches"),
            "library_logs": size("/Library/Logs"),
            "simulator_caches": size("/Library/Developer/CoreSimulator/Caches"),
            "user_temp_and_caches": top(userRoot, limit: 4) + top(userRoot + "/C") + top(userRoot + "/X", limit: 4),
            "private_tmp": top("/private/tmp", limit: 12),
            "users_shared": top("/Users/Shared", limit: 6),
            "trash": size(AdviceActions.trash.path),
            "simulator_runtimes": AdviceActions.runtimes().map { runtime in
                ["identifier": runtime.identifier, "version": runtime.version, "size": runtime.size, "last_used": runtime.lastUsed as Any,
                 "deletable": runtime.deletable,
                 "used_by": simulators.filter { $0.0.runtime.hasSuffix(runtime.version.replacingOccurrences(of: ".", with: "-")) }.map(\.0.name)] as [String: Any]
            },
            "simulators": simulators.filter { $0.1 > 50_000_000 || !$0.0.available }.sorted { $0.1 > $1.1 }.map { simulator, bytes in
                ["udid": simulator.udid, "name": simulator.name, "runtime": simulator.runtime, "state": simulator.state,
                 "available": simulator.available, "size": bytes] as [String: Any]
            },
            "homebrew_cleanup_estimate": AdviceActions.estimate("brew-cleanup", argument: nil),
            "homebrew_casks": casks.map { ["cask": $0, "caskroom_size": size("/opt/homebrew/Caskroom/" + $0)] as [String: Any] }
                .sorted { ($0["caskroom_size"] as? Int64 ?? 0) > ($1["caskroom_size"] as? Int64 ?? 0) }.prefix(15).map { $0 },
            "docker": AdviceActions.refusal("docker-prune", argument: nil) ?? "running, reclaimable \(AdviceActions.estimate("docker-prune", argument: nil)) bytes",
            "local_snapshots": AdviceActions.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]).output
                .split(separator: "\n").filter { $0.contains("com.apple") }.map(String.init),
            "applications": applications(size: size).sorted { $0.size > $1.size }.prefix(60).map { app in
                ["path": app.path, "size": app.size, "last_launch": app.lastLaunch as Any,
                 "days_since_launch": app.lastLaunch.map { Int(now.timeIntervalSince($0) / 86_400) } as Any] as [String: Any]
            },
            "actions": AdviceActions.all.map { ["id": $0.id, "needs_argument": $0.needsArgument, "what": $0.explanation] },
        ]
    }
}
