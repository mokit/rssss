import Foundation

@MainActor
protocol FeedRefreshing: AnyObject {
    func refreshAllFeeds() async
}

extension FeedStore: FeedRefreshing {}

protocol ForegroundRefreshScheduling: AnyObject {
    func schedule(interval: TimeInterval, action: @escaping @MainActor () -> Void)
    func invalidate()
}

protocol BackgroundRefreshScheduling: AnyObject {
    func schedule(interval: TimeInterval, action: @escaping @Sendable () async -> Void)
    func invalidate()
}

final class ForegroundRefreshScheduler: ForegroundRefreshScheduling {
    private var timer: Timer?

    func schedule(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                action()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
    }
}

final class MacBackgroundRefreshScheduler: BackgroundRefreshScheduling {
    private let scheduler: NSBackgroundActivityScheduler

    init(identifier: String) {
        scheduler = NSBackgroundActivityScheduler(identifier: identifier)
    }

    func schedule(interval: TimeInterval, action: @escaping @Sendable () async -> Void) {
        scheduler.invalidate()
        scheduler.repeats = true
        scheduler.interval = interval
        scheduler.tolerance = max(30, interval * 0.2)
        scheduler.schedule { completion in
            Task {
                await action()
                completion(.finished)
            }
        }
    }

    func invalidate() {
        scheduler.invalidate()
    }
}

@MainActor
final class AutoRefreshController: ObservableObject {
    private let feedStore: FeedRefreshing
    private let foregroundScheduler: ForegroundRefreshScheduling
    private let backgroundScheduler: BackgroundRefreshScheduling

    private var isStarted = false

    init(
        feedStore: FeedRefreshing,
        foregroundScheduler: ForegroundRefreshScheduling = ForegroundRefreshScheduler(),
        backgroundScheduler: BackgroundRefreshScheduling = MacBackgroundRefreshScheduler(identifier: "be.mokit.rssss.feed-refresh")
    ) {
        self.feedStore = feedStore
        self.foregroundScheduler = foregroundScheduler
        self.backgroundScheduler = backgroundScheduler
    }

    func start(refreshIntervalMinutes: Int) {
        guard !isStarted else { return }
        isStarted = true
        reschedule(refreshIntervalMinutes: refreshIntervalMinutes)
    }

    func stop() {
        foregroundScheduler.invalidate()
        backgroundScheduler.invalidate()
        isStarted = false
    }

    func updateRefreshInterval(minutes: Int) {
        guard isStarted else { return }
        reschedule(refreshIntervalMinutes: minutes)
    }

    func performBackgroundRefresh() async {
        await feedStore.refreshAllFeeds()
    }

    private func reschedule(refreshIntervalMinutes: Int) {
        let interval = RefreshSettings.refreshInterval(for: refreshIntervalMinutes)

        foregroundScheduler.schedule(interval: interval) { [weak self] in
            guard let self else { return }
            Task {
                await self.feedStore.refreshAllFeeds()
            }
        }

        backgroundScheduler.schedule(interval: interval) { [weak self] in
            guard let self else { return }
            await self.performBackgroundRefresh()
        }
    }

    deinit {
        foregroundScheduler.invalidate()
        backgroundScheduler.invalidate()
    }
}
