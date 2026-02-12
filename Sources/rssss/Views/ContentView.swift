import SwiftUI
import CoreData

struct ContentView: View {
    private enum AddSheetRoute: String, Identifiable {
        case feed
        case opml

        var id: String { rawValue }
    }

    @EnvironmentObject private var feedStore: FeedStore
    @EnvironmentObject private var settingsStore: RefreshSettingsStore

    private let viewContext: NSManagedObjectContext
    @StateObject private var feedsController: FeedsController
    @StateObject private var unreadCountsController: UnreadCountsController

    @State private var selectedFeedID: NSManagedObjectID?
    @State private var showRead = false
    @State private var presentedAddSheet: AddSheetRoute?
    @State private var alertTitle = "Error"
    @State private var alertMessage: String?
    @State private var sessionToken = UUID()
    @State private var detailReloadToken = UUID()
    @State private var isDetailBinding = false
    @State private var boundDetailFeedID: NSManagedObjectID?
    @State private var previewRequest: PreviewRequest?

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
        .sheet(item: $presentedAddSheet) { route in
            switch route {
            case .feed:
                AddFeedSheet { urlString in
                    Task {
                        do {
                            let feed = try feedStore.addFeed(urlString: urlString)
                            selectedFeedID = feed.objectID
                            try await feedStore.refresh(feed: feed)
                        } catch {
                            alertTitle = "Error"
                            alertMessage = error.localizedDescription
                        }
                    }
                    presentedAddSheet = nil
                } onCancel: {
                    presentedAddSheet = nil
                }
            case .opml:
                AddOPMLSheet { urlString in
                    Task {
                        do {
                            let result = try await feedStore.importOPML(urlString: urlString)
                            if let lastImportedFeedID = result.feedObjectIDs.last {
                                selectedFeedID = lastImportedFeedID
                            }
                            if let summary = ContentView.opmlImportSummary(result: result) {
                                alertTitle = "Import Summary"
                                alertMessage = summary
                            }
                        } catch {
                            alertTitle = "Error"
                            alertMessage = error.localizedDescription
                        }
                    }
                    presentedAddSheet = nil
                } onCancel: {
                    presentedAddSheet = nil
                }
            }
        }
        .alert(alertTitle, isPresented: Binding(get: { alertMessage != nil }, set: { _ in alertMessage = nil })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage ?? "Unknown error")
        }
        .onChange(of: selectedFeedID) { _, _ in
            let nextState = ContentView.stateAfterSelectionChange()
            showRead = nextState.showRead
            sessionToken = nextState.sessionToken
            isDetailBinding = selectedFeedID != nil
            boundDetailFeedID = nil
            detailReloadToken = UUID()
            previewRequest = ContentView.previewAfterFeedSelectionChange(current: previewRequest)

            if let selectedFeedID {
                Task {
                    await feedStore.normalizeLegacySummaries(feedObjectID: selectedFeedID)
                }
            }
        }
    }

    private var sidebarPane: some View {
        SidebarPaneView(
            selection: $selectedFeedID,
            feeds: feedsController.feeds,
            unreadCounts: unreadCountsController.counts,
            onDelete: deleteFeed,
            onAddFeed: { presentedAddSheet = .feed },
            onAddOPML: { presentedAddSheet = .opml }
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
            if let previewRequest {
                HSplitView {
                    feedItemsPane(for: feed)
                        .frame(minWidth: ContentView.feedItemsPaneMinWidth, maxWidth: .infinity)
                    WebPreviewPaneView(
                        request: previewRequest,
                        onClose: { self.previewRequest = nil }
                    )
                    .frame(
                        minWidth: ContentView.previewPaneMinWidth,
                        idealWidth: ContentView.previewPaneIdealWidth,
                        maxWidth: .infinity
                    )
                }
            } else {
                feedItemsPane(for: feed)
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

    private func feedItemsPane(for feed: Feed) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            detailHeader(for: feed)

            FeedItemsView(
                feedObjectID: feed.objectID,
                initialItemsLimit: settingsStore.initialFeedItemsLimit,
                showRead: showRead,
                sessionToken: sessionToken,
                viewContext: viewContext,
                onFeedBound: { boundFeedID in
                    guard boundFeedID == selectedFeedID else { return }
                    boundDetailFeedID = boundFeedID
                    isDetailBinding = false
                },
                onOpenInPreview: { request in
                    previewRequest = request
                }
            )
            .id("\(feed.objectID.uriRepresentation().absoluteString)#\(detailReloadToken.uuidString)")
        }
    }

    private func detailHeader(for feed: Feed) -> some View {
        let canMarkAll = ContentView.isMarkAllEnabled(
            displayedFeedID: feed.objectID,
            boundDetailFeedID: boundDetailFeedID,
            isDetailBinding: isDetailBinding
        )

        return HStack(alignment: .top, spacing: 12) {
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
                            guard let targetFeedID = ContentView.markAllTargetFeedID(
                                displayedFeedID: feed.objectID,
                                boundDetailFeedID: boundDetailFeedID,
                                isDetailBinding: isDetailBinding
                            ) else {
                                return
                            }

                            try await feedStore.markAllRead(feedObjectID: targetFeedID)
                            let nextState = ContentView.stateAfterSelectionChange()
                            showRead = nextState.showRead
                            sessionToken = nextState.sessionToken
                            isDetailBinding = true
                            boundDetailFeedID = nil
                            detailReloadToken = UUID()
                        } catch {
                            alertMessage = error.localizedDescription
                        }
                    }
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .help("Mark all items in this feed as read")
                .disabled(!canMarkAll)

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
    static let feedItemsPaneMinWidth: CGFloat = 380
    static let previewPaneMinWidth: CGFloat = 340
    static let previewPaneIdealWidth: CGFloat = 520

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

    static func isMarkAllEnabled(
        displayedFeedID: NSManagedObjectID?,
        boundDetailFeedID: NSManagedObjectID?,
        isDetailBinding: Bool
    ) -> Bool {
        guard !isDetailBinding, let displayedFeedID else { return false }
        return boundDetailFeedID == displayedFeedID
    }

    static func markAllTargetFeedID(
        displayedFeedID: NSManagedObjectID?,
        boundDetailFeedID: NSManagedObjectID?,
        isDetailBinding: Bool
    ) -> NSManagedObjectID? {
        guard isMarkAllEnabled(
            displayedFeedID: displayedFeedID,
            boundDetailFeedID: boundDetailFeedID,
            isDetailBinding: isDetailBinding
        ) else {
            return nil
        }
        return displayedFeedID
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

    static func previewAfterFeedSelectionChange(current: PreviewRequest?) -> PreviewRequest? {
        guard current != nil else { return nil }
        return nil
    }

    static func opmlImportSummary(result: OPMLImportResult) -> String? {
        guard result.skippedNonHTTPSCount > 0 || result.refreshFailedCount > 0 else {
            return nil
        }

        var lines: [String] = [
            "Imported \(result.importedCount) feeds (\(result.addedCount) new, \(result.existingCount) existing).",
            "Skipped non-HTTPS feed URLs: \(result.skippedNonHTTPSCount).",
            "Feeds that failed to refresh: \(result.refreshFailedCount)."
        ]

        if let firstFailure = result.refreshFailures.first {
            lines.append("First refresh failure: \(firstFailure.feedURL)")
        }

        if !result.skippedNonHTTPSFeedURLs.isEmpty {
            let previewLimit = 10
            lines.append("Not imported (HTTP only):")
            lines.append(contentsOf: result.skippedNonHTTPSFeedURLs.prefix(previewLimit).map { "- \($0)" })
            if result.skippedNonHTTPSFeedURLs.count > previewLimit {
                lines.append("- ...and \(result.skippedNonHTTPSFeedURLs.count - previewLimit) more")
            }
        }

        return lines.joined(separator: "\n")
    }
}

struct PreviewRequest: Equatable {
    let url: URL
    let title: String
}
