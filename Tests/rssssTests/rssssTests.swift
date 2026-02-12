import XCTest
import CoreData
import AppKit
@testable import rssss

final class rssssTests: XCTestCase {
    func testDeduperPrefersGuid() {
        let key = Deduper.itemKey(guid: "abc", link: "https://example.com", title: "Title", pubDate: nil)
        XCTAssertEqual(key, "guid:abc")
    }

    func testDeduperUsesLinkAndTitleWhenNoGuid() {
        let first = Deduper.itemKey(guid: nil, link: "https://example.com/post", title: "Title A", pubDate: nil)
        let second = Deduper.itemKey(guid: nil, link: "https://example.com/post", title: "Title B", pubDate: nil)
        XCTAssertNotEqual(first, second)
    }

    func testDeduperIncludesDateWhenAvailable() {
        let link = "https://example.com/post"
        let title = "Same title"
        let first = Deduper.itemKey(
            guid: nil,
            link: link,
            title: title,
            pubDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let second = Deduper.itemKey(
            guid: nil,
            link: link,
            title: title,
            pubDate: Date(timeIntervalSince1970: 1_700_000_001)
        )
        XCTAssertNotEqual(first, second)
    }

    func testSummaryNormalizerConvertsHTMLAndTrims() {
        let normalized = SummaryNormalizer.normalized("  <p>Hello <b>world</b></p>  ")
        XCTAssertEqual(normalized, "Hello world")
    }

    @MainActor
    func testRefreshStoresNormalizedSummaryText() async {
        let persistence = PersistenceController(inMemory: true)
        let feedURL = URL(string: "https://example.com/feed.xml")!
        let rss = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Example Feed</title>
            <item>
              <guid>item-1</guid>
              <title>First item</title>
              <link>https://example.com/item-1</link>
              <description><![CDATA[<p>Hello <b>world</b></p>]]></description>
            </item>
          </channel>
        </rss>
        """

        let session = makeMockedSession { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url == feedURL {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(rss.utf8)
                )
            }
            throw URLError(.fileDoesNotExist)
        }
        defer {
            URLProtocolMock.requestHandler = nil
            session.invalidateAndCancel()
        }

        let store = FeedStore(persistence: persistence, urlSession: session)
        let feed = try? store.addFeed(urlString: feedURL.absoluteString)
        if let feed {
            try? await store.refresh(feed: feed)
        }

        let request: NSFetchRequest<FeedItem> = FeedItem.fetchRequest()
        request.fetchLimit = 1
        let item = try? persistence.container.viewContext.fetch(request).first
        let summary = item?.summary ?? ""
        XCTAssertTrue(summary.contains("Hello"))
        XCTAssertFalse(summary.contains("<"))
    }

    @MainActor
    func testNormalizeLegacySummariesUpdatesFeedItemsInBackground() async {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = FeedStore(persistence: persistence)

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = "https://example.com"

        let item = FeedItem(context: context)
        item.id = UUID()
        item.createdAt = Date()
        item.feed = feed
        item.summary = "<p>Legacy <em>summary</em></p>"
        try? context.save()

        let itemID = item.objectID
        await store.normalizeLegacySummaries(feedObjectID: feed.objectID, maxItemsPerRun: 500)
        await waitUntil(timeout: 2.0) {
            let updated = try? context.existingObject(with: itemID) as? FeedItem
            return (updated?.summary ?? "").contains("<") == false
        }

        let updated = try? context.existingObject(with: itemID) as? FeedItem
        XCTAssertEqual(updated?.summary, "Legacy summary")
    }

    @MainActor
    func testPersistenceControllerConnectsViewContext() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        XCTAssertNotNil(context.persistentStoreCoordinator)
        XCTAssertFalse(persistence.container.persistentStoreCoordinator.persistentStores.isEmpty)
    }

    @MainActor
    func testReadTrackerMarksOnlyPastItems() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = "https://example.com"

        let itemAObject = FeedItem(context: context)
        itemAObject.id = UUID()
        itemAObject.createdAt = Date()
        itemAObject.feed = feed

        let itemBObject = FeedItem(context: context)
        itemBObject.id = UUID()
        itemBObject.createdAt = Date()
        itemBObject.feed = feed

        try? context.save()

        let itemA = itemAObject.objectID
        let itemB = itemBObject.objectID

        let frames: [NSManagedObjectID: CGRect] = [
            itemA: CGRect(x: 0, y: -50, width: 100, height: 40),
            itemB: CGRect(x: 0, y: 10, width: 100, height: 40)
        ]

        let toRead = ReadTracker.itemsToMarkRead(itemFrames: frames, containerMinY: 0)
        XCTAssertTrue(toRead.contains(itemA))
        XCTAssertFalse(toRead.contains(itemB))
    }

    @MainActor
    func testAddFeedRejectsHTTPURL() {
        let persistence = PersistenceController(inMemory: true)
        let store = FeedStore(persistence: persistence)

        XCTAssertThrowsError(try store.addFeed(urlString: "http://example.com/feed.xml")) { error in
            guard let feedError = error as? FeedError else {
                return XCTFail("Expected FeedError")
            }
            XCTAssertEqual(feedError, .insecureURL)
        }
    }

    @MainActor
    func testAddFeedAcceptsHTTPSURL() {
        let persistence = PersistenceController(inMemory: true)
        let store = FeedStore(persistence: persistence)

        XCTAssertNoThrow(try store.addFeed(urlString: "https://example.com/feed.xml"))
    }

    @MainActor
    func testImportOPMLRejectsNonHTTPSURL() async {
        let persistence = PersistenceController(inMemory: true)
        let store = FeedStore(persistence: persistence)

        do {
            _ = try await store.importOPML(urlString: "http://example.com/feeds.opml")
            XCTFail("Expected invalidOPMLURL error")
        } catch let error as FeedError {
            XCTAssertEqual(error, .invalidOPMLURL)
        } catch {
            XCTFail("Expected FeedError.invalidOPMLURL, got \(error)")
        }
    }

    func testOPMLParserExtractsNestedOutlineXMLURLs() throws {
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="1.0">
          <body>
            <outline text="Folder">
              <outline text="Feed A" xmlUrl="https://example.com/a.xml"/>
              <outline text="Feed B" xmlUrl="https://example.com/b.xml"/>
            </outline>
          </body>
        </opml>
        """
        let urls = try OPMLDocumentParser.parseFeedURLs(data: Data(opml.utf8))
        XCTAssertEqual(urls, ["https://example.com/a.xml", "https://example.com/b.xml"])
    }

    func testOPMLParserIgnoresOutlinesWithoutXMLURL() throws {
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="1.0">
          <body>
            <outline text="Folder">
              <outline text="No feed"/>
              <outline text="Feed A" xmlUrl="https://example.com/a.xml"/>
            </outline>
          </body>
        </opml>
        """
        let urls = try OPMLDocumentParser.parseFeedURLs(data: Data(opml.utf8))
        XCTAssertEqual(urls, ["https://example.com/a.xml"])
    }

    @MainActor
    func testImportOPMLDedupesDuplicatesAndTracksAddedVsExisting() async {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let opmlURL = URL(string: "https://example.com/feeds.opml")!
        let existingFeedURL = URL(string: "https://example.com/existing.xml")!
        let newFeedURL = URL(string: "https://example.com/new.xml")!

        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <body>
            <outline text="Existing" xmlUrl="\(existingFeedURL.absoluteString)"/>
            <outline text="New" xmlUrl="\(newFeedURL.absoluteString)"/>
            <outline text="New duplicate" xmlUrl="\(newFeedURL.absoluteString)"/>
            <outline text="Ignored insecure" xmlUrl="http://example.com/insecure.xml"/>
          </body>
        </opml>
        """

        let session = makeMockedSession { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            if url == opmlURL {
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(opml.utf8))
            }
            if url == existingFeedURL || url == newFeedURL {
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.sampleRSSData)
            }
            throw URLError(.fileDoesNotExist)
        }
        defer {
            URLProtocolMock.requestHandler = nil
            session.invalidateAndCancel()
        }

        let store = FeedStore(persistence: persistence, urlSession: session)
        _ = try? store.addFeed(urlString: existingFeedURL.absoluteString)
        let result = try? await store.importOPML(urlString: opmlURL.absoluteString)

        XCTAssertEqual(result?.addedCount, 1)
        XCTAssertEqual(result?.existingCount, 1)
        XCTAssertEqual(result?.importedCount, 2)
        XCTAssertEqual(result?.feedObjectIDs.count, 2)
        XCTAssertEqual(result?.skippedNonHTTPSCount, 1)
        XCTAssertEqual(result?.skippedNonHTTPSFeedURLs, ["http://example.com/insecure.xml"])
        XCTAssertEqual(result?.refreshFailedCount, 0)
        XCTAssertEqual(result?.refreshFailures.count, 0)

        let request: NSFetchRequest<Feed> = Feed.fetchRequest()
        let feeds = try? context.fetch(request)
        XCTAssertEqual(feeds?.count, 2)
    }

    @MainActor
    func testImportOPMLContinuesWhenOneFeedRefreshFails() async {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let opmlURL = URL(string: "https://example.com/feeds.opml")!
        let goodFeedURL = URL(string: "https://example.com/good.xml")!
        let badFeedURL = URL(string: "https://example.com/bad.xml")!

        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <body>
            <outline text="Good" xmlUrl="\(goodFeedURL.absoluteString)"/>
            <outline text="Bad" xmlUrl="\(badFeedURL.absoluteString)"/>
          </body>
        </opml>
        """

        let session = makeMockedSession { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            if url == opmlURL {
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(opml.utf8))
            }
            if url == goodFeedURL {
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.sampleRSSData)
            }
            if url == badFeedURL {
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("not-a-feed".utf8))
            }
            throw URLError(.fileDoesNotExist)
        }
        defer {
            URLProtocolMock.requestHandler = nil
            session.invalidateAndCancel()
        }

        let store = FeedStore(persistence: persistence, urlSession: session)
        let result = try? await store.importOPML(urlString: opmlURL.absoluteString)

        XCTAssertEqual(result?.addedCount, 2)
        XCTAssertEqual(result?.existingCount, 0)
        XCTAssertEqual(result?.refreshFailedCount, 1)
        XCTAssertEqual(result?.refreshFailures.first?.feedURL, badFeedURL.absoluteString)

        let request: NSFetchRequest<Feed> = Feed.fetchRequest()
        let feeds = try? context.fetch(request)
        XCTAssertEqual(feeds?.count, 2)
    }

    @MainActor
    func testImportOPMLCountsSkippedNonHTTPSFeeds() async {
        let persistence = PersistenceController(inMemory: true)
        let opmlURL = URL(string: "https://example.com/feeds.opml")!
        let secureFeedURL = URL(string: "https://example.com/secure.xml")!

        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <body>
            <outline text="Secure" xmlUrl="\(secureFeedURL.absoluteString)"/>
            <outline text="Insecure A" xmlUrl="http://example.com/a.xml"/>
            <outline text="Insecure B" xmlUrl="http://example.com/b.xml"/>
          </body>
        </opml>
        """

        let session = makeMockedSession { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            if url == opmlURL {
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(opml.utf8))
            }
            if url == secureFeedURL {
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.sampleRSSData)
            }
            throw URLError(.fileDoesNotExist)
        }
        defer {
            URLProtocolMock.requestHandler = nil
            session.invalidateAndCancel()
        }

        let store = FeedStore(persistence: persistence, urlSession: session)
        let result = try? await store.importOPML(urlString: opmlURL.absoluteString)
        XCTAssertEqual(result?.importedCount, 1)
        XCTAssertEqual(result?.skippedNonHTTPSCount, 2)
        XCTAssertEqual(
            Set(result?.skippedNonHTTPSFeedURLs ?? []),
            Set(["http://example.com/a.xml", "http://example.com/b.xml"])
        )
    }

    @MainActor
    func testImportOPMLThrowsWhenNoValidHTTPSFeeds() async {
        let persistence = PersistenceController(inMemory: true)
        let opmlURL = URL(string: "https://example.com/feeds.opml")!
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <body>
            <outline text="Insecure" xmlUrl="http://example.com/insecure.xml"/>
            <outline text="No URL"/>
          </body>
        </opml>
        """

        let session = makeMockedSession { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            if url == opmlURL {
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(opml.utf8))
            }
            throw URLError(.fileDoesNotExist)
        }
        defer {
            URLProtocolMock.requestHandler = nil
            session.invalidateAndCancel()
        }

        let store = FeedStore(persistence: persistence, urlSession: session)
        do {
            _ = try await store.importOPML(urlString: opmlURL.absoluteString)
            XCTFail("Expected opmlContainsNoValidFeeds error")
        } catch let error as FeedError {
            XCTAssertEqual(error, .opmlContainsNoValidFeeds)
        } catch {
            XCTFail("Expected FeedError.opmlContainsNoValidFeeds, got \(error)")
        }
    }

    @MainActor
    func testMarkItemsReadUpdatesStore() async {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = "https://example.com"

        let itemAObject = FeedItem(context: context)
        itemAObject.id = UUID()
        itemAObject.createdAt = Date()
        itemAObject.feed = feed

        let itemBObject = FeedItem(context: context)
        itemBObject.id = UUID()
        itemBObject.createdAt = Date()
        itemBObject.feed = feed

        try? context.save()

        let ids = [itemAObject.objectID, itemBObject.objectID]
        await persistence.markItemsRead(objectIDs: ids)

        let verifyContext = persistence.container.newBackgroundContext()
        let expectation = expectation(description: "verify read flags")
        await verifyContext.perform {
            let itemA = try? verifyContext.existingObject(with: ids[0]) as? FeedItem
            let itemB = try? verifyContext.existingObject(with: ids[1]) as? FeedItem
            XCTAssertEqual(itemA?.isRead, true)
            XCTAssertEqual(itemB?.isRead, true)
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 2.0)
    }

    @MainActor
    func testFeedSidebarReloadsWhenUnreadCountsChange() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = "https://example.com"
        try? context.save()

        let feedID = feed.objectID

        let shouldReload = FeedSidebarView.Coordinator.shouldReloadData(
            currentFeedIDs: [feedID],
            previousFeedIDs: [feedID],
            currentUnreadCounts: [feedID: 2],
            previousUnreadCounts: [feedID: 1]
        )

        XCTAssertTrue(shouldReload)
    }

    @MainActor
    func testFeedSidebarDoesNotReloadWhenDataUnchanged() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = "https://example.com"
        try? context.save()

        let feedID = feed.objectID
        let unreadCounts = [feedID: 1]

        let shouldReload = FeedSidebarView.Coordinator.shouldReloadData(
            currentFeedIDs: [feedID],
            previousFeedIDs: [feedID],
            currentUnreadCounts: unreadCounts,
            previousUnreadCounts: unreadCounts
        )

        XCTAssertFalse(shouldReload)
    }

    @MainActor
    func testFeedSidebarReloadsWhenFeedIDsChange() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feedA = Feed(context: context)
        feedA.id = UUID()
        feedA.url = "https://a.example.com"

        let feedB = Feed(context: context)
        feedB.id = UUID()
        feedB.url = "https://b.example.com"
        try? context.save()

        let shouldReload = FeedSidebarView.Coordinator.shouldReloadData(
            currentFeedIDs: [feedA.objectID, feedB.objectID],
            previousFeedIDs: [feedA.objectID],
            currentUnreadCounts: [:],
            previousUnreadCounts: [:]
        )

        XCTAssertTrue(shouldReload)
    }

    @MainActor
    func testFeedSidebarReloadsWhenFeedOrderChanges() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feedA = Feed(context: context)
        feedA.id = UUID()
        feedA.url = "https://a.example.com"

        let feedB = Feed(context: context)
        feedB.id = UUID()
        feedB.url = "https://b.example.com"
        try? context.save()

        let shouldReload = FeedSidebarView.Coordinator.shouldReloadData(
            currentFeedIDs: [feedB.objectID, feedA.objectID],
            previousFeedIDs: [feedA.objectID, feedB.objectID],
            currentUnreadCounts: [:],
            previousUnreadCounts: [:]
        )

        XCTAssertTrue(shouldReload)
    }

    func testContentViewStateAfterSelectionChangeResetsShowReadAndChangesToken() {
        let first = UUID()
        let second = UUID()
        var tokens = [first, second]

        let stateA = ContentView.stateAfterSelectionChange {
            tokens.removeFirst()
        }
        let stateB = ContentView.stateAfterSelectionChange {
            tokens.removeFirst()
        }

        XCTAssertFalse(stateA.showRead)
        XCTAssertFalse(stateB.showRead)
        XCTAssertNotEqual(stateA.sessionToken, stateB.sessionToken)
    }

    @MainActor
    func testContentViewMarkAllDisabledWhileDetailBinding() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = "https://example.com"
        try? context.save()

        XCTAssertFalse(
            ContentView.isMarkAllEnabled(
                displayedFeedID: feed.objectID,
                boundDetailFeedID: feed.objectID,
                isDetailBinding: true
            )
        )
    }

    @MainActor
    func testContentViewMarkAllDisabledWhenBoundFeedMismatchesDisplayedFeed() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feedA = Feed(context: context)
        feedA.id = UUID()
        feedA.url = "https://a.example.com"

        let feedB = Feed(context: context)
        feedB.id = UUID()
        feedB.url = "https://b.example.com"
        try? context.save()

        XCTAssertFalse(
            ContentView.isMarkAllEnabled(
                displayedFeedID: feedA.objectID,
                boundDetailFeedID: feedB.objectID,
                isDetailBinding: false
            )
        )
    }

    @MainActor
    func testContentViewMarkAllEnabledWhenBoundFeedMatchesDisplayedFeed() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = "https://example.com"
        try? context.save()

        XCTAssertTrue(
            ContentView.isMarkAllEnabled(
                displayedFeedID: feed.objectID,
                boundDetailFeedID: feed.objectID,
                isDetailBinding: false
            )
        )
    }

    @MainActor
    func testContentViewMarkAllTargetUsesBoundFeedAfterRapidSwitch() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feedA = Feed(context: context)
        feedA.id = UUID()
        feedA.url = "https://a.example.com"

        let feedB = Feed(context: context)
        feedB.id = UUID()
        feedB.url = "https://b.example.com"
        try? context.save()

        let targetBeforeSwitch = ContentView.markAllTargetFeedID(
            displayedFeedID: feedA.objectID,
            boundDetailFeedID: feedA.objectID,
            isDetailBinding: false
        )
        XCTAssertEqual(targetBeforeSwitch, feedA.objectID)

        let targetDuringSwitch = ContentView.markAllTargetFeedID(
            displayedFeedID: feedB.objectID,
            boundDetailFeedID: nil,
            isDetailBinding: true
        )
        XCTAssertNil(targetDuringSwitch)

        let targetAfterSwitch = ContentView.markAllTargetFeedID(
            displayedFeedID: feedB.objectID,
            boundDetailFeedID: feedB.objectID,
            isDetailBinding: false
        )
        XCTAssertEqual(targetAfterSwitch, feedB.objectID)
    }

    func testContentViewSidebarPaneWidths() {
        XCTAssertEqual(ContentView.sidebarMinWidth, 220)
        XCTAssertEqual(ContentView.sidebarIdealWidth, 260)
        XCTAssertEqual(ContentView.sidebarMaxWidth, 360)
    }

    func testContentViewDetailPaneMinWidth() {
        XCTAssertEqual(ContentView.detailMinWidth, 380)
    }

    func testFeedSidebarBottomBarLayoutConstants() {
        XCTAssertEqual(FeedSidebarView.bottomBarVerticalPadding, 10)
        XCTAssertEqual(FeedSidebarView.bottomBarHorizontalPadding, 10)
        XCTAssertEqual(FeedSidebarView.bottomBarButtonSpacing, 10)
    }

    func testSidebarPaneUsesSystemSidebarMaterial() {
        XCTAssertEqual(SidebarPaneView.sidebarMaterial, .sidebar)
        XCTAssertEqual(SidebarPaneView.sidebarOpacity, 0.96)
        XCTAssertEqual(SidebarPaneView.blurOverlayMaterial, .underWindowBackground)
        XCTAssertEqual(SidebarPaneView.blurOverlayOpacity, 0.34)
    }

    @MainActor
    func testContentViewDetailIdentityUsesFeedObjectID() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = "https://example.com"
        try? context.save()

        XCTAssertEqual(ContentView.detailIdentity(for: feed), feed.objectID)
    }

    func testContentViewLastRefreshLabelShowsNeverWhenNil() {
        XCTAssertEqual(ContentView.lastRefreshLabel(lastRefreshedAt: nil), "Last refresh: Never")
    }

    func testContentViewLastRefreshLabelFormatsDate() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let label = ContentView.lastRefreshLabel(lastRefreshedAt: date, formatter: formatter)
        XCTAssertEqual(label, "Last refresh: 2023-11-14 22:13")
    }

    @MainActor
    func testFeedItemsControllerScopesToSelectedFeed() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feedA = Feed(context: context)
        feedA.id = UUID()
        feedA.url = "https://a.example.com"

        let feedB = Feed(context: context)
        feedB.id = UUID()
        feedB.url = "https://b.example.com"

        let itemA = FeedItem(context: context)
        itemA.id = UUID()
        itemA.createdAt = Date()
        itemA.feed = feedA

        let itemB = FeedItem(context: context)
        itemB.id = UUID()
        itemB.createdAt = Date().addingTimeInterval(1)
        itemB.feed = feedB

        try? context.save()

        let controller = FeedItemsController(context: context, feedObjectID: feedA.objectID)
        XCTAssertEqual(controller.items.count, 1)
        XCTAssertEqual(controller.items.first?.feed.objectID, feedA.objectID)
    }

    @MainActor
    func testFeedItemsControllerAppliesInitialFetchLimit() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = "https://example.com"

        for offset in 0..<5 {
            let item = FeedItem(context: context)
            item.id = UUID()
            item.createdAt = Date().addingTimeInterval(TimeInterval(offset))
            item.feed = feed
            item.isRead = false
        }
        try? context.save()

        let controller = FeedItemsController(context: context, feedObjectID: feed.objectID, initialFetchLimit: 2)
        XCTAssertEqual(controller.items.count, 2)
        XCTAssertEqual(controller.currentFetchLimit, 2)
    }

    @MainActor
    func testFeedItemsControllerLoadMoreIncreasesVisibleItems() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = "https://example.com"

        for offset in 0..<5 {
            let item = FeedItem(context: context)
            item.id = UUID()
            item.createdAt = Date().addingTimeInterval(TimeInterval(offset))
            item.feed = feed
            item.isRead = false
        }
        try? context.save()

        let controller = FeedItemsController(context: context, feedObjectID: feed.objectID, initialFetchLimit: 2)
        XCTAssertEqual(controller.items.count, 2)
        controller.loadMore()
        XCTAssertEqual(controller.items.count, 4)
        controller.loadMore()
        XCTAssertEqual(controller.items.count, 5)
    }

    @MainActor
    func testFeedItemsControllerAutoExpandWhenUnreadBeyondInitialLimit() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = "https://example.com"

        for offset in 0..<6 {
            let item = FeedItem(context: context)
            item.id = UUID()
            item.createdAt = Date().addingTimeInterval(TimeInterval(offset))
            item.feed = feed
            item.isRead = true
            if offset == 1 {
                item.isRead = false
            }
        }
        try? context.save()

        let controller = FeedItemsController(context: context, feedObjectID: feed.objectID, initialFetchLimit: 3)
        XCTAssertEqual(controller.items.count, 3)
        XCTAssertFalse(controller.items.contains { !$0.isRead })

        let expandedPages = controller.maybeAutoExpandForUnread(showRead: false, sessionUnreadIDs: [])
        XCTAssertEqual(expandedPages, 1)
        XCTAssertTrue(controller.items.contains { !$0.isRead })
    }

    @MainActor
    func testFeedItemsControllerAutoExpandStopsWhenNoMoreItems() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = "https://example.com"

        for offset in 0..<3 {
            let item = FeedItem(context: context)
            item.id = UUID()
            item.createdAt = Date().addingTimeInterval(TimeInterval(offset))
            item.feed = feed
            item.isRead = true
        }
        try? context.save()

        let controller = FeedItemsController(context: context, feedObjectID: feed.objectID, initialFetchLimit: 2)
        XCTAssertEqual(controller.items.count, 2)

        let expandedPages = controller.maybeAutoExpandForUnread(showRead: false, sessionUnreadIDs: [])
        XCTAssertEqual(expandedPages, 1)
        XCTAssertEqual(controller.items.count, 3)
        XCTAssertFalse(controller.canLoadMore)
    }

    @MainActor
    func testUnreadCountsControllerAggregatesByFeed() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feedA = Feed(context: context)
        feedA.id = UUID()
        feedA.url = "https://a.example.com"

        let feedB = Feed(context: context)
        feedB.id = UUID()
        feedB.url = "https://b.example.com"

        for index in 0..<3 {
            let item = FeedItem(context: context)
            item.id = UUID()
            item.createdAt = Date().addingTimeInterval(TimeInterval(index))
            item.feed = index < 2 ? feedA : feedB
            item.isRead = false
        }
        try? context.save()

        let controller = UnreadCountsController(context: context)
        XCTAssertEqual(controller.counts[feedA.objectID], 2)
        XCTAssertEqual(controller.counts[feedB.objectID], 1)
    }

    @MainActor
    func testUnreadCountsControllerClearsAfterDeletingLastFeed() async {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = "https://example.com"

        let item = FeedItem(context: context)
        item.id = UUID()
        item.createdAt = Date()
        item.feed = feed
        item.isRead = false
        try? context.save()

        let controller = UnreadCountsController(context: context)
        XCTAssertEqual(controller.counts[feed.objectID], 1)

        context.delete(feed)
        try? context.save()

        await waitUntil(timeout: 2.0) {
            controller.counts.isEmpty
        }
        XCTAssertTrue(controller.counts.isEmpty)
    }

    @MainActor
    func testFeedItemsControllerClearsAfterDeletingFeed() async {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = "https://example.com"

        let item = FeedItem(context: context)
        item.id = UUID()
        item.createdAt = Date()
        item.feed = feed
        item.isRead = false
        try? context.save()

        let controller = FeedItemsController(context: context, feedObjectID: feed.objectID)
        XCTAssertEqual(controller.items.count, 1)

        context.delete(feed)
        try? context.save()

        await waitUntil(timeout: 2.0) {
            controller.items.isEmpty
        }
        XCTAssertTrue(controller.items.isEmpty)
    }

    @MainActor
    func testMarkAllReadUpdatesUnreadCountsController() async {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = FeedStore(persistence: persistence)

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = "https://example.com"

        for offset in 0..<2 {
            let item = FeedItem(context: context)
            item.id = UUID()
            item.createdAt = Date().addingTimeInterval(TimeInterval(offset))
            item.feed = feed
            item.isRead = false
        }
        try? context.save()

        let countsController = UnreadCountsController(context: context)
        XCTAssertEqual(countsController.counts[feed.objectID], 2)

        try? await store.markAllRead(feed: feed)
        await waitUntil(timeout: 2.0) {
            countsController.counts[feed.objectID, default: 0] == 0
        }
        XCTAssertEqual(countsController.counts[feed.objectID, default: 0], 0)
    }

    @MainActor
    func testMarkAllReadMarksEveryUnreadItemInLargeFeed() async {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = FeedStore(persistence: persistence)

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = "https://example.com/large"

        let unreadItemCount = 300
        for offset in 0..<unreadItemCount {
            let item = FeedItem(context: context)
            item.id = UUID()
            item.createdAt = Date().addingTimeInterval(TimeInterval(offset))
            item.feed = feed
            item.isRead = false
        }
        try? context.save()

        try? await store.markAllRead(feedObjectID: feed.objectID)

        let unreadRequest: NSFetchRequest<FeedItem> = FeedItem.fetchRequest()
        unreadRequest.predicate = NSPredicate(format: "feed == %@ AND isRead == NO", feed)
        let remainingUnread = (try? context.fetch(unreadRequest).count) ?? -1
        XCTAssertEqual(remainingUnread, 0)
    }

    @MainActor
    func testSelectionAfterDeletingSelectedFeedPicksNextRemainingFeed() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feedA = Feed(context: context)
        feedA.id = UUID()
        feedA.url = "https://a.example.com"

        let feedB = Feed(context: context)
        feedB.id = UUID()
        feedB.url = "https://b.example.com"
        try? context.save()

        let next = ContentView.selectionAfterDeleting(
            selected: feedA.objectID,
            deleting: feedA.objectID,
            remainingFeeds: [feedB]
        )

        XCTAssertEqual(next, feedB.objectID)
    }

    @MainActor
    func testSelectionAfterDeletingUnselectedFeedKeepsSelection() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feedA = Feed(context: context)
        feedA.id = UUID()
        feedA.url = "https://a.example.com"

        let feedB = Feed(context: context)
        feedB.id = UUID()
        feedB.url = "https://b.example.com"
        try? context.save()

        let next = ContentView.selectionAfterDeleting(
            selected: feedA.objectID,
            deleting: feedB.objectID,
            remainingFeeds: [feedA]
        )

        XCTAssertEqual(next, feedA.objectID)
    }

    @MainActor
    func testResolveSelectedFeedReturnsNilAfterDeletion() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = "https://example.com"
        try? context.save()

        let deletedID = feed.objectID
        context.delete(feed)
        try? context.save()

        let resolved = ContentView.resolveSelectedFeed(id: deletedID, in: context)
        XCTAssertNil(resolved)
    }

    @MainActor
    func testResolveSelectedFeedReturnsFeedWhenPresent() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = "https://example.com"
        try? context.save()

        let resolved = ContentView.resolveSelectedFeed(id: feed.objectID, in: context)
        XCTAssertEqual(resolved?.objectID, feed.objectID)
    }

    func testFeedItemsViewEmptyMessageVariants() {
        XCTAssertEqual(FeedItemsView.emptyMessage(showRead: true), "This feed has no items.")
        XCTAssertEqual(FeedItemsView.emptyMessage(showRead: false), "No unread items. Toggle Show Read to see older items.")
    }

    @MainActor
    func testFeedItemsFilteringIncludesSessionUnreadEvenIfRead() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = "https://example.com"

        let unread = FeedItem(context: context)
        unread.id = UUID()
        unread.createdAt = Date()
        unread.feed = feed
        unread.isRead = false

        let readButInSession = FeedItem(context: context)
        readButInSession.id = UUID()
        readButInSession.createdAt = Date().addingTimeInterval(1)
        readButInSession.feed = feed
        readButInSession.isRead = true

        try? context.save()

        let filtered = FeedItemsView.filteredItems(
            items: [unread, readButInSession],
            showRead: false,
            sessionUnreadIDs: [readButInSession.objectID]
        )

        XCTAssertEqual(filtered.count, 2)
    }

    func testFeedItemsNextSelectionIndexKeyboardBehavior() {
        XCTAssertNil(FeedItemsView.nextSelectionIndex(currentIndex: nil, itemCount: 0, delta: 1))
        XCTAssertEqual(FeedItemsView.nextSelectionIndex(currentIndex: nil, itemCount: 3, delta: 1), 0)
        XCTAssertEqual(FeedItemsView.nextSelectionIndex(currentIndex: 0, itemCount: 3, delta: -1), 0)
        XCTAssertEqual(FeedItemsView.nextSelectionIndex(currentIndex: 1, itemCount: 3, delta: 1), 2)
    }

    @MainActor
    func testFeedItemsSessionUnreadIDsClearsWhenAllItemsRead() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = "https://example.com"

        let item = FeedItem(context: context)
        item.id = UUID()
        item.createdAt = Date()
        item.feed = feed
        item.isRead = true
        try? context.save()

        let next = FeedItemsView.nextSessionUnreadIDs(
            current: [item.objectID],
            items: [item]
        )

        XCTAssertTrue(next.isEmpty)
    }

    func testAnchorToRevealSelectionTopWhenAboveViewport() {
        let anchor = FeedItemsView.anchorToRevealSelection(
            selectedFrame: CGRect(x: 0, y: -8, width: 100, height: 40),
            nextFrame: nil,
            containerHeight: 300
        )
        XCTAssertEqual(anchor, .top)
    }

    func testAnchorToRevealSelectionBottomWhenBelowViewport() {
        let anchor = FeedItemsView.anchorToRevealSelection(
            selectedFrame: CGRect(x: 0, y: 280, width: 100, height: 40),
            nextFrame: nil,
            containerHeight: 300
        )
        XCTAssertEqual(anchor, .bottom)
    }

    func testAnchorToRevealSelectionNilWhenVisible() {
        let anchor = FeedItemsView.anchorToRevealSelection(
            selectedFrame: CGRect(x: 0, y: 80, width: 100, height: 40),
            nextFrame: nil,
            containerHeight: 300
        )
        XCTAssertNil(anchor)
    }

    @MainActor
    func testFeedItemsIdentityUsesObjectIDNotUUIDField() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = "https://example.com"

        let item = FeedItem(context: context)
        item.createdAt = Date()
        item.feed = feed
        item.setPrimitiveValue(nil, forKey: "id")

        let identity = FeedItemsView.itemIdentity(item)
        XCTAssertEqual(identity, item.objectID)
    }

    @MainActor
    func testOpenTargetReturnsSelectedItem() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = "https://example.com"

        let first = FeedItem(context: context)
        first.id = UUID()
        first.createdAt = Date()
        first.feed = feed

        let second = FeedItem(context: context)
        second.id = UUID()
        second.createdAt = Date().addingTimeInterval(1)
        second.feed = feed

        let target = FeedItemsView.openTarget(selectedItemID: second.objectID, items: [first, second])
        XCTAssertEqual(target?.objectID, second.objectID)
    }

    @MainActor
    func testRefreshSettingsDefaultIntervalIsFiveMinutes() {
        let suiteName = "rssssTests.\(#function).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Unable to create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RefreshSettingsStore(userDefaults: defaults, key: "interval")
        XCTAssertEqual(store.refreshIntervalMinutes, 5)
        XCTAssertEqual(store.showLastRefresh, true)
        XCTAssertEqual(store.initialFeedItemsLimit, RefreshSettings.defaultInitialFeedItemsLimit)
    }

    @MainActor
    func testRefreshSettingsClampsAndPersistsInterval() {
        let suiteName = "rssssTests.\(#function).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Unable to create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RefreshSettingsStore(userDefaults: defaults, key: "interval")
        store.refreshIntervalMinutes = 0
        XCTAssertEqual(store.refreshIntervalMinutes, RefreshSettings.minimumRefreshIntervalMinutes)
        XCTAssertEqual(
            defaults.integer(forKey: "interval"),
            RefreshSettings.minimumRefreshIntervalMinutes
        )

        store.refreshIntervalMinutes = 999
        XCTAssertEqual(store.refreshIntervalMinutes, RefreshSettings.maximumRefreshIntervalMinutes)
        XCTAssertEqual(
            defaults.integer(forKey: "interval"),
            RefreshSettings.maximumRefreshIntervalMinutes
        )
    }

    @MainActor
    func testRefreshSettingsPersistsShowLastRefreshToggle() {
        let suiteName = "rssssTests.\(#function).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Unable to create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RefreshSettingsStore(userDefaults: defaults, key: "interval", showLastRefreshKey: "showLastRefresh")
        XCTAssertEqual(store.showLastRefresh, true)

        store.showLastRefresh = false
        XCTAssertEqual(defaults.object(forKey: "showLastRefresh") as? Bool, false)

        let reloaded = RefreshSettingsStore(userDefaults: defaults, key: "interval", showLastRefreshKey: "showLastRefresh")
        XCTAssertEqual(reloaded.showLastRefresh, false)
    }

    @MainActor
    func testRefreshSettingsClampsAndPersistsInitialFeedItemsLimit() {
        let suiteName = "rssssTests.\(#function).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Unable to create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RefreshSettingsStore(
            userDefaults: defaults,
            key: "interval",
            showLastRefreshKey: "showLastRefresh",
            initialFeedItemsLimitKey: "initialFeedItemsLimit"
        )

        store.initialFeedItemsLimit = 1
        XCTAssertEqual(store.initialFeedItemsLimit, RefreshSettings.minimumInitialFeedItemsLimit)
        XCTAssertEqual(
            defaults.integer(forKey: "initialFeedItemsLimit"),
            RefreshSettings.minimumInitialFeedItemsLimit
        )

        store.initialFeedItemsLimit = 99999
        XCTAssertEqual(store.initialFeedItemsLimit, RefreshSettings.maximumInitialFeedItemsLimit)
        XCTAssertEqual(
            defaults.integer(forKey: "initialFeedItemsLimit"),
            RefreshSettings.maximumInitialFeedItemsLimit
        )
    }

    @MainActor
    func testAutoRefreshControllerSchedulesForegroundAndBackground() {
        let suiteName = "rssssTests.\(#function).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Unable to create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = RefreshSettingsStore(userDefaults: defaults, key: "interval")
        let feedRefresher = MockFeedRefresher()
        let foreground = MockForegroundRefreshScheduler()
        let background = MockBackgroundRefreshScheduler()
        let controller = AutoRefreshController(
            feedStore: feedRefresher,
            foregroundScheduler: foreground,
            backgroundScheduler: background
        )

        controller.start(refreshIntervalMinutes: settings.refreshIntervalMinutes)

        XCTAssertEqual(foreground.scheduledIntervals.last, 60)
        XCTAssertEqual(background.scheduledIntervals.last, 60)
    }

    @MainActor
    func testAutoRefreshControllerReschedulesWhenSettingsChange() async {
        let suiteName = "rssssTests.\(#function).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Unable to create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = RefreshSettingsStore(userDefaults: defaults, key: "interval")
        let foreground = MockForegroundRefreshScheduler()
        let background = MockBackgroundRefreshScheduler()
        let controller = AutoRefreshController(
            feedStore: MockFeedRefresher(),
            foregroundScheduler: foreground,
            backgroundScheduler: background
        )

        controller.start(refreshIntervalMinutes: settings.refreshIntervalMinutes)
        settings.refreshIntervalMinutes = 10
        controller.updateRefreshInterval(minutes: settings.refreshIntervalMinutes)

        await waitUntil(timeout: 2.0) {
            foreground.scheduledIntervals.last == 60 && background.scheduledIntervals.last == 60
        }
        XCTAssertEqual(foreground.scheduledIntervals.last, 60)
        XCTAssertEqual(background.scheduledIntervals.last, 60)
    }

    @MainActor
    func testAutoRefreshControllerBackgroundRefreshInvokesFeedStore() async {
        let suiteName = "rssssTests.\(#function).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Unable to create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = RefreshSettingsStore(userDefaults: defaults, key: "interval")
        let feedRefresher = MockFeedRefresher()
        let background = MockBackgroundRefreshScheduler()
        let controller = AutoRefreshController(
            feedStore: feedRefresher,
            foregroundScheduler: MockForegroundRefreshScheduler(),
            backgroundScheduler: background
        )

        controller.start(refreshIntervalMinutes: settings.refreshIntervalMinutes)
        await background.runLatest()
        XCTAssertEqual(feedRefresher.roundRobinBatchCallCount, 1)
        XCTAssertEqual(feedRefresher.lastTargetCycleInterval, 300)
        XCTAssertEqual(feedRefresher.lastTickInterval, 60)
    }

    @MainActor
    func testFetchFeedsForRefreshUsesOrderIndexAscending() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = FeedStore(persistence: persistence)

        let feedA = Feed(context: context)
        feedA.id = UUID()
        feedA.url = "https://a.example.com"
        feedA.orderIndex = 10

        let feedB = Feed(context: context)
        feedB.id = UUID()
        feedB.url = "https://b.example.com"
        feedB.orderIndex = 2

        let feedC = Feed(context: context)
        feedC.id = UUID()
        feedC.url = "https://c.example.com"
        feedC.orderIndex = 5

        try? context.save()

        let feeds = try? store.fetchFeedsForRefresh()
        XCTAssertEqual(feeds?.map(\.url), ["https://b.example.com", "https://c.example.com", "https://a.example.com"])
    }

    @MainActor
    func testRoundRobinRefreshStartsAtFirstFeedWhenNoCursor() async {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let (defaults, suiteName) = isolatedDefaults()
        defer { clear(defaults: defaults, suiteName: suiteName) }

        let feedAURL = URL(string: "https://example.com/a.xml")!
        let feedBURL = URL(string: "https://example.com/b.xml")!
        addFeed(url: feedAURL.absoluteString, orderIndex: 0, in: context)
        addFeed(url: feedBURL.absoluteString, orderIndex: 1, in: context)
        try? context.save()

        let log = URLRequestLog()
        let session = makeMockedSession { request in
            guard let url = request.url else { throw URLError(.badURL) }
            log.append(url)
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.sampleRSSData)
        }
        defer {
            URLProtocolMock.requestHandler = nil
            session.invalidateAndCancel()
        }

        let store = FeedStore(persistence: persistence, urlSession: session, userDefaults: defaults)
        await store.refreshNextFeedInRoundRobin()

        XCTAssertEqual(log.snapshot(), [feedAURL])
        XCTAssertEqual(defaults.string(forKey: RefreshSettings.lastRoundRobinFeedURLKey), feedAURL.absoluteString)
    }

    @MainActor
    func testRoundRobinRefreshAdvancesCursorEachTick() async {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let (defaults, suiteName) = isolatedDefaults()
        defer { clear(defaults: defaults, suiteName: suiteName) }

        let feedAURL = URL(string: "https://example.com/a.xml")!
        let feedBURL = URL(string: "https://example.com/b.xml")!
        let feedCURL = URL(string: "https://example.com/c.xml")!
        addFeed(url: feedAURL.absoluteString, orderIndex: 0, in: context)
        addFeed(url: feedBURL.absoluteString, orderIndex: 1, in: context)
        addFeed(url: feedCURL.absoluteString, orderIndex: 2, in: context)
        try? context.save()

        let log = URLRequestLog()
        let session = makeMockedSession { request in
            guard let url = request.url else { throw URLError(.badURL) }
            log.append(url)
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.sampleRSSData)
        }
        defer {
            URLProtocolMock.requestHandler = nil
            session.invalidateAndCancel()
        }

        let store = FeedStore(persistence: persistence, urlSession: session, userDefaults: defaults)
        await store.refreshNextFeedInRoundRobin()
        await store.refreshNextFeedInRoundRobin()
        await store.refreshNextFeedInRoundRobin()

        XCTAssertEqual(log.snapshot(), [feedAURL, feedBURL, feedCURL])
    }

    @MainActor
    func testRoundRobinRefreshWrapsAtEnd() async {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let (defaults, suiteName) = isolatedDefaults()
        defer { clear(defaults: defaults, suiteName: suiteName) }

        let feedAURL = URL(string: "https://example.com/a.xml")!
        let feedBURL = URL(string: "https://example.com/b.xml")!
        addFeed(url: feedAURL.absoluteString, orderIndex: 0, in: context)
        addFeed(url: feedBURL.absoluteString, orderIndex: 1, in: context)
        try? context.save()

        let log = URLRequestLog()
        let session = makeMockedSession { request in
            guard let url = request.url else { throw URLError(.badURL) }
            log.append(url)
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.sampleRSSData)
        }
        defer {
            URLProtocolMock.requestHandler = nil
            session.invalidateAndCancel()
        }

        let store = FeedStore(persistence: persistence, urlSession: session, userDefaults: defaults)
        await store.refreshNextFeedInRoundRobin()
        await store.refreshNextFeedInRoundRobin()
        await store.refreshNextFeedInRoundRobin()

        XCTAssertEqual(log.snapshot(), [feedAURL, feedBURL, feedAURL])
    }

    @MainActor
    func testRoundRobinRefreshAdvancesEvenWhenSelectedFeedFails() async {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let (defaults, suiteName) = isolatedDefaults()
        defer { clear(defaults: defaults, suiteName: suiteName) }

        let feedAURL = URL(string: "https://example.com/a.xml")!
        let feedBURL = URL(string: "https://example.com/b.xml")!
        let feedCURL = URL(string: "https://example.com/c.xml")!
        addFeed(url: feedAURL.absoluteString, orderIndex: 0, in: context)
        addFeed(url: feedBURL.absoluteString, orderIndex: 1, in: context)
        addFeed(url: feedCURL.absoluteString, orderIndex: 2, in: context)
        try? context.save()

        let log = URLRequestLog()
        let session = makeMockedSession { request in
            guard let url = request.url else { throw URLError(.badURL) }
            log.append(url)
            if url == feedBURL {
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("invalid-feed".utf8))
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.sampleRSSData)
        }
        defer {
            URLProtocolMock.requestHandler = nil
            session.invalidateAndCancel()
        }

        let store = FeedStore(persistence: persistence, urlSession: session, userDefaults: defaults)
        await store.refreshNextFeedInRoundRobin()
        await store.refreshNextFeedInRoundRobin()
        await store.refreshNextFeedInRoundRobin()

        XCTAssertEqual(log.snapshot(), [feedAURL, feedBURL, feedCURL])
        XCTAssertEqual(defaults.string(forKey: RefreshSettings.lastRoundRobinFeedURLKey), feedCURL.absoluteString)
    }

    @MainActor
    func testRoundRobinRefreshHandlesDeletedCursorFeed() async {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let (defaults, suiteName) = isolatedDefaults()
        defer { clear(defaults: defaults, suiteName: suiteName) }

        let feedAURL = URL(string: "https://example.com/a.xml")!
        let feedBURL = URL(string: "https://example.com/b.xml")!
        addFeed(url: feedAURL.absoluteString, orderIndex: 0, in: context)
        addFeed(url: feedBURL.absoluteString, orderIndex: 1, in: context)
        try? context.save()

        defaults.set("https://example.com/deleted.xml", forKey: RefreshSettings.lastRoundRobinFeedURLKey)

        let log = URLRequestLog()
        let session = makeMockedSession { request in
            guard let url = request.url else { throw URLError(.badURL) }
            log.append(url)
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.sampleRSSData)
        }
        defer {
            URLProtocolMock.requestHandler = nil
            session.invalidateAndCancel()
        }

        let store = FeedStore(persistence: persistence, urlSession: session, userDefaults: defaults)
        await store.refreshNextFeedInRoundRobin()

        XCTAssertEqual(log.snapshot(), [feedAURL])
    }

    @MainActor
    func testRoundRobinBatchRefreshesAtLeastOneFeedForLongIntervals() async {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let (defaults, suiteName) = isolatedDefaults()
        defer { clear(defaults: defaults, suiteName: suiteName) }

        let feedAURL = URL(string: "https://example.com/a.xml")!
        let feedBURL = URL(string: "https://example.com/b.xml")!
        let feedCURL = URL(string: "https://example.com/c.xml")!
        addFeed(url: feedAURL.absoluteString, orderIndex: 0, in: context)
        addFeed(url: feedBURL.absoluteString, orderIndex: 1, in: context)
        addFeed(url: feedCURL.absoluteString, orderIndex: 2, in: context)
        try? context.save()

        let log = URLRequestLog()
        let session = makeMockedSession { request in
            guard let url = request.url else { throw URLError(.badURL) }
            log.append(url)
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.sampleRSSData)
        }
        defer {
            URLProtocolMock.requestHandler = nil
            session.invalidateAndCancel()
        }

        let store = FeedStore(persistence: persistence, urlSession: session, userDefaults: defaults)
        await store.refreshRoundRobinBatch(targetCycleInterval: 3600, tickInterval: 60)

        XCTAssertEqual(log.snapshot(), [feedAURL])
    }

    @MainActor
    func testRoundRobinBatchRefreshesScaledCountForShortIntervals() async {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let (defaults, suiteName) = isolatedDefaults()
        defer { clear(defaults: defaults, suiteName: suiteName) }

        let feedAURL = URL(string: "https://example.com/a.xml")!
        let feedBURL = URL(string: "https://example.com/b.xml")!
        let feedCURL = URL(string: "https://example.com/c.xml")!
        let feedDURL = URL(string: "https://example.com/d.xml")!
        let feedEURL = URL(string: "https://example.com/e.xml")!
        addFeed(url: feedAURL.absoluteString, orderIndex: 0, in: context)
        addFeed(url: feedBURL.absoluteString, orderIndex: 1, in: context)
        addFeed(url: feedCURL.absoluteString, orderIndex: 2, in: context)
        addFeed(url: feedDURL.absoluteString, orderIndex: 3, in: context)
        addFeed(url: feedEURL.absoluteString, orderIndex: 4, in: context)
        try? context.save()

        let log = URLRequestLog()
        let session = makeMockedSession { request in
            guard let url = request.url else { throw URLError(.badURL) }
            log.append(url)
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.sampleRSSData)
        }
        defer {
            URLProtocolMock.requestHandler = nil
            session.invalidateAndCancel()
        }

        let store = FeedStore(persistence: persistence, urlSession: session, userDefaults: defaults)
        await store.refreshRoundRobinBatch(targetCycleInterval: 300, tickInterval: 60)

        XCTAssertEqual(log.snapshot(), [feedAURL])

        await store.refreshRoundRobinBatch(targetCycleInterval: 120, tickInterval: 60)
        XCTAssertEqual(log.snapshot(), [feedAURL, feedBURL, feedCURL, feedDURL])
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static let sampleRSSData = Data(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Example Feed</title>
            <item>
              <guid>item-1</guid>
              <title>First item</title>
              <link>https://example.com/item-1</link>
            </item>
          </channel>
        </rss>
        """.utf8
    )

    private func makeMockedSession(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        URLProtocolMock.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolMock.self]
        return URLSession(configuration: configuration)
    }

    @MainActor
    private func addFeed(url: String, orderIndex: Int64, in context: NSManagedObjectContext) {
        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = url
        feed.orderIndex = orderIndex
    }

    private func isolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "rssssTests.\(#function).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Unable to create isolated defaults")
        }
        return (defaults, suiteName)
    }

    private func clear(defaults: UserDefaults, suiteName: String) {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private final class MockFeedRefresher: FeedRefreshing {
    private(set) var roundRobinBatchCallCount = 0
    private(set) var lastTargetCycleInterval: TimeInterval?
    private(set) var lastTickInterval: TimeInterval?

    func refreshRoundRobinBatch(targetCycleInterval: TimeInterval, tickInterval: TimeInterval) async {
        roundRobinBatchCallCount += 1
        lastTargetCycleInterval = targetCycleInterval
        lastTickInterval = tickInterval
    }
}

private final class MockForegroundRefreshScheduler: ForegroundRefreshScheduling {
    private(set) var scheduledIntervals: [TimeInterval] = []

    func schedule(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        scheduledIntervals.append(interval)
    }

    func invalidate() {}
}

private final class MockBackgroundRefreshScheduler: BackgroundRefreshScheduling {
    private(set) var scheduledIntervals: [TimeInterval] = []
    private var latestAction: (@Sendable () async -> Void)?

    func schedule(interval: TimeInterval, action: @escaping @Sendable () async -> Void) {
        scheduledIntervals.append(interval)
        latestAction = action
    }

    func invalidate() {}

    func runLatest() async {
        await latestAction?()
    }
}

private final class URLProtocolMock: URLProtocol {
    static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class URLRequestLog: @unchecked Sendable {
    private var urls: [URL] = []
    private let lock = NSLock()

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    func snapshot() -> [URL] {
        lock.lock()
        let copy = urls
        lock.unlock()
        return copy
    }
}
