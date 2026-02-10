import SwiftUI
import CoreData

struct FeedSidebarView: NSViewRepresentable {
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
        var parent: FeedSidebarView
        weak var tableView: NSTableView?
        fileprivate var lastFeedIDs: [NSManagedObjectID] = []
        fileprivate var lastUnreadCounts: [NSManagedObjectID: Int] = [:]

        init(parent: FeedSidebarView) {
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

private final class NoKeyboardTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        // Disable keyboard navigation in the sidebar.
    }
}
