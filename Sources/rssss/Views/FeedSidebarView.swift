import SwiftUI
import CoreData
import AppKit

struct FeedSidebarView: View {
    @Binding var selection: NSManagedObjectID?
    let feeds: [Feed]
    let unreadCounts: [NSManagedObjectID: Int]
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
    @Binding var selection: NSManagedObjectID?
    let feeds: [Feed]
    let unreadCounts: [NSManagedObjectID: Int]
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
            if Coordinator.shouldReloadData(
                currentFeedIDs: currentIDs,
                previousFeedIDs: context.coordinator.lastFeedIDs,
                currentUnreadCounts: currentUnreadCounts,
                previousUnreadCounts: context.coordinator.lastUnreadCounts
            ) {
                context.coordinator.lastFeedIDs = currentIDs
                context.coordinator.lastUnreadCounts = currentUnreadCounts
                tableView.reloadData()
            }
            context.coordinator.syncSelection(to: selection)
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: FeedSidebarTableView
        weak var tableView: NSTableView?
        fileprivate var lastFeedIDs: [NSManagedObjectID] = []
        fileprivate var lastUnreadCounts: [NSManagedObjectID: Int] = [:]

        init(parent: FeedSidebarTableView) {
            self.parent = parent
        }

        static func shouldReloadData(
            currentFeedIDs: [NSManagedObjectID],
            previousFeedIDs: [NSManagedObjectID],
            currentUnreadCounts: [NSManagedObjectID: Int],
            previousUnreadCounts: [NSManagedObjectID: Int]
        ) -> Bool {
            currentFeedIDs != previousFeedIDs || currentUnreadCounts != previousUnreadCounts
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.feeds.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0 && row < parent.feeds.count else { return nil }

            let identifier = NSUserInterfaceItemIdentifier("FeedCell")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
            view.identifier = identifier

            let feed = parent.feeds[row]
            let hosting: NSHostingView<FeedRowView>
            if let existing = view.subviews.compactMap({ $0 as? NSHostingView<FeedRowView> }).first {
                hosting = existing
                hosting.rootView = FeedRowView(
                    feed: feed,
                    unreadCount: parent.unreadCounts[feed.objectID] ?? 0
                )
            } else {
                hosting = NSHostingView(
                    rootView: FeedRowView(
                        feed: feed,
                        unreadCount: parent.unreadCounts[feed.objectID] ?? 0
                    )
                )
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
            if row >= 0 && row < parent.feeds.count {
                parent.selection = parent.feeds[row].objectID
            } else {
                parent.selection = nil
            }
        }

        func syncSelection(to selection: NSManagedObjectID?) {
            guard let tableView = tableView else { return }
            if let selection, let row = parent.feeds.firstIndex(where: { $0.objectID == selection }) {
                if tableView.selectedRow != row {
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
            guard row >= 0 && row < parent.feeds.count else { return }

            let deleteItem = NSMenuItem(title: "Remove Feed", action: #selector(deleteFeed(_:)), keyEquivalent: "")
            deleteItem.representedObject = row
            deleteItem.target = self
            menu.addItem(deleteItem)
        }

        @objc private func deleteFeed(_ sender: NSMenuItem) {
            guard let row = sender.representedObject as? Int else { return }
            guard row >= 0 && row < parent.feeds.count else { return }
            parent.onDelete(parent.feeds[row])
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
