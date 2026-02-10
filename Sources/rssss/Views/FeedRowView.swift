import SwiftUI
import CoreData

struct FeedRowView: View {
    let feed: Feed

    @FetchRequest private var unreadItems: FetchedResults<FeedItem>

    init(feed: Feed) {
        self.feed = feed
        _unreadItems = FetchRequest(
            sortDescriptors: [],
            predicate: NSPredicate(format: "feed == %@ AND isRead == NO", feed),
            animation: .default
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            FeedFaviconView(url: feed.resolvedFaviconURL)
            Text(feed.displayName)
                .lineLimit(1)
            Text("(\(unreadItems.count))")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
