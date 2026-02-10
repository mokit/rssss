import CoreData

@MainActor
final class PersistenceController: ObservableObject {
    static let shared = PersistenceController()

    let container: NSPersistentContainer
    @Published private(set) var isLoaded = false

    init(inMemory: Bool = false) {
        let model = ManagedModel.shared
        container = NSPersistentContainer(name: "Model", managedObjectModel: model)
        container.viewContext.persistentStoreCoordinator = container.persistentStoreCoordinator
        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }
        container.persistentStoreDescriptions.forEach {
            $0.shouldMigrateStoreAutomatically = true
            $0.shouldInferMappingModelAutomatically = true
            $0.shouldAddStoreAsynchronously = false
        }

        container.loadPersistentStores { _, error in
            if let error {
                fatalError("Unresolved Core Data error: \(error)")
            }
            Task { @MainActor in
                self.isLoaded = true
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    func markItemsRead(objectIDs: [NSManagedObjectID]) async {
        guard !objectIDs.isEmpty else { return }
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        await context.perform {
            for objectID in objectIDs {
                guard let item = try? context.existingObject(with: objectID) as? FeedItem else { continue }
                if !item.isRead {
                    item.isRead = true
                }
            }
            if context.hasChanges {
                try? context.save()
            }
        }
    }
}
