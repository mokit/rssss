import SwiftUI
import CoreData
import AppKit

struct FeedSidebarView: View {
    @Binding var selection: SidebarSelection?
    let feeds: [Feed]
    let unreadCounts: [NSManagedObjectID: Int]
    let starredCount: Int
    let onDelete: (Feed) -> Void
    let onAddFeed: () -> Void
    let onAddOPML: () -> Void

    static let bottomBarVerticalPadding: CGFloat = 10
    static let bottomBarHorizontalPadding: CGFloat = 10
    static let bottomBarButtonSpacing: CGFloat = 10

    var body: some View {
        VStack(spacing: 0) {
            FeedSidebarTableView(
                selection: $selection,
                feeds: feeds,
                unreadCounts: unreadCounts,
                starredCount: starredCount,
                onDelete: onDelete
            )

            Divider()

            HStack(spacing: FeedSidebarView.bottomBarButtonSpacing) {
                Button("Add feed", action: onAddFeed)
                .help("Add feed")

                Button("Add OPML", action: onAddOPML)
                    .help("Import feeds from an online OPML file")
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, FeedSidebarView.bottomBarVerticalPadding)
            .padding(.horizontal, FeedSidebarView.bottomBarHorizontalPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct FeedSidebarTableView: NSViewRepresentable {
    @Binding var selection: SidebarSelection?
    let feeds: [Feed]
    let unreadCounts: [NSManagedObjectID: Int]
    let starredCount: Int
    let onDelete: (Feed) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        let tableView = NoKeyboardTableView()
        tableView.headerView = nil
        tableView.usesAutomaticRowHeights = true
        tableView.rowSizeStyle = .medium
        tableView.style = .sourceList
        tableView.focusRingType = .none
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FeedColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator

        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let tableView = context.coordinator.tableView {
            let currentIDs = feeds.map(\.objectID)
            let currentUnreadCounts = unreadCounts

            if currentIDs != context.coordinator.lastFeedIDs {
                context.coordinator.lastFeedIDs = currentIDs
                context.coordinator.lastUnreadCounts = currentUnreadCounts
                context.coordinator.lastStarredCount = starredCount
                tableView.reloadData()
                context.coordinator.syncSelection(to: selection)
                return
            }

            var rowsToReload = IndexSet()
            if starredCount != context.coordinator.lastStarredCount {
                context.coordinator.lastStarredCount = starredCount
                rowsToReload.insert(0)
            }

            if currentUnreadCounts != context.coordinator.lastUnreadCounts {
                let changedFeedIDs = Coordinator.changedUnreadFeedIDs(
                    currentUnreadCounts: currentUnreadCounts,
                    previousUnreadCounts: context.coordinator.lastUnreadCounts
                )
                context.coordinator.lastUnreadCounts = currentUnreadCounts
                for feedID in changedFeedIDs {
                    if let index = currentIDs.firstIndex(of: feedID) {
                        rowsToReload.insert(index + 1)
                    }
                }
            }

            if !rowsToReload.isEmpty {
                tableView.reloadData(forRowIndexes: rowsToReload, columnIndexes: IndexSet(integer: 0))
            }
            context.coordinator.syncSelection(to: selection)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: FeedSidebarTableView
        weak var tableView: NSTableView?
        fileprivate var lastFeedIDs: [NSManagedObjectID] = []
        fileprivate var lastUnreadCounts: [NSManagedObjectID: Int] = [:]
        fileprivate var lastStarredCount: Int = -1

        init(parent: FeedSidebarTableView) {
            self.parent = parent
        }

        static func shouldReloadData(
            currentFeedIDs: [NSManagedObjectID],
            previousFeedIDs: [NSManagedObjectID],
            currentUnreadCounts: [NSManagedObjectID: Int],
            previousUnreadCounts: [NSManagedObjectID: Int],
            currentStarredCount: Int,
            previousStarredCount: Int
        ) -> Bool {
            currentFeedIDs != previousFeedIDs ||
            currentUnreadCounts != previousUnreadCounts ||
            currentStarredCount != previousStarredCount
        }

        static func changedUnreadFeedIDs(
            currentUnreadCounts: [NSManagedObjectID: Int],
            previousUnreadCounts: [NSManagedObjectID: Int]
        ) -> Set<NSManagedObjectID> {
            var changed = Set<NSManagedObjectID>()
            let ids = Set(currentUnreadCounts.keys).union(previousUnreadCounts.keys)
            for id in ids where currentUnreadCounts[id, default: 0] != previousUnreadCounts[id, default: 0] {
                changed.insert(id)
            }
            return changed
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.feeds.count + 1
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let rowKind = rowKind(for: row) else { return nil }

            let identifier = NSUserInterfaceItemIdentifier("FeedCell")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
            view.identifier = identifier

            let rootView: AnyView
            switch rowKind {
            case .starred:
                rootView = AnyView(StarredRowView(starredCount: parent.starredCount))
            case .feed(let feedIndex):
                let feed = parent.feeds[feedIndex]
                rootView = AnyView(
                    FeedRowView(
                        feed: feed,
                        unreadCount: parent.unreadCounts[feed.objectID] ?? 0
                    )
                )
            }

            let hosting: NSHostingView<AnyView>
            if let existing = view.subviews.compactMap({ $0 as? NSHostingView<AnyView> }).first {
                hosting = existing
                hosting.rootView = rootView
            } else {
                hosting = NSHostingView(rootView: rootView)
                hosting.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(hosting)
                NSLayoutConstraint.activate([
                    hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                    hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                    hosting.topAnchor.constraint(equalTo: view.topAnchor, constant: 2),
                    hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -2)
                ])
            }

            return view
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView = tableView else { return }
            let row = tableView.selectedRow
            switch rowKind(for: row) {
            case .some(.starred):
                parent.selection = .starred
            case .some(.feed(let feedIndex)):
                parent.selection = .feed(parent.feeds[feedIndex].objectID)
            case .none:
                parent.selection = nil
            }
        }

        func syncSelection(to selection: SidebarSelection?) {
            guard let tableView = tableView else { return }
            if let selection {
                let row: Int?
                switch selection {
                case .starred:
                    row = 0
                case .feed(let objectID):
                    row = parent.feeds.firstIndex(where: { $0.objectID == objectID }).map { $0 + 1 }
                }
                if let row, tableView.selectedRow != row {
                    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
            } else if tableView.selectedRow != -1 {
                tableView.deselectAll(nil)
            }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView = tableView else { return }
            let row = tableView.clickedRow
            guard case .feed(let feedIndex) = rowKind(for: row) else { return }

            let deleteItem = NSMenuItem(title: "Remove Feed", action: #selector(deleteFeed(_:)), keyEquivalent: "")
            deleteItem.representedObject = feedIndex
            deleteItem.target = self
            menu.addItem(deleteItem)
        }

        @objc private func deleteFeed(_ sender: NSMenuItem) {
            guard let feedIndex = sender.representedObject as? Int else { return }
            guard feedIndex >= 0 && feedIndex < parent.feeds.count else { return }
            parent.onDelete(parent.feeds[feedIndex])
        }

        private enum RowKind {
            case starred
            case feed(Int)
        }

        private func rowKind(for row: Int) -> RowKind? {
            guard row >= 0 else { return nil }
            if row == 0 { return .starred }
            let feedIndex = row - 1
            guard feedIndex < parent.feeds.count else { return nil }
            return .feed(feedIndex)
        }
    }
}

extension FeedSidebarView {
    typealias Coordinator = FeedSidebarTableView.Coordinator
}

private final class NoKeyboardTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        // Disable keyboard navigation in the sidebar.
    }
}

private struct StarredRowView: View {
    let starredCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "star.fill")
            Text("Starred")
                .lineLimit(1)
            if starredCount > 0 {
                Text("(\(starredCount))")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
