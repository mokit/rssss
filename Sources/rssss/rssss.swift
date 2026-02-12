import SwiftUI
import AppKit

@main
struct rssssApp: App {
    @StateObject private var persistence = PersistenceController.shared
    @StateObject private var feedStore: FeedStore
    @StateObject private var settingsStore: RefreshSettingsStore
    @StateObject private var autoRefreshController: AutoRefreshController
    @StateObject private var logStore: AppLogStore

    init() {
        let persistence = PersistenceController.shared
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
    }

    var body: some Scene {
        WindowGroup {
            if persistence.isLoaded {
                RootView(
                    persistence: persistence,
                    feedStore: feedStore,
                    settingsStore: settingsStore,
                    autoRefreshController: autoRefreshController,
                    logStore: logStore
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
    let settingsStore: RefreshSettingsStore
    let autoRefreshController: AutoRefreshController
    let logStore: AppLogStore

    var body: some View {
        ContentView(viewContext: persistence.container.viewContext)
            .environmentObject(feedStore)
            .environmentObject(settingsStore)
            .environmentObject(logStore)
            .background(WindowChromeConfigurator().frame(width: 0, height: 0))
            .ignoresSafeArea(.container, edges: .top)
            .task {
                autoRefreshController.start(refreshIntervalMinutes: settingsStore.refreshIntervalMinutes)
            }
            .onChange(of: settingsStore.refreshIntervalMinutes) { _, newValue in
                autoRefreshController.updateRefreshInterval(minutes: newValue)
            }
            .onDisappear {
                autoRefreshController.stop()
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
