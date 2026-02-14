import CoreData

@MainActor
final class FeedsController: NSObject, ObservableObject, @preconcurrency NSFetchedResultsControllerDelegate {
    @Published private(set) var feeds: [Feed] = []

    private let controller: NSFetchedResultsController<Feed>

    init(context: NSManagedObjectContext) {
        let request: NSFetchRequest<Feed> = Feed.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Feed.orderIndex, ascending: true),
            NSSortDescriptor(keyPath: \Feed.title, ascending: true),
            NSSortDescriptor(keyPath: \Feed.url, ascending: true)
        ]
        controller = NSFetchedResultsController(
            fetchRequest: request,
            managedObjectContext: context,
            sectionNameKeyPath: nil,
            cacheName: nil
        )
        super.init()
        controller.delegate = self
        try? controller.performFetch()
        feeds = (controller.fetchedObjects ?? []).filter { !$0.isDeleted && $0.managedObjectContext != nil }
    }

    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        feeds = (self.controller.fetchedObjects ?? []).filter { !$0.isDeleted && $0.managedObjectContext != nil }
    }
}

@MainActor
final class UnreadCountsController: NSObject, ObservableObject, @preconcurrency NSFetchedResultsControllerDelegate {
    @Published private(set) var counts: [NSManagedObjectID: Int] = [:]

    private let controller: NSFetchedResultsController<FeedItem>

    init(context: NSManagedObjectContext) {
        let request: NSFetchRequest<FeedItem> = FeedItem.fetchRequest()
        request.predicate = NSPredicate(format: "isRead == NO OR isRead == NIL")
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \FeedItem.createdAt, ascending: false)
        ]
        controller = NSFetchedResultsController(
            fetchRequest: request,
            managedObjectContext: context,
            sectionNameKeyPath: nil,
            cacheName: nil
        )
        super.init()
        controller.delegate = self
        try? controller.performFetch()
        rebuildCounts()
    }

    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        rebuildCounts()
    }

    private func rebuildCounts() {
        let context = controller.managedObjectContext
        let request = NSFetchRequest<NSDictionary>(entityName: "FeedItem")
        request.resultType = .dictionaryResultType
        request.predicate = NSPredicate(format: "isRead == NO OR isRead == NIL")
        request.propertiesToGroupBy = ["feed"]

        let countExpression = NSExpressionDescription()
        countExpression.name = "count"
        countExpression.expression = NSExpression(
            forFunction: "count:",
            arguments: [NSExpression(forKeyPath: "feed")]
        )
        countExpression.expressionResultType = .integer64AttributeType
        request.propertiesToFetch = ["feed", countExpression]

        let rows = (try? context.fetch(request)) ?? []
        var next: [NSManagedObjectID: Int] = [:]
        next.reserveCapacity(rows.count)
        for row in rows {
            let countValue: Int
            if let number = row["count"] as? NSNumber {
                countValue = number.intValue
            } else if let intValue = row["count"] as? Int {
                countValue = intValue
            } else if let int64Value = row["count"] as? Int64 {
                countValue = Int(int64Value)
            } else {
                continue
            }
            guard countValue > 0 else {
                continue
            }

            if let feedID = row["feed"] as? NSManagedObjectID {
                guard let feed = try? context.existingObject(with: feedID) as? Feed,
                      !feed.isDeleted,
                      feed.managedObjectContext != nil else {
                    continue
                }
                next[feedID] = countValue
            } else if let feed = row["feed"] as? Feed, !feed.isDeleted, feed.managedObjectContext != nil {
                next[feed.objectID] = countValue
            }
        }
        counts = next
    }
}

@MainActor
final class FeedItemsController: NSObject, ObservableObject, @preconcurrency NSFetchedResultsControllerDelegate {
    @Published private(set) var items: [FeedItem] = []

    private let controller: NSFetchedResultsController<FeedItem>
    private let pageSize: Int
    private var fetchLimit: Int
    private static let maxAutoExpandPages = 5

    var currentFetchLimit: Int {
        fetchLimit
    }

    var canLoadMore: Bool {
        !items.isEmpty && items.count >= fetchLimit
    }

    init(
        context: NSManagedObjectContext,
        feedObjectID: NSManagedObjectID,
        initialFetchLimit: Int = RefreshSettings.defaultInitialFeedItemsLimit
    ) {
        let normalizedLimit = max(1, initialFetchLimit)
        pageSize = normalizedLimit
        fetchLimit = normalizedLimit

        let request: NSFetchRequest<FeedItem> = FeedItem.fetchRequest()
        if let feed = try? context.existingObject(with: feedObjectID) as? Feed {
            request.predicate = NSPredicate(format: "feed == %@", feed)
        } else {
            request.predicate = NSPredicate(value: false)
        }
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \FeedItem.pubDate, ascending: false),
            NSSortDescriptor(keyPath: \FeedItem.createdAt, ascending: false)
        ]
        request.fetchLimit = normalizedLimit
        request.fetchBatchSize = normalizedLimit
        controller = NSFetchedResultsController(
            fetchRequest: request,
            managedObjectContext: context,
            sectionNameKeyPath: nil,
            cacheName: nil
        )
        super.init()
        controller.delegate = self
        try? controller.performFetch()
        applyFetchedObjects()
    }

    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        applyFetchedObjects()
    }

    func loadMore() {
        resetFetchLimit(to: fetchLimit + pageSize)
    }

    func resetFetchLimit(to limit: Int) {
        let normalizedLimit = max(1, limit)
        fetchLimit = normalizedLimit
        controller.fetchRequest.fetchLimit = normalizedLimit
        controller.fetchRequest.fetchBatchSize = pageSize
        try? controller.performFetch()
        applyFetchedObjects()
    }

    @discardableResult
    func maybeAutoExpandForUnread(showRead: Bool, sessionUnreadIDs: Set<NSManagedObjectID>) -> Int {
        guard !showRead else { return 0 }

        var expandedPages = 0
        while expandedPages < Self.maxAutoExpandPages {
            if Self.hasVisibleUnread(items: items, sessionUnreadIDs: sessionUnreadIDs) {
                break
            }
            guard canLoadMore else {
                break
            }
            loadMore()
            expandedPages += 1
        }

        return expandedPages
    }

    private func applyFetchedObjects() {
        items = (controller.fetchedObjects ?? []).filter { !$0.isDeleted && $0.managedObjectContext != nil }
    }

    private static func hasVisibleUnread(items: [FeedItem], sessionUnreadIDs: Set<NSManagedObjectID>) -> Bool {
        items.contains { item in
            item.isEffectivelyUnread || sessionUnreadIDs.contains(item.objectID)
        }
    }
}

@MainActor
final class StarredItemsController: NSObject, ObservableObject, @preconcurrency NSFetchedResultsControllerDelegate {
    @Published private(set) var items: [FeedItem] = []

    private let controller: NSFetchedResultsController<FeedItem>
    private let pageSize: Int
    private var fetchLimit: Int

    var currentFetchLimit: Int {
        fetchLimit
    }

    var canLoadMore: Bool {
        !items.isEmpty && items.count >= fetchLimit
    }

    init(
        context: NSManagedObjectContext,
        initialFetchLimit: Int = RefreshSettings.defaultInitialFeedItemsLimit
    ) {
        let normalizedLimit = max(1, initialFetchLimit)
        pageSize = normalizedLimit
        fetchLimit = normalizedLimit

        let request: NSFetchRequest<FeedItem> = FeedItem.fetchRequest()
        request.predicate = NSPredicate(format: "isStarred == YES")
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \FeedItem.pubDate, ascending: false),
            NSSortDescriptor(keyPath: \FeedItem.createdAt, ascending: false)
        ]
        request.fetchLimit = normalizedLimit
        request.fetchBatchSize = normalizedLimit
        controller = NSFetchedResultsController(
            fetchRequest: request,
            managedObjectContext: context,
            sectionNameKeyPath: nil,
            cacheName: nil
        )
        super.init()
        controller.delegate = self
        try? controller.performFetch()
        applyFetchedObjects()
    }

    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        applyFetchedObjects()
    }

    func loadMore() {
        resetFetchLimit(to: fetchLimit + pageSize)
    }

    func resetFetchLimit(to limit: Int) {
        let normalizedLimit = max(1, limit)
        fetchLimit = normalizedLimit
        controller.fetchRequest.fetchLimit = normalizedLimit
        controller.fetchRequest.fetchBatchSize = pageSize
        try? controller.performFetch()
        applyFetchedObjects()
    }

    private func applyFetchedObjects() {
        items = (controller.fetchedObjects ?? []).filter { !$0.isDeleted && $0.managedObjectContext != nil }
    }
}

@MainActor
final class StarredCountController: NSObject, ObservableObject, @preconcurrency NSFetchedResultsControllerDelegate {
    @Published private(set) var count: Int = 0

    private let controller: NSFetchedResultsController<FeedItem>

    init(context: NSManagedObjectContext) {
        let request: NSFetchRequest<FeedItem> = FeedItem.fetchRequest()
        request.predicate = NSPredicate(format: "isStarred == YES")
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \FeedItem.createdAt, ascending: false)
        ]
        controller = NSFetchedResultsController(
            fetchRequest: request,
            managedObjectContext: context,
            sectionNameKeyPath: nil,
            cacheName: nil
        )
        super.init()
        controller.delegate = self
        try? controller.performFetch()
        rebuildCount()
    }

    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        rebuildCount()
    }

    private func rebuildCount() {
        let context = controller.managedObjectContext
        let request: NSFetchRequest<FeedItem> = FeedItem.fetchRequest()
        request.predicate = NSPredicate(format: "isStarred == YES")
        count = (try? context.count(for: request)) ?? 0
    }
}
