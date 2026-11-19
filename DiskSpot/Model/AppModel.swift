import AppKit
import Observation

struct ScanJob: Identifiable {
    let id = UUID()
    let title: String
    let context: ScanContext
}

struct Breakdown {
    var spotlight: Int64 = 0
    var exact: Int64 = 0
    var system: Int64 = 0
    var unseen: Int64 = 0
}

enum SidebarItem: Hashable {
    case volume(String)
    case folder(String)

    var path: String {
        switch self {
        case .volume(let path), .folder(let path): path
        }
    }
}

struct FolderShortcut: Identifiable {
    let path: String
    let name: String
    let symbol: String
    var id: String { path }
}

@MainActor
@Observable
final class AppModel {
    static let thresholds: [Int64] = [10, 50, 100, 500].map { $0 * 1_000_000 }
    private static let recentsKey = "recentFolders"

    var scope: Scope = .boot
    var threshold: Int64 = 50_000_000
    var volumes: [VolumeEntry] = []
    private(set) var recentFolders: [String] = UserDefaults.standard.stringArray(forKey: AppModel.recentsKey) ?? []

    private(set) var root: Node?
    private(set) var zoomRoot: Node?
    var selection: Node?
    var hovered: Node?
    var highlightedKind: FileKind?
    var searchText = ""
    var inspectorShown = true
    var accessSheetShown = false

    let folderShortcuts: [FolderShortcut] = {
        let home = NSHomeDirectory()
        return [
            FolderShortcut(path: home, name: "Личное", symbol: "house"),
            FolderShortcut(path: home + "/Desktop", name: "Рабочий стол", symbol: "menubar.dock.rectangle"),
            FolderShortcut(path: home + "/Documents", name: "Документы", symbol: "doc"),
            FolderShortcut(path: home + "/Downloads", name: "Загрузки", symbol: "arrow.down.circle"),
            FolderShortcut(path: home + "/Library", name: "Библиотека", symbol: "books.vertical"),
            FolderShortcut(path: "/Applications", name: "Программы", symbol: "app"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }()

    var sidebarSelection: SidebarItem? {
        get {
            scope.kind == .volume ? .volume(scope.path) : .folder(scope.path)
        }
        set {
            guard let newValue, newValue.path != scope.path else { return }
            open(folder: URL(fileURLWithPath: newValue.path))
        }
    }

    private(set) var treeVersion = 0
    private(set) var isQuerying = false
    private(set) var blindSpots: [BlindSpot] = []
    private(set) var exclusions: [String] = []
    private(set) var space: SpaceStats?
    private(set) var breakdown = Breakdown()
    private(set) var hitCount = 0
    private(set) var queryDuration: TimeInterval = 0
    private(set) var jobs: [ScanJob] = []
    private(set) var jobStatus = ""
    private(set) var hasFullDiskAccess = true
    private(set) var lastError: String?

    private var scanContext: ScanContext?
    private var unseen: Node?
    private var progressTimer: Timer?
    private var started = false

    var isBusy: Bool { isQuerying || !jobs.isEmpty }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        ExactScanner.disableDatalessMaterialization()
        volumes = Volumes.list()
        accessSheetShown = !Permissions.hasFullDiskAccess()
        #if DEBUG
        if ProcessInfo.processInfo.environment["DISKSPOT_NO_SHEET"] != nil { accessSheetShown = false }
        #endif
        rescan()
    }

    // MARK: - Scanning

    func open(scope newScope: Scope) {
        scope = newScope
        rescan()
    }

    func open(folder url: URL) {
        let path = url.standardizedFileURL.path
        if let volume = volumes.first(where: { $0.path == path }) {
            open(scope: Scope(path: volume.path, name: volume.name, kind: .volume))
        } else {
            let name = folderShortcuts.first { $0.path == path }?.name ?? url.lastPathComponent
            open(scope: Scope(path: path, name: name, kind: .folder))
            if !folderShortcuts.contains(where: { $0.path == path }) {
                remember(path)
            }
        }
    }

    private func remember(_ path: String) {
        recentFolders.removeAll { $0 == path }
        recentFolders.insert(path, at: 0)
        recentFolders = Array(recentFolders.prefix(8))
        UserDefaults.standard.set(recentFolders, forKey: Self.recentsKey)
    }

    func forgetRecent(_ path: String) {
        recentFolders.removeAll { $0 == path }
        UserDefaults.standard.set(recentFolders, forKey: Self.recentsKey)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Анализировать"
        if panel.runModal() == .OK, let url = panel.url {
            open(folder: url)
        }
    }

    func rescan() {
        cancelAll()
        let context = ScanContext()
        scanContext = context
        let scope = scope
        let threshold = threshold
        let exclusions = Spotlight.exclusions()
        self.exclusions = exclusions
        hasFullDiskAccess = Permissions.hasFullDiskAccess()
        volumes = Volumes.list()
        isQuerying = true
        lastError = nil

        Task {
            let prepared = await runDetached {
                ScanPlanner.prepare(scope: scope, threshold: threshold, exclusions: exclusions)
            }
            guard scanContext === context, !context.isCancelled else { return }
            install(prepared)
            isQuerying = false
            await refineBlindSpots(context: context)
        }
    }

    func refreshAccess() {
        let granted = Permissions.hasFullDiskAccess()
        guard granted != hasFullDiskAccess else { return }
        hasFullDiskAccess = granted
        if granted && root != nil { rescan() }
    }

    func cancelAll() {
        scanContext?.cancel()
        for job in jobs { job.context.cancel() }
        jobs.removeAll()
        isQuerying = false
        updateProgressTimer()
    }

    private func install(_ prepared: PreparedScan) {
        root = prepared.root
        zoomRoot = prepared.root
        unseen = prepared.unseen
        space = prepared.space
        blindSpots = prepared.blindSpots
        hitCount = prepared.hitCount
        queryDuration = prepared.queryDuration
        selection = nil
        hovered = nil
        treeChanged()
    }

    private func refineBlindSpots(context: ScanContext) async {
        guard !blindSpots.isEmpty else { return }
        let job = ScanJob(title: "Досчитываю слепые зоны Spotlight", context: context)
        addJob(job)
        defer { removeJob(job) }

        for index in blindSpots.indices {
            guard scanContext === context, !context.isCancelled else { return }
            blindSpots[index].state = .scanning
            let paths = blindSpots[index].paths
            let scanner = ExactScanner(context: context)
            let results = await runDetached { scanner.scan(paths: paths) }
            guard scanContext === context, !context.isCancelled else { return }
            var total: Int64 = 0
            for result in results {
                graft(result.node, at: result.path)
                total += result.node.size
            }
            blindSpots[index].state = .done
            blindSpots[index].size = total
        }
    }

    /// Exact walk of one folder; its Spotlight-based contents are replaced by the result.
    func scanExactly(_ node: Node) {
        guard let root else { return }
        if node === root || node === unseen {
            scanEverythingExactly()
            return
        }
        guard node.isDirectory, node.existsOnDisk else { return }
        let path = node.path
        let context = ScanContext()
        let job = ScanJob(title: "Точный подсчёт: \(Format.path(path))", context: context)
        addJob(job)
        Task {
            let scanner = ExactScanner(context: context)
            let result = await runDetached { scanner.scan(path: path) }
            removeJob(job)
            guard self.root === root, !context.isCancelled, let result else { return }
            graft(result, at: path)
        }
    }

    /// Walks the whole volume. On the boot volume the Data volume is walked and its folders are
    /// mapped back to the paths users see (/Users, /Applications…) through firmlinks.
    func scanEverythingExactly() {
        guard let root else { return }
        let scope = scope
        let context = ScanContext()
        let job = ScanJob(title: "Точный подсчёт всего: \(scope.name)", context: context)
        addJob(job)
        Task {
            let scanner = ExactScanner(context: context)
            let walkPath = scope.isBoot ? Volumes.dataVolume : scope.path
            let result = await runDetached { scanner.scan(path: walkPath) }
            removeJob(job)
            guard self.root === root, !context.isCancelled, let result else { return }
            if scope.isBoot {
                distributeDataVolume(result)
            } else {
                graft(result, at: scope.path)
            }
        }
    }

    private func distributeDataVolume(_ data: Node) {
        let links = Volumes.firmlinks().sorted { $0.target.count > $1.target.count }
        for link in links {
            guard let node = data.descendant(relativePath: link.target), node !== data else { continue }
            node.detach()
            graft(node, at: link.source)
        }
        data.name = "Data"
        graft(data, at: Volumes.dataVolume)
    }

    private func graft(_ subtree: Node, at path: String) {
        guard let root, let target = root.descendant(at: path, create: true) else { return }
        let oldSize = target.size
        let oldCount = target.fileCount
        let kept = target === root ? target.children.filter { $0.role == .unseen || $0.role == .systemGroup } : []
        target.adopt(subtree.children + kept)
        target.size = subtree.size + kept.reduce(0) { $0 + $1.size }
        target.fileCount = subtree.fileCount + kept.reduce(0) { $0 + $1.fileCount }
        if subtree.role == .file {
            target.role = .file
            target.kind = subtree.kind
        } else if target.role == .file {
            target.role = .folder
        }
        target.isExact = target !== root
        target.sortChildren()
        target.propagate(sizeDelta: target.size - oldSize, fileDelta: target.fileCount - oldCount)
        treeChanged()
    }

    private func treeChanged() {
        if let root, let unseen, let space {
            root.refreshUnseen(unseen, used: space.used)
        }
        if let root {
            if let zoom = zoomRoot, !zoom.isInside(root) { zoomRoot = root }
            if let selected = selection, !selected.isInside(root) { selection = nil }
        }
        breakdown = computeBreakdown()
        treeVersion += 1
    }

    private func computeBreakdown() -> Breakdown {
        var result = Breakdown()
        guard let root else { return result }
        func visit(_ node: Node) {
            if node.isExact {
                result.exact += node.size
            } else if node.children.isEmpty {
                result.spotlight += node.size
            } else {
                node.children.forEach(visit)
            }
        }
        for child in root.children {
            switch child.role {
            case .unseen: result.unseen += child.size
            case .systemGroup: result.system += child.size
            default: visit(child)
            }
        }
        return result
    }

    // MARK: - Progress

    private func addJob(_ job: ScanJob) {
        jobs.append(job)
        updateProgressTimer()
    }

    private func removeJob(_ job: ScanJob) {
        jobs.removeAll { $0.id == job.id }
        updateProgressTimer()
    }

    private func updateProgressTimer() {
        if jobs.isEmpty {
            progressTimer?.invalidate()
            progressTimer = nil
            jobStatus = ""
        } else if progressTimer == nil {
            refreshJobStatus()
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshJobStatus() }
            }
        }
    }

    private func refreshJobStatus() {
        guard let job = jobs.last else { return }
        let snapshot = job.context.snapshot
        var text = "\(job.title) · \(Format.count(snapshot.files)) файлов · \(Format.bytes(snapshot.bytes))"
        if jobs.count > 1 { text += " · ещё задач: \(jobs.count - 1)" }
        jobStatus = text
    }

    // MARK: - Navigation

    func select(_ node: Node?) {
        selection = node
        if let node, let zoom = zoomRoot, !node.isInside(zoom) {
            zoomRoot = node.parent ?? root
        }
        QuickLook.shared.show(node?.url, onlyIfVisible: true)
    }

    func quickLook() {
        QuickLook.shared.show(selection?.url, onlyIfVisible: false)
    }

    /// Case-insensitive match of the search field against the name.
    func matches(_ node: Node) -> Bool {
        searchText.isEmpty || node.name.localizedCaseInsensitiveContains(searchText)
    }

    func zoom(to node: Node) {
        zoomRoot = node.children.isEmpty ? (node.parent ?? root) : node
    }

    func zoomOut() {
        if let parent = zoomRoot?.parent { zoomRoot = parent }
    }

    func open(_ node: Node) {
        if node.children.isEmpty {
            reveal(node)
        } else {
            zoom(to: node)
        }
    }

    // MARK: - File actions

    func reveal(_ node: Node) {
        guard let url = node.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyPath(_ node: Node) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
    }

    func canTrash(_ node: Node) -> Bool {
        node.existsOnDisk && node.role != .systemVolume && node !== root && node.parent != nil
    }

    func confirmTrash(_ node: Node) {
        guard canTrash(node), let url = node.url else { return }
        let alert = NSAlert()
        alert.messageText = "Переместить «\(node.name)» в Корзину?"
        alert.informativeText = "\(Format.bytes(node.size)) · \(Format.path(node.path))\n\nМесто освободится после очистки Корзины."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "В Корзину")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            moveToTrash(node, trashedPath: (resulting as URL?)?.path)
        } catch {
            lastError = error.localizedDescription
            let failure = NSAlert(error: error)
            failure.runModal()
        }
    }

    /// The file still takes space inside ~/.Trash, so it is moved there in the tree instead of vanishing.
    private func moveToTrash(_ node: Node, trashedPath: String?) {
        if selection?.isInside(node) == true { selection = nil }
        if hovered?.isInside(node) == true { hovered = nil }
        if let zoom = zoomRoot, zoom.isInside(node) { zoomRoot = node.parent }
        node.detach()
        if let trashedPath, let root, let folder = root.descendant(at: (trashedPath as NSString).deletingLastPathComponent, create: true) {
            node.name = (trashedPath as NSString).lastPathComponent
            folder.append(node)
            folder.size += node.size
            folder.fileCount += node.fileCount
            folder.sortChildren()
            folder.propagate(sizeDelta: node.size, fileDelta: node.fileCount)
        }
        treeChanged()
    }
}

private func runDetached<T>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: work())
        }
    }
}
