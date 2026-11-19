import Combine
import SwiftUI

extension Node: Identifiable {
    var id: ObjectIdentifier { ObjectIdentifier(self) }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            DetailView()
                .inspector(isPresented: $model.inspectorShown) {
                    InspectorView()
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
                }
        }
        .toolbar { toolbar }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Имя файла")
        .navigationTitle(model.scope.name)
        .navigationSubtitle(Format.path(model.scope.path))
        .sheet(isPresented: $model.accessSheetShown) { AccessSheet() }
        .onChange(of: model.threshold) { model.rescan() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAccess()
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name(AdviceStore.changedNotification)).receive(on: RunLoop.main)) { _ in
            model.cleanup.reloadAdvice()
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name(AdviceStore.showNotification)).receive(on: RunLoop.main)) { _ in
            model.showCleanup()
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(folder: url)
            return true
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup(placement: .primaryAction) {
            Picker(selection: $model.threshold) {
                ForEach(AppModel.thresholds, id: \.self) { value in
                    Text("от \(Format.bytes(value))").tag(value)
                }
            } label: {
                Label("Крупные файлы", systemImage: "line.3.horizontal.decrease")
            }
            .help("Минимальный размер файла в запросе к Spotlight. Слепые зоны считаются точно независимо от порога.")

            if model.isBusy {
                Button { model.cancelAll() } label: {
                    Label("Остановить", systemImage: "stop.fill")
                }
                .help("Остановить сканирование")
            } else {
                Button { model.rescan() } label: {
                    Label("Пересканировать", systemImage: "arrow.clockwise")
                }
                .help("Пересканировать (⌘R)")
            }

            Button { model.inspectorShown.toggle() } label: {
                Label("Инспектор", systemImage: "sidebar.trailing")
            }
            .help("Показать или скрыть инспектор (⌥⌘I)")
        }
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            SummaryBar()
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider()
            SplitPane(minLeading: 300, idealLeading: 480, minTrailing: 360, storageKey: "outlineWidth") {
                OutlinePane(model: model, root: model.root, version: model.treeVersion, selection: model.selection)
            } trailing: {
                VStack(spacing: 0) {
                    pathBar
                    Divider()
                    treemap
                }
            }
            Divider()
            StatusBar()
        }
        .frame(minWidth: 640)
    }

    private var pathBar: some View {
        HStack(spacing: 6) {
            Button { model.zoomOut() } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(model.zoomRoot?.parent == nil)
            .help("Уровень выше (⌘↑)")
            PathBar(model: model, node: model.zoomRoot, version: model.treeVersion)
                .frame(height: 22)
            Spacer(minLength: 0)
            if let zoom = model.zoomRoot {
                Text(Format.bytes(zoom.size))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
    }

    @ViewBuilder
    private var treemap: some View {
        if model.root == nil {
            ContentUnavailableView {
                ProgressView()
                    .controlSize(.large)
            } description: {
                Text("Спрашиваю Spotlight…")
            }
        } else if let root = model.root, root.children.isEmpty {
            ContentUnavailableView(
                "Крупных файлов нет",
                systemImage: "magnifyingglass",
                description: Text("В «\(model.scope.name)» нет файлов от \(Format.bytes(model.threshold)). Понизьте порог или посчитайте папку точно.")
            )
        } else {
            TreemapView(
                model: model,
                root: model.zoomRoot,
                version: model.treeVersion,
                selection: model.selection,
                highlightedKind: model.highlightedKind,
                searchText: model.searchText
            )
        }
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if model.isQuerying || !model.jobStatus.isEmpty {
                ProgressView()
                    .controlSize(.small)
                Text(model.isQuerying ? "Спрашиваю Spotlight…" : model.jobStatus)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
            } else if let node = model.hovered ?? model.selection {
                Text(title(for: node))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(details(for: node))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            } else if let root = model.root {
                Text(summary(for: root))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 26)
    }

    private func summary(for root: Node) -> String {
        var parts = ["\(Format.count(root.fileCount)) файлов"]
        if let space = model.space {
            parts.append("свободно \(Format.bytes(space.available))")
        }
        parts.append("Spotlight нашёл \(Format.count(model.hitCount)) файлов от \(Format.bytes(model.threshold)) за \(Format.duration(model.queryDuration))")
        return parts.joined(separator: " · ")
    }

    private func title(for node: Node) -> String {
        if node.existsOnDisk { return Format.path(node.path) }
        if node.parent == nil { return node.name }
        return "\(Format.path(node.path)) › \(node.name)"
    }

    private func details(for node: Node) -> String {
        var parts = [Format.bytes(node.size)]
        switch node.role {
        case .unseen:
            var text = "мелкие файлы вне слепых зон, APFS-снапшоты, служебные данные"
            if let purgeable = model.space?.purgeable, purgeable > 0 {
                text += ", очищаемое \(Format.bytes(purgeable))"
            }
            if !model.hasFullDiskAccess {
                text += "; без полного доступа сюда же попадают Рабочий стол, Документы и Загрузки"
            }
            parts.append(text)
        case .smallFiles:
            parts.append("\(Format.count(node.fileCount)) объектов меньше 1 МБ")
        case .remainder:
            parts.append("часть пакета, которую Spotlight не индексирует")
        case .systemGroup, .systemVolume:
            parts.append("размер тома")
        case .folder, .package:
            parts.append("\(Format.count(node.fileCount)) файлов")
            parts.append(node.isExact ? "посчитано точно" : "по данным Spotlight")
        case .file:
            parts.append(node.kind.title)
        }
        return parts.joined(separator: " · ")
    }
}

struct AccessSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("DiskSpot нужен полный доступ к диску")
                .font(.title2.weight(.semibold))
            Text("Без него macOS прячет от Spotlight файлы на Рабочем столе, в Документах и Загрузках, а часть ~/Library нельзя прочитать. Включите DiskSpot в списке «Полный доступ к диску», затем откройте приложение заново.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Продолжить без доступа") { model.accessSheetShown = false }
                    .keyboardShortcut(.cancelAction)
                Button("Открыть Настройки") {
                    Permissions.openFullDiskAccessSettings()
                    model.accessSheetShown = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 440)
    }
}
