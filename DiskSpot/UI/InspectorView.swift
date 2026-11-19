import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("Раздел", selection: $model.inspectorTab) {
                Text("Обзор").tag(InspectorTab.overview)
                Text("Уборка").tag(InspectorTab.cleanup)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if model.inspectorTab == .cleanup {
                CleanupView()
            } else {
                overview
            }
        }
    }

    private var overview: some View {
        Form {
            if let node = model.selection {
                SelectionSection(node: node)
            } else {
                Section {
                    Text("Выберите файл или папку на карте или в списке.")
                        .foregroundStyle(.secondary)
                }
            }

            if !model.hasFullDiskAccess {
                Section {
                    LabeledContent {
                        Button("Настройки…") { Permissions.openFullDiskAccessSettings() }
                            .controlSize(.small)
                    } label: {
                        Label("Нет полного доступа к диску", systemImage: "lock")
                        Text("Рабочий стол, Документы и Загрузки скрыты от Spotlight")
                    }
                }
            }

            Section("Типы файлов") {
                let totals = kindTotals()
                let sum = max(1, totals.reduce(Int64(0)) { $0 + $1.size })
                ForEach(totals, id: \.kind) { entry in
                    kindRow(entry.kind, size: entry.size, total: sum)
                }
            }

            Section {
                ForEach(model.blindSpots) { spot in
                    blindSpotRow(spot)
                }
                if model.blindSpots.isEmpty {
                    Text("Нет").foregroundStyle(.secondary)
                }
                Button("Посчитать всё точно…") { model.scanEverythingExactly() }
                    .disabled(model.root == nil)
                    .help("Полный обход без Spotlight. Долго, зато видно и мелкие файлы.")
            } header: {
                Text("Слепые зоны Spotlight")
            } footer: {
                Text("Эти места Spotlight не индексирует, поэтому они считаются обходом файлов.")
            }

            Section {
                if model.exclusions.isEmpty {
                    Text("Нет исключений").foregroundStyle(.secondary)
                }
                ForEach(model.exclusions, id: \.self) { path in
                    exclusionRow(path)
                }
                Button("Настройки Spotlight…") { Permissions.openSpotlightSettings() }
            } header: {
                Text("Исключения Spotlight")
            }
        }
        .formStyle(.grouped)
    }

    private func kindTotals() -> [(kind: FileKind, size: Int64)] {
        _ = model.treeVersion
        guard let root = model.zoomRoot else { return [] }
        var totals: [FileKind: Int64] = [:]
        func visit(_ node: Node) {
            if node.children.isEmpty {
                totals[node.kind, default: 0] += node.size
            } else {
                node.children.forEach(visit)
            }
        }
        visit(root)
        return totals
            .filter { $0.value > 0 }
            .map { (kind: $0.key, size: $0.value) }
            .sorted { $0.size > $1.size }
    }

    private func kindRow(_ kind: FileKind, size: Int64, total: Int64) -> some View {
        let active = model.highlightedKind == kind
        return Button {
            model.highlightedKind = active ? nil : kind
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(nsColor: kind.color))
                    .frame(width: 10, height: 10)
                Text(kind.title)
                    .foregroundStyle(.primary)
                Spacer()
                Text(Format.bytes(size))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text(Format.percent(size, of: total))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .fontWeight(active ? .semibold : .regular)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(active ? "Снять подсветку на карте" : "Подсветить на карте")
    }

    private func blindSpotRow(_ spot: BlindSpot) -> some View {
        LabeledContent {
            switch spot.state {
            case .pending:
                Text("ждёт").foregroundStyle(.tertiary)
            case .scanning:
                ProgressView().controlSize(.small)
            case .done:
                Text(Format.bytes(spot.size)).monospacedDigit()
            }
        } label: {
            Label(spot.title, systemImage: symbol(for: spot.reason))
            Text(spot.paths.count > 1 ? "\(spot.detail) · \(spot.paths.count) шт." : spot.detail)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard spot.paths.count == 1, let path = spot.paths.first else { return }
            model.select(model.root?.descendant(at: path, create: false))
        }
    }

    private func exclusionRow(_ path: String) -> some View {
        _ = model.treeVersion
        let node = model.root?.descendant(at: path, create: false)
        return LabeledContent {
            if let node {
                Text(Format.bytes(node.size)).monospacedDigit()
            } else {
                Text("вне области").foregroundStyle(.tertiary)
            }
        } label: {
            Label((path as NSString).lastPathComponent, systemImage: "hand.raised")
            Text(Format.path(path))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let node { model.select(node) }
        }
    }

    private func symbol(for reason: BlindSpot.Reason) -> String {
        switch reason {
        case .library: "books.vertical"
        case .hidden: "eye.slash"
        case .system: "gearshape"
        case .exclusion: "hand.raised"
        case .notIndexed: "magnifyingglass"
        }
    }
}

private struct SelectionSection: View {
    @Environment(AppModel.self) private var model
    let node: Node

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.name)
                        .font(.headline)
                        .lineLimit(2)
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)

            LabeledContent("Размер", value: Format.bytes(node.size))
            if let parent = node.parent {
                LabeledContent("Доля", value: "\(Format.percent(node.size, of: parent.size)) от «\(parent.name)»")
            }
            if node.fileCount > 0 {
                LabeledContent("Файлов", value: Format.count(node.fileCount))
            }
            if node.isDirectory {
                LabeledContent("Источник", value: node.isExact ? "обход файлов" : "индекс Spotlight")
            }
            if node.existsOnDisk {
                LabeledContent("Путь") {
                    Text(Format.path(node.path))
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.trailing)
                }
                if let modified {
                    LabeledContent("Изменён", value: modified.formatted(date: .abbreviated, time: .shortened))
                }
            }
        } footer: {
            if node.existsOnDisk {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        primaryActions
                        Spacer()
                        trashButton
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { primaryActions }
                        trashButton
                    }
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var primaryActions: some View {
        Button("Показать в Finder") { model.reveal(node) }
            .fixedSize()
        if node.isDirectory && node.role != .systemVolume {
            Button("Посчитать точно") { model.scanExactly(node) }
                .fixedSize()
        }
    }

    @ViewBuilder
    private var trashButton: some View {
        if model.canTrash(node) {
            Button("В Корзину…", role: .destructive) { model.confirmTrash(node) }
                .fixedSize()
        }
    }

    private var icon: NSImage {
        if node.existsOnDisk {
            return NSWorkspace.shared.icon(forFile: node.path)
        }
        let image = NSImage(systemSymbolName: node.kind.symbol, accessibilityDescription: nil) ?? NSImage()
        return image.withSymbolConfiguration(.init(pointSize: 36, weight: .light)) ?? image
    }

    private var subtitle: String {
        switch node.role {
        case .folder: node.parent == nil ? (model.scope.kind == .volume ? "Том" : "Папка") : "Папка"
        case .package: "Пакет · \(node.kind.title)"
        case .file: node.kind.title
        case .remainder: "Неиндексируемая часть пакета"
        case .smallFiles: "Файлы и папки меньше 1 МБ"
        case .unseen: "Не учтено ни Spotlight, ни обходом"
        case .systemGroup: "Тома APFS вне тома данных"
        case .systemVolume: "Том APFS"
        }
    }

    private var modified: Date? {
        let values = try? node.url?.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }
}
