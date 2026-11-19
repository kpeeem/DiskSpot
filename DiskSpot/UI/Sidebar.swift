import SwiftUI

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            Section("Тома") {
                ForEach(model.volumes) { volume in
                    VolumeRow(volume: volume)
                        .tag(SidebarItem.volume(volume.path))
                }
            }
            Section("Папки") {
                ForEach(model.folderShortcuts) { shortcut in
                    Label(shortcut.name, systemImage: shortcut.symbol)
                        .tag(SidebarItem.folder(shortcut.path))
                }
            }
            if !model.recentFolders.isEmpty {
                Section("Недавние") {
                    ForEach(model.recentFolders, id: \.self) { path in
                        Label((path as NSString).lastPathComponent, systemImage: "folder")
                            .help(Format.path(path))
                            .tag(SidebarItem.folder(path))
                            .contextMenu {
                                Button("Показать в Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                }
                                Button("Убрать из недавних") { model.forgetRecent(path) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                model.chooseFolder()
            } label: {
                Label("Другая папка…", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

private struct VolumeRow: View {
    let volume: VolumeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(volume.name, systemImage: volume.isBoot ? "internaldrive" : "externaldrive")
            if let space = volume.space {
                ProgressView(value: Double(space.used), total: Double(max(space.total, 1)))
                    .controlSize(.mini)
                    .tint(space.available < space.total / 10 ? .orange : .secondary)
                Text("\(Format.bytes(space.available)) свободно")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
