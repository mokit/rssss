import SwiftUI
import CoreData
import AppKit

struct FeedItemsView: View {
    private let viewContext: NSManagedObjectContext
    let feedObjectID: NSManagedObjectID
    let showRead: Bool
    let sessionToken: UUID

    @StateObject private var readMarker = ReadMarker(persistence: PersistenceController.shared)
    @StateObject private var itemsController: FeedItemsController
    @State private var sessionUnreadIDs: Set<NSManagedObjectID> = []
    @State private var selectedItemID: NSManagedObjectID?
    @State private var suppressReadTracking = false
    @State private var itemFrames: [NSManagedObjectID: CGRect] = [:]
    @State private var containerHeight: CGFloat = 0
    @State private var selectionChangedByKeyboard = false
    @State private var scrollProxy: ScrollViewProxy?

    init(feedObjectID: NSManagedObjectID, showRead: Bool, sessionToken: UUID, viewContext: NSManagedObjectContext) {
        self.feedObjectID = feedObjectID
        self.showRead = showRead
        self.sessionToken = sessionToken
        self.viewContext = viewContext
        _itemsController = StateObject(wrappedValue: FeedItemsController(context: viewContext, feedObjectID: feedObjectID))
    }

    var body: some View {
        let visibleItems = filteredItems(from: itemsController.items)

        if visibleItems.isEmpty {
            VStack(spacing: 12) {
                Image("RSSSSLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .foregroundStyle(.secondary)
                Text("No Items")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(FeedItemsView.emptyMessage(showRead: showRead))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(visibleItems, id: \.objectID) { item in
                                ItemRowView(
                                    item: item,
                                    isSelected: item.objectID == selectedItemID,
                                    onView: { openItem(item) }
                                )
                                    .id(item.objectID)
                                    .onTapGesture {
                                        selectionChangedByKeyboard = false
                                        selectedItemID = item.objectID
                                    }
                                    .background(
                                        GeometryReader { proxy in
                                            Color.clear.preference(
                                                key: ItemFramePreferenceKey.self,
                                                value: [item.objectID: proxy.frame(in: .named("itemsScroll"))]
                                            )
                                        }
                                    )
                                Divider()
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { containerHeight = proxy.size.height }
                                .onChange(of: proxy.size.height) { _, newValue in
                                    containerHeight = newValue
                                }
                        }
                    )
                    .coordinateSpace(name: "itemsScroll")
                    .onPreferenceChange(ItemFramePreferenceKey.self) { frames in
                        itemFrames = frames
                        guard !suppressReadTracking else { return }
                        let ids = ReadTracker.itemsToMarkRead(itemFrames: frames, containerMinY: 0)
                        readMarker.queue(ids)
                    }
                    .onChange(of: selectedItemID) { _, _ in
                        guard selectionChangedByKeyboard else { return }
                        ensureSelectionVisibility(in: visibleItems, proxy: proxy)
                        selectionChangedByKeyboard = false
                    }
                }
                .onAppear {
                    scrollProxy = proxy
                }
                .background(
                    KeyMonitorView { event in
                        handleKey(event, visibleItems: visibleItems)
                    }
                )
            }
            
        .task(id: sessionToken) {
                sessionUnreadIDs = Set(itemsController.items.filter { !$0.isRead }.map { $0.objectID })
            }
            .onChange(of: itemsController.items.map { $0.objectID }) { _, _ in
                sessionUnreadIDs.formUnion(itemsController.items.filter { !$0.isRead }.map { $0.objectID })
            }
        }
    }

    private func filteredItems(from items: [FeedItem]) -> [FeedItem] {
        FeedItemsView.filteredItems(items: items, showRead: showRead, sessionUnreadIDs: sessionUnreadIDs)
    }

    private func moveSelection(in items: [FeedItem], delta: Int) {
        suspendReadTracking()
        guard !items.isEmpty else {
            selectedItemID = nil
            return
        }
        guard let currentID = selectedItemID else {
            let firstIndex = FeedItemsView.nextSelectionIndex(currentIndex: nil, itemCount: items.count, delta: delta)
            let firstID = firstIndex.flatMap { items[$0].objectID }
            selectedItemID = firstID
            if let firstID, let proxy = scrollProxy {
                proxy.scrollTo(firstID, anchor: .top)
            }
            return
        }

        markReadOnNavigate(from: currentID)
        guard let currentIndex = items.firstIndex(where: { $0.objectID == currentID }) else {
            selectionChangedByKeyboard = true
            selectedItemID = items.first?.objectID
            return
        }
        let nextIndex = FeedItemsView.nextSelectionIndex(currentIndex: currentIndex, itemCount: items.count, delta: delta) ?? currentIndex
        selectionChangedByKeyboard = true
        selectedItemID = items[nextIndex].objectID
    }

    private func markReadOnNavigate(from objectID: NSManagedObjectID) {
        if let item = itemsController.items.first(where: { $0.objectID == objectID }), !item.isRead {
            item.isRead = true
            if viewContext.hasChanges {
                try? viewContext.save()
            }
        }
        readMarker.queue([objectID])
    }

    private func suspendReadTracking() {
        suppressReadTracking = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            suppressReadTracking = false
        }
    }

    private func openItem(_ item: FeedItem) {
        guard let link = item.link, let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    private func ensureSelectionVisibility(in items: [FeedItem], proxy: ScrollViewProxy) {
        guard let selectedItemID else { return }
        guard let selectedFrame = itemFrames[selectedItemID] else {
            proxy.scrollTo(selectedItemID, anchor: .center)
            return
        }

        if let selectedIndex = items.firstIndex(where: { $0.objectID == selectedItemID }) {
            let nextIndex = selectedIndex + 1
            let nextFrame = nextIndex < items.count ? itemFrames[items[nextIndex].objectID] : nil
            if let anchor = FeedItemsView.anchorToRevealSelection(
                selectedFrame: selectedFrame,
                nextFrame: nextFrame,
                containerHeight: containerHeight
            ) {
                proxy.scrollTo(selectedItemID, anchor: anchor)
            }
            return
        }

        if let anchor = FeedItemsView.anchorToRevealSelection(
            selectedFrame: selectedFrame,
            nextFrame: nil,
            containerHeight: containerHeight
        ) {
            proxy.scrollTo(selectedItemID, anchor: anchor)
        }
    }

    private func handleKey(_ event: NSEvent, visibleItems: [FeedItem]) -> Bool {
        guard shouldHandleKey(event) else { return false }
        switch event.keyCode {
        case 126: // up arrow
            moveSelection(in: visibleItems, delta: -1)
            return true
        case 125: // down arrow
            moveSelection(in: visibleItems, delta: 1)
            return true
        default:
            let key = event.charactersIgnoringModifiers?.lowercased()
            if key == "k" {
                moveSelection(in: visibleItems, delta: -1)
                return true
            } else if key == "j" {
                moveSelection(in: visibleItems, delta: 1)
                return true
            } else if key == "o" {
                guard let item = FeedItemsView.openTarget(selectedItemID: selectedItemID, items: visibleItems) else {
                    return false
                }
                openItem(item)
                return true
            }
            return false
        }
    }

    private func shouldHandleKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty == false {
            return false
        }
        if let responder = NSApp.keyWindow?.firstResponder {
            if responder is NSTextView || responder is NSTextField || responder is NSSearchField {
                return false
            }
        }
        return true
    }
}

extension FeedItemsView {
    static func itemIdentity(_ item: FeedItem) -> NSManagedObjectID {
        item.objectID
    }

    static func emptyMessage(showRead: Bool) -> String {
        showRead ? "This feed has no items." : "No unread items. Toggle Show Read to see older items."
    }

    static func filteredItems(items: [FeedItem], showRead: Bool, sessionUnreadIDs: Set<NSManagedObjectID>) -> [FeedItem] {
        if showRead {
            return items
        }
        return items.filter { item in
            !item.isRead || sessionUnreadIDs.contains(item.objectID)
        }
    }

    static func nextSelectionIndex(currentIndex: Int?, itemCount: Int, delta: Int) -> Int? {
        guard itemCount > 0 else { return nil }
        guard let currentIndex else { return 0 }
        return max(0, min(itemCount - 1, currentIndex + delta))
    }

    static func openTarget(selectedItemID: NSManagedObjectID?, items: [FeedItem]) -> FeedItem? {
        guard let selectedItemID else { return nil }
        return items.first(where: { $0.objectID == selectedItemID })
    }

    static func anchorToRevealSelection(selectedFrame: CGRect, nextFrame: CGRect?, containerHeight: CGFloat) -> UnitPoint? {
        if selectedFrame.minY < 0 {
            return .top
        }

        let nextHeight = nextFrame?.height ?? selectedFrame.height
        let threshold = containerHeight - nextHeight
        if selectedFrame.maxY > threshold {
            return .bottom
        }

        return nil
    }
}

private struct KeyMonitorView: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onKeyDown: onKeyDown)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onKeyDown = onKeyDown
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator {
        var onKeyDown: (NSEvent) -> Bool
        private var monitor: Any?

        init(onKeyDown: @escaping (NSEvent) -> Bool) {
            self.onKeyDown = onKeyDown
        }

        func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.onKeyDown(event) ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}
