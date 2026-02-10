import SwiftUI

struct FeedRowView: View {
    let feed: Feed
    let unreadCount: Int

    var body: some View {
        HStack(spacing: 8) {
            FeedFaviconView(url: feed.resolvedFaviconURL)
            Text(feed.displayName)
                .lineLimit(1)
            if unreadCount > 0 {
                Text("(\(unreadCount))")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
