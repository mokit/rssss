import SwiftUI

@main
struct rssssApp: App {
    @StateObject private var persistence = PersistenceController.shared
    @StateObject private var feedStore: FeedStore
    @StateObject private var settingsStore: RefreshSettingsStore
    @StateObject private var autoRefreshController: AutoRefreshController

    init() {
        let persistence = PersistenceController.shared
        let feedStore = FeedStore(persistence: persistence)
        let settingsStore = RefreshSettingsStore()
        _persistence = StateObject(wrappedValue: persistence)
        _feedStore = StateObject(wrappedValue: feedStore)
        _settingsStore = StateObject(wrappedValue: settingsStore)
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
                    autoRefreshController: autoRefreshController
                )
            } else {
                ProgressView("Loading...")
                    .frame(minWidth: 200, minHeight: 120)
            }
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

    var body: some View {
        ContentView(viewContext: persistence.container.viewContext)
            .environmentObject(feedStore)
            .environmentObject(settingsStore)
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
