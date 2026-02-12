import CoreData

enum SidebarSelection: Equatable {
    case starred
    case feed(NSManagedObjectID)

    var feedObjectID: NSManagedObjectID? {
        switch self {
        case .starred:
            return nil
        case .feed(let objectID):
            return objectID
        }
    }
}
