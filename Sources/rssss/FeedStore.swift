import Foundation
import CoreData
import FeedKit

struct ParsedFeed {
    var title: String?
    var faviconURL: String?
    var items: [ParsedItem]
}

struct ParsedItem {
    var guid: String?
    var link: String?
    var title: String?
    var summary: String?
    var pubDate: Date?
}

@MainActor
final class FeedStore: ObservableObject {
    @Published var isRefreshing = false

    private let persistence: PersistenceController

    init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    func addFeed(urlString: String) throws -> Feed {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            throw FeedError.invalidURL
        }
        guard scheme == "http" || scheme == "https" else { throw FeedError.invalidURL }
        guard scheme == "https" else { throw FeedError.insecureURL }

        let context = persistence.container.viewContext
        let request: NSFetchRequest<Feed> = Feed.fetchRequest()
        request.predicate = NSPredicate(format: "url == %@", url.absoluteString)
        request.fetchLimit = 1
        if let existing = try? context.fetch(request).first {
            return existing
        }

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = url.absoluteString
        feed.title = nil
        feed.lastRefreshedAt = nil
        feed.orderIndex = nextOrderIndex(in: context)

        try context.save()
        return feed
    }

    func deleteFeed(_ feed: Feed) throws {
        let context = persistence.container.viewContext
        guard feed.managedObjectContext === context, !feed.isDeleted else { return }
        context.delete(feed)
        try context.save()
    }

    func refresh(feed: Feed) async throws {
        guard let url = URL(string: feed.url) else { throw FeedError.invalidURL }
        isRefreshing = true
        defer { isRefreshing = false }

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(from: url)
        } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
            throw FeedError.insecureURL
        }
        let parsed = try parseFeed(data: data)

        let container = persistence.container
        let feedObjectID = feed.objectID
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        try await context.perform {
            guard let backgroundFeed = try? context.existingObject(with: feedObjectID) as? Feed else { return }
            if let title = parsed.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                backgroundFeed.title = title
            }
            if let favicon = parsed.faviconURL, !favicon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                backgroundFeed.faviconURL = favicon
            }
            backgroundFeed.lastRefreshedAt = Date()

            let request: NSFetchRequest<FeedItem> = FeedItem.fetchRequest()
            request.predicate = NSPredicate(format: "feed == %@", backgroundFeed)
            let existingItems = (try? context.fetch(request)) ?? []
            var existingKeys = Set<String>()
            existingKeys.reserveCapacity(existingItems.count)

            for item in existingItems {
                let key = Deduper.itemKey(
                    guid: item.guid,
                    link: item.link,
                    title: item.title,
                    pubDate: item.pubDate
                )
                existingKeys.insert(key)
            }

            for parsedItem in parsed.items {
                let key = Deduper.itemKey(
                    guid: parsedItem.guid,
                    link: parsedItem.link,
                    title: parsedItem.title,
                    pubDate: parsedItem.pubDate
                )
                if existingKeys.contains(key) {
                    continue
                }
                let newItem = FeedItem(context: context)
                newItem.id = UUID()
                newItem.guid = parsedItem.guid
                newItem.link = parsedItem.link
                newItem.title = parsedItem.title
                newItem.summary = parsedItem.summary
                newItem.pubDate = parsedItem.pubDate
                newItem.isRead = false
                newItem.createdAt = Date()
                newItem.feed = backgroundFeed
                existingKeys.insert(key)
            }

            if context.hasChanges {
                try context.save()
            }
        }
    }

    private func parseFeed(data: Data) throws -> ParsedFeed {
        let parser = FeedParser(data: data)
        let result = parser.parse()

        switch result {
        case .success(let feed):
            switch feed {
            case .rss(let rss):
                let items = rss.items?.compactMap { item in
                    ParsedItem(
                        guid: item.guid?.value,
                        link: item.link,
                        title: item.title,
                        summary: item.description,
                        pubDate: item.pubDate
                    )
                } ?? []
                return ParsedFeed(title: rss.title, faviconURL: rss.image?.url, items: items)
            case .atom(let atom):
                let items = atom.entries?.compactMap { entry in
                    ParsedItem(
                        guid: entry.id,
                        link: entry.links?.first?.attributes?.href,
                        title: entry.title,
                        summary: entry.summary?.value,
                        pubDate: entry.updated
                    )
                } ?? []
                return ParsedFeed(title: atom.title, faviconURL: atom.icon, items: items)
            case .json(let json):
                let items = json.items?.compactMap { item in
                    ParsedItem(
                        guid: item.id,
                        link: item.url,
                        title: item.title,
                        summary: item.summary,
                        pubDate: item.datePublished
                    )
                } ?? []
                return ParsedFeed(title: json.title, faviconURL: json.icon, items: items)
            }
        case .failure:
            throw FeedError.parseFailed
        }
    }

    func markAllRead(feed: Feed) async throws {
        let container = persistence.container
        let feedObjectID = feed.objectID
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        try await context.perform {
            guard let backgroundFeed = try? context.existingObject(with: feedObjectID) as? Feed else { return }
            let request: NSFetchRequest<FeedItem> = FeedItem.fetchRequest()
            request.predicate = NSPredicate(format: "feed == %@ AND isRead == NO", backgroundFeed)
            let unreadItems = (try? context.fetch(request)) ?? []
            for item in unreadItems {
                item.isRead = true
            }
            if context.hasChanges {
                try context.save()
            }
        }
    }

    private func nextOrderIndex(in context: NSManagedObjectContext) -> Int64 {
        let request = NSFetchRequest<NSDictionary>(entityName: "Feed")
        request.resultType = .dictionaryResultType
        let expression = NSExpressionDescription()
        expression.name = "maxOrder"
        expression.expression = NSExpression(forFunction: "max:", arguments: [NSExpression(forKeyPath: "orderIndex")])
        expression.expressionResultType = .integer64AttributeType
        request.propertiesToFetch = [expression]

        if let result = try? context.fetch(request).first,
           let maxValue = result["maxOrder"] as? Int64 {
            return maxValue + 1
        }
        return 0
    }
}

enum FeedError: LocalizedError, Equatable {
    case invalidURL
    case insecureURL
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Please enter a valid http(s) feed URL."
        case .insecureURL:
            return "This feed URL uses HTTP. Please use an HTTPS feed URL instead."
        case .parseFailed:
            return "Unable to parse this feed."
        }
    }
}

enum Deduper {
    static func itemKey(guid: String?, link: String?, title: String?, pubDate: Date?) -> String {
        let trimmedGuid = guid?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedGuid, !trimmedGuid.isEmpty {
            return "guid:\(trimmedGuid)"
        }

        let trimmedLink = link?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedLink, !trimmedLink.isEmpty {
            if let pubDate {
                return "link:\(trimmedLink)|date:\(Int(pubDate.timeIntervalSince1970))"
            }
            return "link:\(trimmedLink)"
        }

        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTitle, !trimmedTitle.isEmpty {
            if let pubDate {
                return "title:\(trimmedTitle)|date:\(Int(pubDate.timeIntervalSince1970))"
            }
            return "title:\(trimmedTitle)"
        }

        if let pubDate {
            return "date:\(Int(pubDate.timeIntervalSince1970))"
        }

        return UUID().uuidString
    }
}
