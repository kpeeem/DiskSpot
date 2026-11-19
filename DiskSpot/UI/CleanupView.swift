import SwiftUI

struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = false
    @State private var showFailures = false
    @State private var confirmRun: AdviceItem?

    var body: some View {
        @Bindable var store = model.cleanup
        VStack(spacing: 0) {
            Form {
                adviceSection
                ForEach(PlaceSafety.allCases, id: \.self) { safety in
                    let groups = store.places.filter { $0.rule.safety == safety }
                    if !groups.isEmpty {
                        Section {
                            ForEach(groups) { group in
                                PlaceGroupRow(group: group)
                            }
                        } header: {
                            HStack {
                                Text(safety.title)
                                Spacer()
                                Text(Format.bytes(store.total(safety))).monospacedDigit()
                            }
                        }
                    }
                }
                if store.measuring && !store.measured {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Считаю кэши и служебные папки").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
                .padding(12)
        }
        .task { if !store.measured { await store.measure() } }
        .confirmationDialog("Переместить в Корзину: \(store.chosenCount)?", isPresented: $confirm) {
            Button("В Корзину", role: .destructive) { Task { await model.trashCleanupChoice() } }
        } message: {
            Text("Освободится \(Format.bytes(store.chosenSize)) после очистки Корзины. Из Корзины всё можно вернуть.")
        }
        .confirmationDialog(confirmRun?.title ?? "", isPresented: Binding { confirmRun != nil } set: { if !$0 { confirmRun = nil } },
                            presenting: confirmRun) { item in
            Button(item.action == "empty-trash" ? "Очистить Корзину" : "Выполнить", role: .destructive) {
                Task { await model.runCleanupAction(item) }
            }
        } message: { item in
            let command = item.action.flatMap { AdviceActions.definition($0)?.commandLine(item.argument) }
            Text([item.action == "empty-trash" ? "Всё из Корзины удалится навсегда, вернуть будет нельзя." : command,
                  item.size > 0 ? "Освободится около \(Format.bytes(item.size))." : nil].compactMap { $0 }.joined(separator: "\n\n"))
        }
        .sheet(isPresented: $showFailures) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Не удалось переместить: \(store.failures.count)").font(.headline)
                List(store.failures, id: \.self) { Text($0).font(.callout).textSelection(.enabled) }
                    .frame(minWidth: 440, minHeight: 200)
                HStack {
                    Spacer()
                    Button("Готово") { showFailures = false }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder private var adviceSection: some View {
        if let advice = model.cleanup.advice {
            Section {
                if !advice.summary.isEmpty {
                    Text(advice.summary).foregroundStyle(.secondary)
                }
                ForEach(advice.items.filter { $0.status == .pending } + advice.items.filter { $0.status != .pending }) { item in
                    AdviceRow(item: item) { confirmRun = $0 }
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(advice.title)
                    Text("\(advice.author) · \(advice.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            Section("Анализ Claude") {
                Text("Спросите Claude, чем забит диск: его выводы появятся здесь с объяснением по каждому пункту, а удаляется только то, что вы подтвердите.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        let store = model.cleanup
        VStack(alignment: .leading, spacing: 8) {
            if let working = store.working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(working).foregroundStyle(.secondary)
                }
            } else if !store.failures.isEmpty {
                HStack {
                    Label("Не удалось переместить: \(store.failures.count)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Подробнее…") { showFailures = true }.controlSize(.small)
                }
            }
            HStack {
                Text("Выбрано: \(store.chosenCount) · \(Format.bytes(store.chosenSize))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("В Корзину…", role: .destructive) { confirm = true }
                    .disabled(store.chosenCount == 0 || store.working != nil)
            }
        }
    }
}

private struct ItemActions: View {
    @Environment(AppModel.self) private var model
    let path: String

    var body: some View {
        Button("Открыть") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        Button("Быстрый просмотр") { QuickLook.shared.show(URL(fileURLWithPath: path), onlyIfVisible: false) }
        Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        Button("Показать на карте") { model.revealPath(path) }
    }
}

private struct AdviceRow: View {
    @Environment(AppModel.self) private var model
    let item: AdviceItem
    let run: (AdviceItem) -> Void

    private var location: String {
        if item.path.isEmpty { return item.action.flatMap { AdviceActions.definition($0)?.commandLine(item.argument) } ?? "" }
        return Format.path(item.isAction ? item.path : (item.path as NSString).deletingLastPathComponent)
    }

    private var verdict: (String, String) {
        switch item.verdict {
        case .safe: ("Можно удалять", "checkmark.shield")
        case .regenerable: ("Восстановится заново", "arrow.triangle.2.circlepath")
        case .review: ("Стоит посмотреть", "eye")
        case .keep: ("Оставить", "lock")
        }
    }

    var body: some View {
        @Bindable var store = model.cleanup
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if item.isAction {
                Image(systemName: item.status == .done ? "checkmark" : item.status == .failed ? "exclamationmark.triangle" : "terminal")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            } else if item.status == .pending && item.verdict != .keep {
                Toggle(Format.path(item.path), isOn: Binding {
                    store.adviceSelected.contains(item.id)
                } set: { on in
                    if on { store.adviceSelected.insert(item.id) } else { store.adviceSelected.remove(item.id) }
                })
                .toggleStyle(.checkbox)
                .labelsHidden()
            } else {
                Image(systemName: item.verdict == .keep ? "lock" : "checkmark").foregroundStyle(.secondary).frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .strikethrough(item.status == .trashed || item.status == .missing || item.status == .done)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label(verdict.0, systemImage: verdict.1).font(.caption).foregroundStyle(.secondary)
                if !item.reason.isEmpty {
                    Text(item.reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                switch item.status {
                case .trashed: Text("Перемещено в Корзину").font(.caption).foregroundStyle(.tertiary)
                case .kept: Text("Вы решили оставить").font(.caption).foregroundStyle(.tertiary)
                case .missing: Text("Уже нет на диске").font(.caption).foregroundStyle(.tertiary)
                case .done: Text("Выполнено").font(.caption).foregroundStyle(.tertiary)
                case .failed:
                    Text(item.output.map { String($0.suffix(600)) } ?? "Не получилось")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                case .pending:
                    if item.isRunnable {
                        Button(item.action == "empty-trash" ? "Очистить Корзину…" : "Выполнить…") { run(item) }
                            .controlSize(.small)
                            .disabled(model.cleanup.working != nil)
                            .padding(.top, 2)
                    }
                }
            }
            Spacer(minLength: 4)
            Text(Format.bytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { if !item.path.isEmpty { model.revealPath(item.path) } }
        .contextMenu {
            if !item.path.isEmpty { ItemActions(path: item.path) }
            if item.status == .pending, item.verdict != .keep {
                Divider()
                Button("Оставить") { model.cleanup.keep(item) }
            }
        }
    }
}

private struct PlaceGroupRow: View {
    @Environment(AppModel.self) private var model
    let group: PlaceGroup

    var body: some View {
        @Bindable var store = model.cleanup
        DisclosureGroup {
            ForEach(group.items) { item in
                HStack {
                    Toggle(Format.path(item.path), isOn: Binding {
                        store.placeSelected.contains(item.path)
                    } set: { on in
                        if on { store.placeSelected.insert(item.path) } else { store.placeSelected.remove(item.path) }
                    })
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    Text((item.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(Format.bytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.revealPath(item.path) }
                .contextMenu { ItemActions(path: item.path) }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Toggle(group.rule.title, isOn: Binding {
                    group.items.allSatisfy { store.placeSelected.contains($0.path) }
                } set: { on in
                    for item in group.items {
                        if on { store.placeSelected.insert(item.path) } else { store.placeSelected.remove(item.path) }
                    }
                })
                .toggleStyle(.checkbox)
                .labelsHidden()
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.rule.title)
                    Text(group.rule.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Text(Format.bytes(group.size)).monospacedDigit()
            }
        }
    }
}
