import CoreData

@MainActor
final class PersistenceController: ObservableObject {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        let model = ManagedModel.makeModel()
        container = NSPersistentContainer(name: "Model", managedObjectModel: model)
        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }
        container.persistentStoreDescriptions.forEach {
            $0.shouldMigrateStoreAutomatically = true
            $0.shouldInferMappingModelAutomatically = true
        }

        container.loadPersistentStores { _, error in
            if let error {
                fatalError("Unresolved Core Data error: \(error)")
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
