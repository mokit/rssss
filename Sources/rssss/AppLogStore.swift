import Foundation

struct AppLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
}

@MainActor
final class AppLogStore: ObservableObject {
    @Published private(set) var entries: [AppLogEntry] = []

    private let capacity: Int

    init(capacity: Int = 1000) {
        self.capacity = max(100, capacity)
    }

    func add(_ message: String, at timestamp: Date = Date()) {
        entries.append(AppLogEntry(timestamp: timestamp, message: message))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
    }
}
