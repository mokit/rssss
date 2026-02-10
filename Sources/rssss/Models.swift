import CoreData

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
        if let faviconURL, let url = URL(string: faviconURL) {
            return url
        }
        guard let feedURL = URL(string: url), let host = feedURL.host else { return nil }
        var components = URLComponents()
        components.scheme = feedURL.scheme ?? "https"
        components.host = host
        components.path = "/favicon.ico"
        return components.url
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
        let trimmed = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return ""
        }
        return trimmed.plainTextFromHTML()
    }
}

private extension String {
    func plainTextFromHTML() -> String {
        guard let data = data(using: .utf8) else { return self }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil)
        let string = attributed?.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return string?.isEmpty == false ? string! : self
    }
}
