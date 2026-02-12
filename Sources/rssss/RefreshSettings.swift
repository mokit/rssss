import Foundation
import Combine

enum RefreshSettings {
    static let refreshIntervalMinutesKey = "refreshIntervalMinutes"
    static let showLastRefreshKey = "showLastRefresh"
    static let initialFeedItemsLimitKey = "initialFeedItemsLimit"
    static let lastRoundRobinFeedURLKey = "lastRoundRobinFeedURL"
    static let defaultRefreshIntervalMinutes = 5
    static let defaultShowLastRefresh = true
    static let monitorPerformanceKey = "monitorPerformance"
    static let defaultMonitorPerformance = false
    static let minimumRefreshIntervalMinutes = 1
    static let maximumRefreshIntervalMinutes = 60
    static let defaultInitialFeedItemsLimit = 300
    static let minimumInitialFeedItemsLimit = 100
    static let maximumInitialFeedItemsLimit = 2000

    static func normalizedRefreshInterval(minutes: Int) -> Int {
        min(max(minutes, minimumRefreshIntervalMinutes), maximumRefreshIntervalMinutes)
    }

    static func refreshInterval(for minutes: Int) -> TimeInterval {
        TimeInterval(normalizedRefreshInterval(minutes: minutes) * 60)
    }

    static func normalizedInitialFeedItemsLimit(_ limit: Int) -> Int {
        min(max(limit, minimumInitialFeedItemsLimit), maximumInitialFeedItemsLimit)
    }
}

@MainActor
final class RefreshSettingsStore: ObservableObject {
    @Published var refreshIntervalMinutes: Int {
        didSet {
            let normalized = RefreshSettings.normalizedRefreshInterval(minutes: refreshIntervalMinutes)
            if normalized != refreshIntervalMinutes {
                refreshIntervalMinutes = normalized
                return
            }
            userDefaults.set(normalized, forKey: key)
        }
    }
    @Published var showLastRefresh: Bool {
        didSet {
            userDefaults.set(showLastRefresh, forKey: showLastRefreshKey)
        }
    }
    @Published var initialFeedItemsLimit: Int {
        didSet {
            let normalized = RefreshSettings.normalizedInitialFeedItemsLimit(initialFeedItemsLimit)
            if normalized != initialFeedItemsLimit {
                initialFeedItemsLimit = normalized
                return
            }
            userDefaults.set(normalized, forKey: initialFeedItemsLimitKey)
        }
    }
    @Published var monitorPerformance: Bool {
        didSet {
            userDefaults.set(monitorPerformance, forKey: monitorPerformanceKey)
        }
    }

    private let userDefaults: UserDefaults
    private let key: String
    private let showLastRefreshKey: String
    private let initialFeedItemsLimitKey: String
    private let monitorPerformanceKey: String

    init(
        userDefaults: UserDefaults = .standard,
        key: String = RefreshSettings.refreshIntervalMinutesKey,
        showLastRefreshKey: String = RefreshSettings.showLastRefreshKey,
        initialFeedItemsLimitKey: String = RefreshSettings.initialFeedItemsLimitKey,
        monitorPerformanceKey: String = RefreshSettings.monitorPerformanceKey
    ) {
        self.userDefaults = userDefaults
        self.key = key
        self.showLastRefreshKey = showLastRefreshKey
        self.initialFeedItemsLimitKey = initialFeedItemsLimitKey
        self.monitorPerformanceKey = monitorPerformanceKey

        let storedValue = userDefaults.object(forKey: key) as? Int
        let initial = RefreshSettings.normalizedRefreshInterval(
            minutes: storedValue ?? RefreshSettings.defaultRefreshIntervalMinutes
        )
        let storedInitialFeedItemsLimit = userDefaults.object(forKey: initialFeedItemsLimitKey) as? Int
        let initialFeedItemsLimitValue = RefreshSettings.normalizedInitialFeedItemsLimit(
            storedInitialFeedItemsLimit ?? RefreshSettings.defaultInitialFeedItemsLimit
        )

        refreshIntervalMinutes = initial
        initialFeedItemsLimit = initialFeedItemsLimitValue

        if userDefaults.object(forKey: showLastRefreshKey) == nil {
            userDefaults.set(RefreshSettings.defaultShowLastRefresh, forKey: showLastRefreshKey)
        }
        showLastRefresh = userDefaults.bool(forKey: showLastRefreshKey)

        if userDefaults.object(forKey: monitorPerformanceKey) == nil {
            userDefaults.set(RefreshSettings.defaultMonitorPerformance, forKey: monitorPerformanceKey)
        }
        monitorPerformance = userDefaults.bool(forKey: monitorPerformanceKey)

        if storedValue != initial {
            userDefaults.set(initial, forKey: key)
        }
        if storedInitialFeedItemsLimit != initialFeedItemsLimitValue {
            userDefaults.set(initialFeedItemsLimitValue, forKey: initialFeedItemsLimitKey)
        }
    }
}
