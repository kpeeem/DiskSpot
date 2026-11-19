import SwiftUI

@main
struct DiskSpotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        #if DEBUG
        ExceptionLog.install()
        #endif
    }

    var body: some Scene {
        Window("DiskSpot", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1120, minHeight: 600)
                .task {
                    model.startIfNeeded()
                    #if DEBUG
                    DebugSnapshots.startIfRequested(model: model)
                    #endif
                }
        }
        .defaultSize(width: 1500, height: 900)
        .commands { AppCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        SidebarCommands()
        InspectorCommands()
        CommandGroup(replacing: .newItem) {
            Button("Анализировать папку…") { model.chooseFolder() }
                .keyboardShortcut("o")
            Button("Пересканировать") { model.rescan() }
                .keyboardShortcut("r")
            Divider()
            Button("Остановить сканирование") { model.cancelAll() }
                .keyboardShortcut(".")
                .disabled(!model.isBusy)
        }
        CommandMenu("Объект") {
            Button("Быстрый просмотр") { model.quickLook() }
                .keyboardShortcut("y")
                .disabled(model.selection?.existsOnDisk != true)
            Button("Показать в Finder") { model.selection.map(model.reveal) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selection?.existsOnDisk != true)
            Button("Скопировать путь") { model.selection.map(model.copyPath) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model.selection?.existsOnDisk != true)
            Divider()
            Button("Приблизить") { model.selection.map(model.zoom(to:)) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(model.selection?.children.isEmpty != false)
            Button("Уровень выше") { model.zoomOut() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model.zoomRoot?.parent == nil)
            Button("Посчитать точно") { model.selection.map(model.scanExactly) }
                .keyboardShortcut("e")
                .disabled(model.selection == nil)
            Divider()
            Button("Переместить в Корзину…") { model.selection.map(model.confirmTrash) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selection.map(model.canTrash) != true)
        }
    }
}
