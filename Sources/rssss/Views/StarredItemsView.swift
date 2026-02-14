import SwiftUI
import CoreData
import AppKit

struct StarredItemsView: View {
    @EnvironmentObject private var logStore: AppLogStore
    private let viewContext: NSManagedObjectContext
    let initialItemsLimit: Int
    let sessionToken: UUID
    let onOpenInPreview: (PreviewRequest) -> Void
    let onToggleStar: (NSManagedObjectID) -> Void

    @StateObject private var readMarker = ReadMarker(persistence: PersistenceController.shared)
    @StateObject private var itemsController: StarredItemsController
    @State private var selectedItemID: NSManagedObjectID?
    @State private var suppressReadTracking = false
    @State private var itemFrames: [NSManagedObjectID: CGRect] = [:]
    @State private var containerHeight: CGFloat = 0
    @State private var selectionChangedByKeyboard = false
    @State private var scrollProxy: ScrollViewProxy?

    init(
        initialItemsLimit: Int,
        sessionToken: UUID,
        viewContext: NSManagedObjectContext,
        onOpenInPreview: @escaping (PreviewRequest) -> Void,
        onToggleStar: @escaping (NSManagedObjectID) -> Void
    ) {
        self.initialItemsLimit = initialItemsLimit
        self.sessionToken = sessionToken
        self.viewContext = viewContext
        self.onOpenInPreview = onOpenInPreview
        self.onToggleStar = onToggleStar
        _itemsController = StateObject(
            wrappedValue: StarredItemsController(
                context: viewContext,
                initialFetchLimit: initialItemsLimit
            )
        )
    }

    var body: some View {
        let visibleItems = itemsController.items

        Group {
            if visibleItems.isEmpty {
                VStack(spacing: 14) {
                    VStack(spacing: 12) {
                        Image("RSSSSLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 56, height: 56)
                            .foregroundStyle(.secondary)
                        Text("No Starred Items")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(StarredItemsView.emptyMessage())
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if itemsController.canLoadMore {
                        Button("Load older items") {
                            loadOlderItems()
                        }
                        .buttonStyle(.bordered)
                    }
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
                                        sourceLabel: item.feed.displayName,
                                        onView: { openItem(item) },
                                        onMarkRead: { markItemRead(item) },
                                        onToggleStar: { onToggleStar(item.objectID) }
                                    )
                                    .id(item.objectID)
                                    .onTapGesture(count: 2) {
                                        selectionChangedByKeyboard = false
                                        selectedItemID = item.objectID
                                        openItem(item)
                                    }
                                    .onTapGesture {
                                        selectionChangedByKeyboard = false
                                        selectedItemID = item.objectID
                                    }
                                    .background(
                                        GeometryReader { proxy in
                                            Color.clear.preference(
                                                key: ItemFramePreferenceKey.self,
                                                value: [item.objectID: proxy.frame(in: .named("starredItemsScroll"))]
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
                        .coordinateSpace(name: "starredItemsScroll")
                        .onPreferenceChange(ItemFramePreferenceKey.self) { frames in
                            guard frames != itemFrames else { return }
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

                        if itemsController.canLoadMore {
                            Divider()
                            HStack {
                                Spacer()
                                Button("Load older items") {
                                    loadOlderItems()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                Spacer()
                            }
                            .padding(.vertical, 10)
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
            }
        }
        .task(id: sessionToken) {
            itemsController.resetFetchLimit(to: initialItemsLimit)
        }
        .onChange(of: initialItemsLimit) { _, newLimit in
            itemsController.resetFetchLimit(to: newLimit)
        }
    }

    private func loadOlderItems() {
        itemsController.loadMore()
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
        if let item = itemsController.items.first(where: { $0.objectID == objectID }), item.isEffectivelyUnread {
            item.isRead = true
            if viewContext.hasChanges {
                try? viewContext.save()
            }
        }
    }

    private func markItemRead(_ item: FeedItem) {
        guard item.isEffectivelyUnread else { return }
        item.isRead = true
        if viewContext.hasChanges {
            try? viewContext.save()
        }
    }

    private func suspendReadTracking() {
        suppressReadTracking = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            suppressReadTracking = false
        }
    }

    private func openItem(_ item: FeedItem) {
        guard let request = FeedItemsView.previewRequest(for: item) else {
            logStore.add(
                "Inline preview open failed: invalid starred item URL for \"\(item.displayTitle)\""
            )
            return
        }
        logStore.add(
            "Inline preview open requested: source=starred, feed=\(item.feed.displayName), title=\"\(request.title)\", url=\(request.url.absoluteString)"
        )
        onOpenInPreview(request)
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
            } else if key == "s" {
                guard let item = FeedItemsView.starTarget(selectedItemID: selectedItemID, items: visibleItems) else {
                    return false
                }
                onToggleStar(item.objectID)
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

extension StarredItemsView {
    static func emptyMessage() -> String {
        "Star items to keep track of them here."
    }
}
