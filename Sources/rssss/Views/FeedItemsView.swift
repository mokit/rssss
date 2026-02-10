import SwiftUI
import CoreData
import AppKit

struct FeedItemsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    let feedID: UUID
    let showRead: Bool
    let sessionToken: UUID

    @StateObject private var readMarker = ReadMarker(persistence: PersistenceController.shared)
    @State private var sessionUnreadIDs: Set<NSManagedObjectID> = []
    @State private var selectedItemID: NSManagedObjectID?
    @State private var suppressReadTracking = false
    @State private var itemFrames: [NSManagedObjectID: CGRect] = [:]
    @State private var containerHeight: CGFloat = 0
    @State private var selectionChangedByKeyboard = false
    @State private var scrollProxy: ScrollViewProxy?

    @FetchRequest private var items: FetchedResults<FeedItem>

    init(feedID: UUID, showRead: Bool, sessionToken: UUID) {
        self.feedID = feedID
        self.showRead = showRead
        self.sessionToken = sessionToken

        let predicate = NSPredicate(format: "feed.id == %@", feedID as CVarArg)

        _items = FetchRequest(
            sortDescriptors: [
                NSSortDescriptor(keyPath: \FeedItem.pubDate, ascending: false),
                NSSortDescriptor(keyPath: \FeedItem.createdAt, ascending: false)
            ],
            predicate: predicate,
            animation: .default
        )
    }

    var body: some View {
        let visibleItems = filteredItems()

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
                Text(showRead ? "This feed has no items." : "No unread items. Toggle Show Read to see older items.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(visibleItems) { item in
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
                    KeyCaptureView { event in
                        handleKey(event, visibleItems: visibleItems)
                    }
                )
            }
            
        .task(id: sessionToken) {
                sessionUnreadIDs = Set(items.filter { !$0.isRead }.map { $0.objectID })
            }
            .onChange(of: items.map { $0.objectID }) { _, _ in
                sessionUnreadIDs.formUnion(items.filter { !$0.isRead }.map { $0.objectID })
            }
        }
    }

    private func filteredItems() -> [FeedItem] {
        if showRead {
            return Array(items)
        }
        return items.filter { item in
            !item.isRead || sessionUnreadIDs.contains(item.objectID)
        }
    }

    private func moveSelection(in items: [FeedItem], delta: Int) {
        suspendReadTracking()
        guard !items.isEmpty else {
            selectedItemID = nil
            return
        }
        guard let currentID = selectedItemID else {
            let firstID = items.first?.objectID
            selectedItemID = firstID
            if let firstID, let proxy = scrollProxy {
                proxy.scrollTo(firstID, anchor: .top)
            }
            return
        }

        if ensureCurrentSelectionVisibility() {
            return
        }

        markReadOnNavigate(from: currentID)
        guard let currentIndex = items.firstIndex(where: { $0.objectID == currentID }) else {
            selectionChangedByKeyboard = true
            selectedItemID = items.first?.objectID
            return
        }
        let nextIndex = max(0, min(items.count - 1, currentIndex + delta))
        selectionChangedByKeyboard = true
        selectedItemID = items[nextIndex].objectID
    }

    private func markReadOnNavigate(from objectID: NSManagedObjectID) {
        if let item = items.first(where: { $0.objectID == objectID }), !item.isRead {
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
        guard let selectedFrame = itemFrames[selectedItemID] else { return }

        if selectedFrame.minY < 0 {
            proxy.scrollTo(selectedItemID, anchor: .top)
            return
        }

        guard let selectedIndex = items.firstIndex(where: { $0.objectID == selectedItemID }) else { return }
        let nextIndex = selectedIndex + 1
        guard nextIndex < items.count else { return }
        let nextID = items[nextIndex].objectID
        let nextFrame = itemFrames[nextID] ?? CGRect(x: 0, y: selectedFrame.maxY, width: 0, height: selectedFrame.height)
        let threshold = containerHeight - nextFrame.height
        if selectedFrame.maxY > threshold {
            proxy.scrollTo(nextID, anchor: .bottom)
        }
    }

    private func ensureCurrentSelectionVisibility() -> Bool {
        guard let proxy = scrollProxy else { return false }
        guard let selectedItemID else { return false }
        guard let selectedFrame = itemFrames[selectedItemID] else { return false }
        if selectedFrame.minY < 0 {
            proxy.scrollTo(selectedItemID, anchor: .top)
            return true
        }
        let threshold = containerHeight - selectedFrame.height
        if selectedFrame.maxY > threshold {
            proxy.scrollTo(selectedItemID, anchor: .bottom)
            return true
        }
        return false
    }

    private func handleKey(_ event: NSEvent, visibleItems: [FeedItem]) {
        switch event.keyCode {
        case 126: // up arrow
            moveSelection(in: visibleItems, delta: -1)
        case 125: // down arrow
            moveSelection(in: visibleItems, delta: 1)
        default:
            let key = event.charactersIgnoringModifiers?.lowercased()
            if key == "k" {
                moveSelection(in: visibleItems, delta: -1)
            } else if key == "j" {
                moveSelection(in: visibleItems, delta: 1)
            }
        }
    }
}

private struct KeyCaptureView: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onKeyDown = onKeyDown
        view.focusRingType = .none
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onKeyDown = onKeyDown
        if nsView.window?.firstResponder !== nsView {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

private final class KeyCaptureNSView: NSView {
    var onKeyDown: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        onKeyDown?(event)
    }
}
