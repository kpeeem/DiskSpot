import AppKit
import Foundation

enum InspectorTab: String, CaseIterable {
    case overview, cleanup
}

enum PlaceSafety: Int, CaseIterable, Comparable {
    case safe, regenerable, review

    var title: String {
        switch self {
        case .safe: "Можно удалять"
        case .regenerable: "Восстановится заново"
        case .review: "Стоит посмотреть"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct PlaceRule: Sendable {
    enum Pick: Sendable { case itself, children }

    let path: String
    let pick: Pick
    let title: String
    let explanation: String
    let safety: PlaceSafety
}

struct PlaceItem: Identifiable, Hashable, Sendable {
    let path: String
    let size: Int64
    var id: String { path }
}

struct PlaceGroup: Identifiable, Sendable {
    let rule: PlaceRule
    let items: [PlaceItem]
    var id: String { rule.path }
    var size: Int64 { items.reduce(0) { $0 + $1.size } }
}

enum CleanupPlaces {
    static let rules: [PlaceRule] = [
        PlaceRule(path: "Library/Caches", pick: .children, title: "Кэши программ",
                  explanation: "Программы пересоздают кэш сами, первый запуск после удаления может быть медленнее.", safety: .safe),
        PlaceRule(path: "Library/Logs", pick: .children, title: "Журналы программ",
                  explanation: "Нужны только для разбора сбоев, программы заводят новые.", safety: .safe),
        PlaceRule(path: "Library/Developer/CoreSimulator/Caches", pick: .itself, title: "Кэши симуляторов",
                  explanation: "Xcode пересоберёт их при следующем запуске симулятора.", safety: .safe),
        PlaceRule(path: "Library/Developer/Xcode/DerivedData", pick: .children, title: "DerivedData Xcode",
                  explanation: "Промежуточные файлы сборки, Xcode соберёт проект заново.", safety: .regenerable),
        PlaceRule(path: "Library/Developer/Xcode/iOS DeviceSupport", pick: .children, title: "Символы устройств iOS",
                  explanation: "Xcode скопирует их снова при подключении устройства.", safety: .regenerable),
        PlaceRule(path: ".cache", pick: .children, title: "Кэши утилит",
                  explanation: "uv, pip, Hugging Face и другие скачают содержимое заново, когда понадобится.", safety: .regenerable),
        PlaceRule(path: ".npm/_cacache", pick: .itself, title: "Кэш npm",
                  explanation: "npm скачает пакеты заново при следующей установке.", safety: .regenerable),
        PlaceRule(path: ".gradle/caches", pick: .itself, title: "Кэш Gradle",
                  explanation: "Gradle скачает зависимости заново при следующей сборке.", safety: .regenerable),
        PlaceRule(path: ".cargo/registry", pick: .itself, title: "Реестр Cargo",
                  explanation: "Cargo скачает исходники крейтов заново.", safety: .regenerable),
        PlaceRule(path: "Library/Developer/CoreSimulator/Devices", pick: .children, title: "Устройства симулятора",
                  explanation: "Приложения и данные в симуляторах; ненужные лучше удалять в окне Devices Xcode.", safety: .review),
        PlaceRule(path: "Library/Developer/Xcode/Archives", pick: .children, title: "Архивы Xcode",
                  explanation: "Нужны для расшифровки отчётов о сбоях выпущенных сборок.", safety: .review),
        PlaceRule(path: ".ollama/models", pick: .itself, title: "Модели Ollama",
                  explanation: "Скачиваются заново командой ollama pull, но это гигабайты трафика.", safety: .review),
    ]

    static func measure(home: String = NSHomeDirectory()) -> [PlaceGroup] {
        rules.compactMap { rule in
            let path = home + "/" + rule.path
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            let scanner = ExactScanner(context: ScanContext(), fileThreshold: 1_000_000, folderThreshold: 1_000_000)
            guard let node = scanner.scan(path: path) else { return nil }
            let items: [PlaceItem]
            switch rule.pick {
            case .itself:
                items = node.size > 0 ? [PlaceItem(path: path, size: node.size)] : []
            case .children:
                items = node.children
                    .filter { $0.role != .smallFiles && !$0.name.hasPrefix(".") && $0.size > 0 }
                    .map { PlaceItem(path: path + "/" + $0.name, size: $0.size) }
            }
            return items.isEmpty ? nil : PlaceGroup(rule: rule, items: items)
        }
    }
}

@Observable
final class CleanupStore {
    private(set) var advice: AdviceSheet? = AdviceStore.load()
    private(set) var places: [PlaceGroup] = []
    private(set) var measuring = false
    private(set) var measured = false
    var working: String?
    var failures: [String] = []
    var adviceSelected: Set<UUID> = []
    var placeSelected: Set<String> = []

    var pendingAdvice: [AdviceItem] { advice?.items.filter { $0.status == .pending && $0.verdict != .keep } ?? [] }
    var chosenAdvice: [AdviceItem] { pendingAdvice.filter { adviceSelected.contains($0.id) } }
    var chosenPlaces: [PlaceItem] {
        let advised = Set(chosenAdvice.map(\.path))
        return places.flatMap(\.items).filter { placeSelected.contains($0.path) && !advised.contains($0.path) }
    }
    var chosenCount: Int { chosenAdvice.count + chosenPlaces.count }
    var chosenSize: Int64 { chosenAdvice.reduce(0) { $0 + $1.size } + chosenPlaces.reduce(0) { $0 + $1.size } }

    func total(_ safety: PlaceSafety) -> Int64 {
        places.filter { $0.rule.safety == safety }.reduce(0) { $0 + $1.size }
    }

    func reloadAdvice() {
        advice = AdviceStore.load()
        adviceSelected.formIntersection(Set(pendingAdvice.map(\.id)))
        for item in pendingAdvice where item.verdict == .safe { adviceSelected.insert(item.id) }
    }

    func measure() async {
        guard !measuring else { return }
        measuring = true
        let groups = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: CleanupPlaces.measure())
            }
        }
        places = groups
        placeSelected = Set(groups.filter { $0.rule.safety == .safe }.flatMap { $0.items.map(\.path) })
        measuring = false
        measured = true
    }

    func keep(_ item: AdviceItem) {
        try? AdviceStore.mark([item.id], as: .kept)
        reloadAdvice()
    }
}
