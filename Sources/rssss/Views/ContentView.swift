import SwiftUI
import CoreData

struct ContentView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject private var feedStore: FeedStore

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \Feed.orderIndex, ascending: true),
            NSSortDescriptor(keyPath: \Feed.title, ascending: true),
            NSSortDescriptor(keyPath: \Feed.url, ascending: true)
        ],
        animation: .default
    ) private var feeds: FetchedResults<Feed>

    @State private var selectedFeedID: NSManagedObjectID?
    @State private var showRead = false
    @State private var isAddSheetPresented = false
    @State private var alertMessage: String?
    @State private var sessionToken = UUID()

    private var selectedFeed: Feed? {
        guard let selectedFeedID else { return nil }
        guard let feed = viewContext.object(with: selectedFeedID) as? Feed else { return nil }
        return feed.isDeleted ? nil : feed
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
            showRead = false
            sessionToken = UUID()
        }
    }

    private var sidebar: some View {
        FeedSidebarView(
            selection: $selectedFeedID,
            feeds: Array(feeds),
            viewContext: viewContext,
            onDelete: deleteFeed
        )
        .frame(minWidth: 220, idealWidth: 260)
        .task {
            if selectedFeedID == nil, let first = feeds.first {
                selectedFeedID = first.objectID
            }
        }
        .onChange(of: feeds.count) { _, _ in
            if selectedFeedID == nil, let first = feeds.first {
                selectedFeedID = first.objectID
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let feed = selectedFeed {
            FeedItemsView(feedID: feed.id, showRead: showRead, sessionToken: sessionToken)
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
            if selectedFeedID == feed.objectID {
                selectedFeedID = nil
                showRead = false
                sessionToken = UUID()
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
