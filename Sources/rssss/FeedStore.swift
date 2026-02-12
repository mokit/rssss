import Foundation
import CoreData
import FeedKit
import os.log

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

struct OPMLImportResult {
    let addedCount: Int
    let existingCount: Int
    let feedObjectIDs: [NSManagedObjectID]
    let skippedNonHTTPSCount: Int
    let skippedNonHTTPSFeedURLs: [String]
    let refreshFailures: [FeedRefreshFailure]

    var importedCount: Int {
        addedCount + existingCount
    }

    var refreshFailedCount: Int {
        refreshFailures.count
    }
}

struct FeedRefreshFailure: Equatable {
    let feedURL: String
    let reason: String
}

@MainActor
final class FeedStore: ObservableObject {
    @Published var isRefreshing = false

    private static let logger = Logger(subsystem: "rssss", category: "network")
    private static let requestTimeout: TimeInterval = 15
    private static let resourceTimeout: TimeInterval = 30
    private static let maxNetworkAttempts = 3
    private static let backoffDelaysNanos: [UInt64] = [
        300_000_000,
        900_000_000
    ]

    private let persistence: PersistenceController
    private let urlSession: URLSession
    private let userDefaults: UserDefaults
    private let logStore: AppLogStore?

    init(
        persistence: PersistenceController,
        urlSession: URLSession? = nil,
        userDefaults: UserDefaults = .standard,
        logStore: AppLogStore? = nil
    ) {
        self.persistence = persistence
        self.urlSession = urlSession ?? FeedStore.makeURLSession()
        self.userDefaults = userDefaults
        self.logStore = logStore
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

    func importOPML(urlString: String) async throws -> OPMLImportResult {
        let opmlURL = try validateOPMLURL(urlString: urlString)
        let opmlData = try await fetchOPMLData(from: opmlURL)
        let rawFeedURLs = try OPMLDocumentParser.parseFeedURLs(data: opmlData)
        let sanitizeResult = sanitizeAndFilterHTTPSURLs(rawFeedURLs)
        let feedURLs = sanitizeResult.urls
        guard !feedURLs.isEmpty else { throw FeedError.opmlContainsNoValidFeeds }

        var existingURLs = try fetchExistingFeedURLSet()
        var feedObjectIDs: [NSManagedObjectID] = []
        feedObjectIDs.reserveCapacity(feedURLs.count)

        var addedCount = 0
        var existingCount = 0
        var refreshFailures: [FeedRefreshFailure] = []

        for feedURL in feedURLs {
            let wasExisting = existingURLs.contains(feedURL)
            let feed = try addFeed(urlString: feedURL)
            if wasExisting {
                existingCount += 1
            } else {
                addedCount += 1
                existingURLs.insert(feedURL)
            }
            feedObjectIDs.append(feed.objectID)
        }

        let context = persistence.container.viewContext
        for feedObjectID in feedObjectIDs {
            guard let feed = try? context.existingObject(with: feedObjectID) as? Feed else { continue }
            do {
                try await refresh(feed: feed)
            } catch {
                refreshFailures.append(
                    FeedRefreshFailure(feedURL: feed.url, reason: error.localizedDescription)
                )
                logStore?.add("OPML refresh failed for \(feed.url): \(error.localizedDescription)")
            }
        }

        return OPMLImportResult(
            addedCount: addedCount,
            existingCount: existingCount,
            feedObjectIDs: feedObjectIDs,
            skippedNonHTTPSCount: sanitizeResult.skippedNonHTTPSCount,
            skippedNonHTTPSFeedURLs: sanitizeResult.skippedNonHTTPSFeedURLs,
            refreshFailures: refreshFailures
        )
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
        logStore?.add("Refresh started for \(feed.url)")

        let data: Data
        do {
            data = try await fetchFeedData(from: url)
        } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
            logStore?.add("Refresh failed for \(feed.url): \(FeedError.insecureURL.localizedDescription)")
            throw FeedError.insecureURL
        } catch {
            logStore?.add("Refresh failed for \(feed.url): \(error.localizedDescription)")
            throw error
        }
        let parsed: ParsedFeed
        do {
            parsed = try parseFeed(data: data)
        } catch {
            logStore?.add("Refresh failed for \(feed.url): \(error.localizedDescription)")
            throw error
        }

        let container = persistence.container
        let feedObjectID = feed.objectID
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        let insertedCount = try await context.perform { () -> Int in
            guard let backgroundFeed = try? context.existingObject(with: feedObjectID) as? Feed else { return 0 }
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

            var insertedCount = 0
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
                newItem.summary = SummaryNormalizer.normalized(parsedItem.summary)
                newItem.pubDate = parsedItem.pubDate
                newItem.isRead = false
                newItem.isStarred = false
                newItem.createdAt = Date()
                newItem.feed = backgroundFeed
                existingKeys.insert(key)
                insertedCount += 1
            }

            if context.hasChanges {
                try context.save()
            }
            return insertedCount
        }
        let dedupedCount = max(0, parsed.items.count - insertedCount)
        logStore?.add(
            "Refresh succeeded for \(feed.url); fetched=\(parsed.items.count), inserted=\(insertedCount), deduped=\(dedupedCount)"
        )
    }

    func normalizeLegacySummaries(feedObjectID: NSManagedObjectID, maxItemsPerRun: Int = 500) async {
        let clampedMaxItems = max(1, maxItemsPerRun)
        let context = persistence.container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        let (feedURL, normalizedCount) = await context.perform { () -> (String?, Int) in
            guard let feed = try? context.existingObject(with: feedObjectID) as? Feed else {
                return (nil, 0)
            }

            let request: NSFetchRequest<FeedItem> = FeedItem.fetchRequest()
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "feed == %@", feed),
                NSPredicate(format: "summary != nil")
            ])
            request.sortDescriptors = [
                NSSortDescriptor(keyPath: \FeedItem.createdAt, ascending: false)
            ]
            request.fetchLimit = clampedMaxItems
            request.fetchBatchSize = clampedMaxItems

            let items = (try? context.fetch(request)) ?? []
            guard !items.isEmpty else {
                return (feed.url, 0)
            }

            var changedCount = 0
            for item in items {
                let normalized = SummaryNormalizer.normalized(item.summary)
                if item.summary != normalized {
                    item.summary = normalized
                    changedCount += 1
                }
            }

            if context.hasChanges {
                try? context.save()
            }

            return (feed.url, changedCount)
        }

        guard normalizedCount > 0, let feedURL else { return }
        logStore?.add(
            "Normalized legacy summaries for \(feedURL); updated=\(normalizedCount), scanned=\(clampedMaxItems)"
        )
    }

    private func fetchFeedData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout

        var attempt = 0
        while true {
            do {
                let (data, _) = try await urlSession.data(for: request)
                if attempt > 0 {
                    Self.logger.info("Recovered feed request after retry for \(url.absoluteString, privacy: .public)")
                }
                return data
            } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
                throw error
            } catch let error as URLError where shouldRetry(error) && attempt < Self.maxNetworkAttempts - 1 {
                Self.logger.error(
                    "Feed request transient failure for \(url.absoluteString, privacy: .public), attempt \(attempt + 1)/\(Self.maxNetworkAttempts), code \(error.code.rawValue): \(error.localizedDescription, privacy: .public)"
                )
                if attempt < Self.backoffDelaysNanos.count {
                    try await Task.sleep(nanoseconds: Self.backoffDelaysNanos[attempt])
                }
                attempt += 1
                continue
            } catch {
                if let urlError = error as? URLError {
                    Self.logger.error(
                        "Feed request failed for \(url.absoluteString, privacy: .public), code \(urlError.code.rawValue): \(urlError.localizedDescription, privacy: .public)"
                    )
                } else {
                    Self.logger.error(
                        "Feed request failed for \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                }
                throw error
            }
        }
    }

    private func validateOPMLURL(urlString: String) throws -> URL {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https" else {
            throw FeedError.invalidOPMLURL
        }
        return url
    }

    private func fetchOPMLData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout

        do {
            let (data, response) = try await urlSession.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw FeedError.opmlFetchFailed
            }
            return data
        } catch let error as FeedError {
            throw error
        } catch {
            throw FeedError.opmlFetchFailed
        }
    }

    private func sanitizeAndFilterHTTPSURLs(_ rawURLs: [String]) -> (urls: [String], skippedNonHTTPSCount: Int, skippedNonHTTPSFeedURLs: [String]) {
        var deduped: [String] = []
        var seen = Set<String>()
        var skippedNonHTTPSCount = 0
        var skippedNonHTTPSFeedURLs: [String] = []
        var seenSkippedNonHTTPS = Set<String>()

        for raw in rawURLs {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let url = URL(string: trimmed) else { continue }
            guard url.scheme?.lowercased() == "https" else {
                skippedNonHTTPSCount += 1
                let candidate = url.absoluteString
                if !seenSkippedNonHTTPS.contains(candidate) {
                    seenSkippedNonHTTPS.insert(candidate)
                    skippedNonHTTPSFeedURLs.append(candidate)
                }
                continue
            }
            let canonical = url.absoluteString
            guard !seen.contains(canonical) else { continue }
            seen.insert(canonical)
            deduped.append(canonical)
        }

        return (deduped, skippedNonHTTPSCount, skippedNonHTTPSFeedURLs)
    }

    private func fetchExistingFeedURLSet() throws -> Set<String> {
        let context = persistence.container.viewContext
        let request = NSFetchRequest<NSDictionary>(entityName: "Feed")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["url"]

        let results = try context.fetch(request)
        return Set(results.compactMap { $0["url"] as? String })
    }

    private func shouldRetry(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut,
                .networkConnectionLost,
                .cannotConnectToHost,
                .cannotFindHost,
                .dnsLookupFailed,
                .notConnectedToInternet,
                .internationalRoamingOff,
                .callIsActive,
                .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    private static func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }

    func refreshAllFeeds() async {
        guard !isRefreshing else { return }
        let feeds: [Feed]
        do {
            feeds = try fetchFeedsForRefresh()
        } catch {
            return
        }

        for feed in feeds {
            do {
                try await refresh(feed: feed)
            } catch {
                continue
            }
        }
    }

    func refreshNextFeedInRoundRobin() async {
        guard !isRefreshing else { return }

        let feeds: [Feed]
        do {
            feeds = try fetchFeedsForRefresh()
        } catch {
            return
        }

        guard !feeds.isEmpty else {
            clearRoundRobinCursor()
            return
        }

        let selectedFeedIndex: Int
        if let cursorURL = roundRobinCursorFeedURL(),
           let currentIndex = feeds.firstIndex(where: { $0.url == cursorURL }) {
            selectedFeedIndex = (currentIndex + 1) % feeds.count
        } else {
            selectedFeedIndex = 0
        }

        let selectedFeed = feeds[selectedFeedIndex]
        setRoundRobinCursorFeedURL(selectedFeed.url)
        logStore?.add("Round-robin selecting feed \(selectedFeed.url)")

        do {
            try await refresh(feed: selectedFeed)
        } catch {
            Self.logger.error(
                "Round-robin refresh failed for \(selectedFeed.url, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            logStore?.add("Round-robin refresh failed for \(selectedFeed.url): \(error.localizedDescription)")
        }
    }

    func refreshRoundRobinBatch(targetCycleInterval: TimeInterval, tickInterval: TimeInterval) async {
        guard targetCycleInterval > 0, tickInterval > 0 else { return }

        let feeds: [Feed]
        do {
            feeds = try fetchFeedsForRefresh()
        } catch {
            return
        }

        let feedCount = feeds.count
        guard feedCount > 0 else {
            clearRoundRobinCursor()
            return
        }

        let ratio = min(1, tickInterval / targetCycleInterval)
        let scaledCount = Int(ceil(Double(feedCount) * ratio))
        let batchSize = max(1, min(feedCount, scaledCount))
        logStore?.add(
            "Round-robin batch refresh starting: feeds=\(feedCount), batchSize=\(batchSize), tick=\(Int(tickInterval))s, targetCycle=\(Int(targetCycleInterval))s"
        )

        for _ in 0..<batchSize {
            await refreshNextFeedInRoundRobin()
        }
    }

    func fetchFeedsForRefresh() throws -> [Feed] {
        let context = persistence.container.viewContext
        let request: NSFetchRequest<Feed> = Feed.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(key: "orderIndex", ascending: true),
            NSSortDescriptor(key: "url", ascending: true)
        ]
        return try context.fetch(request)
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
        try await markAllRead(feedObjectID: feed.objectID)
    }

    func toggleStarred(itemObjectID: NSManagedObjectID) throws {
        let context = persistence.container.viewContext
        guard let item = try context.existingObject(with: itemObjectID) as? FeedItem, !item.isDeleted else {
            return
        }

        item.isStarred.toggle()
        if context.hasChanges {
            try context.save()
        }
    }

    func setStarred(itemObjectID: NSManagedObjectID, isStarred: Bool) throws {
        let context = persistence.container.viewContext
        guard let item = try context.existingObject(with: itemObjectID) as? FeedItem, !item.isDeleted else {
            return
        }
        guard item.isStarred != isStarred else { return }

        item.isStarred = isStarred
        if context.hasChanges {
            try context.save()
        }
    }

    func markAllRead(feedObjectID: NSManagedObjectID) async throws {
        let container = persistence.container
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        let updatedObjectIDs: [NSManagedObjectID] = try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    guard let backgroundFeed = try? context.existingObject(with: feedObjectID) as? Feed else {
                        continuation.resume(returning: [])
                        return
                    }

                    let fetchRequest = NSFetchRequest<FeedItem>(entityName: "FeedItem")
                    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                        NSPredicate(format: "feed == %@", backgroundFeed),
                        NSPredicate(format: "isRead == NO")
                    ])
                    let items = try context.fetch(fetchRequest)
                    guard !items.isEmpty else {
                        continuation.resume(returning: [])
                        return
                    }

                    for item in items {
                        item.isRead = true
                    }
                    try context.save()
                    let objectIDs = items.map(\.objectID)
                    continuation.resume(returning: objectIDs)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        guard !updatedObjectIDs.isEmpty else { return }
        NSManagedObjectContext.mergeChanges(
            fromRemoteContextSave: [NSUpdatedObjectsKey: updatedObjectIDs],
            into: [container.viewContext]
        )
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

    private func roundRobinCursorFeedURL() -> String? {
        userDefaults.string(forKey: RefreshSettings.lastRoundRobinFeedURLKey)
    }

    private func setRoundRobinCursorFeedURL(_ url: String) {
        userDefaults.set(url, forKey: RefreshSettings.lastRoundRobinFeedURLKey)
    }

    private func clearRoundRobinCursor() {
        userDefaults.removeObject(forKey: RefreshSettings.lastRoundRobinFeedURLKey)
    }
}

enum FeedError: LocalizedError, Equatable {
    case invalidURL
    case insecureURL
    case parseFailed
    case invalidOPMLURL
    case opmlFetchFailed
    case opmlParseFailed
    case opmlContainsNoValidFeeds

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Please enter a valid http(s) feed URL."
        case .insecureURL:
            return "This feed URL uses HTTP. Please use an HTTPS feed URL instead."
        case .parseFailed:
            return "Unable to parse this feed."
        case .invalidOPMLURL:
            return "Please enter a valid HTTPS OPML URL."
        case .opmlFetchFailed:
            return "Unable to download this OPML file."
        case .opmlParseFailed:
            return "Unable to parse this OPML file."
        case .opmlContainsNoValidFeeds:
            return "No valid HTTPS feed URLs were found in this OPML file."
        }
    }
}

final class OPMLDocumentParser: NSObject, XMLParserDelegate {
    private var feedURLs: [String] = []

    static func parseFeedURLs(data: Data) throws -> [String] {
        let parserDelegate = OPMLDocumentParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        guard parser.parse() else {
            throw FeedError.opmlParseFailed
        }
        return parserDelegate.feedURLs
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        guard elementName.caseInsensitiveCompare("outline") == .orderedSame else { return }
        guard let xmlURL = attributeDict.first(where: { $0.key.caseInsensitiveCompare("xmlUrl") == .orderedSame })?.value else {
            return
        }
        let trimmed = xmlURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        feedURLs.append(trimmed)
    }
}

enum Deduper {
    static func itemKey(guid: String?, link: String?, title: String?, pubDate: Date?) -> String {
        let trimmedGuid = guid?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedGuid, !trimmedGuid.isEmpty {
            return "guid:\(trimmedGuid)"
        }

        let trimmedLink = link?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var components: [String] = []
        if let trimmedLink, !trimmedLink.isEmpty {
            components.append("link:\(trimmedLink)")
        }
        if let trimmedTitle, !trimmedTitle.isEmpty {
            components.append("title:\(trimmedTitle)")
        }

        if let pubDate {
            components.append("date:\(Int(pubDate.timeIntervalSince1970))")
        }

        if !components.isEmpty {
            return components.joined(separator: "|")
        }

        return UUID().uuidString
    }
}
