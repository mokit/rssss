import SwiftUI
import CoreData

struct ItemFramePreferenceKey: PreferenceKey {
    static var defaultValue: [NSManagedObjectID: CGRect] = [:]

    static func reduce(value: inout [NSManagedObjectID: CGRect], nextValue: () -> [NSManagedObjectID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

enum ReadTracker {
    static func itemsToMarkRead(itemFrames: [NSManagedObjectID: CGRect], containerMinY: CGFloat) -> [NSManagedObjectID] {
        itemFrames.compactMap { key, frame in
            frame.maxY < containerMinY ? key : nil
        }
    }
}

@MainActor
final class ReadMarker: ObservableObject {
    private let persistence: PersistenceController
    private var pending = Set<NSManagedObjectID>()
    private var flushTask: Task<Void, Never>?

    init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    func queue(_ objectIDs: [NSManagedObjectID]) {
        guard !objectIDs.isEmpty else { return }
        for id in objectIDs {
            pending.insert(id)
        }

        flushTask?.cancel()
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self else { return }
            let snapshot = self.pending
            self.pending.removeAll()
            await self.persistence.markItemsRead(objectIDs: Array(snapshot))
        }
    }
}
