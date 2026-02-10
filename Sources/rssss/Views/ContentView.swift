import SwiftUI
import CoreData

struct ContentView: View {
    @EnvironmentObject private var feedStore: FeedStore

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
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar {
            addFeedToolbar
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

    private var sidebar: some View {
        FeedSidebarView(
            selection: $selectedFeedID,
            feeds: feedsController.feeds,
            unreadCounts: unreadCountsController.counts,
            onDelete: deleteFeed
        )
        .frame(minWidth: 220, idealWidth: 260)
        .task {
            selectedFeedID = ContentView.nextSelection(current: selectedFeedID, feeds: feedsController.feeds)
        }
        .onChange(of: feedsController.feeds.count) { _, _ in
            selectedFeedID = ContentView.nextSelection(current: selectedFeedID, feeds: feedsController.feeds)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let feed = selectedFeed {
            FeedItemsView(
                feedObjectID: feed.objectID,
                showRead: showRead,
                sessionToken: sessionToken,
                viewContext: viewContext
            )
                .id(ContentView.detailIdentity(for: feed))
                .navigationTitle(feed.displayName)
                .toolbar {
                    feedToolbar(for: feed)
                }
        } else {
            VStack(spacing: 12) {
                Image("RSSSSLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .foregroundStyle(.secondary)
                Text("No Feed Selected")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Select a feed from the sidebar or add a new one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ToolbarContentBuilder
    private func feedToolbar(for feed: Feed) -> some ToolbarContent {
        ToolbarItemGroup {
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
                Label("Mark All Read", systemImage: "checkmark.circle")
            }
            .help("Mark all items in this feed as read")

            Button {
                showRead.toggle()
            } label: {
                Label(showRead ? "Hide Read" : "Show Read", systemImage: "eye")
            }
            .help(showRead ? "Hide read items" : "Show read items")
        }
    }

    @ToolbarContentBuilder
    private var addFeedToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                isAddSheetPresented = true
            } label: {
                Image(systemName: "plus")
            }
            .help("Add feed")
        }
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

    static func nextSelection(current: NSManagedObjectID?, feeds: [Feed]) -> NSManagedObjectID? {
        current ?? feeds.first?.objectID
    }

    static func selectionAfterDeleting(selected: NSManagedObjectID?, deleting: NSManagedObjectID, remainingFeeds: [Feed]) -> NSManagedObjectID? {
        guard selected == deleting else { return selected }
        return remainingFeeds.first?.objectID
    }
}
