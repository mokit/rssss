import SwiftUI
import CoreData

struct ContentView: View {
    @EnvironmentObject private var feedStore: FeedStore
    @EnvironmentObject private var settingsStore: RefreshSettingsStore

    private let viewContext: NSManagedObjectContext
    @StateObject private var feedsController: FeedsController
    @StateObject private var unreadCountsController: UnreadCountsController

    @State private var selectedFeedID: NSManagedObjectID?
    @State private var showRead = false
    @State private var isAddSheetPresented = false
    @State private var alertMessage: String?
    @State private var sessionToken = UUID()

    init(viewContext: NSManagedObjectContext) {
        self.viewContext = viewContext
        _feedsController = StateObject(wrappedValue: FeedsController(context: viewContext))
        _unreadCountsController = StateObject(wrappedValue: UnreadCountsController(context: viewContext))
    }

    private var selectedFeed: Feed? {
        ContentView.resolveSelectedFeed(id: selectedFeedID, in: viewContext)
    }

    var body: some View {
        HSplitView {
            sidebarPane
                .frame(
                    minWidth: ContentView.sidebarMinWidth,
                    idealWidth: ContentView.sidebarIdealWidth,
                    maxWidth: ContentView.sidebarMaxWidth
                )

            detailContainer
                .frame(minWidth: ContentView.detailMinWidth, maxWidth: .infinity)
        }
        .sheet(isPresented: $isAddSheetPresented) {
            AddFeedSheet { urlString in
                Task {
                    do {
                        let feed = try feedStore.addFeed(urlString: urlString)
                        selectedFeedID = feed.objectID
                        try await feedStore.refresh(feed: feed)
                    } catch {
                        alertMessage = error.localizedDescription
                    }
                }
                isAddSheetPresented = false
            } onCancel: {
                isAddSheetPresented = false
            }
        }
        .alert("Error", isPresented: Binding(get: { alertMessage != nil }, set: { _ in alertMessage = nil })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage ?? "Unknown error")
        }
        .onChange(of: selectedFeedID) { _, _ in
            let nextState = ContentView.stateAfterSelectionChange()
            showRead = nextState.showRead
            sessionToken = nextState.sessionToken
        }
    }

    private var sidebarPane: some View {
        SidebarPaneView(
            selection: $selectedFeedID,
            feeds: feedsController.feeds,
            unreadCounts: unreadCountsController.counts,
            onDelete: deleteFeed,
            onAdd: { isAddSheetPresented = true }
        )
        .task {
            selectedFeedID = ContentView.nextSelection(current: selectedFeedID, feeds: feedsController.feeds)
        }
        .onChange(of: feedsController.feeds.count) { _, _ in
            selectedFeedID = ContentView.nextSelection(current: selectedFeedID, feeds: feedsController.feeds)
        }
    }

    private var detailContainer: some View {
        detail
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var detail: some View {
        if let feed = selectedFeed {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(for: feed)

                FeedItemsView(
                    feedObjectID: feed.objectID,
                    showRead: showRead,
                    sessionToken: sessionToken,
                    viewContext: viewContext
                )
                .id(ContentView.detailIdentity(for: feed))
            }
        } else {
            VStack {
                Image("RSSSSLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .foregroundStyle(.secondary)
                    .opacity(0.75)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(for feed: Feed) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(feed.displayName)
                    .font(.title2.weight(.semibold))
                if settingsStore.showLastRefresh {
                    Text(ContentView.lastRefreshLabel(lastRefreshedAt: feed.lastRefreshedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button {
                    refresh(feed)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh feed")
                .disabled(feedStore.isRefreshing)

                Button {
                    Task {
                        do {
                            try await feedStore.markAllRead(feed: feed)
                        } catch {
                            alertMessage = error.localizedDescription
                        }
                    }
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .help("Mark all items in this feed as read")

                Button {
                    showRead.toggle()
                } label: {
                    Image(systemName: showRead ? "eye.slash" : "eye")
                }
                .help(showRead ? "Hide read items" : "Show read items")
            }
            .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 16)
        .padding(.top, -6)
        .padding(.bottom, 8)
    }

    private func deleteFeed(_ feed: Feed) {
        do {
            guard !feed.isDeleted else { return }
            let remainingFeeds = feedsController.feeds.filter { $0.objectID != feed.objectID }
            selectedFeedID = ContentView.selectionAfterDeleting(
                selected: selectedFeedID,
                deleting: feed.objectID,
                remainingFeeds: remainingFeeds
            )
            if selectedFeedID == nil {
                let nextState = ContentView.stateAfterSelectionChange()
                showRead = nextState.showRead
                sessionToken = nextState.sessionToken
            }
            try feedStore.deleteFeed(feed)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func refresh(_ feed: Feed) {
        Task {
            do {
                try await feedStore.refresh(feed: feed)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }
}

extension ContentView {
    static let sidebarMinWidth: CGFloat = 220
    static let sidebarIdealWidth: CGFloat = 260
    static let sidebarMaxWidth: CGFloat = 360
    static let detailMinWidth: CGFloat = 380

    private static let lastRefreshFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    static func resolveSelectedFeed(id: NSManagedObjectID?, in context: NSManagedObjectContext) -> Feed? {
        guard let id else { return nil }
        guard let feed = try? context.existingObject(with: id) as? Feed else { return nil }
        return feed.isDeleted ? nil : feed
    }

    static func stateAfterSelectionChange(sessionTokenGenerator: () -> UUID = UUID.init) -> (showRead: Bool, sessionToken: UUID) {
        (false, sessionTokenGenerator())
    }

    static func detailIdentity(for feed: Feed?) -> NSManagedObjectID? {
        feed?.objectID
    }

    static func lastRefreshLabel(lastRefreshedAt: Date?, formatter: DateFormatter = ContentView.lastRefreshFormatter) -> String {
        guard let lastRefreshedAt else { return "Last refresh: Never" }
        return "Last refresh: \(formatter.string(from: lastRefreshedAt))"
    }

    static func nextSelection(current: NSManagedObjectID?, feeds: [Feed]) -> NSManagedObjectID? {
        current ?? feeds.first?.objectID
    }

    static func selectionAfterDeleting(selected: NSManagedObjectID?, deleting: NSManagedObjectID, remainingFeeds: [Feed]) -> NSManagedObjectID? {
        guard selected == deleting else { return selected }
        return remainingFeeds.first?.objectID
    }
}
