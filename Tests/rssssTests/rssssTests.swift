import XCTest
import CoreData
@testable import rssss

final class rssssTests: XCTestCase {
    func testDeduperPrefersGuid() {
        let key = Deduper.itemKey(guid: "abc", link: "https://example.com", title: "Title", pubDate: nil)
        XCTAssertEqual(key, "guid:abc")
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
}
