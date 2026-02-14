import CoreData

@MainActor
final class ManagedModel {
    static let shared = ManagedModel.makeModel()

    static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let feedEntity = NSEntityDescription()
        feedEntity.name = "Feed"
        feedEntity.managedObjectClassName = NSStringFromClass(Feed.self)

        let feedId = NSAttributeDescription()
        feedId.name = "id"
        feedId.attributeType = .UUIDAttributeType
        feedId.isOptional = false

        let feedTitle = NSAttributeDescription()
        feedTitle.name = "title"
        feedTitle.attributeType = .stringAttributeType
        feedTitle.isOptional = true

        let feedUrl = NSAttributeDescription()
        feedUrl.name = "url"
        feedUrl.attributeType = .stringAttributeType
        feedUrl.isOptional = false

        let feedLastRefreshed = NSAttributeDescription()
        feedLastRefreshed.name = "lastRefreshedAt"
        feedLastRefreshed.attributeType = .dateAttributeType
        feedLastRefreshed.isOptional = true

        let feedFaviconURL = NSAttributeDescription()
        feedFaviconURL.name = "faviconURL"
        feedFaviconURL.attributeType = .stringAttributeType
        feedFaviconURL.isOptional = true

        let feedOrderIndex = NSAttributeDescription()
        feedOrderIndex.name = "orderIndex"
        feedOrderIndex.attributeType = .integer64AttributeType
        feedOrderIndex.isOptional = false
        feedOrderIndex.defaultValue = 0

        let itemEntity = NSEntityDescription()
        itemEntity.name = "FeedItem"
        itemEntity.managedObjectClassName = NSStringFromClass(FeedItem.self)

        let itemId = NSAttributeDescription()
        itemId.name = "id"
        itemId.attributeType = .UUIDAttributeType
        itemId.isOptional = false

        let itemGuid = NSAttributeDescription()
        itemGuid.name = "guid"
        itemGuid.attributeType = .stringAttributeType
        itemGuid.isOptional = true

        let itemLink = NSAttributeDescription()
        itemLink.name = "link"
        itemLink.attributeType = .stringAttributeType
        itemLink.isOptional = true

        let itemTitle = NSAttributeDescription()
        itemTitle.name = "title"
        itemTitle.attributeType = .stringAttributeType
        itemTitle.isOptional = true

        let itemSummary = NSAttributeDescription()
        itemSummary.name = "summary"
        itemSummary.attributeType = .stringAttributeType
        itemSummary.isOptional = true

        let itemPubDate = NSAttributeDescription()
        itemPubDate.name = "pubDate"
        itemPubDate.attributeType = .dateAttributeType
        itemPubDate.isOptional = true

        let itemIsRead = NSAttributeDescription()
        itemIsRead.name = "isRead"
        itemIsRead.attributeType = .booleanAttributeType
        itemIsRead.isOptional = false
        itemIsRead.defaultValue = false

        let itemIsStarred = NSAttributeDescription()
        itemIsStarred.name = "isStarred"
        itemIsStarred.attributeType = .booleanAttributeType
        itemIsStarred.isOptional = false
        itemIsStarred.defaultValue = false

        let itemCreatedAt = NSAttributeDescription()
        itemCreatedAt.name = "createdAt"
        itemCreatedAt.attributeType = .dateAttributeType
        itemCreatedAt.isOptional = false

        let itemsRel = NSRelationshipDescription()
        itemsRel.name = "items"
        itemsRel.destinationEntity = itemEntity
        itemsRel.minCount = 0
        itemsRel.maxCount = 0
        itemsRel.deleteRule = .cascadeDeleteRule
        itemsRel.isOptional = true
        itemsRel.isOrdered = false

        let feedRel = NSRelationshipDescription()
        feedRel.name = "feed"
        feedRel.destinationEntity = feedEntity
        feedRel.minCount = 1
        feedRel.maxCount = 1
        feedRel.deleteRule = .nullifyDeleteRule
        feedRel.isOptional = false

        itemsRel.inverseRelationship = feedRel
        feedRel.inverseRelationship = itemsRel

        feedEntity.properties = [
            feedId,
            feedTitle,
            feedUrl,
            feedLastRefreshed,
            feedFaviconURL,
            feedOrderIndex,
            itemsRel
        ]

        itemEntity.properties = [
            itemId,
            itemGuid,
            itemLink,
            itemTitle,
            itemSummary,
            itemPubDate,
            itemIsRead,
            itemIsStarred,
            itemCreatedAt,
            feedRel
        ]

        feedEntity.uniquenessConstraints = [["url"]]

        model.entities = [feedEntity, itemEntity]
        return model
    }
}

@objc(Feed)
final class Feed: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var title: String?
    @NSManaged var url: String
    @NSManaged var lastRefreshedAt: Date?
    @NSManaged var faviconURL: String?
    @NSManaged var orderIndex: Int64
    @NSManaged var items: Set<FeedItem>?
}

extension Feed: Identifiable {}

extension Feed {
    @nonobjc class func fetchRequest() -> NSFetchRequest<Feed> {
        NSFetchRequest<Feed>(entityName: "Feed")
    }

    var displayName: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return URL(string: url)?.host ?? url
    }

    var resolvedFaviconURL: URL? {
        guard let faviconURL else { return nil }
        let trimmed = faviconURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        // Prefer absolute favicon URLs from the feed.
        if let absolute = URL(string: trimmed), let scheme = absolute.scheme, !scheme.isEmpty {
            return absolute
        }

        // Some feeds emit relative favicon paths (for example "/favicon.ico").
        // Resolve them against the feed URL so AsyncImage receives a valid absolute URL.
        guard let baseFeedURL = URL(string: url) else { return nil }
        return URL(string: trimmed, relativeTo: baseFeedURL)?.absoluteURL
    }
}

@objc(FeedItem)
final class FeedItem: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var guid: String?
    @NSManaged var link: String?
    @NSManaged var title: String?
    @NSManaged var summary: String?
    @NSManaged var pubDate: Date?
    @NSManaged var isRead: Bool
    @NSManaged var isStarred: Bool
    @NSManaged var createdAt: Date
    @NSManaged var feed: Feed
}

extension FeedItem {
    @nonobjc class func fetchRequest() -> NSFetchRequest<FeedItem> {
        NSFetchRequest<FeedItem>(entityName: "FeedItem")
    }

    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed! : "(Untitled)"
    }

    var displaySummary: String {
        summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // Treat legacy nil read flags as unread so list filtering matches unread badge counts.
    var isEffectivelyUnread: Bool {
        primitiveValue(forKey: "isRead") == nil || !isRead
    }

    var isEffectivelyRead: Bool {
        !isEffectivelyUnread
    }
}
