import XCTest
import CoreData
import AppKit
@testable import rssss

final class rssssTests: XCTestCase {
    func testDeduperPrefersGuid() {
        let key = Deduper.itemKey(guid: "abc", link: "https://example.com", title: "Title", pubDate: nil)
        XCTAssertEqual(key, "guid:abc")
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
        XCTAssertEqual(FeedSidebarView.addButtonSize, 16)
    }

    func testSidebarPaneUsesSystemSidebarMaterial() {
        XCTAssertEqual(SidebarPaneView.sidebarMaterial, .sidebar)
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

        XCTAssertEqual(foreground.scheduledIntervals.last, 300)
        XCTAssertEqual(background.scheduledIntervals.last, 300)
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
            foreground.scheduledIntervals.last == 600 && background.scheduledIntervals.last == 600
        }
        XCTAssertEqual(foreground.scheduledIntervals.last, 600)
        XCTAssertEqual(background.scheduledIntervals.last, 600)
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
        XCTAssertEqual(feedRefresher.refreshAllCallCount, 1)
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

    private func waitUntil(timeout: TimeInterval, condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

@MainActor
private final class MockFeedRefresher: FeedRefreshing {
    private(set) var refreshAllCallCount = 0

    func refreshAllFeeds() async {
        refreshAllCallCount += 1
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
