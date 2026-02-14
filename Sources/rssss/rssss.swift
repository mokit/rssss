import SwiftUI
import AppKit

@main
struct rssssApp: App {
    @StateObject private var persistence = PersistenceController.shared
    @StateObject private var feedStore: FeedStore
    @StateObject private var settingsStore: RefreshSettingsStore
    @StateObject private var autoRefreshController: AutoRefreshController
    @StateObject private var logStore: AppLogStore
    @StateObject private var performanceMonitor: PerformanceMonitor

    private static let uiTestingFlag = "RSSSS_UI_TESTING"
    private static let uiTestingSeedFlag = "RSSSS_UI_TESTING_SEED_DATA"

    init() {
        let environment = ProcessInfo.processInfo.environment
        let isUITesting = environment[Self.uiTestingFlag] == "1"
        let shouldSeedUITestData = environment[Self.uiTestingSeedFlag] == "1"

        let persistence = isUITesting ? PersistenceController(inMemory: true) : PersistenceController.shared
        if shouldSeedUITestData {
            Self.seedUITestDataIfNeeded(in: persistence.container.viewContext)
        }
        let logStore = AppLogStore()
        let feedStore = FeedStore(persistence: persistence, logStore: logStore)
        let settingsStore = RefreshSettingsStore()
        _persistence = StateObject(wrappedValue: persistence)
        _feedStore = StateObject(wrappedValue: feedStore)
        _settingsStore = StateObject(wrappedValue: settingsStore)
        _logStore = StateObject(wrappedValue: logStore)
        _autoRefreshController = StateObject(
            wrappedValue: AutoRefreshController(feedStore: feedStore)
        )
        _performanceMonitor = StateObject(wrappedValue: PerformanceMonitor())
    }

    private static func seedUITestDataIfNeeded(in context: NSManagedObjectContext) {
        let request: NSFetchRequest<Feed> = Feed.fetchRequest()
        request.fetchLimit = 1
        if (try? context.count(for: request)) ?? 0 > 0 {
            return
        }

        let feed = Feed(context: context)
        feed.id = UUID()
        feed.url = "https://example.com/ui-testing.xml"
        feed.title = "UI Test Feed"
        feed.orderIndex = 0
        feed.lastRefreshedAt = Date()

        let item = FeedItem(context: context)
        item.id = UUID()
        item.feed = feed
        item.guid = "ui-test-item-1"
        item.link = "https://example.com/ui-test-item"
        item.title = "UI Test Item"
        item.summary = "Seeded item used for UI smoke tests."
        item.pubDate = Date()
        item.createdAt = Date()
        item.isRead = false
        item.isStarred = false

        try? context.save()
    }

    var body: some Scene {
        WindowGroup {
            if persistence.isLoaded {
                RootView(
                    persistence: persistence,
                    feedStore: feedStore,
                    settingsStore: settingsStore,
                    autoRefreshController: autoRefreshController,
                    logStore: logStore,
                    performanceMonitor: performanceMonitor
                )
            } else {
                ProgressView("Loading...")
                    .frame(minWidth: 200, minHeight: 120)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            RefreshLogsCommands()
        }

        Window("Logs", id: "refresh-logs") {
            LogsView()
                .environmentObject(logStore)
        }

        Settings {
            SettingsView()
                .environmentObject(settingsStore)
        }
    }
}

private struct RootView: View {
    let persistence: PersistenceController
    let feedStore: FeedStore
    @ObservedObject var settingsStore: RefreshSettingsStore
    let autoRefreshController: AutoRefreshController
    let logStore: AppLogStore
    let performanceMonitor: PerformanceMonitor

    var body: some View {
        ContentView(viewContext: persistence.container.viewContext)
            .environmentObject(feedStore)
            .environmentObject(settingsStore)
            .environmentObject(logStore)
            .environmentObject(performanceMonitor)
            .background(WindowChromeConfigurator().frame(width: 0, height: 0))
            .ignoresSafeArea(.container, edges: .top)
            .task {
                autoRefreshController.start(refreshIntervalMinutes: settingsStore.refreshIntervalMinutes)
                if settingsStore.monitorPerformance {
                    performanceMonitor.start()
                }
            }
            .onChange(of: settingsStore.refreshIntervalMinutes) { _, newValue in
                autoRefreshController.updateRefreshInterval(minutes: newValue)
            }
            .onChange(of: settingsStore.monitorPerformance) { _, enabled in
                if enabled {
                    performanceMonitor.start()
                } else {
                    performanceMonitor.stop()
                }
            }
            .onDisappear {
                autoRefreshController.stop()
                performanceMonitor.stop()
            }
    }
}

private struct RefreshLogsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("View") {
            Button("Show Logs") {
                openWindow(id: "refresh-logs")
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ConfigurationView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ConfigurationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }

        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
    }
}
