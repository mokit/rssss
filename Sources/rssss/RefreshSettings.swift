import Foundation
import Combine

enum RefreshSettings {
    static let refreshIntervalMinutesKey = "refreshIntervalMinutes"
    static let showLastRefreshKey = "showLastRefresh"
    static let defaultRefreshIntervalMinutes = 5
    static let defaultShowLastRefresh = true
    static let minimumRefreshIntervalMinutes = 1
    static let maximumRefreshIntervalMinutes = 60

    static func normalizedRefreshInterval(minutes: Int) -> Int {
        min(max(minutes, minimumRefreshIntervalMinutes), maximumRefreshIntervalMinutes)
    }

    static func refreshInterval(for minutes: Int) -> TimeInterval {
        TimeInterval(normalizedRefreshInterval(minutes: minutes) * 60)
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

    private let userDefaults: UserDefaults
    private let key: String
    private let showLastRefreshKey: String

    init(
        userDefaults: UserDefaults = .standard,
        key: String = RefreshSettings.refreshIntervalMinutesKey,
        showLastRefreshKey: String = RefreshSettings.showLastRefreshKey
    ) {
        self.userDefaults = userDefaults
        self.key = key
        self.showLastRefreshKey = showLastRefreshKey

        let storedValue = userDefaults.object(forKey: key) as? Int
        let initial = RefreshSettings.normalizedRefreshInterval(
            minutes: storedValue ?? RefreshSettings.defaultRefreshIntervalMinutes
        )
        refreshIntervalMinutes = initial
        if userDefaults.object(forKey: showLastRefreshKey) == nil {
            userDefaults.set(RefreshSettings.defaultShowLastRefresh, forKey: showLastRefreshKey)
        }
        showLastRefresh = userDefaults.bool(forKey: showLastRefreshKey)

        if storedValue != initial {
            userDefaults.set(initial, forKey: key)
        }
    }
}
