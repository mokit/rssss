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
            ContentView()
                .environment(\.managedObjectContext, persistence.container.viewContext)
                .environmentObject(feedStore)
        }
    }
}
