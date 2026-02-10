import SwiftUI

@main
struct rssssApp: App {
    @StateObject private var persistence = PersistenceController.shared
    @StateObject private var feedStore: FeedStore

    init() {
        let persistence = PersistenceController.shared
        _persistence = StateObject(wrappedValue: persistence)
        _feedStore = StateObject(wrappedValue: FeedStore(persistence: persistence))
    }

    var body: some Scene {
        WindowGroup {
            if persistence.isLoaded {
                RootView(persistence: persistence, feedStore: feedStore)
            } else {
                ProgressView("Loading...")
                    .frame(minWidth: 200, minHeight: 120)
            }
        }
    }
}

private struct RootView: View {
    let persistence: PersistenceController
    let feedStore: FeedStore

    var body: some View {
        ContentView(viewContext: persistence.container.viewContext)
            .environmentObject(feedStore)
    }
}
